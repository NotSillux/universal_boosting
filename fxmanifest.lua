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

-- ui_page lets the app also open standalone (via /boosting) with its own NUI
-- focus. When opened through the laptop it is loaded as an iframe instead.
ui_page 'html/index.html'

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
    'server/contracts.lua',
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

-- The laptop resource is an OPTIONAL soft dependency — boosting registers with
-- it if present, but also works via the /boosting command on its own.
