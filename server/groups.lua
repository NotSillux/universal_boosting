--[[
    Boosting groups (crews). In-memory for the session — a crew is a live
    grouping used for queueing together and splitting rewards. Members can
    queue as a group; contracts and payouts respect the crew.
]]

Groups = { groups = {}, bySrc = {}, invites = {} }

local function notify(src, msg, type_)
    Bridge.Framework.server.Notify(src, msg, type_ or 'inform')
    TriggerClientEvent('boosting:notify', src, { title = 'Crew', text = msg })
end

--- All member server ids of a group (online only).
function Groups.Members(groupId)
    local g = Groups.groups[groupId]
    if not g then return {} end
    local out = {}
    for member in pairs(g.members) do
        if GetPlayerName(member) then out[#out + 1] = member end
    end
    return out
end

function Groups.GetGroupId(src) return Groups.bySrc[src] end

--- A pending invite for this player, if any is still live (else nil).
function Groups.PendingInvite(src)
    local inv = Groups.invites[src]
    if not inv then return nil end
    if os.time() > inv.expires then Groups.invites[src] = nil; return nil end
    if not Groups.groups[inv.groupId] then Groups.invites[src] = nil; return nil end
    return { from = inv.from, expiresIn = inv.expires - os.time() }
end

function Groups.GetPayload(src, session)
    local groupId = Groups.bySrc[src]
    if not groupId then
        -- not in a crew: surface any pending invite so the Crew tab can offer
        -- Accept/Decline even if the app was closed when the invite arrived
        return { inGroup = false, invite = Groups.PendingInvite(src) }
    end
    local g = Groups.groups[groupId]
    if not g then return { inGroup = false, invite = Groups.PendingInvite(src) } end

    local members = {}
    for member in pairs(g.members) do
        local ms = Boost.GetSession(member)
        members[#members + 1] = {
            src = member,
            name = ms and ms.name or GetPlayerName(member) or ('Player ' .. member),
            level = ms and ms.profile.level or 1,
            isLeader = member == g.leader,
            isHacker = member == g.hacker,   -- the crew's designated tracker-breaker
        }
    end
    table.sort(members, function(a, b) return a.isLeader and not b.isLeader end)
    return {
        inGroup = true, id = groupId,
        isLeader = g.leader == src,
        isHacker = g.hacker == src,
        hacker = g.hacker,       -- nil => only the leader can disable trackers
        members = members,
    }
end

--- Who in a crew may disable the GPS tracker: the leader, or the assigned hacker.
--- (Solo boosters are handled directly in contracts.lua.)
function Groups.CanDisableTracker(src, groupId)
    local g = Groups.groups[groupId]
    if not g then return false end
    return src == g.leader or (g.hacker ~= nil and src == g.hacker)
end

local function broadcastUpdate(groupId)
    for _, member in ipairs(Groups.Members(groupId)) do
        TriggerClientEvent('boosting:groupUpdate', member)
    end
end

-- ── Callbacks ───────────────────────────────────────────────────────────────

RegisterCallback('group:create', function(src, session)
    if Groups.bySrc[src] then return { error = 'already_in_group' } end
    local id = Utils.Id('crew_')
    Groups.groups[id] = { id = id, leader = src, members = { [src] = true } }
    Groups.bySrc[src] = id
    return { ok = true, group = Groups.GetPayload(src, session) }
end)

RegisterCallback('group:invite', function(src, session, data)
    local groupId = Groups.bySrc[src]
    if not groupId then return { error = 'not_in_group' } end
    local g = Groups.groups[groupId]
    if g.leader ~= src then return { error = 'not_leader' } end
    if #Groups.Members(groupId) >= Config.Groups.maxSize then return { error = 'group_full' } end

    local target = tonumber(data.target)
    if not target or not GetPlayerName(target) or target == src then return { error = 'player_not_found' } end
    if Groups.bySrc[target] then return { error = 'target_busy' } end

    Groups.invites[target] = { groupId = groupId, from = session.name,
        expires = os.time() + (Config.Groups.inviteExpiry or 180) }
    notify(target, ('%s invited you to their crew — open Boosting > Crew to accept (or /crewaccept).'):format(session.name), 'inform')
    TriggerClientEvent('boosting:groupInvite', target, { from = session.name, groupId = groupId })
    return { ok = true }
end)

RegisterCallback('group:accept', function(src, session)
    local inv = Groups.invites[src]
    if not inv or os.time() > inv.expires then
        Groups.invites[src] = nil
        return { error = 'no_invite' }
    end
    local g = Groups.groups[inv.groupId]
    if not g then Groups.invites[src] = nil; return { error = 'group_gone' } end
    if #Groups.Members(inv.groupId) >= Config.Groups.maxSize then return { error = 'group_full' } end
    if Queue.IsQueued(src) then Queue.Remove(src) end

    g.members[src] = true
    Groups.bySrc[src] = inv.groupId
    Groups.invites[src] = nil
    broadcastUpdate(inv.groupId)
    return { ok = true, group = Groups.GetPayload(src, session) }
end)

RegisterCallback('group:decline', function(src)
    Groups.invites[src] = nil
    return { ok = true }
end)

RegisterCallback('group:leave', function(src, session)
    Groups.Remove(src)
    return { ok = true }
end)

--- Leader assigns (or clears) the crew's Hacker — the member who, alongside
--- the leader, is allowed to disable GPS trackers. target = member src, or
--- false/nil to clear back to leader-only.
RegisterCallback('group:setHacker', function(src, session, data)
    local groupId = Groups.bySrc[src]
    if not groupId then return { error = 'not_in_group' } end
    local g = Groups.groups[groupId]
    if g.leader ~= src then return { error = 'not_leader' } end

    if data.target == false or data.target == nil then
        g.hacker = nil
    else
        local target = tonumber(data.target)
        if not target or not g.members[target] then return { error = 'player_not_found' } end
        g.hacker = target
    end
    broadcastUpdate(groupId)
    return { ok = true }
end)

RegisterCallback('group:kick', function(src, session, data)
    local groupId = Groups.bySrc[src]
    if not groupId then return { error = 'not_in_group' } end
    local g = Groups.groups[groupId]
    if g.leader ~= src then return { error = 'not_leader' } end
    local target = tonumber(data.target)
    if not target or not g.members[target] or target == src then return { error = 'player_not_found' } end

    Groups.Remove(target)
    notify(target, 'You were removed from the crew.', 'error')
    return { ok = true }
end)

--- Remove a player from their crew, disbanding / reassigning leadership.
function Groups.Remove(src)
    local groupId = Groups.bySrc[src]
    if not groupId then return end
    local g = Groups.groups[groupId]
    Groups.bySrc[src] = nil
    if g then
        g.members[src] = nil
        local remaining = Groups.Members(groupId)
        if #remaining == 0 then
            Groups.groups[groupId] = nil
        else
            if g.leader == src then g.leader = remaining[1] end -- promote next member
            broadcastUpdate(groupId)
        end
    end
    TriggerClientEvent('boosting:groupUpdate', src)
end

AddEventHandler('playerDropped', function()
    Groups.Remove(source)
    Groups.invites[source] = nil
end)
