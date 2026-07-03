--[[
    Leaderboards — Overall / Hacker / Driver, each Global or Weekly.
    Reads straight from boosting_profiles; weekly columns reset per week_tag.
]]

local COLUMNS = {
    overall = { global = 'xp',        weekly = 'weekly_xp' },
    hacker  = { global = 'hacker_xp', weekly = 'weekly_hacker' },
    driver  = { global = 'driver_xp', weekly = 'weekly_driver' },
}

RegisterCallback('leaderboard:get', function(src, session, data)
    local board = COLUMNS[data.board] and data.board or 'overall'
    local period = data.period == 'weekly' and 'weekly' or 'global'
    local col = COLUMNS[board][period]

    local rows = DB.query(([[SELECT `name`,`level`,`%s` AS score, `completed`
                             FROM `boosting_profiles` ORDER BY `%s` DESC LIMIT ?]]):format(col, col),
        { Config.Leaderboard.topN })

    local out = {}
    for i, r in ipairs(rows) do
        out[#out + 1] = {
            rank = i,
            name = r.name or 'Unknown',
            level = r.level,
            score = r.score or 0,
            completed = r.completed or 0,
            you = r.name == session.name,
        }
    end
    return { ok = true, board = board, period = period, entries = out }
end)
