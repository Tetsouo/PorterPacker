---============================================================================
--- PorterPacker / lib/packets.lua
---============================================================================
--- All FFXI packet handling: porter dialog state machine, the `events` map,
--- packet event registration, find_npc, trade_npc, find_porter_items,
--- wait_for_trades.
---
--- This module DEPENDS on flow.lua at runtime (the 0x052 handler chains to
--- porter_trade in non-continuous mode) but does NOT require it directly to
--- avoid circular import. flow.lua sets `M.porter_trade_callback` after load.
---============================================================================

local Config = require('lib/config')
local State  = require('lib/state')
local Debug  = require('lib/debug')
local Inv    = require('lib/inventory')
local Msg    = require('messages')

local M = {}

-- Set by flow.lua after load to break circular dep. Called from 0x052 handler
-- in non-continuous mode to chain to the next single-slip trade.
M.porter_trade_callback = nil

-- ===========================================================================
-- NPC + trade primitives
-- ===========================================================================

--- Locate a nearby NPC by name, validating range and type.
--- @return table|nil NPC mob record, or nil with an error message printed
function M.find_npc(name)
    local npc = windower.ffxi.get_mob_by_name(name)
    if npc and math.sqrt(npc.distance) < 6 and npc.valid_target and npc.is_npc
        and bit.band(npc.spawn_type, 0xDF) == 2 then
        return npc
    end
    Msg.error(('%s is not in range'):format(name))
    return nil
end

--- Inject a trade packet (0x36) to the given NPC with up to 8 items.
--- Sets State.packet_state to 1 on success.
--- @param npc table NPC mob record from find_npc
--- @param items table Array of item objects {id, slot, count}
function M.trade_npc(npc, items)
    local str = ('I2'):pack(0, npc.id)
    for x = 1, 8 do
        str = str .. ('I'):pack(items[x] and items[x].count or 0)
    end
    str = str .. ('I2'):pack(0, 0)
    for x = 1, 8 do
        str = str .. ('C'):pack(items[x] and items[x].slot or 0)
    end
    str = str .. ('C2HI'):pack(0, 0, npc.index, #items > 8 and 8 or #items)

    if State.debug_enabled then
        local now = os.clock()
        local gap = State.last_trade_clock > 0 and (now - State.last_trade_clock) or 0
        local first_id = items[1] and items[1].id or 0
        local same_slip = (first_id == State.last_trade_slip_id)
        local flag = ''
        if gap > 0 and gap < 0.5 then flag = flag .. ' [FAST<0.5s]' end
        if same_slip then flag = flag .. ' [REPEAT]' end
        Debug.log(('trade #%d items, slip_id=%d, gap=%.2fs%s'):format(
            #items, first_id, gap, flag))
        State.last_trade_clock   = now
        State.last_trade_slip_id = first_id
    end

    State.async_trade_attempts = State.async_trade_attempts + 1
    windower.packets.inject_outgoing(0x36, str)
    State.packet_state = 1
end

--- Block until the packet state machine returns to 0 (or timeout).
--- Bumps async_trade_successes on success. Logs a `!! TIMEOUT` line otherwise.
function M.wait_for_trades()
    local start_state = State.packet_state
    local start_clock = os.clock()
    local poll = 0
    State.last_trade_confirmed = false
    -- 5s timeout (200 polls @ 25ms)
    while State.packet_state ~= 0 and poll < 200 do
        coroutine.sleep(0.025)
        poll = poll + 1
    end
    if State.packet_state ~= 0 then
        Debug.log(('!! TIMEOUT %.2fs state=%d (started at %d) - server stuck'):format(
            os.clock() - start_clock, State.packet_state, start_state))
    else
        State.async_trade_successes = State.async_trade_successes + 1
        coroutine.sleep(0.3)  -- settle for tail packets
    end
end

-- ===========================================================================
-- Porter dialog: scanning bags for slips/items
-- ===========================================================================

--- Find storage slips and the items they can store in the given bags.
--- Items are filtered by State.store (when packing) and excluded if already
--- in retrieve list. Returns slip_id -> array of items (slip itself at [1]).
function M.find_porter_items(bags)
    local slip_tables = {}
    local item_filter = table.length(State.store) > 0 and State.store
    for _, bag in ipairs(bags) do
        for _, item in ipairs(windower.ffxi.get_items(bag)) do
            if item.id ~= 0 and item.status == 0 then
                local slip_id = slips.get_slip_id_by_item_id(item.id)
                if slip_id and not slips.player_has_item(item.id)
                    and (not item_filter or item_filter[item.id])
                    and not State.retrieve[item.id]
                    and not State.original_retrieve[item.id]
                    and (slip_id ~= slips.storages[13] and item.extdata:byte(1) ~= 2
                         or item.extdata:byte(2)%0x80 >= 0x40 and item.extdata:byte(12) >= 0x80) then
                    slip_tables[slip_id] = slip_tables[slip_id] or {}
                    slip_tables[slip_id][#slip_tables[slip_id]+1] = item
                elseif slips.items[item.id] then
                    -- This item IS a slip: store at index 1
                    slip_tables[item.id] = slip_tables[item.id] or {}
                    table.insert(slip_tables[item.id], 1, item)
                end
            end
        end
    end
    return slip_tables
end

-- ===========================================================================
-- Porter menu state machine handlers
-- ===========================================================================

--- Send a menu option selection back to the NPC.
local function inject_option(npc_id, npc_index, zone_id, menu_id, option_index, bool)
    windower.packets.inject_outgoing(0x5B,
        ('I3H4'):pack(0, npc_id, option_index, npc_index, bool, zone_id, menu_id))
    return true
end

--- Handle the "store items" porter menu (legacy, rarely fires in modern FFXI).
local function porter_store(data)
    if data:byte(0x0C+1) == 0 then
        return data:sub(0x00+1, 0x07+1) .. string.char(1, 0, 0, 0, 1) .. data:sub(0x0D+1)
    end
    return false
end

--- Handle the "retrieve items" porter menu: scan stored items, select any
--- matching State.retrieve, send close when done.
local function porter_retrieve(data, update, zone_id, menu_id)
    local npc_id      = data:unpack('I', 0x04+1)
    local npc_index   = data:unpack('H', 0x28+1)
    local slip_number = data:unpack('I', 0x24+1) + 1

    -- Sanity check: slip_number must point to a valid slip definition
    local slip_storage_id = slips.storages[slip_number]
    local slip_item_table = slip_storage_id and slips.items[slip_storage_id]
    if not slip_item_table then
        Debug.log(('!! porter_retrieve ABORT: invalid slip_number=%d'):format(slip_number))
        State.packet_state = 3
        return inject_option(npc_id, npc_index, zone_id, menu_id, 0x40000000, 0)
    end

    if Inv.space_available(0) ~= 0 then
        local option_index = 0
        local stored_items = update and update:sub(0x04+1, 0x1B+1)
            or data:sub(0x08+1, 0x1F+1)
        for bit_position = 0, 191 do
            if stored_items:unpack('b', math.floor(bit_position/8)+1, bit_position%8+1) == 1 then
                local item_id = slip_item_table[bit_position+1]
                if item_id and State.retrieve[item_id] and Inv.space_available(0) ~= 0 then
                    if update and bit_position == update:unpack('I', 0x2A+1) then
                        State.retrieve[item_id] = nil
                        State.async_current_slip_items = State.async_current_slip_items + 1
                    else
                        return inject_option(npc_id, npc_index, zone_id, menu_id, option_index, 1)
                    end
                end
                option_index = option_index + 1
            end
        end
    end
    State.packet_state = 3
    return inject_option(npc_id, npc_index, zone_id, menu_id, 0x40000000, 0)
end

-- Build zone_id -> menu_id -> handler map.
local events = {}
for zone_id, menu_id in pairs(Config.zones) do
    events[zone_id] = {
        [menu_id-1] = porter_store,
        [menu_id]   = porter_retrieve,
    }
end

--- Dispatch an incoming porter dialog packet to porter_store/porter_retrieve.
local function check_event(data, update)
    local zone_id, menu_id = data:unpack('H2', 0x2A+1)
    if events[zone_id] and events[zone_id][menu_id] then
        if update and update == State.last_update then
            return true
        end
        State.packet_state = 2
        State.last_update = update
        return events[zone_id][menu_id](data, update, zone_id, menu_id)
    end
    return false
end

--- Handle explicit menu cancel: send close, full state reset.
local function release_event(data, release)
    local zone_id, menu_id = data:unpack('H2', 0x2A+1)
    if menu_id == release:unpack('H', 0x05+1) then
        local npc_id    = data:unpack('I', 0x04+1)
        local npc_index = data:unpack('H', 0x28+1)
        inject_option(npc_id, npc_index, zone_id, menu_id, 0x40000000, 0)
        State.packet_state  = 0
        State.last_update   = nil
        State.retrieve      = {}
        State.store         = {}
        State.storing_items = false
    end
end

-- ===========================================================================
-- Event registrations
-- ===========================================================================

windower.register_event('incoming chunk', function(id, data, modified, injected, blocked)
    if id == 0x034 and State.packet_state == 1 then
        return check_event(data)
    elseif id == 0x05C and State.packet_state == 2 then
        check_event(windower.packets.last_incoming(0x34), data)
    elseif id == 0x052 and State.packet_state ~= 0 then
        if State.packet_state == 3 then
            -- Final menu close from server (matches our 0x40000000 sent earlier)
            State.packet_state = 0
            State.last_update = nil
            State.last_trade_confirmed = true
            -- Chain to next slip in non-continuous (single-slip) mode
            if not State.continuous and M.porter_trade_callback then
                M.porter_trade_callback()
            end
        elseif State.packet_state == 2 and data:byte(0x04+1) == 2 then
            -- Only byte4=2 = explicit cancel = release. byte4=1 during state==2
            -- is an intermediate sub-menu close; ignoring it (state stays at 2)
            -- lets porter_retrieve continue processing 0x05C updates.
            release_event(windower.packets.last_incoming(0x34), data)
        end
    end
end)

windower.register_event('outgoing chunk', function(id, data, modified, injected, blocked)
    if id == 0x05B and State.packet_state ~= 0 and not injected then
        -- Manual user click during an active op: log and treat like our close
        Debug.log(('!! MANUAL 0x5B click during op (state=%d) - user touched UI'):format(State.packet_state))
        State.packet_state = 3
    end
end)

windower.register_event('incoming text', function(original, modified, mode)
    -- Strip "wait for Enter" markers during porter ops to auto-advance dialogs.
    local active = State.packet_state ~= 0
        or State.storing_items
        or (State.retrieve and next(State.retrieve) ~= nil)
    if active and (mode == 150 or mode == 151) then
        modified = modified:gsub(string.char(0x7F, 0x31), '')
    end
    return modified
end)

return M
