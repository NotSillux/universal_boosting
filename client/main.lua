--[[
    Boosting client core:
      - registers the app in the laptop's App Store (client def, store = true)
      - the NUI<->server callback pipe (mirrors the laptop's)
      - the NUI callbacks its own iframe/page calls
      - standalone open via /boosting (own NUI focus) and laptop-embedded open

    The same html/index.html runs in two contexts:
      • as an iframe inside the laptop window (laptop controls focus)
      • as this resource's own ui_page when opened via /boosting (we control focus)
]]

BClient = {
    standalone = false,   -- true when we opened our own NUI (not via laptop)
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
            -- the ?ctx=laptop marker tells the page it is running inside the
            -- laptop iframe (so it shows immediately). The standalone ui_page
            -- has no such marker and stays hidden until /boosting opens it.
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

-- close the app window; when embedded in the laptop, close the laptop for the
-- player (its own ESC handler can't see keypresses inside our iframe)
RegisterNUICallback('close', function(_, cb)
    cb({ ok = true })
    if BClient.standalone then
        SetNuiFocus(false, false)
        BClient.standalone = false
    elseif GetResourceState(LAPTOP) == 'started' then
        pcall(function() exports[LAPTOP]:Close() end)
    end
end)

-- start the world phase for the currently assigned contract
RegisterNUICallback('startContract', function(_, cb)
    cb({ ok = true })
    -- close whichever UI is showing this app
    if BClient.standalone then
        SetNuiFocus(false, false)
        BClient.standalone = false
    elseif GetResourceState(LAPTOP) == 'started' then
        pcall(function() exports[LAPTOP]:Close() end)
    end
    if BClient.contract then
        BClient.BeginWorldPhase(BClient.contract)
    end
end)

-- close the current UI (shared by the tracker-disable + start flows)
local function closeUiForWorld()
    if BClient.standalone then
        SetNuiFocus(false, false)
        BClient.standalone = false
    elseif GetResourceState(LAPTOP) == 'started' then
        pcall(function() exports[LAPTOP]:Close() end)
    end
end

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
    elseif r and r.error == 'not_hacker' then
        Bridge.Framework.client.Notify('Only the crew hacker/leader can disable the GPS tracker.', 'error')
    elseif r and r.error then
        Bridge.Framework.client.Notify('Tracker breach failed.', 'error')
    end
end)

-- ── Standalone open (/boosting) ─────────────────────────────────────────────

local function openStandalone()
    BClient.standalone = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'boosting:show', standalone = true })
end

if Config.Command then
    RegisterCommand(Config.Command, function() openStandalone() end, false)
end

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
    if BClient.standalone then SetNuiFocus(false, false) end
    BClient.EndWorldPhase('resource_stop')
end)
