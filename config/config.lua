Config = {}

-- ═══════════════════════════════════════════════════════════════════════════
--  CORE
-- ═══════════════════════════════════════════════════════════════════════════

Config.Framework = 'auto'    -- 'auto' | 'qbox' | 'qb' | 'esx' | 'standalone'
Config.Inventory = 'auto'    -- 'auto' | 'ox' | 'qb'
Config.Debug     = false

Config.LaptopResource = 'laptop'   -- folder name of the NexOS laptop resource
Config.Command        = 'boosting' -- opens the app standalone (false to disable)

-- ═══════════════════════════════════════════════════════════════════════════
--  APP STORE LISTING  (how it appears inside the laptop)
-- ═══════════════════════════════════════════════════════════════════════════

Config.Store = {
    id          = 'boosting',
    name        = 'Car Boosting',
    developer   = 'Universal',
    category    = 'Crime',
    icon        = '🚗',
    price       = 0,        -- charged from the laptop's Config.Store.currency
    description = "Run high-risk vehicle theft contracts.\n\n" ..
                  "• Steal cars, hack their trackers and outrun the cops\n" ..
                  "• Team up with a crew and share the payout\n" ..
                  "• Deliver clean, or scratch the VIN and keep the car\n" ..
                  "• Level up your Hacker and Driver skills for better jobs\n" ..
                  "• Climb the global & weekly leaderboards",
    screenshots = {},       -- optional image URLs shown in the store
}

-- ═══════════════════════════════════════════════════════════════════════════
--  CURRENCY  (the "crypto" players earn)
-- ═══════════════════════════════════════════════════════════════════════════

Config.Currency = {
    type    = 'item',       -- 'item' (recommended, e.g. a crypto item) or 'money'
    item    = 'cryptostick',-- when type == 'item'
    account = 'bank',       -- when type == 'money' ('bank'|'cash'|'crypto')
    label   = 'Crypto',
}

-- ═══════════════════════════════════════════════════════════════════════════
--  PROGRESSION
--  XP is tracked in three tracks: overall boosting level, hacker XP, driver XP.
--  A contract's tier is gated by the player's boosting level.
-- ═══════════════════════════════════════════════════════════════════════════

Config.Progression = {
    -- boosting level -> XP required to reach it (index 1 = level 1). The last
    -- entry repeats for every level beyond it.
    levelCurve = { 0, 250, 600, 1100, 1800, 2800, 4200, 6000, 8500, 12000 },
    maxLevel   = 50,

    -- skill perks: every N hacker levels shortens the tracker minigame timer,
    -- every N driver levels reduces police heat. Purely illustrative hooks.
    hackerXpPerLevel = 300,
    driverXpPerLevel = 300,
}

-- ═══════════════════════════════════════════════════════════════════════════
--  TIERS  (D → S+)
--  minLevel   : boosting level required to be offered this tier
--  reward     : base crypto payout (delivery). VIN scratch multiplies it.
--  xp         : { boost, hacker, driver } granted on completion
--  hackGame   : 'memory' | 'timing'   difficulty : 1..3 (tracker minigame)
--  police     : wanted stars applied when the car is stolen
--  vehicles   : spawn models for this tier
-- ═══════════════════════════════════════════════════════════════════════════

Config.Tiers = {
    ['D'] = {
        label = 'D-Class', color = '#8a94a6', minLevel = 1, weight = 40,
        reward = 1200, xp = { boost = 60, hacker = 40, driver = 40 },
        hackGame = 'memory', difficulty = 1, police = 1,
        vehicles = { 'blista', 'panto', 'prairie', 'rhapsody' },
    },
    ['C'] = {
        label = 'C-Class', color = '#5ac2e8', minLevel = 3, weight = 28,
        reward = 2600, xp = { boost = 110, hacker = 80, driver = 80 },
        hackGame = 'memory', difficulty = 2, police = 2,
        vehicles = { 'sultan', 'kuruma', 'buffalo', 'fugitive' },
    },
    ['B'] = {
        label = 'B-Class', color = '#47c78c', minLevel = 6, weight = 18,
        reward = 4800, xp = { boost = 180, hacker = 130, driver = 130 },
        hackGame = 'timing', difficulty = 2, police = 3,
        vehicles = { 'comet2', 'sentinel', 'elegy2', 'jester' },
    },
    ['A'] = {
        label = 'A-Class', color = '#e0a842', minLevel = 10, weight = 9,
        reward = 8500, xp = { boost = 300, hacker = 220, driver = 220 },
        hackGame = 'timing', difficulty = 3, police = 3,
        vehicles = { 'italigtb', 'nero', 'pariah', 't20' },
    },
    ['S'] = {
        label = 'S-Class', color = '#e0565f', minLevel = 16, weight = 4,
        reward = 15000, xp = { boost = 480, hacker = 360, driver = 360 },
        hackGame = 'timing', difficulty = 3, police = 4,
        vehicles = { 'zentorno', 'osiris', 'reaper', 'tempesta' },
    },
    ['S+'] = {
        label = 'S+ Exotic', color = '#c471ed', minLevel = 24, weight = 1,
        reward = 26000, xp = { boost = 750, hacker = 560, driver = 560 },
        hackGame = 'timing', difficulty = 3, police = 5,
        vehicles = { 'adder', 'entityxf', 'krieger', 'emerus' },
    },
}
-- order low → high (used for leaderboards / offers)
Config.TierOrder = { 'D', 'C', 'B', 'A', 'S', 'S+' }

-- ═══════════════════════════════════════════════════════════════════════════
--  CONTRACTS
-- ═══════════════════════════════════════════════════════════════════════════

Config.Contract = {
    queueCooldown   = 15,     -- seconds between queue pops (assignment throttle)
    assignExpiry    = 120,    -- seconds a fresh assignment stays acceptable
    abandonPenalty  = 0.15,   -- fraction of reward lost as a "heat" penalty (cosmetic)
    maxActivePerPlayer = 1,

    -- where target vehicles spawn. The system picks the nearest few to the
    -- player and assigns one. Add as many as you like.
    spawnPoints = {
        vec4(-47.8, -1094.8, 26.4, 160.0),
        vec4(122.5, -1088.5, 29.2, 200.0),
        vec4(-337.9, -1048.5, 30.3, 25.0),
        vec4(795.4, -2998.9, 5.9, 90.0),
        vec4(-1160.8, -1425.6, 4.4, 215.0),
        vec4(1140.6, -770.2, 57.5, 95.0),
    },

    -- clean delivery drop-offs (Normal Delivery)
    deliveryPoints = {
        vec3(1237.8, -3126.5, 5.0),
        vec3(-441.9, -1698.0, 18.9),
        vec3(717.6, -1088.0, 22.1),
    },
    deliveryRadius = 8.0,

    -- secret VIN-scratch garages (keep the car, higher reward)
    vinScratchPoints = {
        vec3(1197.6, -3253.6, 6.0),
        vec3(-1330.4, -1284.9, 4.4),
    },
    vinScratchRadius = 6.0,
    vinScratchReward = 1.9,    -- reward multiplier vs. clean delivery
    vinScratchGame   = 'timing',
    vinScratchDiff   = 3,
}

-- ═══════════════════════════════════════════════════════════════════════════
--  POLICE / RISK
-- ═══════════════════════════════════════════════════════════════════════════

Config.Police = {
    minRequired      = 0,     -- minimum cops online to run contracts (0 = no gate)
    countJobs        = { 'police', 'sheriff', 'bcso' },
    alertOnSteal     = true,  -- fire a dispatch alert when a car is boosted
    escapeLoseStars  = true,  -- player must lose wanted level to reach "escaped"
    escapeDistance   = 350.0, -- OR be this far from the theft point to count as escaped
    heatWantedStars  = true,  -- apply Config.Tiers[tier].police stars on steal
}

-- If you use a custom dispatch (ps-dispatch, cd_dispatch, etc.), wire it here.
-- Runs server-side when a vehicle is stolen. src = booster, coords = theft loc.
Config.Dispatch = function(src, coords, tierLabel)
    -- example: exports['ps-dispatch']:VehicleTheftAlert(src, coords)
    if Config.Debug then
        print(('[boosting] dispatch: %s boosting a %s'):format(GetPlayerName(src) or src, tierLabel))
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  VEHICLE KEYS  (CLIENT-side hook)
--  Runs after a successful tracker hack so the booster can actually enter and
--  start the car. Unlocking the doors is done by the script itself — this hook
--  only integrates with vehicle-key/lock resources, which otherwise block the
--  engine (or re-lock the doors) for cars the player "doesn't own".
--
--  Auto-detects the common systems below; if yours is missing, replace the
--  body with your key resource's client export/event. `vehicle` is the entity
--  handle, `plate` is the trimmed plate text.
-- ═══════════════════════════════════════════════════════════════════════════

-- SERVER-side keys hook — this is the one that matters on Qbox/QB servers,
-- because qbx_vehiclekeys and modern qb-vehiclekeys track keys on the SERVER.
-- Called for the booster and every crew member after a successful hack.
-- Returns true when a key system handled it (the client hook still runs as a
-- fallback for purely client-side key resources).
Config.GiveKeysServer = function(src, vehicle, plate)
    local started = function(res) return GetResourceState(res):find('start') ~= nil end

    if started('qbx_vehiclekeys') and vehicle and vehicle ~= 0 then
        -- Qbox keys: documented server export, entity-based
        local ok = pcall(function() exports.qbx_vehiclekeys:GiveKeys(src, vehicle) end)
        if ok then return true end
    end
    if started('qb-vehiclekeys') then
        -- new qb-vehiclekeys has a server export; older ones use the client event
        local ok = pcall(function() exports['qb-vehiclekeys']:GiveKeys(src, plate) end)
        if not ok then TriggerClientEvent('vehiclekeys:client:SetOwner', src, plate) end
        return true
    end
    return false
end

Config.GiveKeys = function(vehicle, plate)
    local started = function(res) return GetResourceState(res):find('start') ~= nil end

    if started('qbx_vehiclekeys') then
        -- Qbox keys (entity-based export)
        local ok = pcall(function() exports.qbx_vehiclekeys:GiveKeys(vehicle) end)
        if ok then return end
    end
    if started('qb-vehiclekeys') then
        TriggerEvent('vehiclekeys:client:SetOwner', plate)
        return
    end
    if started('wasabi_carlock') then
        pcall(function() exports.wasabi_carlock:GiveKey(plate) end)
        return
    end
    if started('qs-vehiclekeys') then
        pcall(function()
            exports['qs-vehiclekeys']:GiveKeys(plate, GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)))
        end)
        return
    end
    if started('mk_vehiclekeys') then
        pcall(function() exports['mk_vehiclekeys']:AddKey(vehicle) end)
        return
    end
    -- no key system detected: nothing to do — the doors are already unlocked.
end

-- ═══════════════════════════════════════════════════════════════════════════
--  GROUPS / CREWS
-- ═══════════════════════════════════════════════════════════════════════════

Config.Groups = {
    maxSize        = 4,
    rewardSplit    = 'equal',  -- 'equal' | 'leader' (leader takes all, splits manually)
    shareXp        = true,     -- crew members all gain XP on completion
    memberRewardMult = 0.6,    -- non-driver members get this fraction of the reward each
}

-- ═══════════════════════════════════════════════════════════════════════════
--  AUCTION  (sell unwanted contracts to other players)
-- ═══════════════════════════════════════════════════════════════════════════

Config.Auction = {
    enabled     = true,
    duration    = 600,     -- seconds an auction stays live
    minBid      = 100,
    listingFee  = 0.05,    -- fraction of starting price paid to list (anti-spam)
    maxListingsPerPlayer = 3,
}

-- ═══════════════════════════════════════════════════════════════════════════
--  LEADERBOARDS
-- ═══════════════════════════════════════════════════════════════════════════

Config.Leaderboard = {
    topN       = 25,
    weeklyReset = 1,       -- day of week to reset weekly stats (1 = Monday)
}

-- ═══════════════════════════════════════════════════════════════════════════
--  ADMIN
-- ═══════════════════════════════════════════════════════════════════════════

Config.Admin = {
    command  = 'boostadmin',
    -- ace permission required (add via server.cfg: add_ace group.admin boosting.admin allow)
    ace      = 'boosting.admin',
}
