#!/usr/bin/env python3
"""questie_overlay.py -- add WoW: Forever quests to Questie from your own data.
Author: Thunderz

WHY: Questie draws pins from a database it ships. Forever's new quests are not
in it yet, so they show nothing. Until Questie's team has the data, this feeds
Questie from three places, later ones winning field by field:

  1. Forever Beacon's harvest (automatic): quests you accepted or handed in, with
     the NPC and where you stood; plus every mob it saw and where.
  2. Normalized CSV folders under questie-overlay/normalized/ (see DATA_SPEC.md):
     quests, objectives, NPCs, spawns, objects, items. Datamined or hand-built.
  3. questie-overlay/manual_quests.csv: single rows you type in.

WHAT IT WRITES (all inside the installed Questie folder, all re-doable):
  * Database/Corrections/Forever/foreverOverlay.lua   generated quest, NPC, object
    and item records, in the shape Questie used to inject Season of Discovery data
  * one line in Questie-Camelot.toc so the client loads that file
  * a small block in QuestieCorrections.lua that feeds the records in
  * a suffix on Questie's version string (QuestieLib.lua) carrying a hash of the
    overlay, so Questie recompiles its database by itself when the data changes

Only things Questie does not already have are emitted: a vanilla NPC handing out
a new quest is referenced by ID and keeps Questie's own spawn data.

Run it again whenever you have new data. After the FIRST run the game needs a
full restart (a new file was added to the TOC); after that /reload is enough.

USAGE
  python questie_overlay.py            build and install the overlay
  python questie_overlay.py --dry-run  show what would be included, change nothing
  python questie_overlay.py --remove   take the overlay and the patches back out

manual_quests.csv columns (created with a header if missing):
  quest_id, title, quest_level, required_level, faction (H, A, or blank = both),
  giver_npc_id, giver_name, giver_map, giver_x, giver_y,
  ender_npc_id, ender_name, ender_map, ender_x, ender_y, objective_text, notes
  Coordinates are the 0-100 numbers the map shows. A map is a uiMapID (1420) or a
  zone name. In game, target the NPC while standing on it and type /fb target.
"""
import csv
import glob
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
QUESTIE = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\Questie"
BEACON_DATA = os.path.join(PROJECT, "ForeverBeacon", "data")
WORK = os.path.join(PROJECT, "questie-overlay")
NORMALIZED = os.path.join(WORK, "normalized")
MANUAL = os.path.join(WORK, "manual_quests.csv")
TAG = "FOREVER-OVERLAY"

OVERLAY_REL = os.path.join("Database", "Corrections", "Forever", "foreverOverlay.lua")
TOC_AFTER = "Database\\Corrections\\Automatic\\sodBaseQuests.lua"
TOC_LINE = "Database\\Corrections\\Forever\\foreverOverlay.lua"

MANUAL_COLUMNS = ["quest_id", "title", "quest_level", "required_level", "faction",
                  "giver_npc_id", "giver_name", "giver_map", "giver_x", "giver_y",
                  "ender_npc_id", "ender_name", "ender_map", "ender_x", "ender_y",
                  "objective_text", "notes"]

CORRECTIONS_ANCHOR = ('    _LoadCorrections("itemData", QuestieItemStartFixes:LoadAutomaticQuestStarts(), '
                      'QuestieDB.itemKeysReversed, validationTables, true, true)\n')
CORRECTIONS_BLOCK = (
    "    if Questie.IsForever then -- " + TAG + ": records from Forever\\tools\\questie_overlay.py\n"
    '        local ForeverOverlay = QuestieLoader:ImportModule("ForeverOverlay")\n'
    "        if ForeverOverlay.LoadBaseQuests then\n"
    '            _LoadCorrections("questData", ForeverOverlay:LoadBaseQuests(), QuestieDB.questKeysReversed, validationTables)\n'
    '            _LoadCorrections("npcData", ForeverOverlay:LoadBaseNPCs(), QuestieDB.npcKeysReversed, validationTables)\n'
    '            _LoadCorrections("objectData", ForeverOverlay:LoadBaseObjects(), QuestieDB.objectKeysReversed, validationTables)\n'
    '            _LoadCorrections("itemData", ForeverOverlay:LoadBaseItems(), QuestieDB.itemKeysReversed, validationTables)\n'
    "        end\n"
    "    end -- " + TAG + "\n\n")
BLOCK_RE = re.compile(r"    if Questie\.IsForever then -- " + TAG + r".*?    end -- " + TAG + r"\n\n", re.S)
VERSION_OLD = '    return "v" .. cachedVersion\n'
VERSION_NEW = ('    return "v" .. cachedVersion .. (QuestieForeverOverlayHash and ("+fo." .. QuestieForeverOverlayHash) or "")'
               " -- " + TAG + ": a changed overlay forces a DB recompile\n")
CLASSES = {"WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"}


# ---- small helpers -----------------------------------------------------------------

def read(path):
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        return f.read()


def num(v, cast=float):
    try:
        return cast(str(v).strip())
    except (TypeError, ValueError):
        return None


def ids(cell):
    """'96895|96897' -> [96895, 96897]"""
    return [n for n in (num(p, int) for p in str(cell or "").split("|")) if n]


def lua_str(s):
    s = str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\r\n", "\n").replace("\r", "\n")
    return '"' + s.replace("\n", "\\n") + '"'


def known_ids(rel):
    """IDs already in one of Questie's base database files ('[123] = {' keys)."""
    return {int(m) for m in re.findall(r"^\[(\d+)\]\s*=\s*\{", read(os.path.join(QUESTIE, rel)), re.M)}


def map_tables():
    """uiMapID -> Questie areaID, and lower-case zone name -> uiMapID."""
    to_area, by_name = {}, {}
    text = read(os.path.join(QUESTIE, "Database", "Zones", "data", "uiMapIdToAreaId.lua"))
    for ui, area, name in re.findall(r"\[(\d+)\]\s*=\s*(\d+),?[ \t]*(?:--[ \t]*(.*))?", text):
        to_area[int(ui)] = int(area)
        if name.strip():
            by_name.setdefault(name.strip().lower(), int(ui))
    forever = os.path.join(QUESTIE, "Database", "Zones", "data", "Forever", "zoneData.lua")
    if os.path.exists(forever):                         # Forever's five new zones
        for ui, area in re.findall(r"\[(\d+)\]\s*=\s*(\d+)", read(forever)):
            to_area.setdefault(int(ui), int(area))
    return to_area, by_name


# ---- the merged data set -------------------------------------------------------------

class Data:
    def __init__(self):
        self.quests = {}        # qid -> {field: value}
        self.objectives = {}    # qid -> {index: {type, target, count, text}}
        self.npcs = {}          # nid -> {name, faction}
        self.npc_points = {}    # nid -> [(ui_map, x, y)]  x/y 0-100
        self.objects = {}       # oid -> {name}
        self.object_points = {}
        self.items = {}         # iid -> {name, npcs:set, objects:set, vendors:set, starts}
        self.assignments = []   # uimap_assignment rows, for world -> zone conversion
        self.notes = {}         # qid -> where it came from

    def quest(self, qid, source, **fields):
        q = self.quests.setdefault(qid, {})
        for k, v in fields.items():
            if v not in (None, "", []):
                q[k] = v
        self.notes.setdefault(qid, [])
        if source not in self.notes[qid]:
            self.notes[qid].append(source)

    def point(self, table, key, ui_map, x, y):
        if not (key and ui_map and x and y):
            return
        pts = table.setdefault(key, [])
        if not any(m == ui_map and abs(px - x) < 0.6 and abs(py - y) < 0.6 for m, px, py in pts):
            pts.append((ui_map, round(x, 2), round(y, 2)))

    def world_to_zone(self, world_map, wx, wy, ui_map=None):
        """Client UiMapAssignment: world X runs north-south, world Y west-east."""
        for a in self.assignments:
            if a["map_id"] != world_map or (ui_map and a["ui_map"] != ui_map):
                continue
            if a["min_x"] <= wx <= a["max_x"] and a["min_y"] <= wy <= a["max_y"]:
                return (a["ui_map"], (a["max_y"] - wy) / (a["max_y"] - a["min_y"]) * 100,
                        (a["max_x"] - wx) / (a["max_x"] - a["min_x"]) * 100)
        return None


def load_beacon(data):
    faction = ""
    for d in sorted(glob.glob(os.path.join(BEACON_DATA, "2026*"))):
        probe = os.path.join(d, "probe.jsonl")
        if not os.path.exists(probe) or "16001" not in read(probe):
            continue                                     # a Retail / MoP test session, not Forever
        chars = os.path.join(d, "chars.jsonl")
        if os.path.exists(chars):
            m = re.search(r'"faction"\s*:\s*"(\w)', read(chars))
            if m:
                faction = m.group(1).upper()

        def rows(name):
            p = os.path.join(d, name)
            for line in (read(p).splitlines() if os.path.exists(p) else []):
                try:
                    yield json.loads(line)
                except ValueError:
                    pass
        for r in rows("quests.jsonl"):
            qid = num(r.get("id") or r.get("_key"), int)
            if not qid:
                continue
            # Before Beacon 0.3.12 "level" could be the PLAYER's level at accept time rather than the
            # quest's own (spotted by the normalizer's audit). Only a record marked levelSource="quest"
            # is trusted; an older one is kept as a guess and reported as such.
            trusted = r.get("levelSource") == "quest"
            fields = {"title": r.get("title"), "quest_level": r.get("level") if trusted else None,
                      "level_guess": None if trusted else r.get("level"), "objective_text": r.get("objectiveText"),
                      "faction": faction, "turnin_level": r.get("turnInLevel")}
            for who in ("giver", "ender"):
                n = r.get(who)
                if isinstance(n, dict) and n.get("kind") == "Creature" and n.get("id"):
                    fields[who + "_type"], fields[who + "_id"] = "npc", n["id"]
                    data.npcs.setdefault(n["id"], {}).setdefault("name", n.get("name") or "")
                    pos = n.get("pos") or {}
                    if pos.get("x"):                     # you stood within interact range: good enough for a pin
                        data.point(data.npc_points, n["id"], pos.get("map"), pos["x"] * 100, pos["y"] * 100)
                        fields.setdefault("zone_map", pos.get("map"))
            data.quest(qid, "beacon", **fields)
        for r in rows("npcs.jsonl"):                     # every mob Beacon saw, and where
            nid = num(r.get("id") or r.get("_key"), int)
            if not nid:
                continue
            data.npcs.setdefault(nid, {}).setdefault("name", r.get("name") or "")
            for s in r.get("sightings") or []:
                if s.get("x"):
                    data.point(data.npc_points, nid, s.get("map"), s["x"] * 100, s["y"] * 100)


def load_normalized(data):
    """Every folder under normalized/ that holds a quests.csv, in name order."""
    for qfile in sorted(glob.glob(os.path.join(NORMALIZED, "**", "quests.csv"), recursive=True)):
        folder = os.path.dirname(qfile)
        tag = "normalized:" + os.path.basename(folder)

        def table(name):
            p = os.path.join(folder, name)
            if not os.path.exists(p):
                return []
            with open(p, newline="", encoding="utf-8-sig") as f:
                return list(csv.DictReader(f))
        for a in table("uimap_assignment.csv"):
            row = {"ui_map": num(a.get("ui_map"), int), "map_id": num(a.get("map_id"), int),
                   "min_x": num(a.get("region_min_x")), "max_x": num(a.get("region_max_x")),
                   "min_y": num(a.get("region_min_y")), "max_y": num(a.get("region_max_y"))}
            if None not in row.values():
                data.assignments.append(row)
        for r in table("quests.csv"):
            qid = num(r.get("quest_id"), int)
            if not qid:
                continue
            data.quest(qid, tag, title=r.get("title"), quest_level=num(r.get("quest_level"), int),
                       required_level=num(r.get("required_level"), int), max_level=num(r.get("max_level"), int),
                       faction=(r.get("faction") or "").upper()[:1], races_mask=num(r.get("required_races_mask"), int),
                       classes=[c for c in (r.get("required_classes") or "").upper().split("|") if c in CLASSES],
                       giver_type=(r.get("giver_type") or "").lower(), giver_id=num(r.get("giver_id"), int),
                       ender_type=(r.get("ender_type") or "").lower(), ender_id=num(r.get("ender_id"), int),
                       objective_text=r.get("objective_text"), zone_area=num(r.get("zone_area_id"), int),
                       pre_all=ids(r.get("prequests_all")), pre_any=ids(r.get("prequests_any")),
                       next_quest=num(r.get("next_quest_id"), int), exclusive=ids(r.get("exclusive_to")),
                       breadcrumb_for=num(r.get("breadcrumb_for"), int),
                       skill=(num(r.get("required_skill_id"), int), num(r.get("required_skill_value"), int) or 1)
                       if num(r.get("required_skill_id"), int) else None,
                       spell=num(r.get("required_spell_id"), int), repeatable=num(r.get("repeatable"), int),
                       source_item=num(r.get("source_item_id"), int))
        for r in table("quest_objectives.csv"):
            qid, index = num(r.get("quest_id"), int), num(r.get("objective_index"), int)
            if qid and index:
                data.objectives.setdefault(qid, {})[index] = {
                    "type": (r.get("type") or "").lower(), "target": num(r.get("target_id"), int),
                    "count": num(r.get("count"), int), "text": r.get("text") or ""}
        for kind, info, points, key in (("npc", data.npcs, data.npc_points, "npc_id"),
                                        ("object", data.objects, data.object_points, "object_id")):
            for r in table(kind + "s.csv"):
                i = num(r.get(key), int)
                if i:
                    rec = info.setdefault(i, {})
                    if r.get("name"):
                        rec["name"] = r["name"]
                    if (r.get("faction") or "").strip():
                        rec["faction"] = r["faction"].strip().upper()
            for r in table(kind + "_spawns.csv"):
                i, ui, x, y = num(r.get(key), int), num(r.get("ui_map"), int), num(r.get("x")), num(r.get("y"))
                if i and not (ui and x and y) and num(r.get("world_x")) is not None:
                    got = data.world_to_zone(num(r.get("world_map"), int), num(r.get("world_x")), num(r.get("world_y")), ui)
                    if got:
                        ui, x, y = got
                data.point(points, i, ui, x, y)
        for r in table("items.csv"):
            iid = num(r.get("item_id"), int)
            if not iid:
                continue
            it = data.items.setdefault(iid, {"name": "", "npcs": set(), "objects": set(), "vendors": set(), "starts": None})
            it["name"] = r.get("name") or it["name"]
            # "observed loot window" = the corpse that was open when the item arrived. Checked against
            # Questie's vanilla item data these were right every time, so they count as drop sources.
            it["npcs"].update(ids(r.get("dropped_by_npcs")) + ids(r.get("observed_loot_window_npcs")))
            it["objects"].update(ids(r.get("contained_in_objects")) + ids(r.get("observed_loot_window_objects")))
            it["vendors"].update(ids(r.get("sold_by_npcs")))
            it["starts"] = num(r.get("starts_quest_id"), int) or it["starts"]


def load_manual(data, by_name):
    os.makedirs(WORK, exist_ok=True)
    if not os.path.exists(MANUAL):
        with open(MANUAL, "w", newline="", encoding="utf-8") as f:
            csv.writer(f).writerow(MANUAL_COLUMNS)
        return
    with open(MANUAL, newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            qid = num(r.get("quest_id"), int)
            if not qid:
                continue
            fields = {"title": r.get("title"), "quest_level": num(r.get("quest_level"), int),
                      "required_level": num(r.get("required_level"), int),
                      "faction": (r.get("faction") or "").upper()[:1], "objective_text": r.get("objective_text")}
            for who in ("giver", "ender"):
                nid = num(r.get(who + "_npc_id"), int)
                if not nid:
                    continue
                fields[who + "_type"], fields[who + "_id"] = "npc", nid
                if r.get(who + "_name"):
                    data.npcs.setdefault(nid, {})["name"] = r[who + "_name"]
                raw = (r.get(who + "_map") or "").strip()
                ui = num(raw, int) or by_name.get(raw.lower())
                data.point(data.npc_points, nid, ui, num(r.get(who + "_x")), num(r.get(who + "_y")))
                if ui:
                    fields.setdefault("zone_map", ui)
            data.quest(qid, "manual", **fields)


# ---- deciding what to emit -------------------------------------------------------------

def build():
    known = {"quest": known_ids(os.path.join("Database", "Classic", "classicQuestDB.lua")),
             "npc": known_ids(os.path.join("Database", "Classic", "classicNpcDB.lua")),
             "object": known_ids(os.path.join("Database", "Classic", "classicObjectDB.lua")),
             "item": known_ids(os.path.join("Database", "Classic", "classicItemDB.lua"))}
    to_area, by_name = map_tables()
    data = Data()
    load_beacon(data)
    load_normalized(data)
    load_manual(data, by_name)

    def spawns(points):
        out = {}
        for ui, x, y in points:
            if ui in to_area:
                out.setdefault(to_area[ui], []).append((x, y))
        return out

    out = {"quests": {}, "npcs": {}, "objects": {}, "items": {}}

    def usable(kind, i):
        """Can Questie draw this thing? Either it knows it already, or we have a place for it."""
        if not i:
            return False
        if i in known[kind] or i in out[kind + "s"]:
            return True
        info, points = (data.npcs, data.npc_points) if kind == "npc" else (data.objects, data.object_points)
        where = spawns(points.get(i, []))
        if not where:
            return False
        out[kind + "s"][i] = {"name": info.get(i, {}).get("name") or (kind.upper() + " " + str(i)), "spawns": where,
                              "area": max(where, key=lambda a: len(where[a])), "faction": info.get(i, {}).get("faction", ""),
                              "starts": set(), "ends": set()}
        return True

    report = []
    for qid in sorted(data.quests):
        q = data.quests[qid]
        if qid in known["quest"]:
            report.append((qid, q.get("title", ""), "skipped", "Questie already has this quest", ""))
            continue
        if not q.get("title"):
            report.append((qid, "", "skipped", "no title", ""))
            continue
        ends = {}
        for who in ("giver", "ender"):
            kind, i = q.get(who + "_type") or "npc", q.get(who + "_id")
            if kind in ("npc", "object") and usable(kind, i):
                ends[who] = (kind, i)
                if i in out[kind + "s"]:
                    out[kind + "s"][i]["starts" if who == "giver" else "ends"].add(qid)
            elif kind == "item" and i:
                ends[who] = (kind, i)
        if not ends:
            report.append((qid, q["title"], "skipped", "no quest giver or turn-in with a known location yet", ""))
            continue

        creatures, objects, items = [], [], []
        for index in sorted(data.objectives.get(qid, {})):
            o = data.objectives[qid][index]
            t = o["target"]
            if o["type"] in ("kill", "talk") and usable("npc", t):
                creatures.append((t, o["text"]))
            elif o["type"] == "object" and usable("object", t):
                objects.append((t, o["text"]))
            elif o["type"] == "item" and t:
                it = data.items.get(t, {"name": o["text"], "npcs": set(), "objects": set(), "vendors": set(), "starts": None})
                if t not in known["item"]:
                    out["items"][t] = {"name": it["name"] or o["text"] or ("ITEM " + str(t)),
                                       "npcs": sorted(n for n in it["npcs"] if usable("npc", n)),
                                       "objects": sorted(n for n in it["objects"] if usable("object", n)),
                                       "vendors": sorted(n for n in it["vendors"] if usable("npc", n)),
                                       "starts": it["starts"]}
                items.append((t, o["text"]))
        level = q.get("quest_level") or q.get("level_guess") or 1
        guessed = not q.get("quest_level")
        q_out = dict(q)
        q_out.update(level=level, ends=ends, creatures=creatures, objects=objects, items=items,
                     required=q.get("required_level") or max(1, min(level, q.get("turnin_level") or level) - 2),
                     zone=q.get("zone_area") or to_area.get(q.get("zone_map")))
        out["quests"][qid] = q_out
        pins = sum(1 for i, _ in items if i in known["item"] or (out["items"].get(i) and (out["items"][i]["npcs"] or out["items"][i]["objects"])))
        pins += len(creatures) + len(objects)
        total = len(data.objectives.get(qid, {}))
        report.append((qid, q["title"], "included",
                       " + ".join(w for w in ("giver", "ender") if w in ends) + (" (level is a guess)" if guessed else ""),
                       ("%d of %d objectives pinned" % (pins, total)) if total else "", ", ".join(data.notes[qid])))
    return out, report


# ---- rendering ---------------------------------------------------------------------------

def render(out):
    race = {"H": "raceIDs.ALL_HORDE", "A": "raceIDs.ALL_ALLIANCE"}

    def ref(kind_id, slot):                 # startedBy/finishedBy: {npcs},{objects},{items}
        if not kind_id:
            return None
        kind, i = kind_id
        return "{" + ",".join("{%d}" % i if k == kind else "nil" for k in ("npc", "object", "item")[:slot]).rstrip(",nil") + "}"

    def started(kind_id, slots):
        if not kind_id:
            return None
        kind, i = kind_id
        order = ("npc", "object", "item")[:slots]
        parts = ["{%d}" % i if k == kind else "nil" for k in order]
        while parts and parts[-1] == "nil":
            parts.pop()
        return "{" + ",".join(parts) + "}"

    def group(pairs):
        return "{" + ",".join("{%d,%s}" % (i, lua_str(t)) if t else "{%d}" % i for i, t in pairs) + "}" if pairs else "nil"

    L = ["-- GENERATED by Forever\\tools\\questie_overlay.py -- do not edit; change the source data and re-run.",
         "-- Quests, NPCs, objects and items for WoW: Forever that Questie's database does not have yet.",
         "---@class ForeverOverlay", 'local ForeverOverlay = QuestieLoader:CreateModule("ForeverOverlay")',
         'local QuestieDB = QuestieLoader:ImportModule("QuestieDB")', "",
         "function ForeverOverlay:LoadBaseQuests()", "    local questKeys = QuestieDB.questKeys",
         "    local raceIDs = QuestieDB.raceKeys", "    local classIDs = QuestieDB.classKeys", "", "    return {"]
    for qid, q in sorted(out["quests"].items()):
        f = ["[questKeys.name] = " + lua_str(q["title"])]
        if q["ends"].get("giver"):
            f.append("[questKeys.startedBy] = " + started(q["ends"]["giver"], 3))
        if q["ends"].get("ender"):
            f.append("[questKeys.finishedBy] = " + started(q["ends"]["ender"], 2))
        f.append("[questKeys.requiredLevel] = %d" % q["required"])
        f.append("[questKeys.questLevel] = %d" % q["level"])
        f.append("[questKeys.requiredRaces] = " + (str(q["races_mask"]) if q.get("races_mask") else race.get(q.get("faction"), "raceIDs.NONE")))
        if q.get("classes"):
            f.append("[questKeys.requiredClasses] = " + " + ".join("classIDs." + c for c in q["classes"]))
        if q.get("objective_text"):
            f.append("[questKeys.objectivesText] = {%s}" % lua_str(q["objective_text"]))
        if q["creatures"] or q["objects"] or q["items"]:
            parts = [group(q["creatures"]), group(q["objects"]), group(q["items"])]
            while parts[-1] == "nil":
                parts.pop()
            f.append("[questKeys.objectives] = {" + ",".join(parts) + "}")
        for key, field in (("pre_all", "preQuestGroup"), ("pre_any", "preQuestSingle"), ("exclusive", "exclusiveTo")):
            if q.get(key):
                f.append("[questKeys.%s] = {%s}" % (field, ",".join(map(str, q[key]))))
        for key, field in (("source_item", "sourceItemId"), ("zone", "zoneOrSort"), ("next_quest", "nextQuestInChain"),
                           ("breadcrumb_for", "breadcrumbForQuestId"), ("spell", "requiredSpell"), ("max_level", "requiredMaxLevel")):
            if q.get(key):
                f.append("[questKeys.%s] = %d" % (field, q[key]))
        if q.get("skill"):
            f.append("[questKeys.requiredSkill] = {%d,%d}" % q["skill"])
        if q.get("repeatable"):
            f.append("[questKeys.specialFlags] = 1")
        L.append("        [%d] = {\n            %s,\n        }," % (qid, ",\n            ".join(f)))
    L += ["    }", "end", ""]

    def spawn_text(where):
        return ",".join("[%d]={%s}" % (a, ",".join("{%s,%s}" % p for p in pts)) for a, pts in sorted(where.items()))
    for fn, keys, table in (("LoadBaseNPCs", "npcKeys", out["npcs"]), ("LoadBaseObjects", "objectKeys", out["objects"])):
        L += ["function ForeverOverlay:%s()" % fn, "    local %s = QuestieDB.%s" % (keys, keys), "", "    return {"]
        for i, n in sorted(table.items()):
            f = ["[%s.name] = %s" % (keys, lua_str(n["name"]))]
            if keys == "npcKeys":
                f += ["[npcKeys.minLevel] = 0", "[npcKeys.maxLevel] = 0"]
            f += ["[%s.spawns] = {%s}" % (keys, spawn_text(n["spawns"])), "[%s.zoneID] = %d" % (keys, n["area"])]
            if n["starts"]:
                f.append("[%s.questStarts] = {%s}" % (keys, ",".join(map(str, sorted(n["starts"])))))
            if n["ends"]:
                f.append("[%s.questEnds] = {%s}" % (keys, ",".join(map(str, sorted(n["ends"])))))
            if keys == "npcKeys":
                f.append("[npcKeys.friendlyToFaction] = " + lua_str(n["faction"] if n["faction"] in ("A", "H", "AH") else "AH"))
            L.append("        [%d] = {\n            %s,\n        }," % (i, ",\n            ".join(f)))
        L += ["    }", "end", ""]
    L += ["function ForeverOverlay:LoadBaseItems()", "    local itemKeys = QuestieDB.itemKeys", "", "    return {"]
    for i, it in sorted(out["items"].items()):
        f = ["[itemKeys.name] = " + lua_str(it["name"])]
        for key, field in (("npcs", "npcDrops"), ("objects", "objectDrops"), ("vendors", "vendors")):
            if it[key]:
                f.append("[itemKeys.%s] = {%s}" % (field, ",".join(map(str, it[key]))))
        if it["starts"]:
            f.append("[itemKeys.startQuest] = %d" % it["starts"])
        L.append("        [%d] = {\n            %s,\n        }," % (i, ",\n            ".join(f)))
    L += ["    }", "end", ""]
    body = "\n".join(L)
    digest = hashlib.sha1(body.encode("utf-8")).hexdigest()[:8]
    return body + 'QuestieForeverOverlayHash = "%s"\n' % digest, digest


# ---- installing ----------------------------------------------------------------------------

def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def install(body, remove=False):
    corrections = os.path.join(QUESTIE, "Database", "Corrections", "QuestieCorrections.lua")
    lib = os.path.join(QUESTIE, "Modules", "Libs", "QuestieLib.lua")
    toc = os.path.join(QUESTIE, "Questie-Camelot.toc")
    overlay = os.path.join(QUESTIE, OVERLAY_REL)

    text = BLOCK_RE.sub("", read(corrections))          # drop any earlier version of the block
    if not remove:
        if CORRECTIONS_ANCHOR not in text:
            sys.exit("cannot patch QuestieCorrections.lua: the expected line is gone (Questie changed?). Nothing was altered.")
        text = text.replace(CORRECTIONS_ANCHOR, CORRECTIONS_BLOCK + CORRECTIONS_ANCHOR, 1)
    write(corrections, text)

    text = read(lib)
    if remove:
        text = text.replace(VERSION_NEW, VERSION_OLD)
    elif VERSION_NEW not in text:
        if VERSION_OLD not in text:
            sys.exit("cannot patch QuestieLib.lua: the expected line is gone (Questie changed?).")
        text = text.replace(VERSION_OLD, VERSION_NEW, 1)
    write(lib, text)

    text = read(toc)
    nl = "\r\n" if "\r\n" in text else "\n"
    if remove:
        write(toc, text.replace(TOC_LINE + nl, ""))
        if os.path.exists(overlay):
            os.remove(overlay)
        return
    if TOC_LINE not in text:
        if TOC_AFTER not in text:
            sys.exit("cannot find %s in the TOC." % TOC_AFTER)
        write(toc, text.replace(TOC_AFTER + nl, TOC_AFTER + nl + TOC_LINE + nl, 1))
    os.makedirs(os.path.dirname(overlay), exist_ok=True)
    with open(overlay, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)


def main(argv):
    if not os.path.isdir(QUESTIE):
        sys.exit("Questie is not installed at " + QUESTIE)
    if "--remove" in argv:
        install("", remove=True)
        print("overlay and patches removed. Restart the game.")
        return
    out, report = build()
    body, digest = render(out)
    os.makedirs(WORK, exist_ok=True)
    with open(os.path.join(WORK, "overlay_report.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["quest_id", "title", "status", "detail", "objectives", "sources"])
        for r in report:
            w.writerow(list(r) + [""] * (6 - len(r)))
    included = [r for r in report if r[2] == "included"]
    print("quests %d | new NPCs %d | new objects %d | new items %d | skipped %d | overlay hash %s"
          % (len(included), len(out["npcs"]), len(out["objects"]), len(out["items"]), len(report) - len(included), digest))
    for r in included:
        print("   %-7d %-40s %-14s %s" % (r[0], r[1][:40], r[3], r[4]))
    reasons = {}
    for r in report:
        if r[2] != "included":
            reasons[r[3]] = reasons.get(r[3], 0) + 1
    for why, n in sorted(reasons.items(), key=lambda kv: -kv[1]):
        print("   skipped %3d: %s" % (n, why))
    print("report: " + os.path.join(WORK, "overlay_report.csv"))
    if "--dry-run" in argv:
        print("dry run: nothing was changed.")
        return
    install(body)
    print("installed into Questie. First time: fully restart the game. Afterwards: /reload. "
          "Questie will say its DB is updating once.")


if __name__ == "__main__":
    main(sys.argv[1:])
