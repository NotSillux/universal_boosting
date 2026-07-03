-- Framework bridge: Standalone (no framework). Last-resort fallback.

local M = { server = {}, client = {} }

function M.detect() return true end

if IsDuplicityVersion() then
    function M.server.GetIdentifier(src) return GetPlayerIdentifierByType(src, 'license') end
    function M.server.GetName(src) return GetPlayerName(src) or 'Unknown' end
    function M.server.GetJob(src) return { name = 'civilian', grade = 0, label = 'Civilian', onduty = true } end
    function M.server.Notify(src, msg, t)
        TriggerClientEvent('chat:addMessage', src, { args = { '^5[Boosting]^0', msg } })
    end
    function M.server.HasItem(src, item, count) return true end
    function M.server.AddItem(src, item, count, meta) return true end
    function M.server.RemoveItem(src, item, count) return true end
    function M.server.GetMoney(src, acc) return 0 end
    function M.server.AddMoney(src, acc, amount) return true end
    function M.server.RemoveMoney(src, acc, amount) return true end
    function M.server.CountJobPlayers(jobs) return 0 end
else
    function M.client.Notify(msg, t)
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(msg)
        EndTextCommandThefeedPostTicker(false, true)
    end
end

Bridge.RegisterFramework('standalone', M)
