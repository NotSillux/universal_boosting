--[[
    Garage bridge — registers a VIN-scratched vehicle as a CLEAN, player-owned
    car in the server's garage database, so any mainstream garage script can
    store/retrieve it afterwards.

    Instead of chasing dozens of garage-resource exports, we write directly to
    the standard ownership tables both ecosystems share:
      QB / Qbox : `player_vehicles`  (read by qb-garages, qs, jg, cd, okok…)
      ESX       : `owned_vehicles`   (read by esx_garage, okokGarage, loaf…)
    A 'custom' mode hands the data to Config.Garage.custom for anything else.

    Everything here is server-side and only ever called from the validated
    contract:vin flow — players cannot invoke it directly.
]]

Garage = {}

-- ── Plate generation ────────────────────────────────────────────────────────

local function randomPlate()
    local L = function(n)
        local s = ''
        for _ = 1, n do s = s .. string.char(math.random(65, 90)) end
        return s
    end
    return ('%s%03d%s'):format(L(2), math.random(0, 999), L(3)) -- e.g. XK042LDQ
end

local function plateTaken(plate, mode)
    -- only query the table that exists for the active framework (querying a
    -- missing table would log SQL errors)
    if mode == 'qb' then
        if DB.scalar('SELECT 1 FROM `player_vehicles` WHERE `plate` = ?', { plate }) then return true end
    elseif mode == 'esx' then
        if DB.scalar('SELECT 1 FROM `owned_vehicles` WHERE `plate` = ?', { plate }) then return true end
    end
    return DB.scalar('SELECT 1 FROM `boosting_vin_records` WHERE `plate` = ?', { plate }) ~= nil
end

--- Resolve which garage backend to use.
function Garage.Mode()
    local mode = Config.Garage.system or 'auto'
    if mode ~= 'auto' then return mode end
    if Bridge.FrameworkName == 'qbox' or Bridge.FrameworkName == 'qb' then return 'qb' end
    if Bridge.FrameworkName == 'esx' then return 'esx' end
    return 'none'
end

--- Generate a unique clean plate (8 chars, GTA-style).
function Garage.GeneratePlate()
    local mode = Garage.Mode()
    for _ = 1, 10 do
        local plate = randomPlate()
        if not plateTaken(plate, mode) then return plate end
    end
    return randomPlate() -- astronomically unlikely fallback
end

-- ── Registration ────────────────────────────────────────────────────────────

--- Register the vehicle to the player. data = { plate, model, props, tier }.
--- Returns true when the car landed in a garage database.
function Garage.Register(src, session, data)
    if not Config.Garage.enabled then return false end
    local mode = Garage.Mode()
    local props = type(data.props) == 'table' and data.props or {}
    props.plate = data.plate                       -- props must carry the new plate
    local hash = joaat(data.model)
    if props.model == nil then props.model = hash end

    if mode == 'qb' then
        -- standard QB ownership row; state = 0 (vehicle is out in the world,
        -- the player drives it to a garage and stores it normally)
        local license = GetPlayerIdentifierByType(src, 'license') or ''
        local affected = DB.execute([[
            INSERT INTO `player_vehicles` (`license`,`citizenid`,`vehicle`,`hash`,`mods`,`plate`,`garage`,`state`)
            VALUES (?,?,?,?,?,?,?,0)
        ]], { license, session.identifier, data.model, hash, json.encode(props), data.plate, Config.Garage.defaultGarage })
        return (affected or 0) > 0

    elseif mode == 'esx' then
        -- standard ESX ownership row; stored = 0 (out in the world)
        local affected = DB.execute([[
            INSERT INTO `owned_vehicles` (`owner`,`plate`,`vehicle`,`type`,`stored`)
            VALUES (?,?,?,'car',0)
        ]], { session.identifier, data.plate, json.encode(props) })
        if (affected or 0) > 0 then return true end
        -- older ESX schemas lack type/stored — retry minimal
        local minimal = DB.execute('INSERT INTO `owned_vehicles` (`owner`,`plate`,`vehicle`) VALUES (?,?,?)',
            { session.identifier, data.plate, json.encode(props) })
        return (minimal or 0) > 0

    elseif mode == 'custom' then
        local ok, res = pcall(Config.Garage.custom, src, {
            identifier = session.identifier,
            plate = data.plate, model = data.model, hash = hash,
            props = props, tier = data.tier,
        })
        if not ok then print('^1[boosting] Config.Garage.custom error: ' .. tostring(res) .. '^0') end
        return ok and res ~= false
    end

    return false -- 'none'
end
