--[[
    Police VIN check — authorized jobs can inspect a vehicle's VIN.

    Results (server-derived, in priority order):
      'stolen'    the plate belongs to a LIVE boosting contract (hot car)
      'scratched' the plate is registered in `boosting_vin_records`
                  (i.e. a VIN-scratched car with a forged clean identity)
      'clean'     no record

    Fully server-authoritative: the job whitelist, the distance to the vehicle
    and the result lookup all happen here. Every check is written to
    `boosting_vin_checks` for admins (/boostadmin vinlogs).
]]

local function jobAllowed(src)
    local job = Bridge.Framework.server.GetJob(src)
    if not job then return false end
    for _, j in ipairs(Config.VinCheck.jobs) do
        if j == job.name then return job.onduty ~= false end
    end
    return false
end

--- Look the plate up. Returns 'stolen' | 'scratched' | 'clean'.
local function vinResult(plate)
    -- live boosting contract with this plate = actively stolen car
    for _, c in pairs(Contracts.active) do
        if c.plate and c.plate == plate and c.state ~= 'completed' then
            return 'stolen'
        end
    end
    if DB.scalar('SELECT 1 FROM `boosting_vin_records` WHERE `plate` = ?', { plate }) then
        return 'scratched'
    end
    return 'clean'
end

RegisterCallback('vin:check', function(src, session, data)
    if not Config.VinCheck.enabled then return { error = 'vin_disabled' } end
    if not jobAllowed(src) then return { error = 'not_authorized' } end

    -- the net id must resolve to a real vehicle near the officer
    local ent = type(data.netId) == 'number' and NetworkGetEntityFromNetworkId(data.netId) or 0
    if ent == 0 or not DoesEntityExist(ent) or GetEntityType(ent) ~= 2 then
        return { error = 'no_vehicle' }
    end
    local ped = GetPlayerPed(src)
    if ped == 0 or #(GetEntityCoords(ped) - GetEntityCoords(ent)) > (Config.VinCheck.maxDistance + 6.0) then
        return { error = 'too_far' }
    end

    -- read the plate from the entity itself — never trust a client string
    local plate = (GetVehicleNumberPlateText(ent) or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local result = vinResult(plate)

    if Config.VinCheck.logChecks then
        DB.execute([[INSERT INTO `boosting_vin_checks` (`officer`,`officer_name`,`plate`,`result`)
                     VALUES (?,?,?,?)]],
            { session.identifier, session.name, plate, result })
    end
    Utils.Debug(('VIN check by %s on %s -> %s'):format(session.name, plate, result))

    return { ok = true, plate = plate, result = result }
end)
