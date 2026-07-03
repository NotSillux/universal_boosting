-- Inventory bridge: qb-inventory family (qb-inventory, ps-inventory, lj-inventory).
-- These store items on the framework player object, so we go through the
-- framework bridge's player accessor via the framework HasItem/AddItem/RemoveItem.

local M = {}

function M.detect()
    for _, res in ipairs({ 'qb-inventory', 'ps-inventory', 'lj-inventory' }) do
        if GetResourceState(res):find('start') then return true end
    end
    return false
end

-- Delegate to the framework bridge (which already talks to the qb player object).
function M.HasItem(src, item, count) return Bridge.Framework.server.HasItem(src, item, count) end
function M.AddItem(src, item, count, meta) return Bridge.Framework.server.AddItem(src, item, count, meta) end
function M.RemoveItem(src, item, count) return Bridge.Framework.server.RemoveItem(src, item, count) end

Bridge.RegisterInventory('qb', M)
