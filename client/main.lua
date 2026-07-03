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

-- ── Standalone open (/boosting) ─────────────────────────────────────────────

local function openStandalone()
    BClient.standalone = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'boosting:show', standalone = true })
end

if Config.Command then
    RegisterCommand(Config.Command, function() openStandalone() end, false)
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

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if BClient.standalone then SetNuiFocus(false, false) end
    BClient.EndWorldPhase('resource_stop')
end)
