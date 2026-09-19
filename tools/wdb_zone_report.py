#!/usr/bin/env python3
"""wdb_zone_report.py -- which Forever quests belong to which zone?
Author: Thunderz

Reads the newest archived questcache.wdb (the SERVER's own quest records, filled by
playing and by Forever Beacon's /fb sweep), finds where the zone and level fields sit
by checking every candidate offset against Questie's Classic database, then lists the
quests that are new to Forever, grouped by zone, with titles from Forever Beacon.

Nothing is assumed about the record layout beyond its framing (questID, length,
payload). A field offset is only used if it reproduces Questie's value for the
vanilla quests in the cache; the match rate is printed so you can judge it.

USAGE  python wdb_zone_report.py [zone name or area id ...]     default: all zones
       writes questie-overlay/zone_report.csv
"""
import csv
import glob
import json
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
QUESTIE = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\Questie\Database"
WDB_DIR = os.path.join(PROJECT, "ForeverBeacon", "data", "wdb")
BEACON = os.path.join(PROJECT, "ForeverBeacon", "data")
OUT = os.path.join(PROJECT, "questie-overlay", "zone_report.csv")


def read(path):
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        return f.read()


def split_fields(body):
    out, depth, cur, quote, esc = [], 0, "", None, False
    for ch in body:
        if quote:
            cur += ch
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        elif ch == "," and depth == 0:
            out.append(cur)
            cur = ""
            continue
        cur += ch
    out.append(cur)
    return out


def questie_truth():
    """questID -> (required level, quest level, zoneOrSort) from Questie's Classic quest file."""
    truth = {}
    text = read(os.path.join(QUESTIE, "Classic", "classicQuestDB.lua"))
    for m in re.finditer(r"^\[(\d+)\] = \{(.*)\},?\s*$", text, re.M):
        f = split_fields(m.group(2))
        try:
            truth[int(m.group(1))] = (int(f[3]), int(f[4]), int(f[16]))
        except (ValueError, IndexError):
            pass
    return truth


def area_tables():
    names, parent = {}, {}
    for a, n in re.findall(r"\[\d+\]\s*=\s*(\d+),?[ \t]*--[ \t]*(.*)", read(os.path.join(QUESTIE, "Zones", "data", "uiMapIdToAreaId.lua"))):
        names[int(a)] = n.strip()
    for child, par, note in re.findall(r"\[(\d+)\]\s*=\s*(\d+),?[ \t]*--[ \t]*(.*)", read(os.path.join(QUESTIE, "Zones", "data", "subZoneToParentZone.lua"))):
        parent[int(child)] = int(par)
        names.setdefault(int(child), note.split("->")[0].strip())
    return names, parent


def records(path):
    """questID -> payload. Framing: 24-byte file header, then [questID][length][payload]..."""
    raw = open(path, "rb").read()
    out, pos = {}, 24
    while pos + 8 <= len(raw):
        qid, length = struct.unpack_from("<II", raw, pos)
        if qid == 0 or length == 0 or pos + 8 + length > len(raw):
            break
        out[qid] = raw[pos + 8:pos + 8 + length]
        pos += 8 + length
    return out


def best_offset(recs, truth, column, signed=True):
    """The payload byte offset whose int32 equals Questie's value for the most vanilla quests."""
    fmt = "<i" if signed else "<I"
    shared = [q for q in recs if q in truth]
    best = (0, None)
    for off in range(0, 160):
        hits = sum(1 for q in shared if len(recs[q]) >= off + 4 and struct.unpack_from(fmt, recs[q], off)[0] == truth[q][column])
        if hits > best[0]:
            best = (hits, off)
    return best[1], best[0], len(shared)


def beacon_titles():
    titles = {}
    for d in sorted(glob.glob(os.path.join(BEACON, "2026*"))):
        p = os.path.join(d, "quests.jsonl")
        if not os.path.exists(p) or "16001" not in read(os.path.join(d, "probe.jsonl")):
            continue
        for line in read(p).splitlines():
            try:
                r = json.loads(line)
                if r.get("title"):
                    q = int(r.get("id") or r.get("_key"))
                    before = titles.get(q)
                    # Each extract is one session, and a sweep's record has no giver: a giver seen in
                    # ANY session counts, and "played" outranks "sweep".
                    played = (before and before[1] == "played") or not r.get("src")
                    titles[q] = (r["title"], "played" if played else r["src"], len(r.get("objectives") or []),
                                 bool(r.get("giver")) or bool(before and before[3]))
            except (ValueError, TypeError):
                pass
    return titles


def main(argv):
    snapshots = sorted(glob.glob(os.path.join(WDB_DIR, "*questcache.wdb")))
    if not snapshots:
        sys.exit("no archived questcache.wdb in " + WDB_DIR)
    recs = {}
    for s in snapshots:                                   # newest record wins
        recs.update(records(s))
    truth = questie_truth()
    names, parent = area_tables()
    titles = beacon_titles()
    print("cache snapshots: %d | quest records: %d | of which Questie already has: %d"
          % (len(snapshots), len(recs), sum(1 for q in recs if q in truth)))

    offs = {}
    for label, column in (("required level", 0), ("quest level", 1), ("zone or sort", 2)):
        off, hits, total = best_offset(recs, truth, column)
        offs[column] = off
        print("   %-15s payload offset %-4s reproduces Questie for %d of %d vanilla quests" % (label, off, hits, total))
        if total and hits / total < 0.9:
            sys.exit("that field does not decode reliably; stopping rather than guessing.")

    def field(q, column):
        return struct.unpack_from("<i", recs[q], offs[column])[0]

    def zone_of(area):
        seen = set()
        while area in parent and area not in seen:
            seen.add(area)
            area = parent[area]
        return area

    wanted = [a.lower() for a in argv]
    rows = []
    for q in sorted(recs):
        if q in truth:
            continue                                     # vanilla: Questie has it
        area = field(q, 2)
        zone = zone_of(area) if area > 0 else area
        zname = names.get(zone, "quest sort %d" % zone if zone < 0 else "area %d" % zone)
        if wanted and not any(w == str(zone) or w in zname.lower() for w in wanted):
            continue
        t = titles.get(q, ("", "", 0, False))
        rows.append({"quest_id": q, "title": t[0], "quest_level": field(q, 1), "required_level": field(q, 0),
                     "zone_area_id": zone, "zone": zname, "sub_area_id": area if area != zone else "",
                     "sub_area": names.get(area, "") if area != zone else "", "seen": t[1],
                     "has_quest_giver": "yes" if t[3] else ""})
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["quest_id"])
        w.writeheader()
        w.writerows(rows)

    by_zone = {}
    for r in rows:
        by_zone.setdefault(r["zone"], []).append(r)
    print("\nquests new to Forever: %d, in %d zones" % (len(rows), len(by_zone)))
    for zname, rs in sorted(by_zone.items(), key=lambda kv: -len(kv[1])):
        lv = [r["quest_level"] for r in rs if r["quest_level"] > 0]
        print("   %4d  %-28s levels %s" % (len(rs), zname[:28], ("%d-%d" % (min(lv), max(lv))) if lv else "?"))
    print("\nreport: " + OUT)
    return rows


if __name__ == "__main__":
    main(sys.argv[1:])
