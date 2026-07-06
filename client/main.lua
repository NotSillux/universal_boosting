--[[
    Boosting client core:
      - registers the app in the laptop's App Store (client def, store = true)
      - the NUI<->server callback pipe (mirrors the laptop's)
      - the NUI callbacks its own iframe/page calls

    LAPTOP-EXCLUSIVE: this app has no standalone/tablet mode. Its html/index.html
    is only ever loaded as an iframe inside the laptop's window (see the
    RegisterApp call below) — there's no `ui_page` in fxmanifest.lua and no
    command that opens it any other way. All "close the UI" logic below simply
    closes the laptop.
]]

BClient = {
    contract = nil,       -- active contract client payload (world phase)
}

local LAPTOP = Config.LaptopResource

-- ── Server callback pipe ────────────────────────────────────────────────────

local pending, reqSeq = {}, 0

function ServerCallback(name, data)
    reqSeq = reqSeq + 1
    local id = reqSeq
    local p = promise.new()
    pending[id] = p
    TriggerServerEvent('boosting:request', id, name, data or {})
    SetTimeout(10000, function()
        if pending[id] then pending[id]:resolve({ error = 'timeout' }); pending[id] = nil end
    end)
    return Citizen.Await(p)
end

RegisterNetEvent('boosting:response', function(id, result)
    local p = pending[id]
    if p then pending[id] = nil; p:resolve(result) end
end)

-- ── Register with the laptop App Store ──────────────────────────────────────

local function registerApp()
    if GetResourceState(LAPTOP) ~= 'started' then return false end
    return pcall(function()
        exports[LAPTOP]:RegisterApp({
            id     = Config.Store.id,
            label  = Config.Store.name,
            icon   = Config.Store.icon,
            color  = 'linear-gradient(145deg,#12c2e9,#c471ed)',
            -- the ?ctx=laptop marker tells the page it's safe to render
            -- immediately since it's being shown inside the laptop's window
            -- (defense in depth — there's no other way this page ever loads).
            ui     = ('nui://%s/html/index.html?ctx=laptop'):format(GetCurrentResourceName()),
            width  = 980,
            height = 660,
            store  = true,   -- hidden on the desktop until installed via the store
        })
    end)
end

CreateThread(function()
    while not registerApp() do Wait(2000) end
end)

AddEventHandler('onResourceStart', function(res)
    if res == LAPTOP then SetTimeout(2000, registerApp) end
end)

-- ── NUI callbacks (from the app page/iframe) ────────────────────────────────

-- generic server relay
RegisterNUICallback('api', function(req, cb)
    if type(req) ~= 'table' or type(req.name) ~= 'string' then cb({ error = 'bad_request' }); return end
    cb(ServerCallback(req.name, req.data))
end)

-- close the laptop for the player (this app has no NUI focus of its own — the
-- laptop owns focus since we're always an iframe inside it)
local function closeUiForWorld()
    if GetResourceState(LAPTOP) == 'started' then
        pcall(function() exports[LAPTOP]:Close() end)
    end
end

RegisterNUICallback('close', function(_, cb)
    cb({ ok = true })
    closeUiForWorld()
end)

-- start the world phase for the currently assigned contract
RegisterNUICallback('startContract', function(_, cb)
    cb({ ok = true })
    closeUiForWorld()
    if BClient.contract then
        BClient.BeginWorldPhase(BClient.contract)
    end
end)

-- Disable the GPS tracker. The button is only shown to eligible players, but
-- the SERVER re-checks eligibility — this just runs the minigame and reports.
RegisterNUICallback('disableTracker', function(_, cb)
    cb({ ok = true })
    closeUiForWorld()  -- release NUI focus so the minigame overlay works

    Bridge.Framework.client.Notify('Breaching the GPS tracker…', 'inform')
    local success = BClient.RunMinigame(Config.Tracker.minigame, Config.Tracker.difficulty)
    local r = ServerCallback('tracker:disable', { success = success })

    if r and r.disabled then
        Bridge.Framework.client.Notify('GPS tracker disabled — you\'re off the grid.', 'success')
    elseif r and r.failed then
        Bridge.Framework.client.Notify(('Breach failed — wait %ds and try again.'):format(Config.Tracker.failCooldown or 8), 'error')
    elseif r and r.error == 'on_cooldown' then
        Bridge.Framework.client.Notify('Tracker rejected the breach — cooling down.', 'error')
    elseif r and r.error == 'not_eligible' then
        -- message depends on the active crew rule (Config.Tracker.crewRule)
        local rule = Config.Tracker.crewRule or 'non_leader'
        Bridge.Framework.client.Notify(rule == 'non_leader'
            and 'Only a crew member who is not the leader can disable the GPS tracker.'
            or 'Only the crew hacker/leader can disable the GPS tracker.', 'error')
    elseif r and r.error then
        Bridge.Framework.client.Notify('Tracker breach failed.', 'error')
    end
end)

-- Accept/decline a crew invite without opening the app (handy when invited
-- mid-activity). The server rejects these if there's no live invite.
RegisterCommand('crewaccept', function()
    local r = ServerCallback('group:accept', {})
    if r and r.ok then
        Bridge.Framework.client.Notify('You joined the crew.', 'success')
    else
        Bridge.Framework.client.Notify('No pending crew invite.', 'error')
    end
end, false)

RegisterCommand('crewdecline', function()
    ServerCallback('group:decline', {})
    Bridge.Framework.client.Notify('Crew invite declined.', 'inform')
end, false)

-- ── Police VIN check ────────────────────────────────────────────────────────
-- /checkvin scans the vehicle you're in (or the nearest one). Job whitelist,
-- distance and the result lookup are all validated SERVER-side — this client
-- code is just the trigger + presentation. Target/radial resources can call
-- the same flow via:  exports['universal_boosting']:CheckVin(vehicleEntity)

local vinCheckBusy = false

local function nearestVehicle(maxDist)
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then return GetVehiclePedIsIn(ped, false) end
    local pc = GetEntityCoords(ped)
    local best, bestDist = nil, maxDist
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        local d = #(GetEntityCoords(veh) - pc)
        if d < bestDist then best, bestDist = veh, d end
    end
    return best
end

local function runVinCheck(veh)
    if vinCheckBusy or not Config.VinCheck.enabled then return end
    veh = veh or nearestVehicle(Config.VinCheck.maxDistance)
    if not veh or not DoesEntityExist(veh) then
        Bridge.Framework.client.Notify('No vehicle in range to check.', 'error')
        return
    end

    vinCheckBusy = true
    Bridge.Framework.client.Notify('Running VIN check…', 'inform')
    Wait(Config.VinCheck.scanTime or 2500)

    local r = ServerCallback('vin:check', { netId = NetworkGetNetworkIdFromEntity(veh) })
    vinCheckBusy = false

    if not r or r.error then
        local msgs = {
            not_authorized = 'You are not authorized to run VIN checks.',
            no_vehicle = 'Could not read the vehicle.',
            too_far = 'You are too far from the vehicle.',
            vin_disabled = 'VIN checks are disabled.',
        }
        Bridge.Framework.client.Notify(msgs[r and r.error] or 'VIN check failed.', 'error')
        return
    end

    if r.result == 'stolen' then
        Bridge.Framework.client.Notify(('🚨 VIN check [%s]: vehicle reported STOLEN — active theft flag.')
            :format(r.plate), 'error')
    elseif r.result == 'scratched' then
        Bridge.Framework.client.Notify(('⚠️ VIN check [%s]: VIN has been SCRATCHED — identity is forged.')
            :format(r.plate), 'error')
    else
        Bridge.Framework.client.Notify(('✅ VIN check [%s]: VIN is clean.'):format(r.plate), 'success')
    end
end

-- export for target / radial / MDT resources (pass the vehicle entity)
exports('CheckVin', function(veh)
    CreateThread(function() runVinCheck(veh) end)
end)

if Config.VinCheck.enabled and Config.VinCheck.command then
    RegisterCommand(Config.VinCheck.command, function() runVinCheck() end, false)
end
if Config.VinCheck.enabled and Config.VinCheck.keybind then
    RegisterCommand('+boostvincheck', function() runVinCheck() end, false)
    RegisterCommand('-boostvincheck', function() end, false)
    RegisterKeyMapping('+boostvincheck', 'Police: check vehicle VIN', 'keyboard', Config.VinCheck.keybind)
end

-- ── Notifications & server-pushed events ────────────────────────────────────

RegisterNetEvent('boosting:notify', function(data)
    if type(data) ~= 'table' then return end
    -- forward to the app page (if open) and always drop a game notification
    SendNUIMessage({ action = 'boosting:notify', data = data })
    Bridge.Framework.client.Notify(('%s: %s'):format(data.title or 'Boosting', data.text or ''), 'inform')
end)

RegisterNetEvent('boosting:contractAssigned', function(payload)
    BClient.contract = payload
    SendNUIMessage({ action = 'boosting:contractAssigned', data = payload })
    Bridge.Framework.client.Notify(('New %s boosting contract available!'):format(payload.tierLabel), 'success')
    BClient.MarkTarget(payload) -- drop a GPS blip toward the target
end)

RegisterNetEvent('boosting:contractEnded', function(info)
    BClient.EndWorldPhase(info and info.reason or 'ended')
    SendNUIMessage({ action = 'boosting:contractEnded', data = info })
end)

-- search-zone reveal: fired to the whole crew once ANYONE gets close enough
-- (see contract.lua's startSearchLoop / BClient.OnRevealed)
RegisterNetEvent('boosting:contractRevealed', function(data)
    if BClient.OnRevealed then BClient.OnRevealed(data) end
end)

RegisterNetEvent('boosting:groupUpdate', function()
    SendNUIMessage({ action = 'boosting:groupUpdate' })
end)

RegisterNetEvent('boosting:groupInvite', function(data)
    SendNUIMessage({ action = 'boosting:groupInvite', data = data })
    Bridge.Framework.client.Notify(('%s invited you to their crew'):format(data.from), 'inform')
end)

-- server applies wanted level after a successful steal
RegisterNetEvent('boosting:applyHeat', function(stars)
    local pid = PlayerId()
    SetPlayerWantedLevel(pid, math.min(5, stars or 0), false)
    SetPlayerWantedLevelNow(pid, false)
end)

-- ── GPS TRACKER (client) ────────────────────────────────────────────────────
-- Police + crew get a live map blip that follows the tracked vehicle. The
-- driver runs a loop that broadcasts the vehicle's position to the server,
-- which relays it here as boosting:trackerUpdate.

local trackerBlips = {}   -- [contractId] = blip handle

RegisterNetEvent('boosting:trackerStart', function(a)
    if trackerBlips[a.id] then RemoveBlip(trackerBlips[a.id]) end
    local blip = AddBlipForCoord(a.x + 0.0, a.y + 0.0, a.z + 0.0)
    SetBlipSprite(blip, a.sprite or 326)
    SetBlipColour(blip, a.colour or 5)
    SetBlipScale(blip, a.scale or 1.0)
    SetBlipFlashes(blip, true)
    SetBlipCategory(blip, 7)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('📡 %s'):format(a.label or 'Tracked vehicle'))
    EndTextCommandSetBlipName(blip)
    trackerBlips[a.id] = blip
    Bridge.Framework.client.Notify('📡 GPS tracker signal acquired.', 'inform')
end)

RegisterNetEvent('boosting:trackerUpdate', function(u)
    local blip = trackerBlips[u.id]
    if blip and DoesBlipExist(blip) then
        SetBlipCoords(blip, u.x, u.y, u.z)
    end
end)

RegisterNetEvent('boosting:trackerStop', function(u)
    local blip = trackerBlips[u.id]
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
    trackerBlips[u.id] = nil
    if BClient.StopTrackerPing then BClient.StopTrackerPing() end  -- driver stops broadcasting
end)

-- The driver broadcasts the tracked vehicle's live position on an interval.
-- The loop lives in contract.lua where the world vehicle handle is kept.
RegisterNetEvent('boosting:trackerOwner', function(info)
    if BClient.StartTrackerPing then
        BClient.StartTrackerPing(info and info.interval or 3)
    end
end)

-- built-in police alert (only on-duty cops receive this from the server): a
-- flashing radius blip + area blip that auto-removes after alertBlipTime.
RegisterNetEvent('boosting:policeAlert', function(a)
    Bridge.Framework.client.Notify(
        ('🚨 %s%s'):format(a.label or 'Vehicle theft', a.plate and (' — plate '..a.plate) or ''), 'error')

    local coords = vec3(a.x, a.y, a.z)

    -- pulsing area circle
    local radiusBlip = AddBlipForRadius(coords.x, coords.y, coords.z, a.radius or 120.0)
    SetBlipColour(radiusBlip, a.colour or 1)
    SetBlipAlpha(radiusBlip, 128)
    SetBlipHiddenOnLegend(radiusBlip, true)

    -- icon blip with flash
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, a.sprite or 225)
    SetBlipColour(blip, a.colour or 1)
    SetBlipScale(blip, 1.1)
    SetBlipFlashes(blip, true)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(a.label or 'Vehicle theft')
    EndTextCommandSetBlipName(blip)

    PlaySoundFrontend(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', true)

    SetTimeout((a.time or 60) * 1000, function()
        if DoesBlipExist(blip) then RemoveBlip(blip) end
        if DoesBlipExist(radiusBlip) then RemoveBlip(radiusBlip) end
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    BClient.EndWorldPhase('resource_stop')
end)
