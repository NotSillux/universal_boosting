--[[
    Auction house — sell an unwanted (assigned, not-yet-started) contract to
    other players. Bids escrow currency immediately and refund on outbid, so
    money is conserved. Settlement happens on buyout or at expiry.

    Note: refunds/payouts require the recipient to be online. If a winning
    bidder or seller is offline at expiry the sale is cancelled and the bidder
    refunded (see settle()). This keeps the economy balanced without a pending-
    payment queue; extend here if you want offline delivery.
]]

Auction = { escrow = {} }   -- [auctionId] = { src, amount }  (live top bid, for refunds)

local function refund(src, amount)
    if src and GetPlayerName(src) then Bridge.PayReward(src, amount) end
end

local function auctionPayload(row, now)
    return {
        id = row.id, tier = row.tier, model = row.model, reward = row.reward,
        sellerName = row.seller_name, startPrice = row.start_price, buyout = row.buyout,
        topBid = row.top_bid, topBidderName = row.top_bidder_name,
        endsIn = math.max(0, row.ends_at - now),
    }
end

-- ── Callbacks ───────────────────────────────────────────────────────────────

RegisterCallback('auction:list', function(src, session)
    if not Config.Auction.enabled then return { ok = true, auctions = {} } end
    local now = os.time()
    local rows = DB.query('SELECT * FROM `boosting_auctions` WHERE `ends_at` > ? ORDER BY `ends_at` ASC', { now })
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = auctionPayload(r, now) end
    return { ok = true, auctions = out, currencyLabel = Config.Currency.label }
end)

RegisterCallback('auction:create', function(src, session, data)
    if not Config.Auction.enabled then return { error = 'auction_disabled' } end
    local c = Contracts.GetActive(src)
    if not c or c.state ~= 'assigned' then return { error = 'no_listable_contract' } end

    local count = DB.scalar('SELECT COUNT(*) FROM `boosting_auctions` WHERE `seller`=? AND `ends_at` > ?',
        { session.identifier, os.time() }) or 0
    if count >= Config.Auction.maxListingsPerPlayer then return { error = 'too_many_listings' } end

    local startPrice = math.max(Config.Auction.minBid, math.floor(tonumber(data.startPrice) or c.reward * 0.4))
    local buyout = data.buyout and math.max(startPrice, math.floor(tonumber(data.buyout))) or nil

    local fee = Utils.Round(startPrice * Config.Auction.listingFee)
    if fee > 0 and not Bridge.TakeCurrency(src, fee) then return { error = 'cant_afford_fee' } end

    local id = Utils.Id('auc_')
    DB.execute([[INSERT INTO `boosting_auctions`
        (`id`,`seller`,`seller_name`,`tier`,`model`,`reward`,`start_price`,`buyout`,`ends_at`)
        VALUES (?,?,?,?,?,?,?,?,?)]],
        { id, session.identifier, session.name, c.tier, c.model, c.reward, startPrice, buyout,
          os.time() + Config.Auction.duration })

    -- remove the contract from the seller (it's now on the block)
    DB.execute('UPDATE `boosting_contracts` SET `state`=? WHERE `id`=?', { 'auctioned', c.id })
    Contracts.active[src] = nil
    TriggerClientEvent('boosting:contractEnded', src, { reason = 'auctioned' })

    return { ok = true, id = id }
end)

RegisterCallback('auction:bid', function(src, session, data)
    if not Config.Auction.enabled then return { error = 'auction_disabled' } end
    local row = DB.single('SELECT * FROM `boosting_auctions` WHERE `id`=?', { data.id })
    if not row or row.ends_at <= os.time() then return { error = 'auction_over' } end
    if row.seller == session.identifier then return { error = 'own_auction' } end

    local amount = math.floor(tonumber(data.amount) or 0)
    local minNext = (row.top_bid or row.start_price - 1) + Config.Auction.minBid
    if amount < minNext then return { error = 'bid_too_low' } end

    if not Bridge.TakeCurrency(src, amount) then return { error = 'cant_afford' } end

    -- refund the previous top bidder
    local prev = Auction.escrow[row.id]
    if prev then refund(prev.src, prev.amount) end
    Auction.escrow[row.id] = { src = src, amount = amount }

    DB.execute('UPDATE `boosting_auctions` SET `top_bid`=?,`top_bidder`=?,`top_bidder_name`=? WHERE `id`=?',
        { amount, session.identifier, session.name, row.id })
    return { ok = true }
end)

RegisterCallback('auction:buyout', function(src, session, data)
    if not Config.Auction.enabled then return { error = 'auction_disabled' } end
    local row = DB.single('SELECT * FROM `boosting_auctions` WHERE `id`=?', { data.id })
    if not row or row.ends_at <= os.time() then return { error = 'auction_over' } end
    if not row.buyout then return { error = 'no_buyout' } end
    if row.seller == session.identifier then return { error = 'own_auction' } end
    if Contracts.GetActive(src) then return { error = 'already_have_contract' } end

    if not Bridge.TakeCurrency(src, row.buyout) then return { error = 'cant_afford' } end
    Auction.Settle(row, src, session, row.buyout)
    return { ok = true, bought = true }
end)

-- ── Settlement ──────────────────────────────────────────────────────────────

--- Hand the contract to the winner and pay the seller. winnerSrc/session may
--- be resolved live (buyout) or looked up at expiry.
function Auction.Settle(row, winnerSrc, winnerSession, price)
    -- pay the seller (find them online)
    local sellerSrc
    for _, pid in ipairs(GetPlayers()) do
        pid = tonumber(pid)
        if Bridge.Framework.server.GetIdentifier(pid) == row.seller then sellerSrc = pid break end
    end
    if sellerSrc then
        Bridge.PayReward(sellerSrc, price)
        Bridge.Framework.server.Notify(sellerSrc, ('Your %s contract sold for %d %s'):format(row.tier, price, Config.Currency.label), 'success')
    end

    -- give the contract to the winner by re-assigning as a fresh contract
    if winnerSrc and winnerSession then
        local tier = Config.Tiers[row.tier] or Config.Tiers['D']
        local spawn = Config.Contract.spawnPoints[math.random(#Config.Contract.spawnPoints)]
        local contract = {
            id = Utils.Id('ctr_'), owner = winnerSession.identifier, ownerSrc = winnerSrc,
            groupId = Groups.GetGroupId(winnerSrc), tier = row.tier, tierLabel = tier.label,
            color = tier.color, model = row.model, reward = row.reward, xp = tier.xp,
            hackGame = tier.hackGame, difficulty = tier.difficulty, police = tier.police,
            state = 'assigned', spawn = spawn, createdAt = os.time(),
        }
        contract.clientPayload = {
            id = contract.id, tier = row.tier, tierLabel = tier.label, color = tier.color,
            model = row.model, reward = row.reward, hackGame = tier.hackGame, difficulty = tier.difficulty,
            police = tier.police, spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w },
            deliveryPoints = Config.Contract.deliveryPoints, vinPoints = Config.Contract.vinScratchPoints,
            deliveryRadius = Config.Contract.deliveryRadius, vinRadius = Config.Contract.vinScratchRadius,
            vinMultiplier = Config.Contract.vinScratchReward,
        }
        Contracts.active[winnerSrc] = contract
        TriggerClientEvent('boosting:contractAssigned', winnerSrc, contract.clientPayload)
        Bridge.Framework.server.Notify(winnerSrc, 'You won a boosting contract at auction!', 'success')
    end

    Auction.escrow[row.id] = nil
    DB.execute('DELETE FROM `boosting_auctions` WHERE `id`=?', { row.id })
end

-- expiry loop
CreateThread(function()
    while true do
        Wait(5000)
        if Config.Auction.enabled then
            local now = os.time()
            for _, row in ipairs(DB.query('SELECT * FROM `boosting_auctions` WHERE `ends_at` <= ?', { now })) do
                local esc = Auction.escrow[row.id]
                if esc and GetPlayerName(esc.src) and not Contracts.GetActive(esc.src) then
                    local ws = Boost.GetSession(esc.src)
                    Auction.Settle(row, esc.src, ws, esc.amount)
                else
                    -- winner offline or busy: refund + cancel
                    if esc then refund(esc.src, esc.amount) end
                    Auction.escrow[row.id] = nil
                    DB.execute('DELETE FROM `boosting_auctions` WHERE `id`=?', { row.id })
                end
            end
        end
    end
end)
