/* Universal Boosting — NUI app. Runs both embedded in the laptop (iframe) and
   standalone (this resource's ui_page). All actions are relayed to the server
   through the boosting client's 'api' NUI callback. */
'use strict';

const Boost = (() => {
    // resolve this resource for fetch(), works in iframe and standalone
    const RES = (location.hostname || '').replace(/^cfx-nui-/, '') || 'universal_boosting';

    const S = {
        tab: 'dashboard',
        boot: null,
        queued: false,
        lb: { board: 'overall', period: 'global' },
        refreshTimer: null,
    };

    const post = (action, data) =>
        fetch(`https://${RES}/${action}`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data || {}),
        }).then(r => r.json()).catch(() => ({ error: 'nui_error' }));

    const api = (name, data) => post('api', { name, data });

    // ── DOM helpers ──────────────────────────────────────────────────────────
    const el = (t, c, x) => { const e = document.createElement(t); if (c) e.className = c; if (x !== undefined) e.textContent = x; return e; };
    const esc = (s) => String(s ?? '').replace(/[&<>"]/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;' }[c]));
    const money = (n) => (S.boot?.currencyLabel || '') + Number(n || 0).toLocaleString();
    const TIERCOLORS = { D:'--tier-d', C:'--tier-c', B:'--tier-b', A:'--tier-a', S:'--tier-s', 'S+':'--tier-sp' };
    const tierColor = (t) => `var(${TIERCOLORS[t] || '--tier-d'})`;

    function toast(title, text) {
        const host = document.getElementById('toast-host');
        const t = el('div', 'toast');
        t.append(el('div', 't-title', title), el('div', 't-text', text));
        host.appendChild(t);
        setTimeout(() => t.remove(), 4200);
    }

    // ── Navigation ───────────────────────────────────────────────────────────
    const NAV = [
        ['dashboard', '⊞', 'Dashboard'],
        ['crew', '⚇', 'Crew'],
        ['auction', '⚖', 'Auction'],
        ['leaderboard', '★', 'Leaderboards'],
        ['history', '≡', 'History'],
    ];

    function renderNav() {
        const nav = document.getElementById('nav');
        nav.innerHTML = '';
        for (const [id, ico, label] of NAV) {
            if (id === 'auction' && S.boot && S.boot.config && !S.boot.config.auctionEnabled) continue;
            const b = el('button', 'nav-item' + (S.tab === id ? ' active' : ''));
            b.style.position = 'relative';
            b.append(el('span', 'ico', ico), el('span', '', label));
            if (id === 'crew' && S.boot?.group?.inGroup) {
                b.appendChild(el('span', 'nav-badge', String(S.boot.group.members.length)));
            }
            b.onclick = () => { S.tab = id; render(); };
            nav.appendChild(b);
        }
    }

    function renderSideProfile() {
        const host = document.getElementById('side-profile');
        const p = S.boot?.profile;
        if (!p) { host.innerHTML = ''; return; }
        const pct = p.xpForNext > p.xpForCurrent
            ? Math.max(0, Math.min(100, ((p.xp - p.xpForCurrent) / (p.xpForNext - p.xpForCurrent)) * 100)) : 100;
        host.innerHTML = '';
        host.append(
            el('div', 'sp-name', p.name),
            el('div', 'sp-level', `Boost Level ${p.level}`),
        );
        const bar = el('div', 'sp-bar'); const fill = el('div'); fill.style.width = pct + '%'; bar.appendChild(fill);
        host.appendChild(bar);
        document.getElementById('wallet').textContent = '⛃ ' + money(p.earnings);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function render() {
        renderNav();
        renderSideProfile();
        document.getElementById('page-title').textContent = (NAV.find(n => n[0] === S.tab) || [,,''])[2];
        const view = document.getElementById('view');
        view.innerHTML = '';
        ({ dashboard: viewDashboard, crew: viewCrew, auction: viewAuction,
           leaderboard: viewLeaderboard, history: viewHistory })[S.tab](view);
    }

    // Dashboard: profile stats + queue / active contract
    function viewDashboard(view) {
        const p = S.boot.profile;

        const stats = el('div', 'stat-row');
        const mkStat = (v, l, cls) => { const s = el('div', 'stat'); s.append(el('div', 'v ' + (cls||''), v), el('div', 'l', l)); return s; };
        stats.append(
            mkStat(p.level, 'Boost Level'),
            mkStat(p.hackerLevel, 'Hacker Lvl', 'cyan'),
            mkStat(p.driverLevel, 'Driver Lvl', 'mag'),
            mkStat(p.completed, 'Jobs Done'),
        );
        view.appendChild(stats);

        // xp bars
        const xpCard = el('div', 'card');
        xpCard.appendChild(el('h3', '', 'Progression'));
        const hackerPer = S.boot.config.hackerXpPerLevel || 300;
        const driverPer = S.boot.config.driverXpPerLevel || 300;
        xpCard.appendChild(xpTrack('Boost XP', p.xp - p.xpForCurrent, p.xpForNext - p.xpForCurrent, 'to next level'));
        xpCard.appendChild(xpTrack('Hacker XP', p.hackerXp % hackerPer, hackerPer, 'to hacker level ' + (p.hackerLevel + 1)));
        xpCard.appendChild(xpTrack('Driver XP', p.driverXp % driverPer, driverPer, 'to driver level ' + (p.driverLevel + 1)));
        view.appendChild(xpCard);

        const active = S.boot.activeContract;
        if (active) return view.appendChild(contractCard(active));
        if (S.queued) return view.appendChild(queueCard(true));
        return view.appendChild(queueCard(false));
    }

    function xpTrack(label, cur, max, sub) {
        const wrap = el('div', 'xp-track');
        wrap.appendChild(el('div', 'muted', label));
        const bar = el('div', 'xp-bar'); const fill = el('div');
        fill.style.width = Math.max(0, Math.min(100, (cur / Math.max(1, max)) * 100)) + '%';
        bar.appendChild(fill); wrap.appendChild(bar);
        const lbl = el('div', 'xp-label');
        lbl.append(el('span', '', `${Math.max(0, Math.round(cur))} / ${Math.round(max)} XP`), el('span', '', sub));
        wrap.appendChild(lbl);
        return wrap;
    }

    function queueCard(queued) {
        const card = el('div', 'card');
        const hero = el('div', 'queue-hero');
        hero.appendChild(el('div', 'pulse', queued ? '⟳' : '⊚'));
        hero.appendChild(el('h2', '', queued ? 'Searching for a target…' : 'Ready to work'));
        hero.appendChild(el('div', 'muted', queued
            ? 'Stay online — a contract will be assigned shortly. You can queue with your crew.'
            : 'Join the queue to receive a vehicle theft contract matched to your level.'));
        const btn = el('button', 'btn primary wide', queued ? 'Leave queue' : 'Find a contract');
        btn.style.marginTop = '18px';
        btn.onclick = async () => {
            const r = await api(queued ? 'queue:leave' : 'queue:join');
            if (r.error) return toast('Queue', errMsg(r.error));
            S.queued = !!r.queued;
            refresh();
        };
        hero.appendChild(btn);
        card.appendChild(hero);

        // tier legend
        const legend = el('div', 'tier-legend');
        for (const t of S.boot.tiers) {
            const tl = el('div', 'tl');
            const chip = el('span', 'tier-chip', t.id); chip.style.background = tierColor(t.id);
            tl.appendChild(chip);
            tl.appendChild(el('span', '', money(t.reward)));
            if (S.boot.profile.level < t.minLevel) tl.appendChild(el('span', 'lock', `🔒 Lv.${t.minLevel}`));
            legend.appendChild(tl);
        }
        const legendCard = el('div', 'card');
        legendCard.appendChild(el('h3', '', 'Contract Tiers'));
        legendCard.appendChild(legend);
        const frag = document.createDocumentFragment();
        frag.append(card, legendCard);
        return frag;
    }

    function contractCard(c) {
        const frag = document.createDocumentFragment();
        const hero = el('div', 'contract-hero');
        const bt = el('div', 'big-tier', c.tier); bt.style.background = tierColor(c.tier);
        const info = el('div', 'ch-info');
        info.append(el('div', 'ch-model', c.model), el('div', 'ch-meta',
            `${c.tierLabel} · ${c.police}★ police response · VIN scratch ×${c.vinMultiplier}`));
        const reward = el('div'); reward.appendChild(el('div', 'ch-reward', money(c.reward)));
        hero.append(bt, info, reward);

        // state steps
        const steps = el('div', 'state-steps');
        const order = ['assigned', 'stolen', 'escaped', 'completed'];
        const labels = { assigned: 'Locate', stolen: 'Steal', escaped: 'Escape', completed: 'Deliver' };
        const idx = order.indexOf(c.state);
        for (let i = 0; i < order.length; i++) {
            const s = el('div', 'step' + (i <= idx ? ' done' : ''));
            s.append(el('div', 'dot'), el('span', '', labels[order[i]]));
            steps.appendChild(s);
        }

        const card = el('div', 'card');
        card.append(hero, steps);

        // ── GPS tracker status ───────────────────────────────────────────────
        const tr = c.tracker;
        if (tr && tr.required) {
            const box = el('div', 'tracker-box ' + (tr.disabled ? 'is-off' : (tr.escalated ? 'is-hot' : 'is-on')));
            const head = el('div', 'tracker-head');
            head.append(
                el('span', 'tk-icon', '📡'),
                el('span', 'tk-title', 'GPS Tracker'),
                el('span', 'tk-status', tr.disabled ? 'DISABLED' : (tr.escalated ? 'TRACED!' : 'ACTIVE')));
            box.appendChild(head);

            if (!tr.disabled) {
                // countdown bar toward escalation
                const pct = Math.max(0, Math.min(100, (tr.remaining / Math.max(1, tr.disableTime)) * 100));
                const bar = el('div', 'tk-bar'); const fill = el('div'); fill.style.width = pct + '%';
                bar.appendChild(fill); box.appendChild(bar);
                box.appendChild(el('div', 'muted', tr.escalated
                    ? 'The signal is live and police are converging. Disable it now!'
                    : `Disable within ${tr.remaining}s or the police response spikes.`));

                if (tr.canDisable) {
                    const disable = el('button', 'btn primary wide', '📡 Disable GPS Tracker');
                    disable.style.marginTop = '10px';
                    disable.onclick = () => post('disableTracker');
                    box.appendChild(disable);
                } else {
                    // explain WHO can disable it, based on the active crew rule
                    const note = tr.rule === 'non_leader'
                        ? '🔒 Only a crew member who is not the leader can disable the GPS tracker.'
                        : tr.rule === 'hacker'
                            ? '🔒 Only the crew hacker/leader can disable the GPS tracker.'
                            : '🔒 A crew member must disable the GPS tracker.';
                    box.appendChild(el('div', 'tk-note', note));
                }
            } else {
                box.appendChild(el('div', 'muted', 'Tracker offline — you\'re clear to deliver or scratch the VIN.'));
            }
            card.appendChild(box);
        }

        const actions = el('div', 'row');
        if (c.state === 'assigned') {
            const start = el('button', 'btn primary', '▶ Start contract');
            start.onclick = () => post('startContract');
            actions.appendChild(start);

            if (S.boot.config.auctionEnabled) {
                const auc = el('button', 'btn ghost', '⚖ Sell on auction');
                auc.onclick = () => openAuctionCreate(c);
                actions.appendChild(auc);
            }
        } else {
            actions.appendChild(el('div', 'muted', 'Contract in progress — complete it out in the city.'));
        }
        const abandon = el('button', 'btn danger', 'Abandon');
        abandon.style.marginLeft = 'auto';
        abandon.onclick = async () => {
            const r = await api('contract:abandon');
            if (r.ok) { toast('Contract', 'Contract abandoned'); refresh(); }
        };
        actions.appendChild(abandon);
        card.appendChild(actions);
        frag.appendChild(card);
        return frag;
    }

    // Crew
    function viewCrew(view) {
        const g = S.boot.group;

        // pending invite banner — shown whether or not the app was open when it
        // arrived (the invite lives on the server until it expires)
        if (g && !g.inGroup && g.invite) {
            const inviteCard = el('div', 'card invite-card');
            inviteCard.appendChild(el('h3', '', '📨 Crew invitation'));
            inviteCard.appendChild(el('div', 'muted',
                `${g.invite.from} invited you to their crew. Accept to queue and split payouts together.`));
            const row = el('div', 'invite-actions');
            const accept = el('button', 'btn primary', 'Accept');
            accept.onclick = async () => {
                const r = await api('group:accept');
                if (r.error) return toast('Crew', errMsg(r.error));
                S.tab = 'crew'; refresh();
            };
            const decline = el('button', 'btn danger', 'Decline');
            decline.onclick = async () => { await api('group:decline'); refresh(); };
            row.append(accept, decline);
            inviteCard.appendChild(row);
            view.appendChild(inviteCard);
        }

        if (!g || !g.inGroup) {
            const card = el('div', 'card');
            card.appendChild(el('h3', '', 'Crew'));
            card.appendChild(el('div', 'muted', `Roll with up to ${S.boot.config.maxGroupSize} players. Crews queue together and split the payout.`));
            const btn = el('button', 'btn primary', '＋ Create a crew');
            btn.style.marginTop = '14px';
            btn.onclick = async () => { const r = await api('group:create'); if (r.error) return toast('Crew', errMsg(r.error)); refresh(); };
            card.appendChild(btn);
            view.appendChild(card);
            return;
        }

        const card = el('div', 'card');
        card.appendChild(el('h3', '', `Your Crew (${g.members.length}/${S.boot.config.maxGroupSize})`));
        // hint about the active GPS-tracker crew rule (Config.Tracker.crewRule)
        const trackerRule = S.boot.config.trackerRule || 'non_leader';
        card.appendChild(el('div', 'muted', trackerRule === 'non_leader'
            ? 'GPS trackers must be disabled by a crew member who is NOT the leader ♛ — bring backup.'
            : trackerRule === 'hacker'
                ? 'The leader ♛ and the designated hacker 📡 can disable GPS trackers during a job.'
                : 'Any crew member can disable GPS trackers during a job.'));
        for (const m of g.members) {
            const row = el('div', 'member');
            row.appendChild(el('div', 'av', (m.name || '?').charAt(0).toUpperCase()));
            const info = el('div');
            const nm = el('div', 'm-name'); nm.textContent = m.name;
            if (m.isLeader) nm.appendChild(el('span', 'crown', ' ♛'));
            if (m.isHacker) nm.appendChild(el('span', 'hacker-badge', ' 📡'));
            info.append(nm, el('div', 'm-sub', `Boost level ${m.level}` + (m.isHacker ? ' · Hacker' : '')));
            row.appendChild(info);

            const rowActions = el('div', 'm-actions');
            if (g.isLeader && !m.isLeader) {
                // the Hacker role only matters under the 'hacker' rule — hide
                // the assignment button for the other rules to avoid confusion
                if (trackerRule === 'hacker') {
                    const setH = el('button', 'btn ghost sm', m.isHacker ? 'Unset hacker' : 'Make hacker');
                    setH.onclick = async () => {
                        await api('group:setHacker', { target: m.isHacker ? false : m.src });
                        refresh();
                    };
                    rowActions.appendChild(setH);
                }
                const kick = el('button', 'btn danger sm', 'Kick');
                kick.onclick = async () => { await api('group:kick', { target: m.src }); refresh(); };
                rowActions.appendChild(kick);
            }
            rowActions.style.marginLeft = 'auto';
            row.appendChild(rowActions);
            card.appendChild(row);
        }
        view.appendChild(card);

        if (g.isLeader) {
            const inv = el('div', 'card');
            inv.appendChild(el('h3', '', 'Invite a player'));
            inv.appendChild(labelled('Server ID'));
            const input = el('input'); input.type = 'number'; input.placeholder = 'e.g. 12'; input.id = 'inv-id';
            inv.appendChild(input);
            const btn = el('button', 'btn primary', 'Send invite'); btn.style.marginTop = '12px';
            btn.onclick = async () => {
                const r = await api('group:invite', { target: parseInt(input.value, 10) });
                toast('Crew', r.ok ? 'Invite sent' : errMsg(r.error)); input.value = '';
            };
            inv.appendChild(btn);
            view.appendChild(inv);
        }

        const leave = el('button', 'btn danger', 'Leave crew');
        leave.onclick = async () => { await api('group:leave'); refresh(); };
        view.appendChild(leave);
    }

    function labelled(text) { const l = el('label', 'fl'); l.textContent = text; return l; }

    // Auction
    async function viewAuction(view) {
        const create = el('button', 'btn primary', '＋ List a contract');
        create.onclick = () => {
            if (!S.boot.activeContract || S.boot.activeContract.state !== 'assigned')
                return toast('Auction', 'You need an un-started contract to list.');
            openAuctionCreate(S.boot.activeContract);
        };
        view.appendChild(create);

        const list = el('div', 'card');
        list.appendChild(el('h3', '', 'Live auctions'));
        const container = el('div');
        list.appendChild(container);
        view.appendChild(list);

        const r = await api('auction:list');
        container.innerHTML = '';
        if (!r.auctions || !r.auctions.length) { container.appendChild(el('div', 'empty', 'No live auctions.')); return; }
        for (const a of r.auctions) {
            const row = el('div', 'auc');
            const chip = el('span', 'tier-chip', a.tier); chip.style.background = tierColor(a.tier);
            row.appendChild(chip);
            const info = el('div', 'a-info');
            info.append(el('div', 'a-model', a.model),
                el('div', 'a-sub', `by ${esc(a.sellerName)} · reward ${money(a.reward)}`),
                el('div', 'a-time', `ends in ${fmtTime(a.endsIn)}`));
            row.appendChild(info);
            const bid = el('div', 'a-bid');
            bid.appendChild(el('div', 'v', a.topBid ? money(a.topBid) : money(a.startPrice)));
            bid.appendChild(el('div', 'muted', a.topBidderName ? `top: ${esc(a.topBidderName)}` : 'no bids'));
            row.appendChild(bid);
            const btnCol = el('div', 'row');
            const bidBtn = el('button', 'btn', 'Bid');
            bidBtn.onclick = async () => {
                const amount = parseInt(prompt('Bid amount:', (a.topBid || a.startPrice) + 100), 10);
                if (!amount) return;
                const rr = await api('auction:bid', { id: a.id, amount });
                toast('Auction', rr.ok ? 'Bid placed' : errMsg(rr.error)); render();
            };
            btnCol.appendChild(bidBtn);
            if (a.buyout) {
                const bo = el('button', 'btn good', `Buyout ${money(a.buyout)}`);
                bo.onclick = async () => { const rr = await api('auction:buyout', { id: a.id }); toast('Auction', rr.ok ? 'Purchased!' : errMsg(rr.error)); refresh(); };
                btnCol.appendChild(bo);
            }
            row.appendChild(btnCol);
            container.appendChild(row);
        }
    }

    function openAuctionCreate(c) {
        const view = document.getElementById('view');
        view.innerHTML = '';
        const card = el('div', 'card');
        card.appendChild(el('h3', '', `List ${c.tierLabel} — ${c.model}`));
        card.appendChild(labelled('Starting price'));
        const start = el('input'); start.type = 'number'; start.value = Math.round(c.reward * 0.4);
        card.appendChild(start);
        card.appendChild(labelled('Buyout price (optional)'));
        const buyout = el('input'); buyout.type = 'number'; buyout.placeholder = 'leave empty for no buyout';
        card.appendChild(buyout);
        const actions = el('div', 'row'); actions.style.marginTop = '14px';
        const confirm = el('button', 'btn primary', 'List contract');
        confirm.onclick = async () => {
            const r = await api('auction:create', {
                startPrice: parseInt(start.value, 10),
                buyout: buyout.value ? parseInt(buyout.value, 10) : null,
            });
            toast('Auction', r.ok ? 'Listed!' : errMsg(r.error));
            if (r.ok) { S.tab = 'auction'; refresh(); }
        };
        const cancel = el('button', 'btn ghost', 'Cancel');
        cancel.onclick = () => render();
        actions.append(confirm, cancel);
        card.appendChild(actions);
        view.appendChild(card);
    }

    // Leaderboard
    async function viewLeaderboard(view) {
        const tabs = el('div', 'lb-tabs');
        const mk = (group, key, label) => {
            const b = el('div', 'lb-tab' + (S.lb[group] === key ? ' active' : ''), label);
            b.onclick = () => { S.lb[group] = key; render(); };
            return b;
        };
        tabs.append(mk('board','overall','Overall'), mk('board','hacker','Hacker'), mk('board','driver','Driver'));
        const sep = el('span'); sep.style.width = '12px'; tabs.appendChild(sep);
        tabs.append(mk('period','global','Global'), mk('period','weekly','Weekly'));
        view.appendChild(tabs);

        const card = el('div', 'card');
        card.appendChild(el('h3', '', 'Rankings'));
        const container = el('div'); card.appendChild(container); view.appendChild(card);

        const r = await api('leaderboard:get', { board: S.lb.board, period: S.lb.period });
        container.innerHTML = '';
        if (!r.entries || !r.entries.length) { container.appendChild(el('div', 'empty', 'No ranked players yet.')); return; }
        for (const e of r.entries) {
            const row = el('div', 'lb-row' + (e.you ? ' you' : ''));
            row.appendChild(el('div', 'lb-rank' + (e.rank <= 3 ? ' top' : ''), '#' + e.rank));
            const name = el('div', 'lb-name'); name.textContent = e.name;
            name.appendChild(el('small', '', `Lv.${e.level} · ${e.completed} jobs`));
            row.appendChild(name);
            row.appendChild(el('div', 'lb-score', Number(e.score).toLocaleString() + ' XP'));
            container.appendChild(row);
        }
    }

    // History
    async function viewHistory(view) {
        const card = el('div', 'card');
        card.appendChild(el('h3', '', 'Recent contracts'));
        const container = el('div'); card.appendChild(container); view.appendChild(card);
        const r = await api('history:list');
        container.innerHTML = '';
        if (!r.history || !r.history.length) { container.appendChild(el('div', 'empty', 'No contracts run yet.')); return; }
        const winOutcomes = { delivered: 'Delivered', vin_scratched: 'VIN Kept' };
        for (const h of r.history) {
            const row = el('div', 'hist');
            const chip = el('span', 'tier-chip', h.tier); chip.style.background = tierColor(h.tier);
            row.appendChild(chip);
            row.appendChild(el('div', 'h-model', h.model));
            const win = !!winOutcomes[h.outcome];
            row.appendChild(el('div', 'h-out ' + (win ? 'win' : 'loss'),
                winOutcomes[h.outcome] || (h.outcome === 'abandoned' ? 'Abandoned' : 'Failed')));
            row.appendChild(el('div', 'h-reward', h.reward > 0 ? money(h.reward) : '—'));
            container.appendChild(row);
        }
    }

    // ── Misc ─────────────────────────────────────────────────────────────────

    function fmtTime(secs) {
        secs = Math.max(0, secs | 0);
        const m = Math.floor(secs / 60), s = secs % 60;
        return `${m}:${String(s).padStart(2, '0')}`;
    }

    const ERR = {
        already_have_contract: 'You already have an active contract.',
        only_leader_queues: 'Only the crew leader can queue.',
        not_enough_police: 'Not enough police online right now.',
        already_in_group: 'You are already in a crew.',
        not_in_group: 'You are not in a crew.',
        not_leader: 'Only the crew leader can do that.',
        group_full: 'The crew is full.',
        player_not_found: 'Player not found.',
        target_busy: 'That player is already in a crew.',
        no_invite: 'No pending invite.',
        cant_afford: "You can't afford that bid.",
        cant_afford_fee: "You can't afford the listing fee.",
        bid_too_low: 'Bid is too low.',
        own_auction: "You can't bid on your own listing.",
        auction_over: 'That auction has ended.',
        no_listable_contract: 'No un-started contract to list.',
        too_many_listings: 'You have too many active listings.',
        tracker_active: 'Disable the GPS tracker before you can finish the job.',
        not_eligible: 'You are not allowed to disable this GPS tracker.',
        on_cooldown: 'Tracker breach on cooldown — try again shortly.',
        no_tracker: 'No active tracker to disable.',
        nui_error: 'Connection error.',
    };
    const errMsg = (e) => ERR[e] || (e ? e.replace(/_/g, ' ') : 'Error');

    // ── Lifecycle ────────────────────────────────────────────────────────────

    async function refresh() {
        const r = await api('boot');
        if (r.error) { toast('Boosting', errMsg(r.error)); return; }
        S.boot = r;
        S.queued = !!r.queued;
        render();
    }

    // true when embedded inside the laptop's window; false when we are the
    // resource's own top-level ui_page NUI layer.
    //
    // We detect this from an explicit ?ctx=laptop marker on the iframe URL
    // (set by the boosting client's RegisterApp). Iframe/parent detection is
    // unreliable in FiveM's CEF — the standalone ui_page can appear "framed" —
    // so the URL marker is the source of truth.
    let framed = false;
    try { framed = new URLSearchParams(location.search).get('ctx') === 'laptop'; } catch (e) { framed = false; }

    function showApp() {
        document.getElementById('app').classList.remove('hidden');
        refresh();
        if (!S.refreshTimer) {
            // light polling so the queue / auctions / timers stay fresh
            S.refreshTimer = setInterval(() => {
                if (document.hidden) return;
                if (document.getElementById('app').classList.contains('hidden')) return;
                if (S.tab === 'auction' || S.queued || (S.boot && S.boot.activeContract)) refresh();
            }, 5000);
        }
    }

    // hide the app; the standalone ui_page layer stays drawn even without NUI
    // focus, so it must re-hide itself. (The laptop tears down its iframe.)
    function closeApp() {
        post('close');
        if (!framed) document.getElementById('app').classList.add('hidden');
    }

    const isVisible = () => !document.getElementById('app').classList.contains('hidden');

    window.addEventListener('message', (e) => {
        const { action, data } = e.data || {};
        switch (action) {
            case 'boosting:show': showApp(); break;
            case 'boosting:notify': if (data && isVisible()) toast(data.title || 'Boosting', data.text || ''); break;
            case 'boosting:contractAssigned':
            case 'boosting:contractEnded':
            case 'boosting:groupUpdate': if (isVisible()) refresh(); break;
            case 'boosting:groupInvite': if (isVisible()) showInvite(data); break;
        }
    });

    function showInvite(data) {
        const host = document.getElementById('invite-host');
        host.innerHTML = '';
        const box = el('div', 'invite');
        box.appendChild(el('div', '', `${data.from} invited you to their crew`));
        const yes = el('button', 'btn good', 'Accept');
        yes.onclick = async () => { host.innerHTML = ''; await api('group:accept'); S.tab = 'crew'; refresh(); };
        const no = el('button', 'btn ghost', 'Decline');
        no.onclick = async () => { host.innerHTML = ''; await api('group:decline'); };
        box.append(yes, no);
        host.appendChild(box);
        setTimeout(() => { if (host.firstChild === box) host.innerHTML = ''; }, 15000);
    }

    document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeApp(); });

    window.addEventListener('DOMContentLoaded', () => {
        document.getElementById('close-btn').onclick = () => closeApp();
        // Embedded in the laptop: the iframe is shown by the laptop, so there's
        // no 'boosting:show' message — boot immediately.
        // Standalone ui_page layer: stay HIDDEN until /boosting sends
        // 'boosting:show', otherwise it would render fullscreen for everyone.
        if (framed) showApp();
    });

    return { refresh };
})();
