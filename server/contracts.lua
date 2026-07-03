--[[
    Contract lifecycle — fully server-authoritative state machine.

    States:
      assigned  -> a target has been located; player must reach it & hack it
      stolen    -> tracker hacked, car is theirs; must escape the police
      escaped   -> police lost / distance cleared; may deliver or scratch VIN
      completed -> delivered or VIN-scratched, paid out
      abandoned / failed

    The client only *reports* transitions (with a one-time hack token and its
    live ped position). The server validates each step, computes rewards and
    XP, applies wanted level and pays crew members.
]]

Contracts = { active = {} }   -- [ownerSrc] = contract

function Contracts.GetActive(src) return Contracts.active[src] end

-- ── Assignment ──────────────────────────────────────────────────────────────

local function playerCoords(src)
    local ped = GetPlayerPed(src)
    if ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function nearestSpawn(coords)
    if not coords then return Config.Contract.spawnPoints[math.random(#Config.Contract.spawnPoints)] end
    local best, bestDist
    -- pick randomly among the 3 closest so it varies but stays local
    local ranked = {}
    for _, sp in ipairs(Config.Contract.spawnPoints) do
        ranked[#ranked + 1] = { sp = sp, d = #(coords - vec3(sp.x, sp.y, sp.z)) }
    end
    table.sort(ranked, function(a, b) return a.d < b.d end)
    local pick = ranked[math.random(math.min(3, #ranked))]
    return pick.sp
end

--- Create and register a contract for the player. Returns the contract or nil.
function Contracts.Assign(src, session)
    if Contracts.active[src] then return nil end

    local level = session.profile.level
    local tierKey = Utils.WeightedPick(Config.Tiers, function(_, def) return level >= def.minLevel end)
    if not tierKey then tierKey = 'D' end
    local tier = Config.Tiers[tierKey]

    local model = tier.vehicles[math.random(#tier.vehicles)]
    local spawn = nearestSpawn(playerCoords(src))
    local reward = tier.reward

    local contract = {
        id = Utils.Id('ctr_'),
        owner = session.identifier,
        ownerSrc = src,
        groupId = Groups.GetGroupId(src),
        tier = tierKey,
        tierLabel = tier.label,
        color = tier.color,
        model = model,
        reward = reward,
        xp = tier.xp,
        hackGame = tier.hackGame,
        difficulty = tier.difficulty,
        police = tier.police,
        state = 'assigned',
        spawn = spawn,
        createdAt = os.time(),
    }
    Contracts.active[src] = contract

    DB.execute('INSERT INTO `boosting_contracts` (`id`,`owner`,`tier`,`model`,`reward`,`state`) VALUES (?,?,?,?,?,?)',
        { contract.id, contract.owner, tierKey, model, reward, 'assigned' })

    contract.clientPayload = {
        id = contract.id,
        tier = tierKey,
        tierLabel = tier.label,
        color = tier.color,
        model = model,
        reward = reward,
        hackGame = tier.hackGame,
        difficulty = tier.difficulty,
        police = tier.police,
        spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w },
        deliveryPoints = Config.Contract.deliveryPoints,
        vinPoints = Config.Contract.vinScratchPoints,
        deliveryRadius = Config.Contract.deliveryRadius,
        vinRadius = Config.Contract.vinScratchRadius,
        vinMultiplier = Config.Contract.vinScratchReward,
    }
    Utils.Debug(('assigned %s (%s %s) to %s'):format(contract.id, tierKey, model, src))
    return contract
end

--- Resolve the contract a player is involved in: their own, or (for a crew
--- member) the one owned by their crew leader. Returns contract, isOwner.
function Contracts.ResolveForPlayer(src)
    local own = Contracts.active[src]
    if own then return own, true end
    local gid = Groups.GetGroupId and Groups.GetGroupId(src)
    if gid then
        for _, member in ipairs(Groups.Members(gid)) do
            local mc = Contracts.active[member]
            if mc then return mc, false end
        end
    end
    return nil, false
end

--- May this player disable the contract's GPS tracker?
--- Solo → the owner. Crew → the leader or the assigned Hacker.
function Contracts.CanDisable(src, c)
    if c.groupId then return Groups.CanDisableTracker(src, c.groupId) end
    return src == c.ownerSrc
end

--- Serialise a contract's tracker state for the UI.
local function trackerPayload(c, src)
    local tr = c.tracker
    if not tr or not tr.required then return nil end
    return {
        required   = true,
        active     = tr.active,
        disabled   = tr.disabled,
        disableTime = Config.Tracker.disableTime,
        remaining  = tr.active and math.max(0, Config.Tracker.disableTime - (os.time() - tr.startedAt)) or 0,
        escalated  = tr.escalated or false,
        canDisable = tr.active and Contracts.CanDisable(src, c) or false,
        failCooldown = Config.Tracker.failCooldown,
    }
end

--- Payload for the UI (never exposes tokens). Works for the owner AND crew.
function Contracts.GetActivePayload(src, session)
    local c, isOwner = Contracts.ResolveForPlayer(src)
    if not c then return false end
    return {
        id = c.id, tier = c.tier, tierLabel = c.tierLabel, color = c.color,
        model = c.model, reward = c.reward, state = c.state, police = c.police,
        spawn = { x = c.spawn.x, y = c.spawn.y, z = c.spawn.z, w = c.spawn.w },
        vinMultiplier = Config.Contract.vinScratchReward,
        isOwner = isOwner,
        tracker = trackerPayload(c, src),
    }
end

local function history(identifier, tier, model, outcome, reward)
    DB.execute('INSERT INTO `boosting_history` (`identifier`,`tier`,`model`,`outcome`,`reward`) VALUES (?,?,?,?,?)',
        { identifier, tier, model, outcome, reward or 0 })
end

local function setState(contract, state)
    contract.state = state
    DB.execute('UPDATE `boosting_contracts` SET `state`=? WHERE `id`=?', { state, contract.id })
end

local function clearActive(src)
    Contracts.active[src] = nil
end

-- ── Reward payout (handles crews) ───────────────────────────────────────────

local function payout(src, session, contract, grossReward)
    grossReward = Utils.Round(grossReward)
    local members = { src }
    if contract.groupId then
        local m = Groups.Members(contract.groupId)
        if #m > 0 then members = m end
    end

    if #members > 1 and Config.Groups.rewardSplit == 'equal' then
        local share = Utils.Round(grossReward / #members)
        for _, member in ipairs(members) do
            Bridge.PayReward(member, share)
            Bridge.Framework.server.Notify(member, ('Crew payout: %d %s'):format(share, Config.Currency.label), 'success')
        end
    else
        Bridge.PayReward(src, grossReward)
        Bridge.Framework.server.Notify(src, ('Payout: %d %s'):format(grossReward, Config.Currency.label), 'success')
        for _, member in ipairs(members) do
            if member ~= src then
                local share = Utils.Round(grossReward * Config.Groups.memberRewardMult)
                Bridge.PayReward(member, share)
                Bridge.Framework.server.Notify(member, ('Crew cut: %d %s'):format(share, Config.Currency.label), 'success')
            end
        end
    end

    -- XP: driver/owner always; crew shares if configured
    for _, member in ipairs(members) do
        if member == src or Config.Groups.shareXp then
            local ms = Boost.GetSession(member)
            if ms then Boost.GrantXp(member, ms, contract.xp) end
        end
    end
    Boost.RecordCompletion(src, session, grossReward)
end

-- ── Callbacks (state transitions) ───────────────────────────────────────────

--- Player has reached the target and finished the tracker minigame.
RegisterCallback('contract:hackResult', function(src, session, data)
    local c = Contracts.active[src]
    if not c or c.state ~= 'assigned' then return { error = 'no_contract' } end
    if data.success ~= true then
        return { ok = true, failed = true }
    end

    -- anti-cheat: player must actually be at the spawned target vehicle
    local coords = playerCoords(src)
    if not coords or #(coords - vec3(c.spawn.x, c.spawn.y, c.spawn.z)) > 15.0 then
        return { error = 'not_at_target' }
    end

    setState(c, 'stolen')

    -- hand out vehicle keys server-side (qbx_vehiclekeys / qb-vehiclekeys keep
    -- key state on the server — without this the car stays locked/undrivable)
    local veh = 0
    if type(data.netId) == 'number' then
        local ent = NetworkGetEntityFromNetworkId(data.netId)
        -- sanity: the net id must resolve to a real vehicle near the contract spawn
        if ent ~= 0 and DoesEntityExist(ent)
            and #(GetEntityCoords(ent) - vec3(c.spawn.x, c.spawn.y, c.spawn.z)) <= 50.0 then
            veh = ent
        end
    end
    local plate = type(data.plate) == 'string' and data.plate:sub(1, 12) or ''
    local keyTargets = { src }
    if c.groupId then
        local members = Groups.Members(c.groupId)
        if #members > 0 then keyTargets = members end
    end
    for _, member in ipairs(keyTargets) do
        pcall(Config.GiveKeysServer, member, veh, plate)
    end

    -- attach the GPS tracker (mandatory disable step) if this tier uses one
    Contracts.StartTracker(c, src, plate, coords, (type(data.netId) == 'number' and data.netId or nil))

    -- apply heat + alerts
    if Config.Police.heatWantedStars then
        TriggerClientEvent('boosting:applyHeat', src, c.police)
    end
    if Config.Police.alertOnSteal then
        local coords = playerCoords(src) or vec3(c.spawn.x, c.spawn.y, c.spawn.z)
        if Config.Police.builtinAlert then
            Contracts.PoliceAlert(coords, c.tierLabel, plate)
        end
        pcall(Config.Dispatch, src, coords, c.tierLabel)
    end
    return { ok = true, state = 'stolen' }
end)

--- List of on-duty police server ids (via the framework bridge's GetJob).
function Contracts.OnDutyPolice()
    local jobs = {}
    for _, j in ipairs(Config.Police.countJobs) do jobs[j] = true end
    local out = {}
    for _, pid in ipairs(GetPlayers()) do
        local target = tonumber(pid)
        local job = target and Bridge.Framework.server.GetJob(target)
        if job and jobs[job.name] and job.onduty then out[#out + 1] = target end
    end
    return out
end

--- Built-in police alert — blip + notification to every on-duty officer.
function Contracts.PoliceAlert(coords, tierLabel, plate)
    local payload = {
        x = coords.x, y = coords.y, z = coords.z,
        label = ('%s vehicle theft'):format(tierLabel),
        plate = plate ~= '' and plate or nil,
        sprite = Config.Police.alertBlipSprite,
        colour = Config.Police.alertBlipColour,
        time = Config.Police.alertBlipTime,
        radius = Config.Police.alertRadius,
    }
    local cops = Contracts.OnDutyPolice()
    for _, target in ipairs(cops) do
        TriggerClientEvent('boosting:policeAlert', target, payload)
    end
    Utils.Debug(('police alert sent to %d officer(s)'):format(#cops))
end

-- ── GPS TRACKER ─────────────────────────────────────────────────────────────

local function trackerRequired(tier)
    return Config.Tracker.enabled and Config.Tracker.perTier[tier] ~= false
end

--- Everyone who should see the moving tracker blip: on-duty police + crew
--- members other than the driver (who is in the car already).
function Contracts.TrackerAudience(c)
    local seen, out = {}, {}
    for _, cop in ipairs(Contracts.OnDutyPolice()) do
        if not seen[cop] then seen[cop] = true; out[#out + 1] = cop end
    end
    if c.groupId then
        for _, m in ipairs(Groups.Members(c.groupId)) do
            if m ~= c.ownerSrc and not seen[m] then seen[m] = true; out[#out + 1] = m end
        end
    end
    return out
end

--- Attach the tracker on steal: mark state, tell the driver to start pinging
--- its live position, and spawn a moving blip for police + crew.
function Contracts.StartTracker(c, src, plate, coords, netId)
    if not trackerRequired(c.tier) then
        c.tracker = { required = false, active = false, disabled = true }
        return
    end
    c.tracker = {
        required = true, active = true, disabled = false,
        startedAt = os.time(), escalated = false, lastAlert = 0,
        netId = netId, plate = plate,
        lastCoords = { x = coords.x, y = coords.y, z = coords.z },
    }

    local blip = {
        id = c.id, label = ('%s (tracked)'):format(c.tierLabel), plate = plate ~= '' and plate or nil,
        x = coords.x, y = coords.y, z = coords.z,
        sprite = Config.Tracker.blip.sprite, colour = Config.Tracker.blip.colour, scale = Config.Tracker.blip.scale,
    }
    for _, t in ipairs(Contracts.TrackerAudience(c)) do
        TriggerClientEvent('boosting:trackerStart', t, blip)
    end
    -- the driver runs the position-broadcast loop
    TriggerClientEvent('boosting:trackerOwner', c.ownerSrc, { id = c.id, interval = Config.Tracker.updateInterval })
    TriggerClientEvent('boosting:notify', c.ownerSrc, {
        title = 'GPS Tracker', text = ('This vehicle is tracked. Disable it within %ds or the heat spikes.')
            :format(Config.Tracker.disableTime) })
end

--- Tear down the tracker blip everywhere (disabled / contract ended).
function Contracts.StopTracker(c, reason)
    if not c.tracker or not c.tracker.required then return end
    c.tracker.active = false
    for _, t in ipairs(Contracts.TrackerAudience(c)) do
        TriggerClientEvent('boosting:trackerStop', t, { id = c.id })
    end
    TriggerClientEvent('boosting:trackerStop', c.ownerSrc, { id = c.id })
end

-- Live position relayed from the driver to police + crew. Only the contract
-- owner (driver) may ping, so this can't be spammed by others.
RegisterNetEvent('boosting:trackerPing', function(data)
    local src = source
    local c = Contracts.active[src]
    if not c or not c.tracker or not c.tracker.active then return end
    if type(data) ~= 'table' or type(data.x) ~= 'number' then return end
    c.tracker.lastCoords = { x = data.x, y = data.y, z = data.z }
    local upd = { id = c.id, x = data.x, y = data.y, z = data.z }
    for _, t in ipairs(Contracts.TrackerAudience(c)) do
        TriggerClientEvent('boosting:trackerUpdate', t, upd)
    end
end)

--- Disable the tracker (mandatory step). Eligibility is enforced here, not on
--- the client: solo owner, or crew leader / assigned Hacker.
RegisterCallback('tracker:disable', function(src, session, data)
    local c = Contracts.ResolveForPlayer(src)
    if not c or not c.tracker or not c.tracker.active then return { error = 'no_tracker' } end
    if not Contracts.CanDisable(src, c) then return { error = 'not_hacker' } end

    -- honour the fail cooldown
    if c.tracker.lastFail and (os.time() - c.tracker.lastFail) < Config.Tracker.failCooldown then
        return { error = 'on_cooldown' }
    end
    if data.success ~= true then
        c.tracker.lastFail = os.time()
        return { ok = true, failed = true }
    end

    c.tracker.disabled = true
    Contracts.StopTracker(c, 'disabled')

    -- tell crew + police it went dark
    local audience = { c.ownerSrc }
    if c.groupId then audience = Groups.Members(c.groupId) end
    for _, m in ipairs(audience) do
        TriggerClientEvent('boosting:notify', m, { title = 'GPS Tracker', text = 'Tracker disabled — you\'re off the grid.' })
    end
    for _, cop in ipairs(Contracts.OnDutyPolice()) do
        TriggerClientEvent('boosting:notify', cop, { title = 'Dispatch', text = ('Tracking signal lost on %s.'):format(c.tierLabel) })
    end
    Utils.Debug(('tracker on %s disabled by %s'):format(c.id, src))
    return { ok = true, disabled = true }
end)

-- Escalation: if the tracker isn't killed in time, spike the heat and keep
-- re-alerting police to the live position until it's disabled or the job ends.
CreateThread(function()
    while true do
        Wait(1000)
        local now = os.time()
        for owner, c in pairs(Contracts.active) do
            local tr = c.tracker
            if tr and tr.required and tr.active and not tr.disabled then
                if (now - tr.startedAt) >= Config.Tracker.disableTime then
                    if not tr.escalated then
                        tr.escalated = true
                        TriggerClientEvent('boosting:applyHeat', owner, Config.Tracker.escalation.wantedLevel)
                        TriggerClientEvent('boosting:notify', owner, {
                            title = 'GPS Tracker', text = 'Tracker still live — units are converging on your location!' })
                    end
                    if (now - (tr.lastAlert or 0)) >= Config.Tracker.escalation.alertInterval then
                        tr.lastAlert = now
                        local lc = tr.lastCoords or c.spawn
                        Contracts.PoliceAlert(vec3(lc.x, lc.y, lc.z), c.tierLabel .. ' — TRACKED', tr.plate)
                    end
                end
            end
        end
    end
end)

--- Client reports the police were lost / distance cleared.
RegisterCallback('contract:escaped', function(src, session)
    local c = Contracts.active[src]
    if not c or c.state ~= 'stolen' then return { error = 'no_contract' } end
    setState(c, 'escaped')
    return { ok = true, state = 'escaped' }
end)

--- True while a required tracker is still live — blocks completion.
local function trackerBlocks(c)
    return Config.Tracker.blockDelivery and c.tracker and c.tracker.required and not c.tracker.disabled
end

--- Clean delivery — validate the player is at a drop-off, pay base reward.
RegisterCallback('contract:deliver', function(src, session)
    local c = Contracts.active[src]
    if not c or c.state ~= 'escaped' then return { error = 'not_ready' } end
    if trackerBlocks(c) then return { error = 'tracker_active' } end

    local coords = playerCoords(src)
    if not coords then return { error = 'no_ped' } end
    local atPoint = false
    for _, p in ipairs(Config.Contract.deliveryPoints) do
        if #(coords - p) <= Config.Contract.deliveryRadius + 6.0 then atPoint = true break end
    end
    if not atPoint then return { error = 'not_at_dropoff' } end

    setState(c, 'completed')
    Contracts.StopTracker(c, 'delivered')
    payout(src, session, c, c.reward)
    history(session.identifier, c.tier, c.model, 'delivered', c.reward)
    clearActive(src)
    return { ok = true, reward = c.reward }
end)

--- VIN scratch — validate location, higher reward, keep the vehicle.
RegisterCallback('contract:vin', function(src, session, data)
    local c = Contracts.active[src]
    if not c or c.state ~= 'escaped' then return { error = 'not_ready' } end
    if trackerBlocks(c) then return { error = 'tracker_active' } end
    if data.success ~= true then return { ok = true, failed = true } end

    local coords = playerCoords(src)
    if not coords then return { error = 'no_ped' } end
    local atPoint = false
    for _, p in ipairs(Config.Contract.vinScratchPoints) do
        if #(coords - p) <= Config.Contract.vinScratchRadius + 6.0 then atPoint = true break end
    end
    if not atPoint then return { error = 'not_at_garage' } end

    local reward = c.reward * Config.Contract.vinScratchReward
    setState(c, 'completed')
    Contracts.StopTracker(c, 'vin')
    payout(src, session, c, reward)
    history(session.identifier, c.tier, c.model, 'vin_scratched', Utils.Round(reward))

    -- let server owners hook their keys/garage system to keep the car
    TriggerEvent('boosting:vehicleKept', src, { model = c.model, tier = c.tier, plate = data.plate })

    clearActive(src)
    return { ok = true, reward = Utils.Round(reward), kept = true }
end)

RegisterCallback('contract:abandon', function(src, session)
    local c = Contracts.active[src]
    if not c then return { ok = true } end
    Contracts.StopTracker(c, 'abandoned')
    setState(c, 'abandoned')
    history(session.identifier, c.tier, c.model, 'abandoned', 0)
    clearActive(src)
    TriggerClientEvent('boosting:contractEnded', src, { reason = 'abandoned' })
    return { ok = true }
end)

--- History for the UI.
RegisterCallback('history:list', function(src, session)
    local rows = DB.query([[SELECT `tier`,`model`,`outcome`,`reward`,`created_at`
                            FROM `boosting_history` WHERE `identifier`=? ORDER BY `id` DESC LIMIT 30]],
        { session.identifier })
    return { ok = true, history = rows }
end)

-- Contracts are single-life: dropping mid-run fails the job.
AddEventHandler('playerDropped', function()
    local src = source
    local c = Contracts.active[src]
    if c and c.state ~= 'completed' then
        Contracts.StopTracker(c, 'failed')  -- clear the blip for police/crew
        setState(c, 'failed')
        Contracts.active[src] = nil
    end
end)
