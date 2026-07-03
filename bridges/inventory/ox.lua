-- Inventory bridge: ox_inventory

local M = {}
function M.detect() return GetResourceState('ox_inventory'):find('start') ~= nil end

function M.HasItem(src, item, count)
    return (exports.ox_inventory:Search(src, 'count', item) or 0) >= (count or 1)
end
function M.AddItem(src, item, count, meta)
    return exports.ox_inventory:AddItem(src, item, count or 1, meta) and true or false
end
function M.RemoveItem(src, item, count)
    return exports.ox_inventory:RemoveItem(src, item, count or 1) and true or false
end

Bridge.RegisterInventory('ox', M)
