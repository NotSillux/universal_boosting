Utils = {}

function Utils.Debug(...)
    if Config.Debug then print('^5[boosting:debug]^0', ...) end
end

--- Weighted random pick over a { [key] = { weight = n } } table.
function Utils.WeightedPick(pool, filter)
    local total, entries = 0, {}
    for key, def in pairs(pool) do
        if not filter or filter(key, def) then
            local w = def.weight or 1
            total = total + w
            entries[#entries + 1] = { key = key, w = w }
        end
    end
    if total == 0 then return nil end
    local roll = math.random() * total
    for _, e in ipairs(entries) do
        roll = roll - e.w
        if roll <= 0 then return e.key end
    end
    return entries[#entries] and entries[#entries].key or nil
end

--- Short unique-ish id for contracts/auctions.
function Utils.Id(prefix)
    return ('%s%06x%03x'):format(prefix or '', math.random(0, 0xFFFFFF), math.random(0, 0xFFF))
end

function Utils.Round(n) return math.floor(n + 0.5) end

--- Distance between two vec3s (server-safe).
function Utils.Dist(a, b)
    return math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2 + (a.z - b.z)^2)
end
