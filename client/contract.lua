--[[
    Contract world phase — the actual gameplay loop, driven client-side but
    validated server-side at every transition.

    Flow: assigned → (drive to target, hack tracker) → stolen → (escape police)
          → escaped → deliver clean  OR  scratch VIN at a garage → completed

    The tracker & VIN minigames reuse the laptop's StartHacking export when the
    laptop is present, and fall back to a small built-in skill check otherwise.
]]

local world = {
    contract = nil,
    veh = nil,
    blip = nil,
    dropBlips = {},
    phase = nil,       -- 'goto' | 'stolen' | 'escaped'
    theftCoords = nil,
    loop = false,
}

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
    for _, b in ipairs(world.dropBlips) do RemoveBlip(b) end
    world.dropBlips = {}
end

--- Run a minigame, reusing the laptop's if available.
local function runMinigame(game, difficulty)
    if GetResourceState(Config.LaptopResource) == 'started' then
        local ok, res = pcall(function()
            return exports[Config.LaptopResource]:StartHacking(game, difficulty)
        end)
        if ok then return res end
    end
    return FallbackSkillCheck(difficulty)
end

-- ── Public entry points (called from client/main.lua) ───────────────────────

--- Drop a route blip toward a freshly assigned contract's target.
function BClient.MarkTarget(payload)
    if world.blip then RemoveBlip(world.blip) end
    local s = payload.spawn
    world.blip = makeBlip(vec3(s.x, s.y, s.z), 225, payload.police and 1 or 5,
        ('%s Target'):format(payload.tierLabel), true)
end

--- Begin the interactive world phase once the player starts the contract.
function BClient.BeginWorldPhase(payload)
    if world.loop then return end
    world.contract = payload
    world.phase = 'goto'
    world.loop = true
    clearBlips()

    local s = payload.spawn
    local spawnCoords = vec3(s.x, s.y, s.z)
    world.theftCoords = spawnCoords
    world.blip = makeBlip(spawnCoords, 225, 5, ('%s Target'):format(payload.tierLabel), true)

    -- spawn the target vehicle
    CreateThread(function()
        local model = joaat(payload.model)
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

    notify(('Target located: %s. Steal it and hack the tracker.'):format(payload.tierLabel), 'inform')
    startGotoLoop()
end

function BClient.EndWorldPhase(reason)
    world.loop = false
    world.phase = nil
    clearBlips()
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

-- ── Phase loops ─────────────────────────────────────────────────────────────

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
                        help('Press ~INPUT_CONTEXT~ to deliver the vehicle (clean)')
                        if IsControlJustReleased(0, 38) then deliverClean() break end
                    end
                end
                -- VIN scratch
                for _, p in ipairs(world.contract.vinPoints or {}) do
                    if #(pc - p) < (world.contract.vinRadius or 6.0) then
                        wait = 0
                        help('Press ~INPUT_CONTEXT~ to scratch the VIN and keep the car')
                        if IsControlJustReleased(0, 38) then scratchVin() break end
                    end
                end
            end
            Wait(wait)
        end
    end)
end

function deliverClean()
    local r = ServerCallback('contract:deliver', {})
    if r and r.ok then
        notify(('Delivered! +%d %s'):format(r.reward or 0, Config.Currency.label), 'success')
        BClient.EndWorldPhase('delivered')
    else
        notify('Delivery rejected: ' .. (r and r.error or 'error'), 'error')
    end
end

function scratchVin()
    notify('Scratching VIN...', 'inform')
    local success = runMinigame(Config.Contract.vinScratchGame, Config.Contract.vinScratchDiff)
    local r = ServerCallback('contract:vin', { success = success, plate = world.plate })
    if r and r.ok and r.kept then
        notify(('VIN scratched — the car is yours! +%d %s'):format(r.reward or 0, Config.Currency.label), 'success')
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
