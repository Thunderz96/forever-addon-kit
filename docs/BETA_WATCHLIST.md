# WoW: Forever beta — big-ticket watch list

**Author:** Thunderz · written 2026-09-15, for beta opening 2026-09-17 (level cap 30, runs to 2026-10-21)

Each item says what to look for, why it matters for addon work, and how Forever
Beacon captures it (or why it can't). Ordered by how much the answer changes
what we build. Tick things off in the Notes column as the beta answers them.

## Tier 1 — decides whether anything can be built at all

| # | Question | Why it matters | How we find out | Notes |
|---|---|---|---|---|
| 1 | **Do addons load?** Is there an AddOns button on character select, and does Forever Beacon print its login line? | Everything below depends on it. Forum rumour says the BlizzCon demo hid the button. | Eyes on character select. `/fb` in chat. | |
| 2 | **Interface number and build line.** What does `GetBuildInfo()` return, and is the client a 1.60.x Classic branch or a 12.x Retail branch? | Sets the TOC for every port and tells us which API family to code against. | `probe.csv`: `version`, `build`, `interface`, `project`, `projectConstants`. | |
| 3 | **Did Midnight's combat restrictions carry over?** Are creature health, damage amounts and aura data "secret" values? | Decides whether combat-adjacent tools (threat meters, boss mods, ThreatClassic2 port) are viable. | `npcs.csv` column `hpSecret`; `npcAbilities.csv` `maxDmg` null everywhere; `events.csv` args showing `<secret>`. | |
| 4 | **Which C_ namespaces exist?** Especially anything new (`C_Legacy*`, `C_Camp*`, `C_Ruleset*`) and which old Classic globals survive (`GetTalentInfo`, `GetQuestLogTitle`, `UnitAura`). | The API map for the whole beta. Missing calls in the wanted list are our porting to-do. | `probe.csv` → `namespaces` (JSON) and `wanted`; `errors.csv` for collectors that hit a missing call. | |
| 5 | **Is there any addon policy statement?** Q&A on 2026-09-17 10:00 Pacific, beta patch notes, forum blue posts. | Written policy beats inference. | Watch the Q&A. Search the Forever forum for "addon" daily during week one. | |

## Tier 2 — shapes which addon to build first

| # | Question | Why it matters | How we find out | Notes |
|---|---|---|---|---|
| 6 | **Legacy Progression UI and API.** Frame names, events fired when points are earned or spent, whether perks are auras or hidden state, whether the account-wide pool is readable. | Legacy Ledger is idea #2 and needs a data source. | Open the Legacy panel, then `/fb frames` and `/fb probe`. Look in `events.csv` for LEGACY_*; `auras.csv` for perk auras; `probe.frames`. `/fb note` the point costs by hand. | |
| 7 | **Campfire mechanics as data.** Aura spell IDs for the campfire buffs, their durations, the object names and IDs of Basic Campfire and the profession objects, blueprint recipe items, any CAMP_* events. | Campfire Companion (idea #3) is timers plus a catalog; all of it comes from here. | Sit at a fire: `auras.csv`. Hover the fire and each object: `objects.csv`. Loot a blueprint: `items.csv`, `lootEvents.csv`. `/fb note` slot counts and cooldown behaviour. | |
| 8 | **Situational trinket tooltip text.** Exact wording of the terrain and creature-type conditions, and whether a zone's terrain type is exposed anywhere in the API. | Trinket Trace (idea #4) needs to parse conditions and know the current terrain. | Hover every trinket: `items.csv` tooltip column. Probe for anything named terrain/environment in `probe.keywordGlobals`. Note zone → terrain pairs by hand. | |
| 9 | **New dungeon data at level 30 and below.** Which of the nine are reachable in beta, boss NPC IDs, boss spell IDs, loot tables, Advanced Blueprint drops. | Forever Guide (idea #1) starts here. Zephras Isle and Riverglades content is also in scope. | Run each dungeon once: `npcs.csv` (bosses have classification `worldboss`/`elite`), `npcAbilities.csv`, `lootEvents.csv`. Positions inside instances will be missing; note boss order by hand. | |
| 10 | **Quest data coverage.** Do `QUEST_ACCEPTED` and `QUEST_WATCH_UPDATE` carry quest IDs, do objectives come through `C_QuestLog.GetQuestObjectives`, are giver and ender NPC IDs populated? | Quest Harvester (idea #6) and any Questie contribution depend on clean IDs. | `quests.csv`, `questEvents.csv`, `objProgress.csv` after a normal levelling session. Blank `questID` columns mean a signature change to handle. | |
| 11 | **Layering visibility.** Does anything expose the layer or language pool: an event, a CVar, NPC GUID server fields changing on layer switch? | Layer Mate (idea #7) lives or dies on this. | Compare the third GUID field across `npcs.csv` sightings before and after joining a friend's group. `events.csv` for anything fired at the moment of a layer hop. | |
| 12 | **Talent tree shape.** Are trees readable through `GetTalentInfo`, are the 11/21/31 milestones and prerequisites present, do tooltips show the reworked text? | Talent tools and the TalentSwapper port need the read path. | `talents.csv` on a level 10+ character; `spells.csv` tooltips for talent spells. If `talents.unsupported` is true, note which API replaced it. | |

## Tier 3 — good to know, informs later work

| # | Question | Why it matters | How we find out | Notes |
|---|---|---|---|---|
| 13 | **Transmog collection API.** Does `C_TransmogCollection` exist, does the shared-appearance rule show in loot or tooltips ("appearance learned by all")? | Appearance tracker idea, low priority. | `probe.wanted`, `items.csv` tooltip lines on dungeon blues. | |
| 14 | **Vendor and trainer economics.** Reagent-free Tier 1 camping items, spell training costs, riding cost and level. | Feeds guides and the Legacy planner's "is Reagent Economy worth it" math. | `vendors.csv`, `trainers.csv` after visiting each. | |
| 15 | **Racial rework as data.** Spell IDs and tooltips for the two actives and two passives per race. | Reference content for Forever Guide. | Spellbook dump per race: `spellbook.csv`, `spells.csv`. One character per race is the long way; the Skyborne start zone covers one. | |
| 16 | **Map IDs for the new zones.** Zephras Isle, Riverglades, Mount Hyjal, Shen'dralas, and the new dungeons' instance map IDs. | TomTom waypoints and any map overlay need them. | `maps.csv`, `zones.csv` the first time you enter each. | |
| 17 | **Which existing addons already work.** Drop Questie, Leatrix Plus, Details, and BigWigs Classic into the folder and see what loads without errors. | Tells us where the community will already be covered and where the gaps are. | `luaErrors.csv` collects every addon's errors, not just ours. | |
| 18 | **Client folder and product code.** What Battle.net names the install folder, and the CDN product string. | Sync script and any future bridge need the path; CurseForge will need the flavor. | Look in `C:\Program Files (x86)\World of Warcraft\` for the new `_*_` folder after install. | |
| 19 | **Event names for the new systems.** Anything in the firehose with LEGACY, CAMP, RULESET, LAYER, TRANSMOG, SKYBORNE in the name. | Cheapest possible discovery of new hooks. | `events.csv`, sorted by name. | |
| 20 | **Hardcore hooks even though it is post-launch.** Any ruleset identifier readable from Lua (`probe.keywordGlobals` with "ruleset" or "hardcore"). | Future death tracker and ruleset-aware UI. | `probe.csv`. | |

## Day-one order of operations

1. Watch or read the Q&A (item 5). Post the addon question beforehand.
2. Install, character select, AddOns button (item 1).
3. Log in, wait 15 s, `/fb`, `/fb flush`, `/reload`. The sync task picks it up within 30 minutes, or run it by hand (items 2, 3, 4, 18).
4. Open `probe.csv`, `errors.csv` and `events.csv` from the newest extract: set the TOC interface number from `probe`, and fix any collector that hit a missing call.
5. Then play. Open every new panel once and `/fb frames` (item 6). Sit at a campfire (item 7). Hover every trinket (item 8). Everything else accumulates on its own.

## What the sync task does on its own

`ForeverBeaconSync` runs every 30 minutes while you are logged into Windows.
It archives the SavedVariables file to `ForeverBeacon\data\raw\` whenever it
has changed and writes a fresh CSV/JSONL set to `ForeverBeacon\data\<stamp>\`.
The only manual step left is that WoW writes the file on `/reload` or logout,
so a `/reload` before a long break is the one habit worth keeping.
