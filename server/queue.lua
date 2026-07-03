--[[
    Queue: players (solo or as a crew leader) queue to receive vehicle-theft
    contracts. A processing loop pops assignments on a throttle and hands them
    to Contracts.Assign. Crew members are pulled in with their leader.
]]

Queue = { entries = {} }   -- [src] = { since, lastPop }

function Queue.IsQueued(src) return Queue.entries[src] ~= nil end

function Queue.Remove(src)
    Queue.entries[src] = nil
end

-- Only the crew leader queues; a solo player is their own "leader".
local function canQueue(src)
    local groupId = Groups.GetGroupId(src)
    if groupId and Groups.groups[groupId] and Groups.groups[groupId].leader ~= src then
        return false, 'only_leader_queues'
    end
    return true
end

RegisterCallback('queue:join', function(src, session)
    if Contracts.GetActive(src) then return { error = 'already_have_contract' } end
    local ok, why = canQueue(src)
    if not ok then return { error = why } end

    -- police gate
    if Config.Police.minRequired > 0 then
        local cops = Bridge.Framework.server.CountJobPlayers(Config.Police.countJobs)
        if cops < Config.Police.minRequired then
            return { error = 'not_enough_police' }
        end
    end

    Queue.entries[src] = { since = os.time(), lastPop = 0 }
    return { ok = true, queued = true }
end)

RegisterCallback('queue:leave', function(src)
    Queue.Remove(src)
    return { ok = true, queued = false }
end)

-- ── Processing loop ─────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        Wait(1000)
        local now = os.time()
        for src, entry in pairs(Queue.entries) do
            if not GetPlayerName(src) then
                Queue.entries[src] = nil
            elseif now - entry.since >= Config.Contract.queueCooldown
                and not Contracts.GetActive(src) then
                local session = Boost.GetSession(src)
                if session then
                    local contract = Contracts.Assign(src, session)
                    if contract then
                        Queue.entries[src] = nil
                        -- notify the leader + crew that a job is ready
                        local targets = { src }
                        local gid = Groups.GetGroupId(src)
                        if gid then targets = Groups.Members(gid) end
                        for _, t in ipairs(targets) do
                            TriggerClientEvent('boosting:contractAssigned', t, contract.clientPayload)
                            TriggerClientEvent('boosting:notify', t, {
                                title = 'Contract ready',
                                text = ('%s target located — open the Boosting app.'):format(contract.tierLabel),
                            })
                        end
                    end
                end
            end
        end
    end
end)
