--[[
    Boosting server core:
      - profiles + XP/level progression
      - the NUI->server callback router (shared with the laptop's iframe pipe)
      - App Store registration with the laptop (store listing + install hook)
      - session tracking

    Everything is server-authoritative. The NUI only ever *requests* actions;
    rewards, XP, contract state and money all live and mutate here.
]]

Boost = {
    sessions = {},   -- [src] = { identifier, profile, ... }
    callbacks = {},
}

-- ── Callback registry (mirrors the laptop) ──────────────────────────────────

function RegisterCallback(name, fn)
    Boost.callbacks[name] = fn
end

RegisterNetEvent('boosting:request', function(reqId, name, data)
    local src = source
    local fn = Boost.callbacks[name]
    if not fn then
        TriggerClientEvent('boosting:response', src, reqId, { error = 'unknown_action' })
        return
    end
    -- lazily create a session for any authenticated player
    local session = Boost.GetSession(src)
    if not session then
        TriggerClientEvent('boosting:response', src, reqId, { error = 'no_profile' })
        return
    end
    local ok, res = pcall(fn, src, session, type(data) == 'table' and data or {})
    if not ok then
        print(('^1[boosting] callback "%s" error: %s^0'):format(name, res))
        res = { error = 'internal' }
    end
    TriggerClientEvent('boosting:response', src, reqId, res or {})
end)

-- ── Profiles / progression ──────────────────────────────────────────────────

local function weekTag()
    -- portable week bucket for weekly leaderboards (avoids %V / %G, which some
    -- Lua builds — including FiveM's on certain platforms — don't support)
    local t = os.date('*t')
    local week = math.floor((t.yday - 1) / 7) + 1
    return ('%d-W%02d'):format(t.year, week)
end

--- XP needed to reach the given level (1-indexed curve; clamps beyond the end).
function Boost.XpForLevel(level)
    local curve = Config.Progression.levelCurve
    if level <= 1 then return 0 end
    if level <= #curve then return curve[level] end
    -- extrapolate linearly using the last two curve deltas
    local last = curve[#curve]
    local step = curve[#curve] - curve[#curve - 1]
    return last + step * (level - #curve)
end

function Boost.LevelForXp(xp)
    local level = 1
    while level < Config.Progression.maxLevel and xp >= Boost.XpForLevel(level + 1) do
        level = level + 1
    end
    return level
end

local function loadProfile(identifier, name)
    local row = DB.single('SELECT * FROM `boosting_profiles` WHERE `identifier` = ?', { identifier })
    local tag = weekTag()
    if not row then
        DB.execute('INSERT INTO `boosting_profiles` (`identifier`,`name`,`week_tag`) VALUES (?,?,?)',
            { identifier, name, tag })
        row = { identifier = identifier, name = name, level = 1, xp = 0, hacker_xp = 0, driver_xp = 0,
                completed = 0, earnings = 0, weekly_xp = 0, weekly_hacker = 0, weekly_driver = 0, week_tag = tag }
    elseif row.week_tag ~= tag then
        -- new week: reset weekly counters
        DB.execute('UPDATE `boosting_profiles` SET `weekly_xp`=0,`weekly_hacker`=0,`weekly_driver`=0,`week_tag`=? WHERE `identifier`=?',
            { tag, identifier })
        row.weekly_xp, row.weekly_hacker, row.weekly_driver, row.week_tag = 0, 0, 0, tag
    end
    return row
end

function Boost.GetSession(src)
    if Boost.sessions[src] then return Boost.sessions[src] end
    local id = Bridge.Framework.server.GetIdentifier(src)
    if not id then return nil end
    local name = Bridge.Framework.server.GetName(src)
    Boost.sessions[src] = {
        identifier = id,
        name = name,
        profile = loadProfile(id, name),
    }
    return Boost.sessions[src]
end

--- Grant XP across the three tracks and persist. Returns level-up info.
function Boost.GrantXp(src, session, gain)
    local p = session.profile
    local prevLevel = p.level
    p.xp = p.xp + (gain.boost or 0)
    p.hacker_xp = p.hacker_xp + (gain.hacker or 0)
    p.driver_xp = p.driver_xp + (gain.driver or 0)
    p.weekly_xp = p.weekly_xp + (gain.boost or 0)
    p.weekly_hacker = p.weekly_hacker + (gain.hacker or 0)
    p.weekly_driver = p.weekly_driver + (gain.driver or 0)
    p.level = Boost.LevelForXp(p.xp)

    DB.execute([[UPDATE `boosting_profiles` SET
        `level`=?,`xp`=?,`hacker_xp`=?,`driver_xp`=?,
        `weekly_xp`=?,`weekly_hacker`=?,`weekly_driver`=? WHERE `identifier`=?]],
        { p.level, p.xp, p.hacker_xp, p.driver_xp, p.weekly_xp, p.weekly_hacker, p.weekly_driver, p.identifier })

    if p.level > prevLevel then
        Bridge.Framework.server.Notify(src, ('Boosting level up! You are now level %d'):format(p.level), 'success')
    end
    return { leveledUp = p.level > prevLevel, level = p.level }
end

function Boost.RecordCompletion(src, session, reward)
    local p = session.profile
    p.completed = p.completed + 1
    p.earnings = p.earnings + reward
    DB.execute('UPDATE `boosting_profiles` SET `completed`=?,`earnings`=? WHERE `identifier`=?',
        { p.completed, p.earnings, p.identifier })
end

--- Serialise the profile for the NUI (adds derived level thresholds).
function Boost.ProfilePayload(session)
    local p = session.profile
    return {
        name = session.name,
        level = p.level,
        xp = p.xp,
        xpForCurrent = Boost.XpForLevel(p.level),
        xpForNext = Boost.XpForLevel(p.level + 1),
        hackerXp = p.hacker_xp,
        hackerLevel = math.floor(p.hacker_xp / Config.Progression.hackerXpPerLevel) + 1,
        driverXp = p.driver_xp,
        driverLevel = math.floor(p.driver_xp / Config.Progression.driverXpPerLevel) + 1,
        completed = p.completed,
        earnings = p.earnings,
    }
end

-- ── Bootstrap: laptop payload callback ──────────────────────────────────────

RegisterCallback('boot', function(src, session)
    return {
        ok = true,
        profile = Boost.ProfilePayload(session),
        tiers = (function()
            local t = {}
            for _, key in ipairs(Config.TierOrder) do
                local def = Config.Tiers[key]
                t[#t+1] = { id = key, label = def.label, color = def.color, minLevel = def.minLevel,
                            reward = def.reward, police = def.police }
            end
            return t
        end)(),
        group = Groups.GetPayload(src, session),
        activeContract = Contracts.GetActivePayload(src, session),
        queued = Queue.IsQueued(src),
        currencyLabel = Config.Currency.label,
        config = {
            vinScratchReward = Config.Contract.vinScratchReward,
            maxGroupSize = Config.Groups.maxSize,
            auctionEnabled = Config.Auction.enabled,
            hackerXpPerLevel = Config.Progression.hackerXpPerLevel,
            driverXpPerLevel = Config.Progression.driverXpPerLevel,
            trackerRule = Config.Tracker.crewRule or 'non_leader',
        },
    }
end)

-- ── App Store integration with the laptop ───────────────────────────────────

local function registerWithLaptop()
    local laptop = Config.LaptopResource
    if GetResourceState(laptop) ~= 'started' then return false end

    local ok = pcall(function()
        exports[laptop]:RegisterStoreApp({
            id          = Config.Store.id,
            name        = Config.Store.name,
            developer   = Config.Store.developer,
            description = Config.Store.description,
            category    = Config.Store.category,
            icon        = Config.Store.icon,
            price       = Config.Store.price,
            screenshots = Config.Store.screenshots,
            -- laptop must be connected to this network to install (e.g. darknet)
            network     = Config.Store.requiresNetwork or nil,
            -- fired after a player installs us via the store
            onInstall = function(installSrc)
                Utils.Debug(('installed by %s'):format(installSrc))
            end,
        })
    end)
    return ok
end

-- Register once both resources are up (works regardless of start order).
CreateThread(function()
    Bridge.AwaitReady()
    local tries = 0
    while not registerWithLaptop() and tries < 60 do
        tries = tries + 1
        Wait(1000)
    end
    if tries < 60 then
        print('^2[boosting]^0 registered with the ^3'..Config.LaptopResource..'^0 App Store')
    else
        print('^3[boosting]^0 laptop resource not found — running standalone (/'..(Config.Command or 'boosting')..')')
    end
end)

-- If the laptop restarts, re-register.
AddEventHandler('onResourceStart', function(res)
    if res == Config.LaptopResource then
        SetTimeout(2000, registerWithLaptop)
    end
end)

-- Optional server event other resources can listen to when a player installs us
AddEventHandler('nexos:appInstalled', function(src, appId)
    if appId == Config.Store.id then
        Utils.Debug(('nexos:appInstalled -> unlocking boosting for %s'):format(src))
        -- ensure a profile exists so the first open is instant
        Boost.GetSession(src)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    Queue.Remove(src)
    Boost.sessions[src] = nil
end)
