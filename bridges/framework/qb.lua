-- Framework bridge: QB-Core (qb-core)

local M = { server = {}, client = {} }
local QB

function M.detect()
    if GetResourceState('qbx_core'):find('start') then return false end
    return GetResourceState('qb-core'):find('start') ~= nil
end

local function core() if not QB then QB = exports['qb-core']:GetCoreObject() end return QB end

if IsDuplicityVersion() then
    local function P(src) return core().Functions.GetPlayer(src) end

    function M.server.GetIdentifier(src)
        local p = P(src); return p and p.PlayerData.citizenid or nil
    end
    function M.server.GetName(src)
        local p = P(src)
        if not p then return GetPlayerName(src) or 'Unknown' end
        local ci = p.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname, ci.lastname)
    end
    function M.server.GetJob(src)
        local p = P(src)
        if not p then return { name = 'unemployed', grade = 0, label = 'Civilian', onduty = false } end
        local j = p.PlayerData.job
        local grade = type(j.grade) == 'table' and (j.grade.level or 0) or (j.grade or 0)
        return { name = j.name, grade = grade, label = j.label, onduty = j.onduty }
    end
    function M.server.Notify(src, msg, t)
        TriggerClientEvent('QBCore:Notify', src, msg, t or 'primary')
    end
    function M.server.HasItem(src, item, count)
        local p = P(src); if not p then return false end
        local it = p.Functions.GetItemByName(item)
        return it ~= nil and (it.amount or it.count or 0) >= (count or 1)
    end
    function M.server.AddItem(src, item, count, meta)
        local p = P(src); if not p then return false end
        return p.Functions.AddItem(item, count or 1, false, meta) and true or false
    end
    function M.server.RemoveItem(src, item, count)
        local p = P(src); if not p then return false end
        return p.Functions.RemoveItem(item, count or 1) and true or false
    end
    function M.server.GetMoney(src, acc)
        local p = P(src); if not p then return 0 end
        return p.PlayerData.money[acc] or 0
    end
    function M.server.AddMoney(src, acc, amount)
        local p = P(src); if not p then return false end
        return p.Functions.AddMoney(acc, amount, 'boosting') and true or false
    end
    function M.server.RemoveMoney(src, acc, amount)
        local p = P(src); if not p then return false end
        return p.Functions.RemoveMoney(acc, amount, 'boosting') and true or false
    end
    function M.server.CountJobPlayers(jobs)
        local set = {}; for _, j in ipairs(jobs) do set[j] = true end
        local n = 0
        for _, pid in ipairs(core().Functions.GetPlayers()) do
            local p = P(pid)
            if p and set[p.PlayerData.job.name] and p.PlayerData.job.onduty then n = n + 1 end
        end
        return n
    end
else
    function M.client.Notify(msg, t) TriggerEvent('QBCore:Notify', msg, t or 'primary') end
end

Bridge.RegisterFramework('qb', M)
