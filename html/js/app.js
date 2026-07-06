/* Universal Boosting — NUI app. LAPTOP-EXCLUSIVE: this page is only ever
   loaded as an iframe inside the NexOS Laptop's window (see client/main.lua's
   RegisterApp call) — there is no standalone/tablet mode. All actions are
   relayed to the server through the boosting client's 'api' NUI callback. */
'use strict';

const Boost = (() => {
    // resolve this resource for fetch()
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

    // ── In-app dialog ────────────────────────────────────────────────────────
    // Replaces window.prompt()/confirm(): those are native browser dialogs and
    // in FiveM's CEF they render as their OWN top-level OS window, completely
    // separate from (and behind) the game and this app's UI — effectively
    // invisible to a player in-game. This renders inside #dialog-layer instead.
    //
    // dialog({ title, message, inputs: [{ id, label, type, value, placeholder }],
    //          okLabel, cancelLabel, danger }) -> Promise<values|null>
    function dialog(opts) {
        return new Promise((resolve) => {
            const layer = document.getElementById('dialog-layer');
            layer.innerHTML = '';
            layer.classList.remove('hidden');

            const box = el('div', 'dlg');
            if (opts.title) box.appendChild(el('h3', '', opts.title));
            if (opts.message) box.appendChild(el('p', '', opts.message));

            const fields = {};
            for (const inp of opts.inputs || []) {
                if (inp.label) box.appendChild(el('label', 'fl', inp.label));
                const field = el('input');
                field.type = inp.type || 'text';
                if (inp.value !== undefined && inp.value !== null) field.value = inp.value;
                if (inp.placeholder) field.placeholder = inp.placeholder;
                box.appendChild(field);
                fields[inp.id] = field;
            }

            const btns = el('div', 'dlg-buttons');
            const close = (result) => { layer.classList.add('hidden'); layer.innerHTML = ''; resolve(result); };

            const cancel = el('button', 'btn ghost', opts.cancelLabel || 'Cancel');
            cancel.onclick = () => close(null);
            const ok = el('button', `btn ${opts.danger ? 'danger' : 'primary'}`, opts.okLabel || 'Confirm');
            ok.onclick = () => {
                const values = {};
                for (const [id, f] of Object.entries(fields)) values[id] = f.value;
                close(values);
            };
            btns.append(cancel, ok);
            box.appendChild(btns);
            layer.appendChild(box);

            // click the dim backdrop to cancel
            layer.onmousedown = (e) => { if (e.target === layer) close(null); };
            box.addEventListener('keydown', (e) => {
                if (e.key === 'Enter') { e.preventDefault(); ok.click(); }
                if (e.key === 'Escape') { e.preventDefault(); close(null); }
                e.stopPropagation();
            });

            const first = Object.values(fields)[0];
            setTimeout(() => (first ? first.focus() : ok.focus()), 30);
        });
    }

    /** Simple yes/no confirmation dialog. Returns a boolean. */
    const dlgConfirm = (title, message, danger = true) =>
        dialog({ title, message, danger, okLabel: 'Confirm' }).then((v) => v !== null);

    // ── Navigation ───────────────────────────────────────────────────────────
    const NAV = [
        ['dashboard', '⊞', 'Dashboard'],
        ['crew', '⚇', 'Crew'],
        ['auction', '⚖', 'Auction'],
        ['leaderboard', '★', 'Leaderboards'],
        ['history', '≡', 'History'],
        ['admin', '🛡', 'Admin'],
    ];

    function renderNav() {
        const nav = document.getElementById('nav');
        nav.innerHTML = '';
        for (const [id, ico, label] of NAV) {
            if (id === 'auction' && S.boot && S.boot.config && !S.boot.config.auctionEnabled) continue;
            // Admin tab is a UI convenience only — every admin:* callback
            // re-checks the ACE permission server-side regardless (server/admin.lua)
            if (id === 'admin' && !(S.boot && S.boot.isAdmin)) continue;
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
           leaderboard: viewLeaderboard, history: viewHistory, admin: viewAdmin })[S.tab](view);
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
        let metaLine = `${c.tierLabel} · ${c.police}★ police response · VIN scratch ×${c.vinMultiplier}`;
        if (c.searchZone) metaLine += ` · 🔍 search zone (~${Math.round(c.searchZone.radius)}m)`;
        info.append(el('div', 'ch-model', c.model), el('div', 'ch-meta', metaLine));
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
            // Only the contract OWNER starts it — if a crew member also clicked
            // Start, they'd spawn their own duplicate copy of the target vehicle
            // client-side. Crew members can still tag along and search together;
            // they just don't drive the "Start" button.
            if (c.isOwner) {
                const start = el('button', 'btn primary', '▶ Start contract');
                start.onclick = () => post('startContract');
                actions.appendChild(start);

                if (S.boot.config.auctionEnabled) {
                    const auc = el('button', 'btn ghost', '⚖ Sell on auction');
                    auc.onclick = () => openAuctionCreate(c);
                    actions.appendChild(auc);
                }
            } else {
                actions.appendChild(el('div', 'muted', 'Your crew leader has this contract — help them search once they start it.'));
            }
        } else {
            actions.appendChild(el('div', 'muted', 'Contract in progress — complete it out in the city.'));
        }
        if (c.isOwner) {
            const abandon = el('button', 'btn danger', 'Abandon');
            abandon.style.marginLeft = 'auto';
            abandon.onclick = async () => {
                const r = await api('contract:abandon');
                if (r.ok) { toast('Contract', 'Contract abandoned'); refresh(); }
            };
            actions.appendChild(abandon);
        }
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
        // hint about how payouts are split (Config.Groups.payoutMode / fullCrewBonus)
        const payoutMode = S.boot.config.payoutMode || 'equal';
        let payoutHint = payoutMode === 'leader_bonus'
            ? `Payout: split evenly, then the leader ♛ gets a +${Math.round((S.boot.config.leaderBonus || 0) * 100)}% bonus on top.`
            : 'Payout: split evenly among everyone online.';
        if (S.boot.config.fullCrewBonus) {
            payoutHint += ` Everyone gets an extra +${Math.round(S.boot.config.fullCrewBonus * 100)}% if the whole crew is together at delivery.`;
        }
        card.appendChild(el('div', 'muted', payoutHint));
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
                const suggested = (a.topBid || a.startPrice) + 100;
                const v = await dialog({
                    title: `Bid on ${a.model}`,
                    message: `Current top bid: ${a.topBid ? money(a.topBid) : money(a.startPrice)}`,
                    inputs: [{ id: 'amount', label: 'Bid amount', type: 'number', value: suggested }],
                    okLabel: 'Place bid',
                });
                if (!v) return;
                const amount = parseInt(v.amount, 10);
                if (!amount || amount <= 0) return toast('Auction', 'Enter a valid bid amount.');
                const rr = await api('auction:bid', { id: a.id, amount });
                toast('Auction', rr.ok ? 'Bid placed' : errMsg(rr.error)); render();
            };
            btnCol.appendChild(bidBtn);
            if (a.buyout) {
                const bo = el('button', 'btn good', `Buyout ${money(a.buyout)}`);
                bo.onclick = async () => {
                    const ok = await dlgConfirm('Confirm buyout', `Buy "${a.model}" now for ${money(a.buyout)}?`, false);
                    if (!ok) return;
                    const rr = await api('auction:buyout', { id: a.id });
                    toast('Auction', rr.ok ? 'Purchased!' : errMsg(rr.error)); refresh();
                };
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

    // Admin panel — nav item + every admin:* callback are gated server-side
    // (see server/admin.lua); the tab only ever shows for players the server
    // already told us are admins (S.boot.isAdmin), but that's a UI convenience,
    // not the actual security boundary.
    const TIERS = ['D', 'C', 'B', 'A', 'S', 'S+'];

    async function viewAdmin(view) {
        // live stats
        const statsCard = el('div', 'card');
        statsCard.appendChild(el('h3', '', 'Server stats'));
        const statsRow = el('div', 'row');
        statsCard.appendChild(statsRow);
        view.appendChild(statsCard);
        api('admin:stats').then((r) => {
            statsRow.innerHTML = '';
            if (!r.ok) return statsRow.appendChild(el('div', 'muted', errMsg(r.error)));
            statsRow.append(
                adminChip('Active contracts', r.stats.active),
                adminChip('In queue', r.stats.queued),
                adminChip('Crews', r.stats.crews),
            );
        });

        // create a manual contract
        const createCard = el('div', 'card');
        createCard.appendChild(el('h3', '', '＋ Create contract'));
        const row1 = el('div', 'row');
        const targetInput = el('input'); targetInput.type = 'number'; targetInput.placeholder = 'Server ID';
        const tierSelect = el('select');
        for (const t of TIERS) { const o = document.createElement('option'); o.value = t; o.textContent = t; tierSelect.appendChild(o); }
        const createBtn = el('button', 'btn primary', 'Create');
        createBtn.onclick = async () => {
            const target = parseInt(targetInput.value, 10);
            if (!target) return toast('Admin', 'Enter a server ID.');
            const r = await api('admin:createContract', { target, tier: tierSelect.value });
            toast('Admin', r.ok ? 'Contract created' : errMsg(r.error));
            if (r.ok) refreshActiveContracts();
        };
        row1.append(targetInput, tierSelect, createBtn);
        createCard.appendChild(row1);
        view.appendChild(createCard);

        // active contracts
        const activeCard = el('div', 'card');
        activeCard.appendChild(el('h3', '', 'Active contracts'));
        const activeList = el('div');
        activeCard.appendChild(activeList);
        view.appendChild(activeCard);

        async function refreshActiveContracts() {
            const r = await api('admin:activeContracts');
            activeList.innerHTML = '';
            if (!r.ok) return activeList.appendChild(el('div', 'muted', errMsg(r.error)));
            if (!r.contracts.length) return activeList.appendChild(el('div', 'empty', 'No active contracts.'));
            for (const c of r.contracts) {
                const row = el('div', 'adm-row');
                const chip = el('span', 'tier-chip', c.tier); chip.style.background = tierColor(c.tier);
                row.appendChild(chip);
                const info = el('div', 'a-info');
                info.append(el('div', 'a-model', `${c.name} (${c.src}) — ${c.model}`),
                    el('div', 'a-sub', `${c.tierLabel} · ${c.state}${c.isCrew ? ' · crew job' : ''} · ${money(c.reward)}`));
                row.appendChild(info);
                const end = el('button', 'btn danger sm', 'Force end');
                end.onclick = async () => {
                    const ok = await dlgConfirm('Force end contract', `End ${c.name}'s ${c.tierLabel} contract?`);
                    if (!ok) return;
                    const rr = await api('admin:endContract', { target: c.src });
                    toast('Admin', rr.ok ? 'Contract ended' : errMsg(rr.error));
                    refreshActiveContracts();
                };
                row.appendChild(end);
                activeList.appendChild(row);
            }
        }
        refreshActiveContracts();

        // player stats lookup / edit
        const statCard = el('div', 'card');
        statCard.appendChild(el('h3', '', 'Player stats'));
        const lookupRow = el('div', 'row');
        const lookupInput = el('input'); lookupInput.type = 'number'; lookupInput.placeholder = 'Server ID';
        const loadBtn = el('button', 'btn', 'Load');
        lookupRow.append(lookupInput, loadBtn);
        statCard.appendChild(lookupRow);
        const statBody = el('div');
        statCard.appendChild(statBody);
        view.appendChild(statCard);

        loadBtn.onclick = async () => {
            const target = parseInt(lookupInput.value, 10);
            if (!target) return toast('Admin', 'Enter a server ID.');
            const r = await api('admin:playerStats', { target });
            statBody.innerHTML = '';
            if (!r.ok) return toast('Admin', errMsg(r.error));
            const p = r.profile;
            statBody.appendChild(el('div', 'muted',
                `${p.name} — Level ${p.level} (${p.xp} XP) · Hacker Lv.${p.hackerLevel} · Driver Lv.${p.driverLevel} · ${p.completed} jobs · ${money(p.earnings)} earned`));

            const editRow = el('div', 'row'); editRow.style.marginTop = '10px';
            const levelInput = el('input'); levelInput.type = 'number'; levelInput.placeholder = 'New level'; levelInput.style.maxWidth = '110px';
            const setLevelBtn = el('button', 'btn', 'Set level');
            setLevelBtn.onclick = async () => {
                const level = parseInt(levelInput.value, 10);
                if (!level) return toast('Admin', 'Enter a level.');
                const rr = await api('admin:setLevel', { target, level });
                toast('Admin', rr.ok ? 'Level updated' : errMsg(rr.error));
                if (rr.ok) loadBtn.onclick();
            };
            const xpInput = el('input'); xpInput.type = 'number'; xpInput.placeholder = 'XP amount'; xpInput.style.maxWidth = '110px';
            const giveXpBtn = el('button', 'btn', 'Give XP');
            giveXpBtn.onclick = async () => {
                const amount = parseInt(xpInput.value, 10);
                if (!amount) return toast('Admin', 'Enter an amount.');
                const rr = await api('admin:giveXp', { target, amount });
                toast('Admin', rr.ok ? 'XP granted' : errMsg(rr.error));
                if (rr.ok) loadBtn.onclick();
            };
            const resetBtn = el('button', 'btn danger', 'Reset progress');
            resetBtn.onclick = async () => {
                const ok = await dlgConfirm('Reset progress', `Wipe ALL boosting progress for ${p.name}? This cannot be undone.`);
                if (!ok) return;
                const rr = await api('admin:resetProfile', { target });
                toast('Admin', rr.ok ? 'Progress reset' : errMsg(rr.error));
                if (rr.ok) loadBtn.onclick();
            };
            editRow.append(levelInput, setLevelBtn, xpInput, giveXpBtn, resetBtn);
            statBody.appendChild(editRow);
        };

        // VIN check logs
        const vinCard = el('div', 'card');
        const vinHead = el('h3', '', 'Recent VIN checks');
        const vinRefresh = el('button', 'btn ghost sm', 'Refresh'); vinRefresh.style.marginLeft = 'auto';
        vinHead.style.display = 'flex'; vinHead.style.alignItems = 'center';
        vinHead.appendChild(vinRefresh);
        vinCard.appendChild(vinHead);
        const vinList = el('div');
        vinCard.appendChild(vinList);
        view.appendChild(vinCard);

        async function refreshVinLogs() {
            const r = await api('admin:vinLogs', { limit: 20 });
            vinList.innerHTML = '';
            if (!r.ok) return vinList.appendChild(el('div', 'muted', errMsg(r.error)));
            if (!r.logs.length) return vinList.appendChild(el('div', 'empty', 'No VIN checks logged yet.'));
            for (const log of r.logs) {
                const row = el('div', 'adm-row');
                const info = el('div', 'a-info');
                info.append(el('div', 'a-model', `${log.officer_name || log.officer} → ${log.plate}`),
                    el('div', 'a-sub', String(log.created_at)));
                row.appendChild(info);
                row.appendChild(el('div', 'adm-badge ' + log.result, log.result.toUpperCase()));
                vinList.appendChild(row);
            }
        }
        vinRefresh.onclick = refreshVinLogs;
        refreshVinLogs();
    }

    function adminChip(label, value) {
        const c = el('div', 'stat');
        c.append(el('div', 'v', String(value)), el('div', 'l', label));
        return c;
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
        not_authorized: 'You are not authorized to do that.',
        bad_tier: 'Unknown tier.',
        assign_failed: 'Could not assign a contract to that player.',
        no_profile: 'That player has no boosting profile yet.',
        bad_request: 'Invalid request.',
        no_contract: 'No active contract.',
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

    // Defense in depth: this page should ONLY ever load with a ?ctx=laptop
    // marker on its URL (set by the boosting client's RegisterApp call, since
    // there is no ui_page / standalone mode in fxmanifest.lua). If it somehow
    // loads without that marker, stay hidden rather than risk rendering
    // full-screen and uncontrolled.
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

    // The laptop tears down the iframe on close; the `!framed` branch only
    // matters for the defensive fallback above and is otherwise unreachable.
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
