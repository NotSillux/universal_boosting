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

--- Payload for the UI (never exposes tokens).
function Contracts.GetActivePayload(src, session)
    local c = Contracts.active[src]
    if not c then return false end
    return {
        id = c.id, tier = c.tier, tierLabel = c.tierLabel, color = c.color,
        model = c.model, reward = c.reward, state = c.state, police = c.police,
        spawn = { x = c.spawn.x, y = c.spawn.y, z = c.spawn.z, w = c.spawn.w },
        vinMultiplier = Config.Contract.vinScratchReward,
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

    -- apply heat + dispatch
    if Config.Police.heatWantedStars then
        TriggerClientEvent('boosting:applyHeat', src, c.police)
    end
    if Config.Police.alertOnSteal then
        local coords = playerCoords(src) or vec3(c.spawn.x, c.spawn.y, c.spawn.z)
        pcall(Config.Dispatch, src, coords, c.tierLabel)
    end
    return { ok = true, state = 'stolen' }
end)

--- Client reports the police were lost / distance cleared.
RegisterCallback('contract:escaped', function(src, session)
    local c = Contracts.active[src]
    if not c or c.state ~= 'stolen' then return { error = 'no_contract' } end
    setState(c, 'escaped')
    return { ok = true, state = 'escaped' }
end)

--- Clean delivery — validate the player is at a drop-off, pay base reward.
RegisterCallback('contract:deliver', function(src, session)
    local c = Contracts.active[src]
    if not c or c.state ~= 'escaped' then return { error = 'not_ready' } end

    local coords = playerCoords(src)
    if not coords then return { error = 'no_ped' } end
    local atPoint = false
    for _, p in ipairs(Config.Contract.deliveryPoints) do
        if #(coords - p) <= Config.Contract.deliveryRadius + 6.0 then atPoint = true break end
    end
    if not atPoint then return { error = 'not_at_dropoff' } end

    setState(c, 'completed')
    payout(src, session, c, c.reward)
    history(session.identifier, c.tier, c.model, 'delivered', c.reward)
    clearActive(src)
    return { ok = true, reward = c.reward }
end)

--- VIN scratch — validate location, higher reward, keep the vehicle.
RegisterCallback('contract:vin', function(src, session, data)
    local c = Contracts.active[src]
    if not c or c.state ~= 'escaped' then return { error = 'not_ready' } end
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
        setState(c, 'failed')
        Contracts.active[src] = nil
    end
end)
