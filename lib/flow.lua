---============================================================================
--- PorterPacker / lib/flow.lua
---============================================================================
--- Trade orchestration: porter_trade (single-slip async, used outside
--- continuous mode) and continuous_porter (the big sequential loop driven
--- by `all` flag).
---
--- Both functions consume State.retrieve / State.store / State.storing_items
--- and update them as they progress. Trade attempts and successes are tracked
--- in State.async_trade_attempts / async_trade_successes for bulk-mode stall
--- detection.
---============================================================================

local Config  = require('lib/config')
local State   = require('lib/state')
local Debug   = require('lib/debug')
local Inv     = require('lib/inventory')
local Packets = require('lib/packets')
local Msg     = require('messages')

local M = {}

-- ===========================================================================
-- Single-slip async flow (used when `all` flag NOT set)
-- ===========================================================================

--- Find next slip to process and trade it. Re-entered by 0x052 handler after
--- each completed slip until both `store` and `retrieve` lists are exhausted.
function M.porter_trade()
    -- Flush previous slip's per-slip summary (called between slips, async)
    if State.async_current_slip_num then
        if State.async_operation == 'pack' then
            Msg.stored(State.async_current_slip_items, State.async_current_slip_num)
            State.async_total_items = State.async_total_items + State.async_current_slip_items
        elseif State.async_operation == 'unpack' then
            Msg.retrieved(State.async_current_slip_items, State.async_current_slip_num)
            State.async_total_items = State.async_total_items + State.async_current_slip_items
        end
        State.async_total_slips = State.async_total_slips + 1
        State.async_current_slip_num = nil
        State.async_current_slip_items = 0
    end

    local npc = Packets.find_npc('Porter Moogle')
    if not npc then
        State.retrieve = {}
        State.store = {}
        State.storing_items = false
        return
    end

    -- Pack: find a slip+items in inventory and trade it
    if State.storing_items then
        for slip_id, items in pairs(Packets.find_porter_items({0})) do
            if #items > 1 and items[1].id == slip_id then
                local slip_num = slips.get_slip_number_by_id(slip_id)
                local item_count = #items - 1  -- minus the slip itself
                State.async_operation = 'pack'
                State.async_current_slip_num = slip_num
                State.async_current_slip_items = item_count
                Msg.progress('Packing', slip_num, item_count)
                return Packets.trade_npc(npc, items)
            end
        end
        State.store = {}
        State.storing_items = false
    end

    -- Unpack: find the next slip whose items contain something we need
    if table.length(State.retrieve) ~= 0 and Inv.space_available(0) ~= 0 then
        for slip_id, items in pairs(slips.get_player_items()) do
            if items.n ~= 0 then
                for _, item_id in ipairs(items) do
                    if State.retrieve[item_id]
                        and not Inv.find_item(slips.default_storages, item_id, 1) then
                        local slip_item = Inv.find_item({slips.default_storages[1]}, slip_id, 1)
                        if slip_item then
                            local slip_num = slips.get_slip_number_by_id(slip_id)
                            State.async_operation = 'unpack'
                            State.async_current_slip_num = slip_num
                            State.async_current_slip_items = 0
                            Msg.progress('Retrieving from', slip_num, nil)
                            return Packets.trade_npc(npc, {slip_item})
                        end
                    end
                end
            end
        end
    end

    -- Nothing more to process: print summary and return slips
    if State.async_total_slips > 0 then
        local verb = (State.async_operation == 'pack') and 'Packed' or 'Retrieved'
        Msg.summary(verb, State.async_total_items, State.async_total_slips)
        local returned = Inv.return_slips_to_home()
        if returned > 0 then
            Msg.info(('Returned %d storage slip(s) to satchel'):format(returned))
        end
        Msg.completed()
    end
    State.async_operation = nil
    State.async_current_slip_num = nil
    State.async_current_slip_items = 0
    State.async_total_items = 0
    State.async_total_slips = 0
    State.retrieve = {}
end

-- Wire packets.lua's 0x052 handler to call back into porter_trade for chaining
-- single-slip operations. Done via callback to avoid circular require().
Packets.porter_trade_callback = M.porter_trade

-- ===========================================================================
-- Continuous (bulk per-job) flow - used when `all` flag is set
-- ===========================================================================

--- Run a complete pack and/or unpack sequence for the current State.store /
--- State.retrieve until exhausted or a network deadlock is detected.
function M.continuous_porter()
    local npc = Packets.find_npc('Porter Moogle')
    if not npc then
        State.retrieve = {}
        State.store = {}
        State.storing_items = false
        return
    end

    -- Snapshot which bag each slip came from (used to return slips home).
    local Satchel_Slip_table = Packets.find_porter_items({5})
    local Sack_Slip_table    = Packets.find_porter_items({6})
    local Case_Slip_table    = Packets.find_porter_items({7})

    -- Snapshot the retrieve list so we can recover from missing slips later.
    State.original_retrieve = {}
    for k, v in pairs(State.retrieve) do
        State.original_retrieve[k] = v
    end

    -- All_Table = items in any equippable bag matching the store filter,
    -- grouped by slip_id with the slip itself at index 1.
    local All_Table = Packets.find_porter_items(Config.equippable_bags)

    -- ---------------------------------------------------------------
    -- PACK phase
    -- ---------------------------------------------------------------
    local pack_total_items   = 0
    local pack_total_slips   = 0
    local pack_consec_fails  = 0  -- network deadlock detector

    if State.storing_items then
        local action = true
        local pass = 1
        while action do
            action = false
            for slip_id, items in pairs(All_Table) do
                if #items > 1 and items[1].id == slip_id then
                    -- Move slip + items into inventory if needed
                    if Inv.space_available(0) ~= 0 then
                        Inv.retrieve_items(items, Config.equippable_bags)
                        coroutine.sleep(0.15)
                    end
                    -- Trade everything in inventory that forms a complete slip+items group
                    for slip_id2, items2 in pairs(Packets.find_porter_items({0})) do
                        if #items2 > 1 and items2[1].id == slip_id2 then
                            -- Re-check NPC range (player may have moved)
                            npc = Packets.find_npc('Porter Moogle')
                            if not npc then
                                State.retrieve = {}
                                State.store = {}
                                State.storing_items = false
                                return
                            end
                            local slip_num = slips.get_slip_number_by_id(slip_id2)
                            local item_count = #items2 - 1  -- minus slip itself
                            Msg.progress('Packing', slip_num, item_count)
                            Packets.trade_npc(npc, items2)
                            Packets.wait_for_trades()

                            -- Detect failed trade: state stuck at non-zero means
                            -- the server never acked. Don't loop on it.
                            if State.packet_state ~= 0 then
                                State.packet_state = 0
                                pack_consec_fails = pack_consec_fails + 1
                                Debug.log(('PACK trade TIMEOUT slip=%d (consec=%d)'):format(
                                    slip_num, pack_consec_fails))
                                Msg.warning(('Slip %d trade timed out (network deadlock?) - skipping'):format(slip_num))
                                if pack_consec_fails >= 2 then
                                    Debug.log('PACK aborted: 2 consecutive timeouts')
                                    action = false
                                    break
                                end
                                -- Don't set action=true on a failed trade
                            else
                                pack_consec_fails = 0
                                action = true
                                Inv.put_away_items(State.original_retrieve, Config.bag_priority)
                                Msg.stored(item_count, slip_num)
                                pack_total_items = pack_total_items + item_count
                                pack_total_slips = pack_total_slips + 1
                            end
                        end
                    end
                    if pack_consec_fails >= 2 then break end

                    -- Return slip to its original bag (only one matches)
                    if Satchel_Slip_table[slip_id] and Satchel_Slip_table[slip_id][1].id == slip_id then
                        Inv.put_away_items({[slip_id]=true}, {5})
                    elseif Sack_Slip_table[slip_id] and Sack_Slip_table[slip_id][1].id == slip_id then
                        Inv.put_away_items({[slip_id]=true}, {6})
                    elseif Case_Slip_table[slip_id] and Case_Slip_table[slip_id][1].id == slip_id then
                        Inv.put_away_items({[slip_id]=true}, {7})
                    end
                    coroutine.sleep(0.025)
                elseif #items > 2 and pass == 1 then
                    Msg.slip_hint(slips.get_slip_number_by_id(slip_id), #items)
                end
            end
            -- Re-add to retrieve any items still pending (in case slip wasn't yet found)
            for slip_id, items in pairs(slips.get_player_items()) do
                if items.n ~= 0 then
                    for _, item_id in ipairs(items) do
                        if State.original_retrieve[item_id] then
                            State.retrieve[item_id] = true
                        end
                    end
                end
            end
            pass = pass + 1
            if pass > 80 then action = false end
        end
    end

    -- Switch to unpack phase
    State.store = {}
    State.storing_items = false

    -- ---------------------------------------------------------------
    -- UNPACK phase
    -- ---------------------------------------------------------------
    local unpack_total_items = 0
    local unpack_total_slips = 0

    if table.length(State.retrieve) ~= 0 and Inv.space_available(0) ~= 0 then
        -- Pre-compute the set of slip_ids that contain at least one needed item.
        local relevant_slip_ids = {}
        for item_id in pairs(State.original_retrieve) do
            local sid = slips.get_slip_id_by_item_id(item_id)
            if sid then relevant_slip_ids[sid] = true end
        end

        local pass = 1
        local last_count = -1
        local unpack_consec_fails = 0

        while table.length(State.retrieve) > 0 and pass < 15 do
            local current_count = table.length(State.retrieve)
            -- Early exit: no progress = nothing more to do
            if current_count == last_count then break end
            last_count = current_count

            local player_slips = slips.get_player_items()
            for slip_id in pairs(relevant_slip_ids) do
                if unpack_consec_fails >= 2 then break end
                local items = player_slips[slip_id] or {n=0}
                local slip_used = false

                if items.n ~= 0 then
                    for _, item_id in ipairs(items) do
                        if State.retrieve[item_id]
                            and not Inv.find_item(Config.slip_bags, item_id, 1) then
                            local slip_item = Inv.find_item(Config.slip_bags, slip_id, 1)
                            if slip_item then
                                Inv.retrieve_items({[1]=slip_item}, Config.equippable_bags)
                                coroutine.sleep(0.1)
                                slip_item = Inv.find_item({slips.default_storages[1]}, slip_id, 1)

                                if slip_item then
                                    npc = Packets.find_npc('Porter Moogle')
                                    if not npc then
                                        State.retrieve = {}
                                        State.store = {}
                                        State.storing_items = false
                                        return
                                    end
                                    local slip_num = slips.get_slip_number_by_id(slip_id)
                                    Msg.progress('Retrieving from', slip_num, nil)
                                    Packets.trade_npc(npc, {slip_item})
                                    Packets.wait_for_trades()
                                    local trade_timed_out = (State.packet_state ~= 0)
                                    if State.packet_state ~= 0 then State.packet_state = 0 end

                                    -- Count items retrieved (one slip can yield many items at once)
                                    local removed_count = 0
                                    for ret_id in pairs(State.retrieve) do
                                        if Inv.find_item(Config.slip_bags, ret_id, 1) then
                                            State.retrieve[ret_id] = nil
                                            removed_count = removed_count + 1
                                        end
                                    end
                                    Msg.retrieved(removed_count, slip_num)
                                    unpack_total_items = unpack_total_items + removed_count
                                    unpack_total_slips = unpack_total_slips + 1
                                    slip_used = true

                                    -- If trade silently failed (no items received),
                                    -- break the items loop to avoid retrying the same
                                    -- slip 30 times in a row.
                                    if trade_timed_out and removed_count == 0 then
                                        unpack_consec_fails = unpack_consec_fails + 1
                                        Debug.log(('UNPACK slip=%d FAILED (timeout, 0 items) - fails=%d'):format(
                                            slip_num, unpack_consec_fails))
                                        break
                                    else
                                        unpack_consec_fails = 0
                                    end
                                end
                            end
                        end
                    end
                end

                if slip_used then
                    if Satchel_Slip_table[slip_id] and Satchel_Slip_table[slip_id][1].id == slip_id then
                        Inv.put_away_items({[slip_id]=true}, {5})
                    elseif Sack_Slip_table[slip_id] and Sack_Slip_table[slip_id][1].id == slip_id then
                        Inv.put_away_items({[slip_id]=true}, {6})
                    elseif Case_Slip_table[slip_id] and Case_Slip_table[slip_id][1].id == slip_id
                        and Inv.find_item({slips.default_storages[1]}, slip_id, 1) then
                        Inv.put_away_items({[slip_id]=true}, {7})
                    end
                    coroutine.sleep(0.025)
                end
            end

            -- Re-add to retrieve any items still missing (failed trades earlier)
            player_slips = slips.get_player_items()
            for slip_id in pairs(relevant_slip_ids) do
                local items = player_slips[slip_id]
                if items and items.n ~= 0 then
                    for _, item_id in ipairs(items) do
                        if State.original_retrieve[item_id]
                            and not Inv.find_item(Config.slip_bags, item_id, 1)
                            and not State.retrieve[item_id] then
                            State.retrieve[item_id] = true
                        end
                    end
                end
            end

            -- If inventory is filling up, flush items to wardrobes
            if Inv.space_available(0) < 3 then
                Inv.put_away_items(State.original_retrieve, Config.bag_priority)
                coroutine.sleep(0.025)
            end
            pass = pass + 1
        end
    end

    Inv.put_away_items(State.original_retrieve, Config.bag_priority)
    State.retrieve = {}

    -- Summaries
    if pack_total_slips > 0 then
        Msg.summary('Packed', pack_total_items, pack_total_slips)
    end
    if unpack_total_slips > 0 then
        Msg.summary('Retrieved', unpack_total_items, unpack_total_slips)
    end

    -- Export totals so bulk mode (packall) can detect stalls
    State.async_total_items = pack_total_items + unpack_total_items
    State.async_total_slips = pack_total_slips + unpack_total_slips
end

return M
