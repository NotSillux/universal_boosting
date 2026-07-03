-- Database adapter (oxmysql / mysql-async) + migrations for universal_boosting.

DB = {}
local usingOx = GetResourceState('oxmysql'):find('start') ~= nil
local usingAsync = not usingOx and GetResourceState('mysql-async'):find('start') ~= nil

if not usingOx and not usingAsync then
    print('^1[boosting] no MySQL resource found — persistence disabled!^0')
end

local function oxAwait(method, sql, params)
    local p = promise.new()
    exports.oxmysql[method](exports.oxmysql, sql, params or {}, function(r) p:resolve(r) end)
    return Citizen.Await(p)
end

local function asyncConvert(sql, params)
    local map, i = {}, 0
    local out = sql:gsub('%?', function() i = i + 1; map['@p'..i] = params and params[i] or nil; return '@p'..i end)
    return out, map
end
local function asyncAwait(fn, sql, params)
    local conv, map = asyncConvert(sql, params)
    local p = promise.new()
    exports['mysql-async'][fn](exports['mysql-async'], conv, map, function(r) p:resolve(r) end)
    return Citizen.Await(p)
end

function DB.query(sql, params)
    if usingOx then return oxAwait('query', sql, params) or {} end
    if usingAsync then return asyncAwait('mysql_fetch_all', sql, params) or {} end
    return {}
end
function DB.single(sql, params)
    if usingOx then return oxAwait('single', sql, params) end
    return DB.query(sql, params)[1]
end
function DB.scalar(sql, params)
    if usingOx then return oxAwait('scalar', sql, params) end
    if usingAsync then return asyncAwait('mysql_fetch_scalar', sql, params) end
    return nil
end
function DB.execute(sql, params)
    if usingOx then return oxAwait('update', sql, params) or 0 end
    if usingAsync then return asyncAwait('mysql_execute', sql, params) or 0 end
    return 0
end
function DB.insert(sql, params)
    if usingOx then return oxAwait('insert', sql, params) or 0 end
    if usingAsync then return asyncAwait('mysql_insert', sql, params) or 0 end
    return 0
end

CreateThread(function()
    if not usingOx and not usingAsync then return end
    Wait(0)

    DB.execute([[
        CREATE TABLE IF NOT EXISTS `boosting_profiles` (
            `identifier` VARCHAR(64) NOT NULL,
            `name` VARCHAR(64) DEFAULT NULL,
            `level` INT NOT NULL DEFAULT 1,
            `xp` INT NOT NULL DEFAULT 0,
            `hacker_xp` INT NOT NULL DEFAULT 0,
            `driver_xp` INT NOT NULL DEFAULT 0,
            `completed` INT NOT NULL DEFAULT 0,
            `earnings` BIGINT NOT NULL DEFAULT 0,
            `weekly_xp` INT NOT NULL DEFAULT 0,
            `weekly_hacker` INT NOT NULL DEFAULT 0,
            `weekly_driver` INT NOT NULL DEFAULT 0,
            `week_tag` VARCHAR(16) DEFAULT NULL,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`identifier`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    DB.execute([[
        CREATE TABLE IF NOT EXISTS `boosting_groups` (
            `id` VARCHAR(24) NOT NULL,
            `leader` VARCHAR(64) NOT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    DB.execute([[
        CREATE TABLE IF NOT EXISTS `boosting_contracts` (
            `id` VARCHAR(24) NOT NULL,
            `owner` VARCHAR(64) NOT NULL,
            `tier` VARCHAR(4) NOT NULL,
            `model` VARCHAR(48) NOT NULL,
            `reward` INT NOT NULL,
            `state` VARCHAR(24) NOT NULL DEFAULT 'assigned',
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_owner` (`owner`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    DB.execute([[
        CREATE TABLE IF NOT EXISTS `boosting_auctions` (
            `id` VARCHAR(24) NOT NULL,
            `seller` VARCHAR(64) NOT NULL,
            `seller_name` VARCHAR(64) DEFAULT NULL,
            `tier` VARCHAR(4) NOT NULL,
            `model` VARCHAR(48) NOT NULL,
            `reward` INT NOT NULL,
            `start_price` INT NOT NULL,
            `buyout` INT DEFAULT NULL,
            `top_bid` INT DEFAULT NULL,
            `top_bidder` VARCHAR(64) DEFAULT NULL,
            `top_bidder_name` VARCHAR(64) DEFAULT NULL,
            `ends_at` INT NOT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    DB.execute([[
        CREATE TABLE IF NOT EXISTS `boosting_history` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `identifier` VARCHAR(64) NOT NULL,
            `tier` VARCHAR(4) NOT NULL,
            `model` VARCHAR(48) NOT NULL,
            `outcome` VARCHAR(24) NOT NULL,
            `reward` INT NOT NULL DEFAULT 0,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_identifier` (`identifier`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    Utils.Debug('boosting migrations complete')
    TriggerEvent('boosting:dbReady')
end)
