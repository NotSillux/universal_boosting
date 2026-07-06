--[[
    Universal Boosting — a car-boosting job that installs into the NexOS Laptop
    App Store. Fully universal (Qbox / QB-Core / ESX Legacy / Standalone) with
    an open, modular bridge system mirroring the laptop's.

    Everything here is open and editable.
]]

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'universal_boosting'
author 'Universal'
description 'Universal Car Boosting — installs into the NexOS Laptop App Store'
version '1.0.0'

-- LAPTOP-EXCLUSIVE: intentionally no `ui_page` here. The app's HTML/JS/CSS are
-- shipped as plain `files{}` below and are only ever loaded as an iframe by
-- the NexOS Laptop resource (see client/main.lua's RegisterApp call). There is
-- no standalone/tablet mode and no way to open this UI outside the laptop.

shared_scripts {
    'config/config.lua',
    'shared/utils.lua',
    'bridges/init.lua',
}

client_scripts {
    'bridges/framework/qbox.lua',
    'bridges/framework/qb.lua',
    'bridges/framework/esx.lua',
    'bridges/framework/standalone.lua',
    'client/main.lua',
    'client/contract.lua',
}

server_scripts {
    'bridges/framework/qbox.lua',
    'bridges/framework/qb.lua',
    'bridges/framework/esx.lua',
    'bridges/framework/standalone.lua',
    'bridges/inventory/ox.lua',
    'bridges/inventory/qb.lua',
    'bridges/inventory/esx.lua',
    'server/db.lua',
    'server/main.lua',
    'server/groups.lua',
    'server/queue.lua',
    'server/garage.lua',
    'server/contracts.lua',
    'server/vincheck.lua',
    'server/auction.lua',
    'server/leaderboard.lua',
    'server/admin.lua',
}

files {
    'html/index.html',
    'html/css/*.css',
    'html/js/*.js',
}

dependencies {
    '/onesync',
}

-- The laptop resource is a soft dependency (loaded via GetResourceState polling
-- in client/main.lua & server/main.lua, not a hard `dependency`), so start
-- order doesn't matter — but functionally the laptop is REQUIRED, since this
-- app has no other way to open.
