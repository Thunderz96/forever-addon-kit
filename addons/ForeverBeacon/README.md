# Forever Beacon

**Author:** Thunderz · **Status:** 0.1.0, built 2026-09-15 for the WoW: Forever beta (opens 2026-09-17)

A Wowhead-Looter-style data harvester. It sits quietly, records everything the
client shows you, and writes it to SavedVariables. `tools/fb_extract.py` turns
that into CSV/JSONL you can open in anything. The goal for the beta is simple:
**leave every session with more data than you started with**, so the addon
ideas in the Forever briefing (Forever Guide, Legacy Ledger, Campfire Companion,
Trinket Trace) have real IDs and real text to build on.

Beacon (the Retail one) harvests *your character's state*. Forever Beacon
harvests *the world*. They share the JSON encoder and the shell; the domains are
completely different.

## What it collects

| Domain | Source | Stored as |
|---|---|---|
| `probe` | build/interface number, every `C_*` namespace and its functions, globals/enums/frames named Legacy/Camp/Transmog/Ruleset/Layer/Skyborne, Blizzard UI addons, presence of ~40 wanted API calls | catalog |
| `events` | **every event the client fires**, with count and first scalar args. New events for the new systems show up here by themselves | catalog |
| `maps`, `zones`, `zoneVisits` | map tree, zone/subzone entries with instance info, visit log with positions | catalog + log |
| `npcs` | every creature moused over or targeted: level range, type, classification, reaction, max HP/power, faction, up to 12 sighting positions, kill count, melee swing range | catalog |
| `npcAbilities` | from the combat log: per creature, every spell it casts/applies/damages with, count and max damage | catalog |
| `vendors`, `trainers`, `gossip`, `taxi` | full windows when opened, with prices, requirements, options, flight links | catalog |
| `items` | every item tooltip you see (full text, so new stats and trinket conditions are captured) plus `GetItemInfo` fields | catalog |
| `lootEvents` | each loot window: source GUID kind + ID, items, quantity, position | log (20k) |
| `objects` | game objects by tooltip name (and GUID where the client gives it): nodes, chests, campfires | catalog |
| `spells`, `spellbook`, `talents` | spell tooltips, full spellbook per class, full talent trees per class with prereqs | catalog |
| `auras` | every buff/debuff seen on you with duration and source (campfire buffs, food, Legacy perks if they are auras) | catalog |
| `quests`, `questEvents`, `objProgress`, `infoMsgs` | giver + ender NPC and position, quest text, objectives, offered and paid rewards, XP/money, accept/turn-in log, objective-progress positions, "X slain: 3/10" messages with positions | catalog + logs |
| `notes` | `/fb note <text>` annotations with position | log |
| `errors`, `luaErrors` | collector failures (which API was missing) and every Lua error from any addon | logs |

Nothing is automated in your favour: it never casts, moves, buys, or talks.
It only reads, so it stays on the safe side of any addon policy.

## Install

1. Copy this folder to `<flavor>\Interface\AddOns\ForeverBeacon` where
   `<flavor>` is whatever the Forever beta installs as (watch for a new
   `_*_` folder next to `_classic_era_` after the Battle.net install).
2. If the client says it is out of date, tick **Load out of date AddOns**.
   The TOC lists guessed interface numbers; the real one is unknown until Thursday.
3. Log in. You should see `Forever Beacon: collecting. /fb for status.`

## In game

| Command | Does |
|---|---|
| `/fb` | counts per domain, payload size |
| `/fb flush` | encode the payload now (then `/reload` to write it to disk) |
| `/fb note <text>` | timestamped, positioned annotation ("campfire, 3 slots, blacksmith wheel") |
| `/fb probe` | re-run the API probe (do this after opening a new Blizzard panel) |
| `/fb frames` | record visible frames whose name matches a Forever keyword (open the Legacy UI first) |
| `/fb pos` | print current map position |
| `/fb errors` | last collector errors and Lua error count |
| `/fb wipe` | clear everything |
| `/fb help` | full command list, including the Forever Compat placement commands |
| `/fb bugs [n]` | this session's errors from BugGrabber, in chat |
| `/fb frame <Name>` | why a frame is invisible: alpha, scale, size, anchors, hidden ancestor |
| `/fb bagtest` | run ToggleAllBags under pcall and report |

**Habits that produce data:** mouse over everything, open every vendor and
trainer, read every quest instead of skipping, hover loot before taking it,
`/fb note` anything the collectors cannot see (campfire slots, Legacy costs),
and `/reload` before a long AFK so the file gets written.

## Getting the data out

```powershell
.\tools\Sync-ForeverBeacon.ps1            # archive + extract if the file changed
.\tools\Sync-ForeverBeacon.ps1 -Force
.\tools\Sync-ForeverBeacon.ps1 -Register  # every 30 min + logon (elevated shell)
```

Output goes to `..\data\<timestamp>\` as `payload.json` plus one `.csv` and
`.jsonl` per domain. `npcAbilities`, `vendors` and `lootEvents` are exploded to
one row per (npc, spell), (vendor, item) and (loot event, item).

`ForeverBeaconSync` is registered on this PC (2026-09-15, every 30 minutes
while logged in, verified). Raw SavedVariables copies are kept in `..\data\raw\`. They are the archive;
never delete them during the beta.

## Thursday runbook

1. Before logging in: post the addon-policy question on the forums, watch the
   10:00 a.m. Pacific Q&A if it is live.
2. Install as above. Character select: is there an **AddOns** button at all?
3. First login: `/fb` should show the probe ran. Then `/fb flush`, `/reload`,
   and run `Sync-ForeverBeacon.ps1`. Open `probe.csv`: that is the interface
   number, the build, and the API map. Update the TOC to the real number.
4. Open every new panel once (Legacy, campfire, transmog, character sheet),
   then `/fb frames` and `/fb probe`.
5. Check `events.csv` for anything with LEGACY, CAMP, TRANSMOG, RULESET in the
   name and note the args.
6. Check `errors.csv` for collectors that hit a missing API and fix those first.
7. Play normally. Register the sync task so extraction happens on its own.

## Smoke-test results (2026-09-15)

- **MoP Classic 5.5.4 (interface 50504):** clean. Positions, gossip text, quest giver/ender, 183 spellbook entries, 189 C_ namespaces. Talent trees unsupported there (expected; MoP uses the tier grid).
- **Retail 12.1.0 (interface 120100):** clean after two fixes. Midnight returns **secret numbers** for creature max health (every NPC, even out of combat) and for damage amounts; comparing one throws, so `ns.Num` screens them and the JSON encoder emits `null` for any it cannot format. NPCs get `hpSecret = true`. If Forever shows the same, that is the answer to "did Midnight's restrictions carry over".
- Item and spell tooltips capture full text on both clients.

## Known limits (fix after the client is in hand)

- Positions come from `C_Map.GetPlayerMapPosition`; inside instances it returns
  nothing, so dungeon loot has zone but no coordinates. Boss room mapping needs
  a different approach later.
- Object detection is tooltip-based, so a node you loot without hovering (auto
  loot from range) is recorded from the loot event with its GUID but no name
  until you hover one.
- Vendor and trainer windows are read as displayed; trainer filters are
  recorded but not changed.
- `QUEST_WATCH_UPDATE` and `QUEST_ACCEPTED` have changed signatures across
  clients; both shapes are handled but check `questEvents.csv` on day one.
- The SavedVariables file will grow to several MB over the beta. Load time
  stays fine; the payload encode at logout is the only cost.

## Layout

```
ForeverBeacon.toc
FB_JSON.lua      encoder (from Beacon)
FB_Core.lua      DB, helpers, event dispatch, firehose, error hook, slash, payload
FB_Probe.lua     build/API/namespace/keyword/enum/addon probe, frame scan
FB_World.lua     maps, zones, objects (tooltip), taxi
FB_Units.lua     creature catalog, unit tooltips, vendors, trainers, gossip
FB_Items.lua     item tooltips, tooltip wiring (both client styles), loot
FB_Spells.lua    spell tooltips, spellbook, talents, auras, combat-log NPC abilities
FB_Quests.lua    quest detail/complete/progress/turn-in, objective positions, quest log dump
tools/           fb_extract.py, Sync-ForeverBeacon.ps1
data/            created by the sync script (raw/ + per-extract folders)
```
