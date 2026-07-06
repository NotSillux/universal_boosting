--[[
    Contract lifecycle — fully server-authoritative state machine.

    States:
      assigned  -> a search zone (or target, if search zones are disabled) has
                   been issued; player must locate & hack the vehicle
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

--- Build a search-zone circle around the real spawn point. The center may be
--- jittered away from the real spot for extra obfuscation (Config.Contract
--- .searchZone.jitter); the real spot is NEVER sent to the client until the
--- player proves (via contract:searchPing) that they're within revealDistance.
local function makeZone(spawn, tierKey)
    local sz = Config.Contract.searchZone
    local cx, cy = spawn.x, spawn.y
    if sz.jitter and sz.jitter > 0 then
        local angle = math.random() * 2 * math.pi
        local dist = math.random() * sz.jitter
        cx = cx + math.cos(angle) * dist
        cy = cy + math.sin(angle) * dist
    end
    local radius = (sz.radiusByTier and sz.radiusByTier[tierKey]) or 200.0
    return { x = cx, y = cy, z = spawn.z, radius = radius }
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
    local szEnabled = Config.Contract.searchZone and Config.Contract.searchZone.enabled

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
        spawn = spawn,               -- REAL location — never sent to the client until revealed
        zone = makeZone(spawn, tierKey),
        revealed = not szEnabled,    -- search zones off -> behave like the old exact-blip flow
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
        deliveryPoints = Config.Contract.deliveryPoints,
        vinPoints = Config.Contract.vinScratchPoints,
        deliveryRadius = Config.Contract.deliveryRadius,
        vinRadius = Config.Contract.vinScratchRadius,
        vinMultiplier = Config.Contract.vinScratchReward,
    }
    if contract.revealed then
        contract.clientPayload.spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w }
        contract.clientPayload.searchZone = false
    else
        contract.clientPayload.spawn = false
        contract.clientPayload.searchZone = { x = contract.zone.x, y = contract.zone.y,
            z = contract.zone.z, radius = contract.zone.radius }
    end

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
--- Solo → the owner. Crew → governed by Config.Tracker.crewRule.
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
        -- which crew rule is active + whether this is a crew job, so the UI
        -- can explain WHO can disable it (see Config.Tracker.crewRule)
        rule       = Config.Tracker.crewRule or 'non_leader',
        isCrewJob  = c.groupId ~= nil,
    }
end

--- Payload for the UI (never exposes tokens or the un-revealed real spawn).
--- Works for the owner AND crew members tagging along.
function Contracts.GetActivePayload(src, session)
    local c, isOwner = Contracts.ResolveForPlayer(src)
    if not c then return false end

    local payload = {
        id = c.id, tier = c.tier, tierLabel = c.tierLabel, color = c.color,
        model = c.model, reward = c.reward, state = c.state, police = c.police,
        vinMultiplier = Config.Contract.vinScratchReward,
        isOwner = isOwner,
        tracker = trackerPayload(c, src),
    }
    if c.revealed or c.state ~= 'assigned' then
        payload.spawn = { x = c.spawn.x, y = c.spawn.y, z = c.spawn.z, w = c.spawn.w }
        payload.searchZone = false
    else
        payload.spawn = false
        payload.searchZone = { x = c.zone.x, y = c.zone.y, z = c.zone.z, radius = c.zone.radius }
    end
    return payload
end

--- Everyone tied to a contract: the owner + their crew (or just the owner).
local function contractAudience(c)
    if c.groupId then
        local m = Groups.Members(c.groupId)
        if #m > 0 then return m end
    end
    return { c.ownerSrc }
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

--- Force-end a contract from any code path (admin panel, /boostadmin, a
--- player disconnecting mid-run). Tears down the tracker blip for police/crew
--- and clears the queue entry so the slot isn't stuck. Returns true if there
--- was an active contract to end.
function Contracts.ForceEnd(src, reason)
    local c = Contracts.active[src]
    if not c then return false end
    Contracts.StopTracker(c, reason or 'admin')
    setState(c, reason or 'failed')
    Contracts.active[src] = nil
    if Queue and Queue.Remove then Queue.Remove(src) end
    TriggerClientEvent('boosting:contractEnded', src, { reason = reason or 'admin' })
    return true
end

-- ── Reward payout (handles crews) ───────────────────────────────────────────

--- True when every member of `members` is online AND within `radius` of
--- `point` — used for the full-crew participation bonus (Config.Groups
--- .fullCrewBonus). Solo jobs never qualify (there's no "team" to reward).
local function fullCrewPresent(members, point, radius)
    if #members <= 1 or not point then return false end
    for _, m in ipairs(members) do
        local pc = playerCoords(m)
        if not pc or #(pc - point) > radius then return false end
    end
    return true
end

--- Compute and pay out shares for a completed contract.
--- `deliveryPoint` is the actual vec3 the player delivered/scratched at — used
--- only to check full-crew participation; may be nil (no bonus in that case).
local function payout(src, session, contract, grossReward, deliveryPoint)
    grossReward = Utils.Round(grossReward)
    local members = contractAudience(contract)
    local n = #members

    -- base: split evenly across every online crew member (or the full amount
    -- if solo)
    local baseShare = Utils.Round(grossReward / n)
    local shares = {}
    for _, m in ipairs(members) do shares[m] = baseShare end

    -- leader bonus: funded ON TOP of the pool, doesn't reduce anyone else's cut
    if n > 1 and Config.Groups.payoutMode == 'leader_bonus' and contract.groupId then
        local g = Groups.groups[contract.groupId]
        if g and g.leader and shares[g.leader] then
            shares[g.leader] = shares[g.leader] + Utils.Round(grossReward * (Config.Groups.leaderBonus or 0))
        end
    end

    -- full-crew participation bonus: everyone showed up together at the end
    local fullCrew = fullCrewPresent(members, deliveryPoint, Config.Groups.fullCrewRadius or 15.0)
    if fullCrew then
        local bonusEach = Utils.Round((grossReward * (Config.Groups.fullCrewBonus or 0)) / n)
        for _, m in ipairs(members) do shares[m] = shares[m] + bonusEach end
    end

    for _, m in ipairs(members) do
        local share = shares[m] or baseShare
        Bridge.PayReward(m, share)
        local label = (m == src) and 'Payout' or 'Crew payout'
        Bridge.Framework.server.Notify(m, ('%s: %d %s%s'):format(
            label, share, Config.Currency.label, fullCrew and ' (+full crew bonus)' or ''), 'success')
    end

    -- XP: driver/owner always; crew shares if configured
    for _, member in ipairs(members) do
        if member == src or Config.Groups.shareXp then
            local ms = Boost.GetSession(member)
            if ms then Boost.GrantXp(member, ms, contract.xp) end
        end
    end
    -- record the ACTUAL amount paid to the acting player, not the gross pool
    Boost.RecordCompletion(src, session, shares[src] or baseShare)
end

-- ── Vehicle condition (damage-based payout scaling) ─────────────────────────

--- Average body/engine health of a networked vehicle, as a 0-100 percentage.
--- `refCoords`, if given, sanity-checks the entity is actually near the
--- reporting player (defends against a spoofed/stale net id).
local function vehicleCondition(netId, refCoords)
    if not Config.Damage.enabled then return 100 end
    if type(netId) ~= 'number' then return 100 end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if ent == 0 or not DoesEntityExist(ent) or GetEntityType(ent) ~= 2 then return 100 end
    if refCoords and #(GetEntityCoords(ent) - refCoords) > 30.0 then return 100 end

    local body = GetEntityHealth(ent)          -- 0..1000 (default vehicle max)
    local engine = GetVehicleEngineHealth(ent) -- can go negative when destroyed; 1000 = perfect
    local bodyPct = math.max(0, math.min(100, (body / 1000) * 100))
    local enginePct = math.max(0, math.min(100, (engine / 1000) * 100))
    return (bodyPct + enginePct) / 2
end

-- ── Callbacks (state transitions) ───────────────────────────────────────────

--- Player reports they've searched close enough to the real vehicle location.
--- The server is the only one who ever knows the real spot before this point.
RegisterCallback('contract:searchPing', function(src, session, data)
    local c = Contracts.ResolveForPlayer(src)
    if not c or c.state ~= 'assigned' then return { error = 'no_contract' } end

    if c.revealed then
        return { ok = true, revealed = true, spawn = { x = c.spawn.x, y = c.spawn.y, z = c.spawn.z, w = c.spawn.w } }
    end
    if type(data.x) ~= 'number' or type(data.y) ~= 'number' or type(data.z) ~= 'number' then
        return { error = 'bad_request' }
    end

    local dist = #(vec3(data.x, data.y, data.z) - vec3(c.spawn.x, c.spawn.y, c.spawn.z))
    if dist <= (Config.Contract.searchZone.revealDistance or 40.0) then
        c.revealed = true
        local spawnPayload = { x = c.spawn.x, y = c.spawn.y, z = c.spawn.z, w = c.spawn.w }
        for _, t in ipairs(contractAudience(c)) do
            TriggerClientEvent('boosting:contractRevealed', t, { spawn = spawnPayload })
        end
        return { ok = true, revealed = true, spawn = spawnPayload }
    end
    return { ok = true, revealed = false, distance = Utils.Round(dist) }
end)

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
    c.plate = plate ~= '' and plate or nil   -- hot plate → police VIN checks report 'stolen'
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
--- the client: solo owner, or governed by Config.Tracker.crewRule.
RegisterCallback('tracker:disable', function(src, session, data)
    local c = Contracts.ResolveForPlayer(src)
    if not c or not c.tracker or not c.tracker.active then return { error = 'no_tracker' } end
    -- crew eligibility (rule-dependent, see Config.Tracker.crewRule) is
    -- enforced HERE — hiding the button client-side is cosmetic only
    if not Contracts.CanDisable(src, c) then return { error = 'not_eligible' } end

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
    for _, m in ipairs(contractAudience(c)) do
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

--- Clean delivery — validate the player is at a drop-off, scale the reward by
--- vehicle condition, pay out.
RegisterCallback('contract:deliver', function(src, session, data)
    local c = Contracts.active[src]
    if not c or c.state ~= 'escaped' then return { error = 'not_ready' } end
    if trackerBlocks(c) then return { error = 'tracker_active' } end

    local coords = playerCoords(src)
    if not coords then return { error = 'no_ped' } end
    local atPoint, matchedPoint = false, nil
    for _, p in ipairs(Config.Contract.deliveryPoints) do
        if #(coords - p) <= Config.Contract.deliveryRadius + 6.0 then atPoint = true; matchedPoint = p; break end
    end
    if not atPoint then return { error = 'not_at_dropoff' } end

    -- damage-based payout scaling (Config.Damage) — computed from the real,
    -- server-resolved vehicle entity, never trusted from the client
    local condition = vehicleCondition(data.netId, coords)
    local multiplier = Utils.VehicleConditionMultiplier(condition)
    local finalReward = Utils.Round(c.reward * multiplier)

    setState(c, 'completed')
    Contracts.StopTracker(c, 'delivered')
    payout(src, session, c, finalReward, matchedPoint)
    history(session.identifier, c.tier, c.model, 'delivered', finalReward)
    clearActive(src)
    return { ok = true, reward = finalReward, condition = Utils.Round(condition), multiplier = multiplier }
end)

--- VIN scratch — validate location, apply damage scaling, higher reward, keep
--- the vehicle.
RegisterCallback('contract:vin', function(src, session, data)
    local c = Contracts.active[src]
    if not c or c.state ~= 'escaped' then return { error = 'not_ready' } end
    if trackerBlocks(c) then return { error = 'tracker_active' } end
    if data.success ~= true then return { ok = true, failed = true } end

    local coords = playerCoords(src)
    if not coords then return { error = 'no_ped' } end
    local atPoint, matchedPoint = false, nil
    for _, p in ipairs(Config.Contract.vinScratchPoints) do
        if #(coords - p) <= Config.Contract.vinScratchRadius + 6.0 then atPoint = true; matchedPoint = p; break end
    end
    if not atPoint then return { error = 'not_at_garage' } end

    local condition = vehicleCondition(data.netId, coords)
    local condMultiplier = Utils.VehicleConditionMultiplier(condition)
    local reward = c.reward * Config.Contract.vinScratchReward * condMultiplier

    setState(c, 'completed')
    Contracts.StopTracker(c, 'vin')
    payout(src, session, c, reward, matchedPoint)
    history(session.identifier, c.tier, c.model, 'vin_scratched', Utils.Round(reward))

    -- ── clean identity: fresh plate + garage registration + keys ──────────
    -- The scratched car gets a new server-generated plate and is inserted
    -- into the framework's vehicle-ownership table (see server/garage.lua),
    -- so the player can store it in any normal garage. The plate is also
    -- recorded in `boosting_vin_records` — police VIN checks will flag it
    -- as 'scratched' forever.
    local newPlate = Garage.GeneratePlate()
    local garaged = false
    if Config.Garage.enabled then
        garaged = Garage.Register(src, session, {
            plate = newPlate,
            model = c.model,
            props = type(data.props) == 'table' and data.props or nil,
            tier = c.tier,
        })
    end
    DB.execute([[INSERT IGNORE INTO `boosting_vin_records` (`plate`,`identifier`,`model`,`tier`)
                 VALUES (?,?,?,?)]], { newPlate, session.identifier, c.model, c.tier })

    -- give keys for the NEW plate (entity resolved from the client's net id)
    local veh = 0
    if type(data.netId) == 'number' then
        local ent = NetworkGetEntityFromNetworkId(data.netId)
        if ent ~= 0 and DoesEntityExist(ent)
            and #(GetEntityCoords(ent) - coords) <= 30.0 then
            veh = ent
        end
    end
    pcall(Config.GiveKeysServer, src, veh, newPlate)
    c.plate = nil -- no longer a hot plate; the new identity lives in vin_records

    -- legacy hook (kept for compatibility) + richer event with the new plate
    TriggerEvent('boosting:vehicleKept', src, { model = c.model, tier = c.tier, plate = newPlate })
    TriggerEvent('boosting:vehicleRegistered', src, { model = c.model, tier = c.tier,
        plate = newPlate, garaged = garaged })

    clearActive(src)
    return { ok = true, reward = Utils.Round(reward), kept = true,
             newPlate = newPlate, garaged = garaged,
             condition = Utils.Round(condition), multiplier = condMultiplier }
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
    Contracts.ForceEnd(src, 'failed')
end)
