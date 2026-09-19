#!/usr/bin/env python3
"""questie_overlay.py -- add WoW: Forever quests to Questie from your own data.
Author: Thunderz

WHY: Questie draws pins from a database it ships. Forever's new quests are not
in it yet, so they show nothing. Until Questie's team has the data, this feeds
Questie quests from two places:

  1. Forever Beacon's harvest (automatic): every quest you accept or hand in is
     recorded with the quest giver / turn-in NPC and where you stood.
  2. manual_quests.csv (by hand): rows you type in. A hand row beats a
     harvested one with the same quest_id.

WHAT IT WRITES (all inside the installed Questie folder, all re-doable):
  * Database/Corrections/Forever/foreverOverlay.lua   generated quest + NPC records,
    in the same shape Questie used to inject Season of Discovery quests
  * one line in Questie-Camelot.toc so the client loads that file
  * a small block in QuestieCorrections.lua that feeds the records in
  * a suffix on Questie's version string (QuestieLib.lua) carrying a hash of the
    overlay, so Questie recompiles its database by itself when the data changes

Run it again whenever you have new data. After the FIRST run the game needs a
full restart (a new file was added to the TOC); after that /reload is enough.

USAGE
  python questie_overlay.py            build and install the overlay
  python questie_overlay.py --dry-run  show what would be included, change nothing
  python questie_overlay.py --remove   take the overlay and the patches back out

THE CSV (questie-overlay/manual_quests.csv; created with a header if missing)
  quest_id, title, quest_level, required_level, faction (H, A, or blank = both),
  giver_npc_id, giver_name, giver_map, giver_x, giver_y,
  ender_npc_id, ender_name, ender_map, ender_x, ender_y, objective_text, notes
  * Coordinates are the 0-100 numbers the in-game map shows (e.g. 65.9, 61.0).
  * giver_map / ender_map: a uiMapID number (1420) or a zone name (Tirisfal Glades).
  * In game, stand on the NPC, target it, and type /fb target: it prints
    npc_id, name, map, x, y ready to paste.
  * Leave the NPC name/map/x/y blank for an NPC Questie already knows (a vanilla
    NPC handing out a new quest); only the npc_id is needed then.
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
MANUAL = os.path.join(WORK, "manual_quests.csv")
TAG = "FOREVER-OVERLAY"

OVERLAY_REL = os.path.join("Database", "Corrections", "Forever", "foreverOverlay.lua")
TOC_AFTER = "Database\\Corrections\\Automatic\\sodBaseQuests.lua"
TOC_LINE = "Database\\Corrections\\Forever\\foreverOverlay.lua"

COLUMNS = ["quest_id", "title", "quest_level", "required_level", "faction",
           "giver_npc_id", "giver_name", "giver_map", "giver_x", "giver_y",
           "ender_npc_id", "ender_name", "ender_map", "ender_x", "ender_y",
           "objective_text", "notes"]

CORRECTIONS_ANCHOR = ('    _LoadCorrections("itemData", QuestieItemStartFixes:LoadAutomaticQuestStarts(), '
                      'QuestieDB.itemKeysReversed, validationTables, true, true)\n')
CORRECTIONS_BLOCK = (
    "    if Questie.IsForever then -- " + TAG + ": quests and NPCs from tools/questie_overlay.py\n"
    '        local ForeverOverlay = QuestieLoader:ImportModule("ForeverOverlay")\n'
    "        if ForeverOverlay.LoadBaseQuests then\n"
    '            _LoadCorrections("questData", ForeverOverlay:LoadBaseQuests(), QuestieDB.questKeysReversed, validationTables)\n'
    '            _LoadCorrections("npcData", ForeverOverlay:LoadBaseNPCs(), QuestieDB.npcKeysReversed, validationTables)\n'
    "        end\n"
    "    end -- " + TAG + "\n\n")
VERSION_OLD = '    return "v" .. cachedVersion\n'
VERSION_NEW = ('    return "v" .. cachedVersion .. (QuestieForeverOverlayHash and ("+fo." .. QuestieForeverOverlayHash) or "")'
               " -- " + TAG + ": a changed overlay forces a DB recompile\n")


# ---- reading Questie's own data --------------------------------------------------

def read(path):
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        return f.read()


def known_ids(rel):
    """IDs already in one of Questie's base database files ('[123] = {' keys)."""
    return {int(m) for m in re.findall(r"\[(\d+)\]\s*=\s*\{", read(os.path.join(QUESTIE, rel)))}


def map_tables():
    """uiMapID -> Questie areaID, and lower-case zone name -> uiMapID."""
    to_area, by_name = {}, {}
    text = read(os.path.join(QUESTIE, "Database", "Zones", "data", "uiMapIdToAreaId.lua"))
    for ui, area, name in re.findall(r"\[(\d+)\]\s*=\s*(\d+),?\s*(?:--\s*(.*))?", text):
        to_area[int(ui)] = int(area)
        if name.strip():
            by_name.setdefault(name.strip().lower(), int(ui))
    forever = os.path.join(QUESTIE, "Database", "Zones", "data", "Forever", "zoneData.lua")
    if os.path.exists(forever):                         # Forever's five new zones
        for ui, area in re.findall(r"\[(\d+)\]\s*=\s*(\d+)", read(forever)):
            to_area.setdefault(int(ui), int(area))
    return to_area, by_name


# ---- sources -----------------------------------------------------------------------

def num(v, cast=float):
    try:
        return cast(str(v).strip())
    except (TypeError, ValueError):
        return None


def beacon_rows():
    """One row per quest from every Beacon extract taken on the Forever client."""
    rows, faction = {}, ""
    for d in sorted(glob.glob(os.path.join(BEACON_DATA, "2026*"))):
        probe = os.path.join(d, "probe.jsonl")
        if not os.path.exists(probe) or "16001" not in read(probe):
            continue                                     # a Retail / MoP test session, not Forever
        chars = os.path.join(d, "chars.jsonl")
        if os.path.exists(chars):
            m = re.search(r'"faction"\s*:\s*"(\w)', read(chars))
            if m:
                faction = m.group(1).upper()
        qfile = os.path.join(d, "quests.jsonl")
        if not os.path.exists(qfile):
            continue
        for line in read(qfile).splitlines():
            try:
                r = json.loads(line)
                qid = int(r.get("id") or r.get("_key"))
            except (ValueError, TypeError):
                continue
            row = rows.setdefault(qid, {c: "" for c in COLUMNS})
            row["quest_id"] = qid
            row["faction"] = row["faction"] or faction
            if r.get("title"):
                row["title"] = r["title"]
            if r.get("level"):
                row["quest_level"] = r["level"]
            if r.get("turnInLevel") and not row["required_level"]:
                row["_turnin"] = r["turnInLevel"]
            if r.get("objectiveText"):
                row["objective_text"] = r["objectiveText"]
            for who in ("giver", "ender"):
                n = r.get(who)
                if isinstance(n, dict) and n.get("kind") == "Creature" and n.get("id"):
                    pos = n.get("pos") or {}
                    row[who + "_npc_id"] = n["id"]
                    row[who + "_name"] = n.get("name", "")
                    if pos.get("x"):
                        row[who + "_map"] = pos.get("map", "")
                        row[who + "_x"] = round(pos["x"] * 100, 2)
                        row[who + "_y"] = round(pos["y"] * 100, 2)
            row["notes"] = "beacon"
    return rows


def manual_rows():
    os.makedirs(WORK, exist_ok=True)
    if not os.path.exists(MANUAL):
        with open(MANUAL, "w", newline="", encoding="utf-8") as f:
            csv.writer(f).writerow(COLUMNS)
        return {}
    rows = {}
    with open(MANUAL, newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            qid = num(r.get("quest_id"), int)
            if qid:
                rows[qid] = {c: (r.get(c) or "").strip() for c in COLUMNS}
                rows[qid]["quest_id"] = qid
                rows[qid]["notes"] = rows[qid]["notes"] or "manual"
    return rows


# ---- building ----------------------------------------------------------------------

def lua_str(s):
    s = str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\r\n", "\n").replace("\r", "\n")
    return '"' + s.replace("\n", "\\n") + '"'


def build():
    quests_known = known_ids(os.path.join("Database", "Classic", "classicQuestDB.lua"))
    npcs_known = known_ids(os.path.join("Database", "Classic", "classicNpcDB.lua"))
    to_area, by_name = map_tables()

    merged = beacon_rows()
    for qid, row in manual_rows().items():               # hand rows win, field by field
        base = merged.setdefault(qid, {c: "" for c in COLUMNS})
        for c in COLUMNS:
            if row[c] != "":
                base[c] = row[c]

    def area_of(value):
        ui = num(value, int)
        if ui is None and str(value).strip():
            ui = by_name.get(str(value).strip().lower())
        return to_area.get(ui) if ui else None

    quests, npcs, report = {}, {}, []
    for qid in sorted(merged):
        row = merged[qid]
        if qid in quests_known:
            report.append((qid, row["title"], "skipped", "Questie already has this quest"))
            continue
        if not row["title"]:
            report.append((qid, "", "skipped", "no title"))
            continue
        ends = {}
        for who in ("giver", "ender"):
            nid = num(row[who + "_npc_id"], int)
            if not nid:
                continue
            if nid in npcs_known:
                ends[who] = nid                          # a vanilla NPC: Questie has its spawns
                continue
            area, x, y = area_of(row[who + "_map"]), num(row[who + "_x"]), num(row[who + "_y"])
            if not (area and x and y):
                continue                                 # a new NPC is useless without a place
            ends[who] = nid
            n = npcs.setdefault(nid, {"name": row[who + "_name"] or ("NPC " + str(nid)), "area": area,
                                      "spawns": {}, "starts": [], "ends": [], "faction": ""})
            pts = n["spawns"].setdefault(area, [])
            if not any(abs(px - x) < 0.5 and abs(py - y) < 0.5 for px, py in pts):
                pts.append((round(x, 2), round(y, 2)))
            n["starts" if who == "giver" else "ends"].append(qid)
            n["faction"] = n["faction"] or row["faction"].upper()[:1]
        if not ends:
            report.append((qid, row["title"], "skipped", "no quest giver or turn-in NPC with a location yet"))
            continue
        level = num(row["quest_level"], int) or 1
        required = num(row["required_level"], int) or max(1, min(level, num(row.get("_turnin"), int) or level) - 2)
        quests[qid] = {"title": row["title"], "level": level, "required": required,
                       "faction": row["faction"].upper()[:1], "giver": ends.get("giver"), "ender": ends.get("ender"),
                       "text": row["objective_text"],
                       "zone": area_of(row["giver_map"]) or area_of(row["ender_map"])}
        have = " + ".join(w for w in ("giver", "ender") if w in ends)
        report.append((qid, row["title"], "included", have + " (" + row["notes"] + ")"))
    return quests, npcs, report


def render(quests, npcs):
    race = {"H": "raceIDs.ALL_HORDE", "A": "raceIDs.ALL_ALLIANCE"}
    out = ["-- GENERATED by Forever\\tools\\questie_overlay.py -- do not edit; edit manual_quests.csv and re-run.",
           "-- Quests and NPCs for WoW: Forever that Questie's database does not have yet.",
           '---@class ForeverOverlay', 'local ForeverOverlay = QuestieLoader:CreateModule("ForeverOverlay")',
           'local QuestieDB = QuestieLoader:ImportModule("QuestieDB")', "",
           "function ForeverOverlay:LoadBaseQuests()",
           "    local questKeys = QuestieDB.questKeys", "    local raceIDs = QuestieDB.raceKeys", "", "    return {"]
    for qid, q in sorted(quests.items()):
        out.append("        [%d] = {" % qid)
        out.append("            [questKeys.name] = %s," % lua_str(q["title"]))
        if q["giver"]:
            out.append("            [questKeys.startedBy] = {{%d}}," % q["giver"])
        if q["ender"]:
            out.append("            [questKeys.finishedBy] = {{%d}}," % q["ender"])
        out.append("            [questKeys.requiredLevel] = %d," % q["required"])
        out.append("            [questKeys.questLevel] = %d," % q["level"])
        out.append("            [questKeys.requiredRaces] = %s," % race.get(q["faction"], "raceIDs.NONE"))
        if q["text"]:
            out.append("            [questKeys.objectivesText] = {%s}," % lua_str(q["text"]))
        if q["zone"]:
            out.append("            [questKeys.zoneOrSort] = %d," % q["zone"])
        out.append("        },")
    out += ["    }", "end", "", "function ForeverOverlay:LoadBaseNPCs()", "    local npcKeys = QuestieDB.npcKeys", "",
            "    return {"]
    for nid, n in sorted(npcs.items()):
        spawns = ",".join("[%d]={%s}" % (a, ",".join("{%s,%s}" % p for p in pts)) for a, pts in sorted(n["spawns"].items()))
        out.append("        [%d] = {" % nid)
        out.append("            [npcKeys.name] = %s," % lua_str(n["name"]))
        out.append("            [npcKeys.minLevel] = 0,")
        out.append("            [npcKeys.maxLevel] = 0,")
        out.append("            [npcKeys.spawns] = {%s}," % spawns)
        out.append("            [npcKeys.zoneID] = %d," % n["area"])
        if n["starts"]:
            out.append("            [npcKeys.questStarts] = {%s}," % ",".join(map(str, sorted(set(n["starts"])))))
        if n["ends"]:
            out.append("            [npcKeys.questEnds] = {%s}," % ",".join(map(str, sorted(set(n["ends"])))))
        out.append("            [npcKeys.friendlyToFaction] = %s," % lua_str(n["faction"] or "AH"))
        out.append("        },")
    out += ["    }", "end", ""]
    body = "\n".join(out)
    digest = hashlib.sha1(body.encode("utf-8")).hexdigest()[:8]
    return body + 'QuestieForeverOverlayHash = "%s"\n' % digest, digest


# ---- installing --------------------------------------------------------------------

def patch(path, old, new, remove=False):
    text = read(path)
    if remove:
        if new in text:
            open(path, "w", encoding="utf-8", newline="").write(text.replace(new, old))
        return
    if new in text:
        return
    if old not in text:
        sys.exit("cannot patch %s: the expected text is gone (Questie changed?). Nothing else was altered." % path)
    open(path, "w", encoding="utf-8", newline="").write(text.replace(old, new, 1))


def install(body, remove=False):
    corrections = os.path.join(QUESTIE, "Database", "Corrections", "QuestieCorrections.lua")
    lib = os.path.join(QUESTIE, "Modules", "Libs", "QuestieLib.lua")
    toc = os.path.join(QUESTIE, "Questie-Camelot.toc")
    overlay = os.path.join(QUESTIE, OVERLAY_REL)
    patch(corrections, CORRECTIONS_ANCHOR, CORRECTIONS_BLOCK + CORRECTIONS_ANCHOR, remove)
    patch(lib, VERSION_OLD, VERSION_NEW, remove)
    text = read(toc)
    nl = "\r\n" if "\r\n" in text else "\n"
    if remove:
        open(toc, "w", encoding="utf-8", newline="").write(text.replace(TOC_LINE + nl, ""))
        if os.path.exists(overlay):
            os.remove(overlay)
        return
    if TOC_LINE not in text:
        if TOC_AFTER not in text:
            sys.exit("cannot find %s in the TOC; nothing was altered." % TOC_AFTER)
        text = text.replace(TOC_AFTER + nl, TOC_AFTER + nl + TOC_LINE + nl, 1)
        open(toc, "w", encoding="utf-8", newline="").write(text)
    os.makedirs(os.path.dirname(overlay), exist_ok=True)
    open(overlay, "w", encoding="utf-8", newline="\n").write(body)


def main(argv):
    if not os.path.isdir(QUESTIE):
        sys.exit("Questie is not installed at " + QUESTIE)
    if "--remove" in argv:
        install("", remove=True)
        print("overlay and patches removed. Restart the game.")
        return
    quests, npcs, report = build()
    body, digest = render(quests, npcs)
    os.makedirs(WORK, exist_ok=True)
    with open(os.path.join(WORK, "overlay_report.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["quest_id", "title", "status", "detail"])
        w.writerows(report)
    included = [r for r in report if r[2] == "included"]
    print("quests included: %d   new NPCs: %d   skipped: %d   overlay hash: %s"
          % (len(included), len(npcs), len(report) - len(included), digest))
    for qid, title, _, detail in included:
        print("   %-7d %-42s %s" % (qid, title[:42], detail))
    reasons = {}
    for r in report:
        if r[2] != "included":
            reasons[r[3]] = reasons.get(r[3], 0) + 1
    for why, n in sorted(reasons.items(), key=lambda kv: -kv[1]):
        print("   skipped %3d: %s" % (n, why))
    print("report: " + os.path.join(WORK, "overlay_report.csv"))
    print("hand-entered quests go in: " + MANUAL)
    if "--dry-run" in argv:
        print("dry run: nothing was changed.")
        return
    install(body)
    print("installed into Questie. First time: fully restart the game. Afterwards: /reload. "
          "Questie will say its DB is updating once.")


if __name__ == "__main__":
    main(sys.argv[1:])
