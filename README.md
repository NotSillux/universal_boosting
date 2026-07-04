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

- **Full contract lifecycle** — locate → hack the tracker (minigame) → escape
  the police → **Normal Delivery** (crypto + XP) or **VIN Scratch** (secret
  garage, higher reward, keep the car).
- **Crews** — invite friends, queue together, split the payout.
- **Queue** — solo or as a crew; contracts are matched to your boosting level.
- **Progression** — separate **Boost level**, **Hacker XP** and **Driver XP**;
  higher level unlocks higher tiers (D → C → B → A → S → S+).
- **Auction house** — list an unwanted contract, others bid or buy it out.
- **Leaderboards** — Overall / Hacker / Driver, each Global or Weekly.
- **History**, active-contract tracker, notifications.
- **Risk & reward tiers** (D → S+) with configurable vehicles, rewards, police
  response and spawn/delivery/VIN locations.
- **Admin commands** and a heavy `config.lua`.

---

## Installation

1. Install the **NexOS Laptop** resource first (this app registers into its
   App Store). Boosting also works standalone via `/boosting` if the laptop
   isn't present.
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
| `Config.Contract` | spawn points, clean delivery drop-offs, secret VIN garages, VIN reward multiplier, queue timing |
| `Config.Tracker` | GPS tracker (see below): time to disable, per-tier enable, minigame, escalation, fail cooldown |
| `Config.Police` | min cops online, dispatch alert, escape rules (lose stars / distance), applied wanted level |
| `Config.Dispatch` | hook for your dispatch system (ps-dispatch, cd_dispatch, …) |
| `Config.Groups` | crew size, reward split (`equal`/`leader`), XP sharing, invite expiry |
| `Config.Auction` | duration, min bid, listing fee, max listings |
| `Config.Leaderboard` | top N, weekly reset day |
| `Config.Admin` | command name + ACE permission |

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

### Keeping a VIN-scratched car

When a VIN scratch completes, the server fires:
```lua
AddEventHandler('boosting:vehicleKept', function(src, data)
    -- data = { model, tier, plate }
    -- hook your keys / garage system here to permanently give the car
end)
```

---

## Admin

`/boostadmin` (requires the `boosting.admin` ACE):

| Command | Effect |
|---|---|
| `setlevel <id> <level>` | set a player's boosting level |
| `givexp <id> <amount>` | grant XP across all tracks |
| `grant <id> <tier>` | force-assign a contract |
| `clear <id>` | clear a player's active contract |
| `reset <id>` | wipe a player's progress |
| `stats` | live counts (active/queued/crews) |

---

## Security / performance notes

- **Server-authoritative**: rewards, XP, contract state, money and reward
  payouts all live server-side. The NUI only *requests* transitions.
- Steal/deliver/VIN transitions re-validate the player's live ped position
  server-side; state can only advance in order.
- Auctions escrow bids (taken on bid, refunded on outbid) so the economy stays
  balanced. Winner/seller must be online at settlement (documented in
  `server/auction.lua`).
- Minigame *results* are inherently client-reported (as with all FiveM
  client-side minigames); position gating limits abuse.
- No idle loops — the queue/auction threads tick on a few-second cadence; the
  world-phase loops only run during an active contract.

## Data model

`boosting_profiles`, `boosting_contracts`, `boosting_auctions`,
`boosting_history`, `boosting_groups` — see `sql/boosting.sql`.

## Adapting a framework / inventory

Bridges live in `bridges/framework/*.lua` and `bridges/inventory/*.lua` and use
the same interface as the laptop. Copy one, adjust the exports, register it, add
it to `fxmanifest.lua`. Nothing else changes.
