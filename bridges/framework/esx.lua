-- Framework bridge: ESX Legacy (es_extended)

local M = { server = {}, client = {} }
local ESX

function M.detect()
    return GetResourceState('es_extended'):find('start') ~= nil
end

local function core() if not ESX then ESX = exports['es_extended']:getSharedObject() end return ESX end

if IsDuplicityVersion() then
    local ACC = { cash = 'money', bank = 'bank', crypto = 'black_money' }
    local function P(src) return core().GetPlayerFromId(src) end

    function M.server.GetIdentifier(src)
        local xp = P(src); return xp and xp.identifier or nil
    end
    function M.server.GetName(src)
        local xp = P(src)
        if not xp then return GetPlayerName(src) or 'Unknown' end
        return xp.getName and xp.getName() or (GetPlayerName(src) or 'Unknown')
    end
    function M.server.GetJob(src)
        local xp = P(src)
        if not xp then return { name = 'unemployed', grade = 0, label = 'Civilian', onduty = true } end
        local j = xp.getJob()
        return { name = j.name, grade = j.grade or 0, label = j.label or j.name, onduty = true }
    end
    function M.server.Notify(src, msg, t)
        TriggerClientEvent('esx:showNotification', src, msg)
    end
    function M.server.HasItem(src, item, count)
        local xp = P(src); if not xp then return false end
        local it = xp.getInventoryItem(item)
        return it ~= nil and (it.count or 0) >= (count or 1)
    end
    function M.server.AddItem(src, item, count, meta)
        local xp = P(src); if not xp then return false end
        xp.addInventoryItem(item, count or 1); return true
    end
    function M.server.RemoveItem(src, item, count)
        local xp = P(src); if not xp then return false end
        local it = xp.getInventoryItem(item)
        if not it or (it.count or 0) < (count or 1) then return false end
        xp.removeInventoryItem(item, count or 1); return true
    end
    function M.server.GetMoney(src, acc)
        local xp = P(src); if not xp then return 0 end
        local a = xp.getAccount(ACC[acc] or acc); return a and a.money or 0
    end
    function M.server.AddMoney(src, acc, amount)
        local xp = P(src); if not xp then return false end
        xp.addAccountMoney(ACC[acc] or acc, amount); return true
    end
    function M.server.RemoveMoney(src, acc, amount)
        local xp = P(src); if not xp then return false end
        if M.server.GetMoney(src, acc) < amount then return false end
        xp.removeAccountMoney(ACC[acc] or acc, amount); return true
    end
    function M.server.CountJobPlayers(jobs)
        local n = 0
        for _, j in ipairs(jobs) do
            n = n + #(core().GetExtendedPlayers('job', j) or {})
        end
        return n
    end
else
    function M.client.Notify(msg, t) core().ShowNotification(msg) end
end

Bridge.RegisterFramework('esx', M)
