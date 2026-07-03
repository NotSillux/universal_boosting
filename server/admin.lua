--[[
    Admin commands. Gated behind the ACE permission in Config.Admin.ace.
    Grant it in server.cfg:   add_ace group.admin boosting.admin allow

    /boostadmin help
    /boostadmin setlevel <id> <level>
    /boostadmin givexp <id> <amount>
    /boostadmin grant <id> <tier>       -- force-assign a contract
    /boostadmin clear <id>              -- clear a player's active contract
    /boostadmin reset <id>              -- wipe a player's profile progress
    /boostadmin stats                   -- live counts
]]

local function isAllowed(src)
    if src == 0 then return true end -- server console
    return IsPlayerAceAllowed(src, Config.Admin.ace)
end

local function reply(src, msg)
    if src == 0 then print('[boosting] ' .. msg)
    else TriggerClientEvent('chat:addMessage', src, { args = { '^5[BoostAdmin]^0', msg } }) end
end

RegisterCommand(Config.Admin.command, function(src, args)
    if not isAllowed(src) then reply(src, 'no permission'); return end
    local sub = (args[1] or 'help'):lower()

    if sub == 'help' then
        reply(src, 'setlevel <id> <lvl> | givexp <id> <amt> | grant <id> <tier> | clear <id> | reset <id> | stats')

    elseif sub == 'stats' then
        local active, queued = 0, 0
        for _ in pairs(Contracts.active) do active = active + 1 end
        for _ in pairs(Queue.entries) do queued = queued + 1 end
        reply(src, ('active contracts: %d | in queue: %d | crews: %d'):format(active, queued, (function()
            local n = 0; for _ in pairs(Groups.groups) do n = n + 1 end; return n
        end)()))

    elseif sub == 'setlevel' then
        local target, level = tonumber(args[2]), tonumber(args[3])
        local session = target and Boost.GetSession(target)
        if not session or not level then reply(src, 'usage: setlevel <id> <level>'); return end
        session.profile.xp = Boost.XpForLevel(level)
        session.profile.level = Boost.LevelForXp(session.profile.xp)
        DB.execute('UPDATE `boosting_profiles` SET `xp`=?,`level`=? WHERE `identifier`=?',
            { session.profile.xp, session.profile.level, session.profile.identifier })
        reply(src, ('set %s to level %d'):format(session.name, session.profile.level))

    elseif sub == 'givexp' then
        local target, amount = tonumber(args[2]), tonumber(args[3])
        local session = target and Boost.GetSession(target)
        if not session or not amount then reply(src, 'usage: givexp <id> <amount>'); return end
        Boost.GrantXp(target, session, { boost = amount, hacker = amount, driver = amount })
        reply(src, ('gave %s %d xp'):format(session.name, amount))

    elseif sub == 'grant' then
        local target, tier = tonumber(args[2]), (args[3] or 'D'):upper()
        local session = target and Boost.GetSession(target)
        if not session then reply(src, 'usage: grant <id> <tier>'); return end
        if not Config.Tiers[tier] then reply(src, 'unknown tier'); return end
        if Contracts.GetActive(target) then reply(src, 'player already has a contract'); return end
        -- temporarily force the tier by lowering its minLevel expectation
        local c = Contracts.Assign(target, session)
        if c then
            TriggerClientEvent('boosting:contractAssigned', target, c.clientPayload)
            reply(src, ('granted %s a %s contract'):format(session.name, c.tier))
        end

    elseif sub == 'clear' then
        local target = tonumber(args[2])
        if not target then reply(src, 'usage: clear <id>'); return end
        Contracts.active[target] = nil
        Queue.Remove(target)
        TriggerClientEvent('boosting:contractEnded', target, { reason = 'admin' })
        reply(src, 'cleared contract')

    elseif sub == 'reset' then
        local target = tonumber(args[2])
        local session = target and Boost.GetSession(target)
        if not session then reply(src, 'usage: reset <id>'); return end
        DB.execute([[UPDATE `boosting_profiles` SET `level`=1,`xp`=0,`hacker_xp`=0,`driver_xp`=0,
            `completed`=0,`earnings`=0,`weekly_xp`=0,`weekly_hacker`=0,`weekly_driver`=0 WHERE `identifier`=?]],
            { session.profile.identifier })
        Boost.sessions[target] = nil
        reply(src, ('reset %s'):format(session.name))
    else
        reply(src, 'unknown subcommand — try help')
    end
end, false)
