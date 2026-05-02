---============================================================================
--- PorterPacker / lib/inventory.lua
---============================================================================
--- Bag manipulation primitives. All windower.ffxi.{get,put}_item logic lives
--- here. Other modules call these helpers; they don't touch bags directly.
---
--- Functions:
---   space_available(bag_id)        -> free slots (0 if disabled)
---   find_item(bags, item_id, n)    -> first item with count>=n across bags
---   gather_slips_from_home()       -> pull all 33 slips from satchel
---   return_slips_to_home()         -> push every slip in inv back to satchel
---   put_away_items(items, bags)    -> move inv items into target bags
---   retrieve_items(items, bags)    -> pull items from bags into inventory
---============================================================================

local Config = require('lib/config')
local Debug  = require('lib/debug')

local M = {}

--- Free slots remaining in a bag (0 if disabled).
function M.space_available(bag_id)
    local bag = windower.ffxi.get_bag_info(bag_id)
    return bag.enabled and (bag.max - bag.count) or 0
end

--- Find an item across the given bags (returns first match with count >= n).
--- @param bags table Array of bag ids to search
--- @param item_id number FFXI item id
--- @param count number Minimum count needed
function M.find_item(bags, item_id, count)
    for _, bag_id in pairs(bags) do
        for _, item in ipairs(windower.ffxi.get_items(bag_id)) do
            if item.id == item_id and item.count >= count and item.status == 0 then
                return item
            end
        end
    end
    return nil
end

--- Pull every storage slip from SLIP_HOME_BAG into inventory (bag 0).
--- Skips slips already in inventory. Stops if inventory full.
---
--- Returns an extra `needed` value when inventory was too full to gather all
--- pending slips, so the caller can warn the user with an exact figure.
---
--- @return number moved   how many slips were successfully pulled
--- @return number needed  how many free inventory slots were missing (0 if all gathered)
--- @return number pending how many slips remained to gather at start
function M.gather_slips_from_home()
    local moved = 0
    local source_items = windower.ffxi.get_items(Config.SLIP_HOME_BAG)
    if not source_items then return 0, 0, 0 end

    -- Build a set of slip_ids already in inventory (avoid duplicate pulls)
    local in_inv = {}
    for _, inv_item in ipairs(windower.ffxi.get_items(0)) do
        if inv_item.id ~= 0 and inv_item.status == 0 and slips.items[inv_item.id] then
            in_inv[inv_item.id] = true
        end
    end

    -- Snapshot indices first because get_item() shifts the source bag
    local to_grab = {}
    for index, item in ipairs(source_items) do
        if item.id ~= 0 and item.status == 0 and slips.items[item.id] and not in_inv[item.id] then
            to_grab[#to_grab+1] = {index = index, count = item.count}
        end
    end

    local pending = #to_grab
    local available = M.space_available(0)
    local needed = math.max(0, pending - available)

    for _, e in ipairs(to_grab) do
        if M.space_available(0) <= 0 then
            Debug.log(('!! gather inventory full at %d/%d (need %d more free slots)'):format(
                moved, pending, needed))
            break
        end
        windower.ffxi.get_item(Config.SLIP_HOME_BAG, e.index, e.count)
        moved = moved + 1
        -- Batched: 0.05s between get_item calls. Server processes ~10
        -- packets/s; this rate (20/s) is fine because get_item from satchel
        -- is much lighter than trades.
        coroutine.sleep(0.05)
    end
    -- Final settle so FFXI confirms all gets before caller proceeds
    if moved > 0 then coroutine.sleep(0.5) end
    return moved, needed, pending
end

--- Send every storage slip currently in inventory back to SLIP_HOME_BAG.
--- Batched: sends puts at 0.08s spacing (12/s), then verifies and retries
--- only what's left. Up to 3 passes total to defeat FFXI rate-limiting.
--- @return number Count of slips moved
function M.return_slips_to_home()
    local total_moved = 0

    for pass = 1, 3 do
        local inv_items = windower.ffxi.get_items(0)
        if not inv_items then break end

        local to_send = {}
        for index, item in ipairs(inv_items) do
            if item.id ~= 0 and item.status == 0 and slips.items[item.id] then
                to_send[#to_send+1] = {index = index, count = item.count}
            end
        end

        if #to_send == 0 then break end

        Debug.log(('return_slips pass %d: %d slip(s) in inv'):format(pass, #to_send))

        local pass_moved = 0
        for _, e in ipairs(to_send) do
            if M.space_available(Config.SLIP_HOME_BAG) <= 0 then
                Debug.log(('!! return satchel full at %d/%d'):format(pass_moved, #to_send))
                return total_moved + pass_moved
            end
            windower.ffxi.put_item(Config.SLIP_HOME_BAG, e.index, e.count)
            pass_moved = pass_moved + 1
            -- Batched 0.08s = 12/s. First pass is the bulk of the transfer;
            -- any drops are caught by pass 2/3 with the verify-and-retry.
            coroutine.sleep(0.08)
        end
        total_moved = total_moved + pass_moved

        -- Settle, then re-scan inventory; if any slips still remain, retry.
        coroutine.sleep(0.5)
    end

    return total_moved
end

--- Move items in inventory matching `items` table to one of the given bags.
--- Iterates bags in order; first bag with space wins per item.
--- @param items table Set of item_ids (item_id -> truthy)
--- @param bags table Array of bag ids to fill
--- @return number Count of items moved
function M.put_away_items(items, bags)
    local space_in = {}
    local count = 0
    local moving = false
    local pass = 0
    for _, bag_id in pairs(bags) do
        space_in[bag_id] = M.space_available(bag_id)
        if space_in[bag_id] > 0 and not moving then
            moving = true
        end
    end
    while moving and pass < 4 do
        for index, item in ipairs(windower.ffxi.get_items(0)) do
            if items[item.id] and item.status == 0 then
                for _, bag_id in pairs(bags) do
                    if space_in[bag_id] > 0 and windower.ffxi.get_bag_info(bag_id).enabled and bag_id ~= 0 then
                        moving = false
                        count = count + item.count
                        space_in[bag_id] = space_in[bag_id] - 1
                        windower.ffxi.put_item(bag_id, index, item.count)
                        break
                    end
                end
            end
        end
        if moving then coroutine.sleep(0.1) end
        pass = pass + 1
    end
    return count
end

--- Pull items from `bags` into inventory (bag 0). Stops when inv is full.
--- @param items table Array of item objects {id=..., count=...}
--- @param bags table Array of bag ids to pull from (bag 0 is skipped)
--- @return number Count of items moved
function M.retrieve_items(items, bags)
    local inv_free = M.space_available(0)
    local count = 0
    if #items == 0 then return 0 end
    for n = 1, #items do
        for _, bag_id in pairs(bags) do
            if windower.ffxi.get_bag_info(bag_id).enabled and bag_id ~= 0 then
                for index, item in ipairs(windower.ffxi.get_items(bag_id)) do
                    if items[n].id == item.id and item.status == 0 then
                        if inv_free == 0 then return count end
                        count = count + item.count
                        inv_free = inv_free - 1
                        windower.ffxi.get_item(bag_id, index, item.count)
                    end
                end
            end
        end
    end
    return count
end

return M
