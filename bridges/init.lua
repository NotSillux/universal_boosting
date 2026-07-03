--[[
    Bridge core for universal_boosting. Same design as the laptop's bridge:
    framework + inventory abstraction in small, open files.

    Framework module interface (see framework/qbox.lua):
        detect() -> bool
        server.GetIdentifier(src) / GetName(src) / GetJob(src)
        server.Notify(src, msg, type)
        server.HasItem / AddItem / RemoveItem
        server.GetMoney / AddMoney / RemoveMoney
        server.CountJobPlayers(jobs) -> number
        client.Notify(msg, type)

    Inventory module interface (see inventory/ox.lua):
        detect() / HasItem / AddItem / RemoveItem
]]

Bridge = {
    _frameworks = {}, _inventories = {},
    FrameworkName = nil, InventoryName = nil,
    Framework = nil, Inventory = nil, Ready = false,
}

function Bridge.RegisterFramework(name, m) Bridge._frameworks[name] = m end
function Bridge.RegisterInventory(name, m) Bridge._inventories[name] = m end

local function selectFramework()
    if Config.Framework ~= 'auto' and Bridge._frameworks[Config.Framework] then
        return Config.Framework, Bridge._frameworks[Config.Framework]
    end
    for _, name in ipairs({ 'qbox', 'qb', 'esx', 'standalone' }) do
        local m = Bridge._frameworks[name]
        if m and m.detect() then return name, m end
    end
    return 'standalone', Bridge._frameworks['standalone']
end

local function selectInventory()
    if Config.Inventory ~= 'auto' and Bridge._inventories[Config.Inventory] then
        return Config.Inventory, Bridge._inventories[Config.Inventory]
    end
    -- 'esx' (the built-in es_extended inventory) is checked last so dedicated
    -- inventory resources always win on ESX servers
    for _, name in ipairs({ 'ox', 'qb', 'esx' }) do
        local m = Bridge._inventories[name]
        if m and m.detect() then return name, m end
    end
    return nil, nil
end

CreateThread(function()
    local fwName, fw = selectFramework()
    Bridge.FrameworkName, Bridge.Framework = fwName, fw
    if IsDuplicityVersion() then
        local invName, inv = selectInventory()
        Bridge.InventoryName, Bridge.Inventory = invName, inv
        print(('^2[boosting]^0 framework: ^3%s^0 | inventory: ^3%s^0'):format(fwName, invName or 'framework-fallback'))
    end
    Bridge.Ready = true
    TriggerEvent('boosting:bridgeReady')
end)

function Bridge.AwaitReady() while not Bridge.Ready do Wait(10) end end

if IsDuplicityVersion() then
    function Bridge.HasItem(src, item, count)
        if Bridge.Inventory then
            local ok, r = pcall(Bridge.Inventory.HasItem, src, item, count or 1)
            if ok then return r end
        end
        return Bridge.Framework.server.HasItem(src, item, count or 1)
    end
    function Bridge.AddItem(src, item, count, meta)
        if Bridge.Inventory then
            local ok, r = pcall(Bridge.Inventory.AddItem, src, item, count or 1, meta)
            if ok then return r end
        end
        return Bridge.Framework.server.AddItem(src, item, count or 1, meta)
    end
    function Bridge.RemoveItem(src, item, count)
        if Bridge.Inventory then
            local ok, r = pcall(Bridge.Inventory.RemoveItem, src, item, count or 1)
            if ok then return r end
        end
        return Bridge.Framework.server.RemoveItem(src, item, count or 1)
    end

    --- Pay a "crypto" reward using whichever currency the config selects.
    function Bridge.PayReward(src, amount)
        amount = math.floor(amount)
        if amount <= 0 then return true end
        if Config.Currency.type == 'money' then
            return Bridge.Framework.server.AddMoney(src, Config.Currency.account, amount)
        end
        return Bridge.AddItem(src, Config.Currency.item, amount)
    end

    function Bridge.TakeCurrency(src, amount)
        amount = math.floor(amount)
        if amount <= 0 then return true end
        if Config.Currency.type == 'money' then
            return Bridge.Framework.server.RemoveMoney(src, Config.Currency.account, amount)
        end
        return Bridge.RemoveItem(src, Config.Currency.item, amount)
    end

    function Bridge.GetCurrency(src)
        if Config.Currency.type == 'money' then
            return Bridge.Framework.server.GetMoney(src, Config.Currency.account)
        end
        return Bridge.HasItem(src, Config.Currency.item, 1) and math.huge or 0
    end
end
