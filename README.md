# Universal Boosting

> A complete, server-authoritative **car-boosting job** that installs straight
> into the **NexOS Laptop App Store**. Steal high-value cars, hack their
> trackers, outrun the cops, then deliver clean or scratch the VIN to keep the
> car. Team up in crews, auction unwanted jobs, and climb global & weekly
> leaderboards.

Universal for **Qbox / QB-Core / ESX Legacy / Standalone** with the same open,
modular bridge system as the laptop. No build step, nothing encrypted.

---

## What's inside

- **Laptop-exclusive** — no standalone/tablet mode. Opens only from the NexOS
  Laptop's desktop or App Store.
- **Search zones, not pinpoint blips** — the real vehicle location is never
  sent to the client until you search close enough to it; a moving pin only
  appears once you're within range.
- **Full contract lifecycle** — search the zone → hack the tracker (minigame)
  → escape the police → **Normal Delivery** (crypto + XP) or **VIN Scratch**
  (secret garage, higher reward, keep the car — now automatically registered
  to your in-game garage).
- **NPC guards** — tier-scaled security peds spawn near the target vehicle;
  fight or sneak past.
- **Damage-based payout** — a wrecked delivery pays less. Condition% and the
  resulting payout are shown live before you commit.
- **Crews** — invite friends, queue together, configurable payout split
  (equal, or equal + leader bonus) plus a full-crew participation bonus.
- **Queue** — solo or as a crew; contracts are matched to your boosting level.
- **Progression** — separate **Boost level**, **Hacker XP** and **Driver XP**;
  higher level unlocks higher tiers (D → C → B → A → S → S+).
- **Auction house** — list an unwanted contract, others bid or buy it out.
- **Leaderboards** — Overall / Hacker / Driver, each Global or Weekly.
- **Police VIN checks** — flag scratched/stolen plates, with an audit log.
- **History**, active-contract tracker, notifications.
- **Risk & reward tiers** (D → S+) with configurable vehicles, rewards, police
  response and spawn/delivery/VIN locations.
- **In-app Admin panel** (plus `/boostadmin` chat command) and a heavy
  `config.lua` for everything above.

---

## Installation

1. Install the **NexOS Laptop** resource first (this app registers into its
   App Store). **The Boosting App is laptop-exclusive** — there is no
   standalone/tablet mode and no command that opens it; without the laptop
   running, players cannot open it at all.
2. Drop `universal_boosting` into `resources/`.
3. In `server.cfg`, **after** the laptop and your framework:
   ```cfg
   ensure oxmysql
   ensure qbx_core          # or qb-core / es_extended
   ensure ox_inventory      # or qb-inventory
   ensure laptop            # the NexOS laptop
   ensure universal_boosting
   ```
4. Tables auto-create on first start (`sql/boosting.sql` provided for manual
   installs).
5. Add the crypto reward item (default `cryptostick`) to your inventory, or set
   `Config.Currency.type = 'money'` to pay into a bank/cash/crypto account
   instead (on ESX, `account = 'crypto'` maps to `black_money`).
   Classic ESX (default inventory) item:
   ```sql
   INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`)
   VALUES ('cryptostick', 'Crypto Stick', 0, 0, 1);
   ```
   > On classic ESX the console prints `inventory: esx` — the built-in ESX
   > inventory bridge (items route through the ESX player object).
6. Grant admins the panel: `add_ace group.admin boosting.admin allow`.

The app appears in the laptop's **App Store** under *Crime*. Players install it
(free by default) and it lands on their desktop.

---

## How the laptop integration works

Boosting registers with the laptop **twice** — the recommended pattern for any
App Store app:

**Server** (`server/main.lua`) — the authoritative store listing:
```lua
exports['laptop']:RegisterStoreApp({
    id = 'boosting', name = 'Car Boosting', developer = 'Universal',
    category = 'Crime', icon = '🚗', price = 0,
    description = '...', onInstall = function(src) ... end,
})
```

**Client** (`client/main.lua`) — the openable app, hidden until installed:
```lua
exports['laptop']:RegisterApp({
    id = 'boosting', label = 'Car Boosting', icon = '🚗',
    ui = ('nui://%s/html/index.html'):format(GetCurrentResourceName()),
    store = true,    -- ← hidden on the desktop until installed via the store
})
```

When a player installs it, the laptop fires `nexos:appInstalled(src, 'boosting')`
which boosting listens to. The app UI runs as an **iframe inside the laptop
window**; its `fetch('https://universal_boosting/api')` calls hit this
resource's own NUI callbacks — a fully independent client/server pipeline.

Both registrations retry until the laptop is up and re-register if the laptop
restarts, so start order doesn't matter.

### Reusing the laptop's minigames

The tracker hack and VIN scratch call the laptop's exported minigame:
```lua
local success = exports['laptop']:StartHacking('memory'|'timing', difficulty)
```
If the laptop isn't installed, a small built-in skill check (`FallbackSkillCheck`
in `client/contract.lua`) is used instead.

---

## Configuration (`config/config.lua`)

Everything is in one heavily-commented file:

| Section | Controls |
|---|---|
| `Config.Currency` | crypto reward as an **item** or a **money account** |
| `Config.Progression` | XP curve, max level, hacker/driver XP per level |
| `Config.Tiers` (D → S+) | vehicles, base reward, XP split, hack game + difficulty, police stars, level gate, spawn weight |
| `Config.Contract` | spawn points, clean delivery drop-offs, secret VIN garages, VIN reward multiplier, queue timing, **search zone** (radius per tier, reveal distance, jitter) |
| `Config.Tracker` | GPS tracker (see below): time to disable, per-tier enable, minigame, escalation, fail cooldown |
| `Config.Npcs` | security guards during the theft phase: count/weapon/health/accuracy per tier, spawn radius |
| `Config.Damage` | vehicle-condition payout scaling: condition% → multiplier table, payout floor |
| `Config.Police` | min cops online, dispatch alert, escape rules (lose stars / distance), applied wanted level |
| `Config.Dispatch` | hook for your dispatch system (ps-dispatch, cd_dispatch, …) |
| `Config.Groups` | crew size, invite expiry, **payout mode** (`equal`/`leader_bonus`), leader bonus %, full-crew participation bonus |
| `Config.Garage` | VIN-scratch garage storage: backend (`auto`/`qb`/`esx`/`custom`), default garage |
| `Config.VinCheck` | police VIN checks: job whitelist, command/keybind, scan time, audit logging |
| `Config.Auction` | duration, min bid, listing fee, max listings |
| `Config.Leaderboard` | top N, weekly reset day |
| `Config.Admin` | command name + ACE permission (drives both `/boostadmin` and the in-app Admin panel) |

### Search zones (no pinpoint blips)

Instead of dropping an exact blip on the target vehicle, players get a
**circular search area** and must physically locate the car:

- The **real location is never sent to the client** until they've proven
  they're close enough — the server only ships a zone center + radius.
  Every few seconds (`pollInterval`) the client reports its position
  (`contract:searchPing`); once within `revealDistance`, the server reveals
  the exact spot **and only then** does the vehicle spawn.
- Zone **radius scales per tier** (`radiusByTier`, D=150m up to S+=350m by
  default) and the center can be **jittered** away from the real spot
  (`jitter`) for extra obfuscation.
- **Crew sync**: if any crew member searches close enough, the reveal is
  broadcast to the whole crew — everyone's blip updates to the exact pin. Only
  the contract **owner** (shown as the one who queued) can click *Start
  contract*, so crew members don't accidentally spawn duplicate copies of the
  vehicle; they can still tag along and search together beforehand.
- Set `Config.Contract.searchZone.enabled = false` to fall back to the old
  exact-pinpoint-blip behaviour.

| Key | Meaning |
|---|---|
| `enabled` | master switch |
| `revealDistance` | metres from the real spot before it's pinpointed & spawned |
| `jitter` | metres the zone center is randomised off the real spot |
| `pollInterval` | seconds between search pings sent to the server |
| `radiusByTier` | search-zone radius per contract tier |

### NPC guards

Tier-scaled security peds spawn near the target vehicle during the theft
phase (`Config.Npcs`) — purely client-side world dressing, no server
round-trip needed. They despawn once the tracker is hacked (car obtained) or
the contract ends.

| Key | Meaning |
|---|---|
| `enabled` | master switch |
| `spawnRadius` | metres around the vehicle where guards appear |
| `models` | ped models to pick from |
| `perTier` | `count` / `weapon` / `health` / `armor` / `accuracy` per contract tier |

### Vehicle damage & payout

The final payout is scaled by the vehicle's **condition** at delivery/VIN
time — the average of body health and engine health, read from the real
networked vehicle entity **server-side** (never trusted from the client):

- The delivery/VIN-scratch help prompt shows a **live estimate** — condition%
  and the resulting payout — updated every tick as you drive, so you know
  before you commit whether it's worth patching the car up first.
- The actual multiplier is computed and applied **server-side** when you
  deliver; the client estimate is just a preview and may drift slightly from
  network lag, but the final number is always authoritative.

Configure in `Config.Damage`:

| Key | Meaning |
|---|---|
| `enabled` | master switch (off = damage never affects payout) |
| `tiers` | condition% → payout multiplier, evaluated top-down (first match wins) |
| `minPayoutMultiplier` | floor — a totally wrecked car still pays at least this fraction |

### Crew payouts

`Config.Groups` controls how the reward splits when a contract is completed
as a crew:

- **`payoutMode = 'equal'`** *(default)* — the reward is split evenly across
  every online crew member. Nobody gets more just for being the leader.
- **`payoutMode = 'leader_bonus'`** — same even split, then the leader's cut
  is topped up by `leaderBonus` (e.g. `0.15` = +15%), funded **on top** of the
  pool — it never reduces anyone else's share.
- **Full-crew bonus** (`fullCrewBonus`, `fullCrewRadius`) — if **every** online
  crew member is within `fullCrewRadius` of the delivery/VIN point at the
  moment of completion, everyone gets an extra bonus split evenly on top.
  Rewards genuine teamwork over one driver doing everything solo while AFK
  crewmates still collect a cut.
- Everything is computed and paid **server-side**; XP awards likewise respect
  `Config.Groups.shareXp`.

### GPS Tracker (mandatory disable step)

Every stolen vehicle is fitted with a **GPS tracker** the moment it's boosted:

- Its **live position is broadcast** on the map to the booster's crew *and*
  every on-duty officer (a flashing 📡 blip that follows the car in real time).
- Disabling it is **mandatory** — you can't deliver or VIN-scratch while it's
  live (`Config.Tracker.blockDelivery`). Disabling triggers a hacking minigame
  (the same one the laptop Terminal uses, via the shared `StartHacking` export).
- **Crew rule** (`Config.Tracker.crewRule`): solo boosters always disable it
  themselves. In a crew, who may disable it depends on the rule:
  - `'non_leader'` *(default)* — the **leader cannot** disable it; any **other**
    crew member must do it. Forces teamwork: the leader drives, a passenger
    breaks the tracker. Everyone else (including the leader) sees
    *"Only a crew member who is not the leader can disable the GPS tracker."*
    Safety: a leader whose crew has no other online members is treated as solo,
    so the job can never soft-lock.
  - `'hacker'` — the leader or the member assigned as **Hacker**
    (Crew tab → *Make hacker*) may disable it.
  - `'any'` — any crew member may disable it.

  Only eligible players see the *Disable GPS Tracker* button, and the server
  re-checks eligibility on every attempt — the button is cosmetic, the rule is
  enforced server-side.
- **Escalation:** if the tracker isn't killed within `Config.Tracker.disableTime`
  seconds, the booster's wanted level is forced up and police get re-alerted to
  the live position every `escalation.alertInterval` seconds until it's down.

Config lives in `Config.Tracker`:

| Key | Meaning |
|---|---|
| `enabled` | master switch for the whole tracker system |
| `crewRule` | `'non_leader'` (leader can't disable — teamwork), `'hacker'`, or `'any'` |
| `disableTime` | seconds to disable before the police response escalates |
| `perTier` | enable/disable the tracker per contract tier (D → S+) |
| `minigame` / `difficulty` | which hack minigame the disable uses |
| `updateInterval` | how often the live position is broadcast |
| `failCooldown` | wait time after a failed disable attempt |
| `blockDelivery` | block delivery / VIN until the tracker is disabled |
| `escalation.wantedLevel` / `escalation.alertInterval` | how hard it escalates |
| `blip` | sprite / colour / scale of the moving tracker blip |

Server events you can hook:
```lua
-- fired to any resource when a tracker is disabled / times out, if you want
-- to drive your own dispatch or scoring off it (optional):
-- (the built-in police alert + wanted level already work with zero deps)
```

### Keeping a VIN-scratched car (automatic garage storage)

When a VIN scratch completes the car gets a **clean identity, automatically**:

1. The server generates a **fresh plate** (unique against your vehicle tables).
2. The vehicle is **registered to the player** in the framework's standard
   ownership table — `player_vehicles` on QB/Qbox, `owned_vehicles` on ESX —
   which every mainstream garage script reads (qb-garages, qs, jg, cd_garage,
   esx_garage, okokGarage, loaf_garage, …). The row is inserted with
   `state/stored = 0` (car is out in the world), so the player simply drives
   to any garage and **stores it normally**.
3. **Keys for the new plate** are handed out (server-side + client-side hooks,
   same system as the tracker hack).
4. The new plate is recorded in `boosting_vin_records` — police VIN checks
   flag it as *scratched* forever (see below).

Configure in `Config.Garage`:

| Key | Meaning |
|---|---|
| `enabled` | master switch (off = car stays spawned but unowned, old behaviour) |
| `system` | `'auto'` (QB→`player_vehicles`, ESX→`owned_vehicles`), `'qb'`, `'esx'`, `'custom'`, `'none'` |
| `defaultGarage` | QB only: the garage id written to the row |
| `custom` | `function(src, data)` — wire any non-standard garage; `data = { identifier, plate, model, hash, props, tier }` |

Events fired on completion (for extra integrations):
```lua
AddEventHandler('boosting:vehicleKept', function(src, data) end)        -- legacy: { model, tier, plate }
AddEventHandler('boosting:vehicleRegistered', function(src, data) end)  -- { model, tier, plate, garaged }
```

### Police VIN check

Authorized jobs can inspect any vehicle's VIN (`Config.VinCheck`):

- **`/checkvin`** — checks the vehicle the officer is in, or the nearest one
  within `maxDistance`. Optional rebindable key via `keybind = 'F7'`.
- **Target / radial / MDT integration** — call the client export with the
  vehicle entity:
  ```lua
  -- ox_target example:
  exports.ox_target:addGlobalVehicle({{
      name = 'boost_vincheck', icon = 'fas fa-barcode', label = 'Check VIN',
      groups = { 'police' },
      onSelect = function(data) exports['universal_boosting']:CheckVin(data.entity) end,
  }})
  ```
- **Results** (derived server-side; the plate is read from the entity, never
  trusted from the client):
  - `clean` — *"VIN is clean."*
  - `scratched` — the plate is in `boosting_vin_records` → *"VIN has been
    SCRATCHED — identity is forged."*
  - `stolen` — the plate belongs to a **live** boosting contract → *"vehicle
    reported STOLEN."*
- **Server-authoritative**: the job whitelist (`jobs`), the distance check and
  the lookup all run on the server; a non-police client calling the callback
  gets `not_authorized`.
- **Audit log**: every check is written to `boosting_vin_checks`
  (officer, plate, result, timestamp) — review with `/boostadmin vinlogs [n]`.
  Disable with `logChecks = false`.

---

## Admin

Two entry points, sharing the exact same logic (`server/admin.lua`'s `Admin.*`
functions) — every action is gated behind the `boosting.admin` ACE, checked
**server-side** on every single request regardless of which entry point is used:

### In-app Admin panel

Players with the ACE see an **Admin** tab inside the Boosting App itself:

- **Server stats** — active contracts, queue size, crew count.
- **Create contract** — force-assign a tier to any online player.
- **Active contracts** — live list with a *Force end* button per row.
- **Player stats** — look up a player's level/XP/earnings; set their level,
  grant XP, or wipe their progress entirely.
- **Recent VIN checks** — the same audit log as `/boostadmin vinlogs`.

The tab only *shows* for players the server already flagged as admins
(`isAdmin` in the boot payload) — that's a convenience, not the security
boundary. Every `admin:*` action re-checks the ACE permission itself, so a
non-admin can't reach these actions even by forging NUI requests.

### `/boostadmin` chat command

| Command | Effect |
|---|---|
| `setlevel <id> <level>` | set a player's boosting level |
| `givexp <id> <amount>` | grant XP across all tracks |
| `grant <id> <tier>` | force-assign a contract |
| `clear <id>` | force-end a player's active contract (also tears down tracker blips) |
| `reset <id>` | wipe a player's progress |
| `stats` | live counts (active/queued/crews) |
| `vinlogs [n]` | recent police VIN checks (default 10, max 50) |

---

## Security / performance notes

- **Server-authoritative**: rewards, XP, contract state, money, reward
  payouts, vehicle condition and admin actions all live server-side. The NUI
  only *requests* transitions.
- **Search zones**: the real vehicle location is held server-side and only
  released to the client once a position report proves they're within
  `revealDistance` — a modded client can't read it early from a network
  payload, because it was never sent.
- Steal/deliver/VIN transitions re-validate the player's live ped position
  server-side; state can only advance in order. Vehicle net ids are sanity
  checked (must resolve to a real vehicle near the reporting player) before
  keys are granted or condition/damage is read.
- **Admin actions** re-check the `boosting.admin` ACE on every single request,
  independent of the client's cached `isAdmin` flag (which only controls tab
  visibility).
- Auctions escrow bids (taken on bid, refunded on outbid) so the economy stays
  balanced. Winner/seller must be online at settlement (documented in
  `server/auction.lua`).
- Minigame *results* are inherently client-reported (as with all FiveM
  client-side minigames); position gating limits abuse.
- No idle loops — the queue/auction threads tick on a few-second cadence; the
  world-phase loops only run during an active contract.

## Data model

`boosting_profiles`, `boosting_contracts`, `boosting_auctions`,
`boosting_history`, `boosting_groups`, `boosting_vin_records` (scratched-plate
registry), `boosting_vin_checks` (police VIN check audit log) — see
`sql/boosting.sql`.

## Adapting a framework / inventory

Bridges live in `bridges/framework/*.lua` and `bridges/inventory/*.lua` and use
the same interface as the laptop. Copy one, adjust the exports, register it, add
it to `fxmanifest.lua`. Nothing else changes.
