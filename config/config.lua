Config = {}

-- ═══════════════════════════════════════════════════════════════════════════
--  CORE
-- ═══════════════════════════════════════════════════════════════════════════

Config.Framework = 'auto'    -- 'auto' | 'qbox' | 'qb' | 'esx' | 'standalone'
Config.Inventory = 'auto'    -- 'auto' | 'ox' | 'qb'
Config.Debug     = false

Config.LaptopResource = 'laptop'   -- folder name of the NexOS laptop resource

-- The Boosting App is LAPTOP-EXCLUSIVE: there is no standalone/tablet mode.
-- It can only be opened from the laptop's desktop or App Store (client/main.lua
-- registers it via exports[Laptop]:RegisterApp, and no ui_page / open command
-- exists outside of that — see fxmanifest.lua). This is intentional; do not
-- re-add a standalone command unless you also re-add `ui_page` in the manifest.

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
    -- Require the laptop to be connected to this Config.Networks id (in the
    -- LAPTOP resource) before the app can be installed. Set false for no gate.
    -- 'darknet' is the hidden dark-web network shipped in the laptop config.
    requiresNetwork = 'darknet',
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
        vec4(63.9963, 17.3924, 69.2356, 345.3546),
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

    -- ── Search zone ──────────────────────────────────────────────────────────
    -- Instead of a pinpoint blip, players get a circular search area and must
    -- physically locate the vehicle. The exact blip only appears (and the
    -- vehicle only spawns) once the player gets within `revealDistance` of the
    -- REAL location — which the server never sends to the client until then.
    searchZone = {
        enabled        = true,
        revealDistance = 40.0,  -- metres from the real spot before it's pinpointed
        jitter         = 25.0,  -- metres the zone CENTER is randomised off the real spot (0 = centered exactly on it)
        pollInterval   = 3,     -- seconds between search position pings sent to the server
        -- search-zone radius per tier (bigger for rarer/harder cars)
        radiusByTier = {
            ['D'] = 150.0, ['C'] = 180.0, ['B'] = 220.0,
            ['A'] = 260.0, ['S'] = 300.0, ['S+'] = 350.0,
        },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
--  GPS TRACKER
--  Every stolen vehicle gets a GPS tracker that broadcasts its live position to
--  the booster, their crew AND on-duty police. Disabling it is a MANDATORY step
--  (delivery / VIN scratch are blocked while it is still active). If it isn't
--  disabled in time, the police response escalates hard.
--
--  Crew rule: solo boosters disable it themselves. In a crew, WHO may disable
--  is controlled by Config.Tracker.crewRule (see below).
-- ═══════════════════════════════════════════════════════════════════════════

Config.Tracker = {
    enabled        = true,     -- master switch for the whole tracker system
    disableTime    = 120,      -- seconds to disable before police escalation kicks in
    minigame       = 'timing', -- 'timing' | 'memory' — reuses the laptop's hack minigame
    difficulty     = 2,        -- 1..3
    updateInterval = 3,        -- seconds between live position broadcasts
    failCooldown   = 8,        -- seconds you must wait after a failed disable attempt
    blockDelivery  = true,     -- can't deliver / VIN-scratch until the tracker is down

    -- Who may disable the tracker when boosting AS A CREW (solo players always
    -- disable it themselves):
    --   'non_leader' : the leader CANNOT disable it — any OTHER crew member
    --                  must do it (forces teamwork; the driver/leader keeps
    --                  driving while a passenger breaks the tracker).
    --                  Safety: if the leader is the only online member, they
    --                  are treated as solo so the job can't soft-lock.
    --   'hacker'     : the leader OR the member assigned as "Hacker" in the
    --                  Crew tab may disable it.
    --   'any'        : any crew member may disable it.
    crewRule       = 'non_leader',

    -- Whether a tracker is attached per contract tier (set false to exempt a tier)
    perTier = {
        ['D'] = true, ['C'] = true, ['B'] = true,
        ['A'] = true, ['S'] = true, ['S+'] = true,
    },

    -- What happens if the timer runs out before the tracker is disabled
    escalation = {
        wantedLevel   = 5,   -- force the booster's wanted level to this
        alertInterval = 25,  -- re-alert police every N seconds while it stays active
    },

    -- The moving map blip cops & crew see for the tracked vehicle
    blip = { sprite = 326, colour = 5, scale = 1.0 },
}

-- ═══════════════════════════════════════════════════════════════════════════
--  NPC GUARDS
--  Purely a client-side world-population feature (no server round-trip needed
--  — every client already has full Config access). Guards spawn near the
--  target vehicle during the theft phase; the player can fight or sneak past.
--  They despawn once the tracker is hacked (car obtained) or the job ends.
-- ═══════════════════════════════════════════════════════════════════════════

Config.Npcs = {
    enabled          = true,
    spawnRadius      = 8.0,    -- metres around the vehicle where guards appear
    despawnOnPhaseEnd = true,
    -- ped models to pick from (mix in your own — anything valid works)
    models = { 's_m_y_blackops_01', 's_m_y_blackops_02', 'g_m_importexport_01', 'g_m_importexport_02' },

    -- count / weapon / difficulty per contract tier
    perTier = {
        ['D']  = { count = 1, weapon = 'WEAPON_PISTOL',        health = 100, armor = 0,   accuracy = 25 },
        ['C']  = { count = 2, weapon = 'WEAPON_PISTOL',        health = 120, armor = 0,   accuracy = 35 },
        ['B']  = { count = 2, weapon = 'WEAPON_MICROSMG',      health = 150, armor = 25,  accuracy = 45 },
        ['A']  = { count = 3, weapon = 'WEAPON_SMG',           health = 180, armor = 50,  accuracy = 55 },
        ['S']  = { count = 3, weapon = 'WEAPON_CARBINERIFLE',  health = 220, armor = 75,  accuracy = 65 },
        ['S+'] = { count = 4, weapon = 'WEAPON_CARBINERIFLE',  health = 260, armor = 100, accuracy = 75 },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
--  VEHICLE CONDITION / DAMAGE PAYOUT
--  The final payout is scaled by the vehicle's condition at delivery time
--  (average of body health + engine health). Computed and enforced SERVER-side
--  from the networked vehicle entity — the client only shows a live estimate.
-- ═══════════════════════════════════════════════════════════════════════════

Config.Damage = {
    enabled = true,
    minPayoutMultiplier = 0.35,  -- floor: a wrecked car still pays at least this fraction
    -- condition% -> payout multiplier. Evaluated top-down; first match wins.
    tiers = {
        { minCondition = 90, multiplier = 1.00 },  -- pristine / lightly scuffed
        { minCondition = 75, multiplier = 0.90 },
        { minCondition = 50, multiplier = 0.75 },
        { minCondition = 25, multiplier = 0.55 },
        { minCondition = 0,  multiplier = 0.35 },  -- wrecked
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
--  POLICE / RISK
-- ═══════════════════════════════════════════════════════════════════════════

Config.Police = {
    minRequired      = 0,     -- minimum cops online to run contracts (0 = no gate)
    countJobs        = { 'police', 'sheriff', 'bcso' },
    alertOnSteal     = true,  -- fire an alert when a car is boosted
    escapeLoseStars  = true,  -- player must lose wanted level to reach "escaped"
    escapeDistance   = 350.0, -- OR be this far from the theft point to count as escaped
    heatWantedStars  = true,  -- apply Config.Tiers[tier].police stars on steal

    -- Built-in police alert (works with NO dispatch resource): sends a map blip
    -- + notification to every on-duty player whose job is in countJobs. Turn OFF
    -- if you wire a real dispatch system in Config.Dispatch below.
    builtinAlert     = true,
    alertBlipSprite  = 225,    -- car icon
    alertBlipColour  = 1,      -- red
    alertBlipTime    = 60,     -- seconds the blip/alert stays on the cops' map
    alertRadius      = 120.0,  -- blip radius circle (metres)
}

-- Custom dispatch hook. Runs server-side when a vehicle is stolen IN ADDITION
-- to the built-in alert above. Wire your dispatch resource here, and set
-- Config.Police.builtinAlert = false so cops don't get two alerts.
--   src = booster source, coords = theft location, tierLabel = e.g. 'B-Class'
Config.Dispatch = function(src, coords, tierLabel)
    -- ── examples (uncomment the one you use) ──────────────────────────────
    -- ps-dispatch:
    --   local ped = GetPlayerPed(src)
    --   exports['ps-dispatch']:VehicleTheft(ped)
    -- cd_dispatch:
    --   local info = { dispatchcode = '10-72', message = ('%s Vehicle Theft'):format(tierLabel),
    --                  origin = { x = coords.x, y = coords.y, z = coords.z } }
    --   TriggerEvent('cd_dispatch:AddNotification', info)
    -- core_dispatch:
    --   exports.core_dispatch:addCall('10-72', 'Grand Theft Auto',
    --     {{icon='fa-car', info=tierLabel}}, {coords.x,coords.y,coords.z}, 'CRIMINAL', 'car_theft', 45000, 'blip_name')
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
    maxSize      = 4,
    inviteExpiry = 180,   -- seconds a crew invite stays acceptable
    shareXp      = true,  -- crew members all gain XP on completion

    -- ── Payout distribution ──────────────────────────────────────────────────
    -- payoutMode:
    --   'equal'        : the reward is split evenly across all online crew
    --                    members — nobody gets more just for being the leader.
    --   'leader_bonus' : same even split, but the leader's cut is topped up by
    --                    `leaderBonus` — funded ON TOP of the pool, not taken
    --                    out of the other members' shares.
    payoutMode  = 'equal',
    leaderBonus = 0.15,   -- 'leader_bonus' mode: extra fraction of the total reward added to the leader's share

    -- Extra reward for the WHOLE crew if everyone shows up together at the
    -- final step (all online members within `fullCrewRadius` of the delivery
    -- / VIN point when the job completes). Rewards genuine teamwork instead of
    -- one driver doing everything while AFK crewmates still collect a cut.
    fullCrewBonus  = 0.20,  -- fraction of the base reward, split evenly among the whole crew
    fullCrewRadius = 15.0,  -- metres from the delivery/VIN point everyone must be within
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
--  VIN-SCRATCH GARAGE STORAGE
--  After a successful VIN scratch the car gets a CLEAN identity: a fresh plate
--  is generated server-side, the vehicle is registered to the player in the
--  server's garage database, and keys are handed out for the new plate — so
--  the player can store it in any normal garage afterwards.
--
--  system:
--    'auto'   : QB/Qbox -> insert into `player_vehicles`
--               ESX     -> insert into `owned_vehicles`
--               (both are the standard tables every mainstream garage script
--                reads: qb-garages, qs, jg, cd_garage, esx_garage, okokGarage…)
--    'qb'/'esx' : force one of the above
--    'custom' : call Config.Garage.custom(src, data) and do it yourself
--    'none'   : keep the car spawned but don't register ownership
-- ═══════════════════════════════════════════════════════════════════════════

Config.Garage = {
    enabled       = true,
    system        = 'auto',
    defaultGarage = 'pillboxgarage',  -- QB only: which garage the car belongs to
    -- custom integration (system = 'custom'):
    -- data = { identifier, plate, model, hash, props (table), tier }
    custom = function(src, data)
        -- e.g. exports['my_garage']:RegisterVehicle(src, data.plate, data.props)
    end,
}

-- ═══════════════════════════════════════════════════════════════════════════
--  POLICE VIN CHECK
--  Lets authorized jobs inspect a vehicle's VIN. Results:
--    clean     — no record
--    scratched — the plate belongs to a VIN-scratched boosting car
--    stolen    — the plate belongs to a LIVE boosting contract (hot car)
--  Trigger: /checkvin (nearest vehicle or the one you're in), an optional
--  keybind, or from any target/radial resource via the client export:
--      exports['universal_boosting']:CheckVin(vehicleEntity)
--  Every check is logged to `boosting_vin_checks` (/boostadmin vinlogs).
-- ═══════════════════════════════════════════════════════════════════════════

Config.VinCheck = {
    enabled     = true,
    jobs        = { 'police', 'sheriff', 'bcso' }, -- who may run checks (server-checked)
    command     = 'checkvin',   -- false to disable the command
    keybind     = false,        -- e.g. 'F7' to add a rebindable key
    maxDistance = 5.0,          -- metres to the target vehicle
    scanTime    = 2500,         -- ms the "scanning" takes (roleplay pacing)
    logChecks   = true,         -- write every check to the DB for admins
}

-- ═══════════════════════════════════════════════════════════════════════════
--  ADMIN
-- ═══════════════════════════════════════════════════════════════════════════

Config.Admin = {
    command  = 'boostadmin',
    -- ace permission required (add via server.cfg: add_ace group.admin boosting.admin allow)
    ace      = 'boosting.admin',
}
