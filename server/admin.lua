--[[
    Admin functionality — shared by the `/boostadmin` chat command AND the
    in-app Admin panel (Boosting App, visible only to admins).

    Every admin action funnels through the `Admin.*` functions below so both
    entry points share identical logic. The NUI callbacks ('admin:*') are
    reached through the same session-gated router as every other callback
    (see server/main.lua), but a valid session does NOT imply admin rights —
    every admin:* callback re-checks the ACE permission itself. The client's
    "isAdmin" flag (sent in the boot payload) only controls whether the Admin
    tab is SHOWN; it is never trusted for authorization.

    Grant the permission in server.cfg:
        add_ace group.admin boosting.admin allow
]]

Admin = {}

function Admin.IsAllowed(src)
    if src == 0 then return true end -- server console
    return IsPlayerAceAllowed(src, Config.Admin.ace)
end

function Admin.Stats()
    local active, queued, crews = 0, 0, 0
    for _ in pairs(Contracts.active) do active = active + 1 end
    for _ in pairs(Queue.entries) do queued = queued + 1 end
    for _ in pairs(Groups.groups) do crews = crews + 1 end
    return { active = active, queued = queued, crews = crews }
end

--- All currently active contracts, for the admin panel's live list.
function Admin.ActiveContracts()
    local out = {}
    for src, c in pairs(Contracts.active) do
        if GetPlayerName(src) then
            out[#out + 1] = {
                src = src, name = GetPlayerName(src),
                tier = c.tier, tierLabel = c.tierLabel, model = c.model,
                state = c.state, reward = c.reward, isCrew = c.groupId ~= nil,
            }
        end
    end
    table.sort(out, function(a, b) return a.src < b.src end)
    return out
end

function Admin.SetLevel(target, level)
    local session = target and Boost.GetSession(target)
    if not session or not level then return false end
    session.profile.xp = Boost.XpForLevel(level)
    session.profile.level = Boost.LevelForXp(session.profile.xp)
    DB.execute('UPDATE `boosting_profiles` SET `xp`=?,`level`=? WHERE `identifier`=?',
        { session.profile.xp, session.profile.level, session.profile.identifier })
    return true, session
end

function Admin.GiveXp(target, amount)
    local session = target and Boost.GetSession(target)
    if not session or not amount then return false end
    Boost.GrantXp(target, session, { boost = amount, hacker = amount, driver = amount })
    return true, session
end

--- Force-assign a contract to a player, bypassing the queue.
function Admin.GrantContract(target, tier)
    local session = target and Boost.GetSession(target)
    if not session then return false, 'player_not_found' end
    tier = (tier or 'D'):upper()
    if not Config.Tiers[tier] then return false, 'bad_tier' end
    if Contracts.GetActive(target) then return false, 'already_have_contract' end
    -- temporary weight override so Contracts.Assign is guaranteed to pick this
    -- tier regardless of the player's level, without touching the live config
    local original = Config.Tiers[tier].minLevel
    Config.Tiers[tier].minLevel = 0
    local everyoneElse = {}
    for key, def in pairs(Config.Tiers) do
        if key ~= tier then everyoneElse[key] = def.minLevel; def.minLevel = 9999 end
    end
    local c = Contracts.Assign(target, session)
    Config.Tiers[tier].minLevel = original
    for key, ml in pairs(everyoneElse) do Config.Tiers[key].minLevel = ml end

    if not c then return false, 'assign_failed' end
    TriggerClientEvent('boosting:contractAssigned', target, c.clientPayload)
    return true, c
end

function Admin.EndContract(target)
    return Contracts.ForceEnd(target, 'admin')
end

function Admin.ResetProfile(target)
    local session = target and Boost.GetSession(target)
    if not session then return false end
    DB.execute([[UPDATE `boosting_profiles` SET `level`=1,`xp`=0,`hacker_xp`=0,`driver_xp`=0,
        `completed`=0,`earnings`=0,`weekly_xp`=0,`weekly_hacker`=0,`weekly_driver`=0 WHERE `identifier`=?]],
        { session.profile.identifier })
    Boost.sessions[target] = nil
    return true
end

--- Recent police VIN checks, for the admin panel / /boostadmin vinlogs.
function Admin.VinLogs(limit)
    limit = math.min(math.max(tonumber(limit) or 10, 1), 50)
    return DB.query('SELECT * FROM `boosting_vin_checks` ORDER BY `id` DESC LIMIT ?', { limit })
end

-- ── /boostadmin chat command (thin wrapper over Admin.*) ────────────────────

local function reply(src, msg)
    if src == 0 then print('[boosting] ' .. msg)
    else TriggerClientEvent('chat:addMessage', src, { args = { '^5[BoostAdmin]^0', msg } }) end
end

RegisterCommand(Config.Admin.command, function(src, args)
    if not Admin.IsAllowed(src) then reply(src, 'no permission'); return end
    local sub = (args[1] or 'help'):lower()

    if sub == 'help' then
        reply(src, 'setlevel <id> <lvl> | givexp <id> <amt> | grant <id> <tier> | clear <id> | reset <id> | stats | vinlogs [n]')

    elseif sub == 'stats' then
        local s = Admin.Stats()
        reply(src, ('active contracts: %d | in queue: %d | crews: %d'):format(s.active, s.queued, s.crews))

    elseif sub == 'setlevel' then
        local target, level = tonumber(args[2]), tonumber(args[3])
        local ok, session = Admin.SetLevel(target, level)
        if not ok then reply(src, 'usage: setlevel <id> <level>'); return end
        reply(src, ('set %s to level %d'):format(session.name, session.profile.level))

    elseif sub == 'givexp' then
        local target, amount = tonumber(args[2]), tonumber(args[3])
        local ok, session = Admin.GiveXp(target, amount)
        if not ok then reply(src, 'usage: givexp <id> <amount>'); return end
        reply(src, ('gave %s %d xp'):format(session.name, amount))

    elseif sub == 'grant' then
        local target, tier = tonumber(args[2]), (args[3] or 'D'):upper()
        local ok, result = Admin.GrantContract(target, tier)
        if not ok then reply(src, 'grant failed: ' .. tostring(result)); return end
        reply(src, ('granted a %s contract to %s'):format(result.tier, GetPlayerName(target) or target))

    elseif sub == 'clear' then
        local target = tonumber(args[2])
        if not target or not Admin.EndContract(target) then reply(src, 'usage: clear <id> (or no active contract)'); return end
        reply(src, 'cleared contract')

    elseif sub == 'reset' then
        local target = tonumber(args[2])
        local ok = Admin.ResetProfile(target)
        if not ok then reply(src, 'usage: reset <id>'); return end
        reply(src, ('reset %s'):format(GetPlayerName(target) or target))

    elseif sub == 'vinlogs' then
        local rows = Admin.VinLogs(args[2])
        if #rows == 0 then reply(src, 'no VIN checks logged yet'); return end
        for _, r in ipairs(rows) do
            reply(src, ('#%d %s | %s checked %s -> %s'):format(
                r.id, tostring(r.created_at), r.officer_name or r.officer, r.plate, r.result))
        end
    else
        reply(src, 'unknown subcommand — try help')
    end
end, false)

-- ── In-app Admin panel (NUI callbacks) ───────────────────────────────────────
-- Every handler re-checks Admin.IsAllowed(src) itself — never trust the
-- client's cached isAdmin flag for anything except showing/hiding the tab.

local function requireAdmin(src)
    return Admin.IsAllowed(src)
end

RegisterCallback('admin:stats', function(src)
    if not requireAdmin(src) then return { error = 'not_authorized' } end
    return { ok = true, stats = Admin.Stats() }
end)

RegisterCallback('admin:activeContracts', function(src)
    if not requireAdmin(src) then return { error = 'not_authorized' } end
    return { ok = true, contracts = Admin.ActiveContracts() }
end)

RegisterCallback('admin:endContract', function(src, session, data)
    if not requireAdmin(src) then return { error = 'not_authorized' } end
    local target = tonumber(data.target)
    if not target then return { error = 'bad_request' } end
    return { ok = Admin.EndContract(target) }
end)

RegisterCallback('admin:createContract', function(src, session, data)
    if not requireAdmin(src) then return { error = 'not_authorized' } end
    local target = tonumber(data.target)
    if not target or not GetPlayerName(target) then return { error = 'player_not_found' } end
    local ok, err = Admin.GrantContract(target, data.tier)
    if not ok then return { error = tostring(err) } end
    return { ok = true }
end)

RegisterCallback('admin:playerStats', function(src, session, data)
    if not requireAdmin(src) then return { error = 'not_authorized' } end
    local target = tonumber(data.target)
    local ts = target and Boost.GetSession(target)
    if not ts then return { error = 'player_not_found' } end
    return { ok = true, profile = Boost.ProfilePayload(ts), src = target }
end)

RegisterCallback('admin:setLevel', function(src, session, data)
    if not requireAdmin(src) then return { error = 'not_authorized' } end
    local ok = Admin.SetLevel(tonumber(data.target), tonumber(data.level))
    return ok and { ok = true } or { error = 'bad_request' }
end)

RegisterCallback('admin:giveXp', function(src, session, data)
    if not requireAdmin(src) then return { error = 'not_authorized' } end
    local ok = Admin.GiveXp(tonumber(data.target), tonumber(data.amount))
    return ok and { ok = true } or { error = 'bad_request' }
end)

RegisterCallback('admin:resetProfile', function(src, session, data)
    if not requireAdmin(src) then return { error = 'not_authorized' } end
    local target = tonumber(data.target)
    if not target then return { error = 'bad_request' } end
    return { ok = Admin.ResetProfile(target) }
end)

RegisterCallback('admin:vinLogs', function(src, session, data)
    if not requireAdmin(src) then return { error = 'not_authorized' } end
    return { ok = true, logs = Admin.VinLogs(data.limit) }
end)
