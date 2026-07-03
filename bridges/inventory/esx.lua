-- Inventory bridge: ESX built-in inventory (es_extended, classic/default).
-- Checked LAST in detection priority, so ESX servers running ox_inventory or
-- another dedicated inventory still get that bridge instead.

local M = {}
local ESX

function M.detect()
    return GetResourceState('es_extended'):find('start') ~= nil
end

local function xPlayer(src)
    if not ESX then ESX = exports['es_extended']:getSharedObject() end
    return ESX.GetPlayerFromId(src)
end

function M.HasItem(src, item, count)
    local xp = xPlayer(src)
    if not xp then return false end
    local it = xp.getInventoryItem(item)
    return it ~= nil and (it.count or 0) >= (count or 1)
end

function M.AddItem(src, item, count, metadata)
    local xp = xPlayer(src)
    if not xp then return false end
    if xp.canCarryItem and not xp.canCarryItem(item, count or 1) then return false end
    xp.addInventoryItem(item, count or 1) -- classic ESX: no metadata support
    return true
end

function M.RemoveItem(src, item, count)
    local xp = xPlayer(src)
    if not xp then return false end
    local it = xp.getInventoryItem(item)
    if not it or (it.count or 0) < (count or 1) then return false end
    xp.removeInventoryItem(item, count or 1)
    return true
end

Bridge.RegisterInventory('esx', M)
