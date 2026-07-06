--[[
    Contract world phase — the actual gameplay loop, driven client-side but
    validated server-side at every transition.

    Flow: assigned → (search zone*) → (drive to target, hack tracker) → stolen
          → (escape police) → escaped → deliver clean OR scratch VIN → completed

    * Search zone: the server does NOT reveal the real vehicle location up
      front. The client only gets a circular search area; once the player's
      reported position is close enough (contract:searchPing), the server
      reveals the real spot and the vehicle spawns. See Config.Contract.searchZone.

    The tracker & VIN minigames reuse the laptop's StartHacking export when the
    laptop is present, and fall back to a small built-in skill check otherwise.
]]

local world = {
    contract = nil,
    veh = nil,
    blip = nil,
    zoneRadiusBlip = nil,  -- the soft circle drawn under the search-zone blip
    dropBlips = {},
    phase = nil,       -- 'search' | 'goto' | 'stolen' | 'escaped'
    theftCoords = nil,
    loop = false,
    tracking = false,  -- driver is broadcasting the tracked vehicle's position
}

-- ── GPS tracker position broadcast (driver side) ────────────────────────────
-- The server tells the driver (contract owner) to start pinging when the car
-- is stolen; we send the live vehicle position until the tracker is disabled,
-- the contract ends, or the car is destroyed.

function BClient.StartTrackerPing(intervalSec)
    if world.tracking then return end
    world.tracking = true
    local interval = (intervalSec or 3) * 1000
    CreateThread(function()
        while world.tracking do
            if world.veh and DoesEntityExist(world.veh) then
                local c = GetEntityCoords(world.veh)
                TriggerServerEvent('boosting:trackerPing', { x = c.x, y = c.y, z = c.z })
            end
            Wait(interval)
        end
    end)
end

function BClient.StopTrackerPing()
    world.tracking = false
end

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function notify(msg, type_) Bridge.Framework.client.Notify(msg, type_ or 'inform') end

local function help(msg)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

local function makeBlip(coords, sprite, colour, label, route)
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, sprite)
    SetBlipColour(blip, colour)
    SetBlipScale(blip, 0.9)
    SetBlipAsShortRange(blip, not route)
    if route then SetBlipRoute(blip, true); SetBlipRouteColour(blip, colour) end
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(blip)
    return blip
end

local function clearBlips()
    if world.blip then RemoveBlip(world.blip); world.blip = nil end
    if world.zoneRadiusBlip then RemoveBlip(world.zoneRadiusBlip); world.zoneRadiusBlip = nil end
    for _, b in ipairs(world.dropBlips) do RemoveBlip(b) end
    world.dropBlips = {}
end

--- Run a minigame, reusing the laptop's if available. Exposed on BClient so
--- the GPS-tracker disable (client/main.lua) can share the exact same system.
local function runMinigame(game, difficulty)
    if GetResourceState(Config.LaptopResource) == 'started' then
        local ok, res = pcall(function()
            return exports[Config.LaptopResource]:StartHacking(game, difficulty)
        end)
        if ok then return res end
    end
    return FallbackSkillCheck(difficulty)
end
BClient.RunMinigame = runMinigame

-- ── NPC guards (client-only world dressing; see Config.Npcs) ─────────────────
-- No server round-trip needed — Config is a shared_script, so every client
-- already has the full tier/weapon/difficulty tables locally.

local npcPeds = {}
local GUARD_REL_GROUP = 'UB_BOOSTING_GUARDS'
local guardRelGroupHash = nil

local function ensureGuardRelationshipGroup()
    if guardRelGroupHash then return guardRelGroupHash end
    local _, hash = AddRelationshipGroup(GUARD_REL_GROUP)
    guardRelGroupHash = hash or GetHashKey(GUARD_REL_GROUP)
    -- Companion with self so guards never turn on each other (crossfire, etc.)
    SetRelationshipBetweenGroups(0, guardRelGroupHash, guardRelGroupHash, true)
    SetRelationshipBetweenGroups(5, guardRelGroupHash, GetHashKey('PLAYER'), true)
    SetRelationshipBetweenGroups(5, GetHashKey('PLAYER'), guardRelGroupHash, true)
    return guardRelGroupHash
end

local function spawnGuards(coords, tierKey)
    if not Config.Npcs.enabled then return end
    local def = Config.Npcs.perTier[tierKey] or Config.Npcs.perTier['D']
    if not def then return end
    local models = Config.Npcs.models
    if not models or #models == 0 then return end

    CreateThread(function()
        for _ = 1, (def.count or 1) do
            local model = joaat(models[math.random(#models)])
            RequestModel(model)
            local t = GetGameTimer() + 3000
            while not HasModelLoaded(model) and GetGameTimer() < t do Wait(10) end
            if HasModelLoaded(model) then
                local angle = math.random() * 2 * math.pi
                local dist = math.random(3, math.max(3, math.floor(Config.Npcs.spawnRadius or 8)))
                local x = coords.x + math.cos(angle) * dist
                local y = coords.y + math.sin(angle) * dist
                local ped = CreatePed(4, model, x, y, coords.z, math.random(0, 360) + 0.0, true, true)
                SetModelAsNoLongerNeeded(model)
                SetPedArmour(ped, def.armor or 0)
                SetEntityHealth(ped, 100 + (def.health or 100))
                SetPedAccuracy(ped, math.min(100, def.accuracy or 40))
                GiveWeaponToPed(ped, joaat(def.weapon or 'WEAPON_PISTOL'), 250, false, true)
                SetPedCombatAttributes(ped, 46, true) -- can use cover
                SetPedCombatAttributes(ped, 5, true)  -- always fight, don't flee
                SetPedFleeAttributes(ped, 0, false)
                SetPedAsEnemy(ped, true)
                SetPedRelationshipGroupHash(ped, ensureGuardRelationshipGroup())
                SetCanAttackFriendly(ped, false, false)
                SetPedNeverLeavesGroup(ped, true)
                SetPedCombatMovement(ped, 2)
                SetPedCombatAbility(ped, 2)
                TaskCombatPed(ped, PlayerPedId(), 0, 16)
                SetEntityAsMissionEntity(ped, true, true)
                npcPeds[#npcPeds + 1] = ped
            end
        end
    end)
end

local function clearGuards()
    for _, ped in ipairs(npcPeds) do
        if DoesEntityExist(ped) then
            SetEntityAsMissionEntity(ped, true, true)
            DeletePed(ped)
        end
    end
    npcPeds = {}
end

-- ── Vehicle condition estimate (client preview only — server has final say) ─
-- Mirrors Utils.VehicleConditionMultiplier exactly (shared/utils.lua is a
-- shared_script) so the number shown here matches what the server will pay.

local function estimateCondition(veh, baseReward)
    if not Config.Damage.enabled or not veh or not DoesEntityExist(veh) then
        return 100.0, 1.0, baseReward
    end
    local body = GetEntityHealth(veh)
    local engine = GetVehicleEngineHealth(veh)
    local bodyPct = math.max(0, math.min(100, (body / 1000) * 100))
    local enginePct = math.max(0, math.min(100, (engine / 1000) * 100))
    local cond = (bodyPct + enginePct) / 2
    local mult = Utils.VehicleConditionMultiplier(cond)
    return cond, mult, baseReward * mult
end

-- ── Vehicle spawn (shared by the legacy exact-blip path and the reveal path) ─

local function spawnTargetVehicle(s)
    CreateThread(function()
        local model = joaat(world.contract.model)
        RequestModel(model)
        local t = GetGameTimer() + 5000
        while not HasModelLoaded(model) and GetGameTimer() < t do Wait(10) end
        if not HasModelLoaded(model) then notify('Failed to load target vehicle', 'error'); return end

        world.veh = CreateVehicle(model, s.x, s.y, s.z, s.w, true, false)
        SetModelAsNoLongerNeeded(model)
        SetVehicleOnGroundProperly(world.veh)
        -- plain lock state 2 only. Do NOT use SetVehicleDoorsLockedForAllPlayers
        -- here: that per-player override flag frequently fails to clear again,
        -- leaving the car permanently sealed even after unlocking.
        SetVehicleDoorsLocked(world.veh, 2)
        SetVehicleNeedsToBeHotwired(world.veh, false)
        SetEntityAsMissionEntity(world.veh, true, true)
        local plate = ('BOOST%03d'):format(math.random(0, 999))
        SetVehicleNumberPlateText(world.veh, plate)
        world.plate = plate
    end)

    spawnGuards(vec3(s.x, s.y, s.z), world.contract.tier)
end

-- ── Public entry points (called from client/main.lua) ───────────────────────

--- Drop a preview blip for a freshly assigned contract, before the player has
--- clicked "Start contract". Shows a search-zone circle if the location isn't
--- revealed yet, or a route pin if it already is (search zones disabled).
function BClient.MarkTarget(payload)
    if world.blip then RemoveBlip(world.blip) end
    if world.zoneRadiusBlip then RemoveBlip(world.zoneRadiusBlip); world.zoneRadiusBlip = nil end

    local colour = payload.police and 1 or 5
    if payload.searchZone then
        local z = payload.searchZone
        world.blip = makeBlip(vec3(z.x, z.y, z.z), 161, colour, ('%s — search zone'):format(payload.tierLabel), false)
        local radiusBlip = AddBlipForRadius(z.x, z.y, z.z, z.radius)
        SetBlipColour(radiusBlip, colour)
        SetBlipAlpha(radiusBlip, 110)
        world.zoneRadiusBlip = radiusBlip
    elseif payload.spawn then
        local s = payload.spawn
        world.blip = makeBlip(vec3(s.x, s.y, s.z), 225, colour, ('%s Target'):format(payload.tierLabel), true)
    end
end

--- Begin the interactive world phase once the player starts the contract.
function BClient.BeginWorldPhase(payload)
    if world.loop then return end
    world.contract = payload
    world.loop = true
    world.theftCoords = nil
    clearBlips()

    if payload.searchZone then
        -- search-zone mode: only a soft radius blip — no pinpoint, no vehicle
        -- yet. The player must physically search; see startSearchLoop below.
        world.phase = 'search'
        local z = payload.searchZone
        world.blip = makeBlip(vec3(z.x, z.y, z.z), 161, 5, ('%s — search zone'):format(payload.tierLabel), false)
        local radiusBlip = AddBlipForRadius(z.x, z.y, z.z, z.radius)
        SetBlipColour(radiusBlip, 5)
        SetBlipAlpha(radiusBlip, 110)
        world.zoneRadiusBlip = radiusBlip
        notify(('Target last seen somewhere in the marked zone (~%dm radius). Search it!')
            :format(math.floor(z.radius)), 'inform')
        startSearchLoop()
    elseif payload.spawn then
        -- search zones disabled (or already revealed): behave like before
        revealTarget(payload.spawn)
    end
end

function BClient.EndWorldPhase(reason)
    world.loop = false
    world.phase = nil
    world.tracking = false   -- stop the tracker position broadcast
    clearBlips()
    clearGuards()
    if world.veh and DoesEntityExist(world.veh) then
        -- keep the car for VIN scratch; delete on clean delivery / abandon
        if reason == 'delivered' or reason == 'abandoned' or reason == 'admin' or reason == 'resource_stop' then
            SetEntityAsMissionEntity(world.veh, true, true)
            DeleteVehicle(world.veh)
        else
            SetVehicleHasBeenOwnedByPlayer(world.veh, true)
            SetEntityAsMissionEntity(world.veh, false, false)  -- release VIN-kept car to the world
        end
    end
    world.veh = nil
    world.contract = nil
end

--- Crew members who haven't clicked "Start" yet (or who are still searching)
--- get told the real spot once ANYONE in the crew reveals it.
--- Note: `world.contract` (this file) is only set once BeginWorldPhase runs —
--- i.e. only for whoever clicked Start. `BClient.contract` (set in main.lua
--- on every 'boosting:contractAssigned') is what's available to crew members
--- who received the assignment but haven't started it, so the preview-pin
--- branch below must key off that instead.
BClient.OnRevealed = function(data)
    if not data or not data.spawn then return end
    if world.loop and world.phase == 'search' then
        revealTarget(data.spawn)
    elseif not world.loop and BClient.contract then
        -- app not started yet: just refresh the preview pin to the exact spot
        if world.blip then RemoveBlip(world.blip) end
        if world.zoneRadiusBlip then RemoveBlip(world.zoneRadiusBlip); world.zoneRadiusBlip = nil end
        local s = data.spawn
        world.blip = makeBlip(vec3(s.x, s.y, s.z), 225, 5, ('%s Target'):format(BClient.contract.tierLabel), true)
    end
end

-- ── Phase loops ─────────────────────────────────────────────────────────────

--- Search-zone phase: periodically report our position to the server; it
--- alone knows the real spot and only reveals it once we're close enough.
function startSearchLoop()
    CreateThread(function()
        local interval = (Config.Contract.searchZone.pollInterval or 3) * 1000
        while world.loop and world.phase == 'search' do
            local ped = PlayerPedId()
            local pc = GetEntityCoords(ped)
            local r = ServerCallback('contract:searchPing', { x = pc.x, y = pc.y, z = pc.z })
            if world.phase ~= 'search' then break end -- revealed while awaiting the response
            if r and r.ok and r.revealed and r.spawn then
                revealTarget(r.spawn)
                break
            elseif r and r.ok and r.distance then
                help(('Searching for the vehicle — last signal ~%dm away'):format(r.distance))
            end
            Wait(interval)
        end
    end)
end

--- Transition from "searching" (or straight from assignment, if search zones
--- are off) into "goto": drop the exact pin, spawn the vehicle + guards.
function revealTarget(spawn)
    if world.phase ~= 'search' and world.phase ~= nil then return end
    world.phase = 'goto'
    if world.blip then RemoveBlip(world.blip); world.blip = nil end
    if world.zoneRadiusBlip then RemoveBlip(world.zoneRadiusBlip); world.zoneRadiusBlip = nil end

    local spawnCoords = vec3(spawn.x, spawn.y, spawn.z)
    world.theftCoords = spawnCoords
    world.blip = makeBlip(spawnCoords, 225, 5, ('%s Target'):format(world.contract.tierLabel), true)
    notify(('Target located: %s. Steal it and hack the tracker.'):format(world.contract.tierLabel), 'success')

    spawnTargetVehicle(spawn)
    startGotoLoop()
end

function startGotoLoop()
    CreateThread(function()
        while world.loop and world.phase == 'goto' do
            local wait = 500
            local ped = PlayerPedId()
            if world.veh and DoesEntityExist(world.veh) then
                local pc = GetEntityCoords(ped)
                local vc = GetEntityCoords(world.veh)
                local dist = #(pc - vc)
                if dist < 3.5 and not IsPedInAnyVehicle(ped, false) then
                    wait = 0
                    help('Press ~INPUT_CONTEXT~ to hack the vehicle tracker')
                    if IsControlJustReleased(0, 38) then -- E
                        attemptHack()
                    end
                end
            end
            Wait(wait)
        end
    end)
end

function attemptHack()
    local c = world.contract
    notify('Hacking tracker...', 'inform')
    local success = runMinigame(c.hackGame, c.difficulty)
    if not success then
        notify('Tracker hack failed — the car locked you out. Try again.', 'error')
        return
    end

    -- server authorises by active contract + our live position, and hands out
    -- vehicle keys server-side (qbx/qb key systems track keys on the server —
    -- a client-side grant does nothing there)
    local plate = (world.plate or GetVehicleNumberPlateText(world.veh) or ''):gsub('%s+$', '')
    local r = ServerCallback('contract:hackResult', {
        success = true,
        netId = NetworkGetNetworkIdFromEntity(world.veh),
        plate = plate,
    })
    if r and r.error then notify('Hack rejected: ' .. r.error, 'error'); return end

    -- unlock locally + client-side key systems (wasabi / qs / mk fallbacks)
    SetVehicleDoorsLocked(world.veh, 1)
    SetVehicleDoorsLockedForAllPlayers(world.veh, false) -- clear any stray flag from other scripts
    SetVehicleNeedsToBeHotwired(world.veh, false)
    SetVehicleEngineOn(world.veh, true, true, false)
    pcall(Config.GiveKeys, world.veh, plate)
    notify('Tracker down! Get in and lose the cops.', 'success')
    if world.blip then RemoveBlip(world.blip); world.blip = nil end
    clearGuards() -- the risk of the theft site is over once the car is obtained
    world.phase = 'stolen'
    startEscapeLoop()
end

function startEscapeLoop()
    CreateThread(function()
        local pid = PlayerId()
        while world.loop and world.phase == 'stolen' do
            Wait(1500)
            local ped = PlayerPedId()
            local far = world.theftCoords and #(GetEntityCoords(ped) - world.theftCoords) > Config.Police.escapeDistance
            local clean = GetPlayerWantedLevel(pid) == 0
            local escaped = (Config.Police.escapeLoseStars and clean) or (not Config.Police.escapeLoseStars and far) or (far and clean)
            if escaped then
                local r = ServerCallback('contract:escaped', {})
                if r and r.ok then
                    world.phase = 'escaped'
                    notify('You lost them. Deliver the car — or scratch the VIN to keep it.', 'success')
                    revealDropoffs()
                    startDeliverLoop()
                end
            end
        end
    end)
end

function revealDropoffs()
    clearBlips()
    for _, p in ipairs(world.contract.deliveryPoints or {}) do
        world.dropBlips[#world.dropBlips + 1] = makeBlip(p, 524, 2, 'Deliver Vehicle', false)
    end
    for _, p in ipairs(world.contract.vinPoints or {}) do
        world.dropBlips[#world.dropBlips + 1] = makeBlip(p, 402, 5, 'VIN Scratch Garage', false)
    end
end

function startDeliverLoop()
    CreateThread(function()
        while world.loop and world.phase == 'escaped' do
            local wait = 500
            local ped = PlayerPedId()
            local pc = GetEntityCoords(ped)
            local inTarget = world.veh and IsPedInVehicle(ped, world.veh, false)

            if inTarget then
                -- clean delivery
                for _, p in ipairs(world.contract.deliveryPoints or {}) do
                    if #(pc - p) < (world.contract.deliveryRadius or 8.0) then
                        wait = 0
                        local cond, _, estPay = estimateCondition(world.veh, world.contract.reward)
                        help(('Press ~INPUT_CONTEXT~ to deliver (clean) — condition %d%%, ~%d %s')
                            :format(math.floor(cond), math.floor(estPay), Config.Currency.label))
                        if IsControlJustReleased(0, 38) then deliverClean() break end
                    end
                end
                -- VIN scratch
                for _, p in ipairs(world.contract.vinPoints or {}) do
                    if #(pc - p) < (world.contract.vinRadius or 6.0) then
                        wait = 0
                        local vinBase = world.contract.reward * (world.contract.vinMultiplier or 1.0)
                        local cond, _, estPay = estimateCondition(world.veh, vinBase)
                        help(('Press ~INPUT_CONTEXT~ to scratch the VIN and keep the car — condition %d%%, ~%d %s')
                            :format(math.floor(cond), math.floor(estPay), Config.Currency.label))
                        if IsControlJustReleased(0, 38) then scratchVin() break end
                    end
                end
            end
            Wait(wait)
        end
    end)
end

function deliverClean()
    local netId = world.veh and DoesEntityExist(world.veh) and NetworkGetNetworkIdFromEntity(world.veh) or nil
    local r = ServerCallback('contract:deliver', { netId = netId })
    if r and r.ok then
        local dmgNote = (r.multiplier and r.multiplier < 1.0)
            and (' (vehicle condition %d%% → payout ×%.2f)'):format(r.condition or 100, r.multiplier) or ''
        notify(('Delivered! +%d %s%s'):format(r.reward or 0, Config.Currency.label, dmgNote), 'success')
        BClient.EndWorldPhase('delivered')
    else
        notify('Delivery rejected: ' .. (r and r.error or 'error'), 'error')
    end
end

--- Best-effort vehicle properties for the garage row: use the framework's
--- full getter when available (mods survive), else a minimal fallback.
local function getVehicleProps(veh)
    local ok, props = pcall(function()
        if lib and lib.getVehicleProperties then return lib.getVehicleProperties(veh) end -- ox_lib (Qbox)
    end)
    if ok and props then return props end
    ok, props = pcall(function()
        if GetResourceState('qb-core'):find('start') then
            return exports['qb-core']:GetCoreObject().Functions.GetVehicleProperties(veh)
        end
    end)
    if ok and props then return props end
    ok, props = pcall(function()
        if GetResourceState('es_extended'):find('start') then
            return exports['es_extended']:getSharedObject().Game.GetVehicleProperties(veh)
        end
    end)
    if ok and props then return props end
    local c1, c2 = GetVehicleColours(veh)
    return { model = GetEntityModel(veh), color1 = c1, color2 = c2,
             plate = GetVehicleNumberPlateText(veh) }
end

function scratchVin()
    notify('Scratching VIN...', 'inform')
    local success = runMinigame(Config.Contract.vinScratchGame, Config.Contract.vinScratchDiff)

    -- capture the vehicle's state BEFORE the callback (props for the garage
    -- row, net id so the server can hand out keys for the new plate + score damage)
    local props = world.veh and DoesEntityExist(world.veh) and getVehicleProps(world.veh) or nil
    local netId = world.veh and DoesEntityExist(world.veh) and NetworkGetNetworkIdFromEntity(world.veh) or nil

    local r = ServerCallback('contract:vin', {
        success = success, plate = world.plate, netId = netId, props = props,
    })
    if r and r.ok and r.kept then
        -- apply the clean identity: new plate + client-side keys
        if r.newPlate and world.veh and DoesEntityExist(world.veh) then
            SetVehicleNumberPlateText(world.veh, r.newPlate)
            pcall(Config.GiveKeys, world.veh, r.newPlate)
        end
        local dmgNote = (r.multiplier and r.multiplier < 1.0)
            and (' (vehicle condition %d%% → payout ×%.2f)'):format(r.condition or 100, r.multiplier) or ''
        notify(('VIN scratched — the car is yours! +%d %s%s'):format(r.reward or 0, Config.Currency.label, dmgNote), 'success')
        if r.garaged then
            notify(('Registered to your garage under plate %s — park it anywhere you normally store cars.')
                :format(r.newPlate or '?'), 'success')
        end
        BClient.EndWorldPhase('vin')
    elseif r and r.failed then
        notify('Botched it — try the scratch again.', 'error')
    else
        notify('Scratch rejected: ' .. (r and r.error or 'error'), 'error')
    end
end

-- ── Fallback skill check (when the laptop isn't installed) ───────────────────
-- Mash E to fill the bar before it drains / time runs out. Minimal, no assets.

function FallbackSkillCheck(difficulty)
    local target = 100
    local drain = 0.4 + 0.25 * (difficulty or 1)
    local gain = 7
    local progress = 30.0
    local deadline = GetGameTimer() + (7000 - (difficulty or 1) * 1000)
    local done, result = false, false

    while not done do
        Wait(0)
        DisableControlAction(0, 38, true)
        -- draw bar
        DrawRect(0.5, 0.85, 0.24, 0.05, 0, 0, 0, 180)
        DrawRect(0.38 + (progress / 100) * 0.24 / 2, 0.85, (progress / 100) * 0.24, 0.035,
            75, 224, 140, 220)
        SetTextScale(0.4, 0.4); SetTextFont(4); SetTextCentre(true); SetTextColour(255,255,255,255)
        SetTextEntry('STRING'); AddTextComponentSubstringPlayerName('MASH ~INPUT_CONTEXT~ TO BYPASS')
        DrawText(0.5, 0.80)

        if IsDisabledControlJustPressed(0, 38) then progress = progress + gain end
        progress = progress - drain
        if progress >= target then done = true; result = true end
        if progress <= 0 or GetGameTimer() > deadline then done = true; result = false end
    end
    return result
end
