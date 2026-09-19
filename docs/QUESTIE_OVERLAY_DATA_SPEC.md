# Quest data format for the Questie overlay (WoW: Forever)

Hand this file to whoever is producing the data. The goal is to feed the addon **Questie** the
Forever quests its database lacks, so its map pins, tracker and tooltips work for them.

Deliver **plain CSV files**, UTF-8, comma-separated, one header row, double quotes around any
value containing a comma, quote or newline. Use exactly the file names and column names below.
Extra columns are fine and are ignored. Missing files are fine: send what you have.

## Ground rules (these matter more than the columns)

1. **Real game IDs only.** `quest_id`, `npc_id`, `object_id`, `item_id` must be the IDs the game
   client uses. Never invent, guess or renumber an ID. A row with no real ID is worthless.
2. **Blank beats guessed.** If a value is unknown, leave the cell empty. Do not fill in a plausible
   level, coordinate or prerequisite. Questie treats what it is given as fact and will draw a pin
   in the wrong place.
3. **Say where each row came from.** Every file has a `source` column: the client table or cache
   file and build (for example `QuestObjective.db2 1.60.1.69913`, `questcache.wdb`), a URL, or
   `in-game`. And a `confidence` column: `high` (read directly from game data), `medium`
   (derived, for example coordinates converted from world space), `low` (inferred).
4. **Forever only.** Build line 1.60.x, interface 16001. Do not include quests from Retail,
   Season of Discovery or other Classic versions unless they are confirmed present in Forever.
   Vanilla quests Questie already has are skipped automatically, so including them is harmless.
5. **Lists inside one cell** are separated with a pipe: `96895|96897`.
6. **Faction** is `H`, `A`, or blank for both. If you have the raw race bitmask instead, put it in
   `required_races_mask` and leave `faction` blank.

## Coordinates

Questie positions things per **zone**, as the 0 to 100 numbers the in-game map shows
(for example `65.9, 61.0`), together with the zone's **uiMapID** (Tirisfal Glades is `1420`).

- Preferred: `ui_map` + `x` + `y` in that form.
- If you only have **world coordinates** (continent/instance map ID plus X and Y in yards, as
  server-side spawn data uses), put them in `world_map`, `world_x`, `world_y` and leave
  `ui_map`, `x`, `y` blank. Also send `uimap_assignment.csv` (below) so they can be converted.
  Do not convert them yourself unless you can show the conversion is right for a known NPC.
- Forever's new zones: Zephras Isle 2521, Darkspear Islands 2524, Riverglades 2548,
  Shen'dralas 2652, Mount Hyjal 2482.

One spawn point per row. Several rows for the same NPC are expected and welcome: patrols and
multiple spawns become multiple pins.

## Files

### quests.csv (one row per quest)
| column | meaning |
|---|---|
| quest_id | required |
| title | required |
| quest_level | the quest's own level |
| required_level | minimum player level to be offered it |
| max_level | level above which it is no longer offered, if any |
| faction | `H`, `A`, or blank |
| required_races_mask | raw bitmask, only if faction is not enough |
| required_classes | class names separated by pipes (`PALADIN|WARRIOR`), or blank for all |
| giver_type / giver_id | `npc`, `object` or `item`, and that thing's ID |
| ender_type / ender_id | `npc` or `object`, and its ID |
| objective_text | the short objective summary shown in the quest log |
| zone_area_id | AreaTable ID of the quest's zone (Tirisfal Glades is 85), or blank |
| prequests_all | quest IDs that must ALL be completed first |
| prequests_any | quest IDs of which ANY one must be completed first |
| next_quest_id | the next quest in the chain |
| exclusive_to | quest IDs that make this one unavailable once taken or done |
| breadcrumb_for | the quest this optional lead-in quest points to |
| required_skill_id / required_skill_value | profession requirement, e.g. Cooking 1 |
| required_spell_id | quest only offered if the character knows this spell |
| repeatable | `1` if repeatable |
| source_item_id | item handed to the player when the quest is accepted |
| source / confidence | see ground rules |

### quest_objectives.csv (one row per objective)
| column | meaning |
|---|---|
| quest_id | |
| objective_index | 1, 2, 3 in quest-log order |
| type | `kill` (creature), `item`, `object` (interact), `talk`, `event` (explore/area), `reputation`, `spell` |
| target_id | npc_id, item_id, object_id, faction ID or spell ID according to type; blank for `event` |
| count | how many |
| text | the objective line as the game shows it, without the `0/8` counter |
| source / confidence | |

For an `event` objective, put its location in **quest_areas.csv** instead.

### npcs.csv (one row per NPC that is new to Forever or changed)
`npc_id, name, subname, min_level, max_level, faction (A, H, AH or blank), source, confidence`

### npc_spawns.csv (one row per spawn point)
`npc_id, ui_map, x, y, world_map, world_x, world_y, source, confidence`

### objects.csv and object_spawns.csv
Same shape, with `object_id` and no level or subname columns. Needed for quests started by,
ended at, or requiring interaction with a world object (a wanted poster, a campfire kit, a crate).

### items.csv (quest items: where they come from)
`item_id, name, dropped_by_npcs, contained_in_objects, sold_by_npcs, starts_quest_id, source, confidence`
The three middle columns are pipe-separated ID lists. This is what lets Questie pin the mobs
that drop a quest item.

### quest_areas.csv (optional: exploration goals and objective hints)
`quest_id, objective_index, ui_map, x, y, world_map, world_x, world_y, text, source, confidence`
One row per point. Useful for "explore" objectives and for the client's own quest POI data.

### uimap_assignment.csv (only if you sent world coordinates)
The client's `UiMapAssignment` rows for the zones involved:
`ui_map, map_id, area_id, region_min_x, region_min_y, region_max_x, region_max_y, ui_min_x, ui_min_y, ui_max_x, ui_max_y`

## Priorities, if time is limited

1. `quests.csv` with title, levels, faction, giver and ender. That alone produces start and
   turn-in pins for any quest whose NPCs are vanilla NPCs Questie already knows.
2. `npcs.csv` + `npc_spawns.csv` for NPCs that are new in Forever. Without a location a new NPC
   cannot be drawn at all.
3. `quest_objectives.csv`, then `items.csv`: these add objective pins and tooltips.
4. Prerequisites and chains: these stop Questie offering quests the player cannot take yet.

## A sanity check the producer can run

These are known-good rows captured in game on build 1.60.1.69893. Your data should agree:

- quest 96899 "Bandarion Keep", level 12, Horde, given by NPC 267009 "Hadric Harlson" at
  Tirisfal Glades (uiMap 1420) 65.9, 61.0
- quest 97891 "Prompt Potion Runner", level 12, given by NPC 7683 "Alessandro Luca" at Undercity
  (uiMap 1458) 58.5, 54.8, turned in to NPC 11044 "Doctor Martin Felben" at 46.4, 74.1;
  objective "Speak to Doctor Martin Felben", type talk, count 1
