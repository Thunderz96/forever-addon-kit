#!/usr/bin/env python3
"""eui_audit.py -- per-module audit of EllesmereUI (or any addon family) on the
Forever beta client, beyond missing functions.
Author: Thunderz

Reports, per module:
  * secure-snippet sites (broken on build 1.60.1.69893: loadstring_untainted is nil)
  * unguarded references to named Blizzard frames the client does not have
  * events registered that have never been seen firing on this client AND look
    Retail-only (registering an unknown event throws and aborts the file)
  * calls into Retail-only systems (Mythic+, Delves, Warband, Housing, Vault, Hero talents)
"""
import json
import os
import re
import sys
from collections import defaultdict

ADDONS = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Kit layout keeps the baseline at data/forever_api.json; the working tree under ForeverBeacon/data.
_API_PATH = os.path.join(_ROOT, "data", "forever_api.json")
BASE = os.path.join(_ROOT, "data")
if not os.path.exists(_API_PATH):
    BASE = os.path.join(_ROOT, "ForeverBeacon", "data")
    _API_PATH = os.path.join(BASE, "api-baseline", "forever_api.json")
API = json.load(open(_API_PATH, encoding="utf-8"))
FRAMES = set(API["frames"])
FUNCS = set(API["functions"])
NS = set(API["namespaces"])

# every event the firehose has ever seen on this client, across sessions
SEEN = set()
for root, _, files in os.walk(BASE):
    for f in files:
        if f == "events.jsonl":
            for line in open(os.path.join(root, f), encoding="utf-8"):
                try:
                    SEEN.add(json.loads(line)["_key"])
                except Exception:
                    pass

SECURE = re.compile(r"WrapScript\(|SecureHandler\w*\(|RegisterStateDriver\(|RegisterAttributeDriver\(|SetAttribute\(\s*\"_on|SetAttributeNoHandler\(|SecureHandlerExecute\(|RegisterUnitWatch\(")
EVENT = re.compile(r"RegisterEvent\(\s*\"([A-Z0-9_]+)\"")
RETAIL_EVENT = re.compile(r"DELVE|CHALLENGE_MODE|MYTHIC|WEEKLY_REWARD|TRAIT_|HERO_|WARBAND|HOUSING|CATALYST|PERKS_|GARRISON|COVENANT|SOULBIND|AZERITE|ARTIFACT|ISLAND|WARFRONT|TORGHAST|SCENARIO|ENCOUNTER_JOURNAL|KEYSTONE|LFG_LIST|PVP_BRAWL|WORLD_QUEST|TASK_QUEST|CLASS_TALENT|PLAYER_SPECIALIZATION|ACTIVE_TALENT|SPEC_")
RETAIL_API = re.compile(r"\b(C_ChallengeMode|C_MythicPlus|C_DelvesUI|C_WeeklyRewards|C_Housing\w*|C_ClassTalents|C_Traits|C_Catalyst|C_Garrison|C_Covenant\w*|C_Soulbinds|C_AzeriteItem|C_ArtifactUI|C_PerksProgram|C_LFGList|C_Scenario|C_TaskQuest|C_EncounterJournal|C_Heirloom\w*|C_WarbandScene|C_AssistedCombat)\.")
FRAMEREF = re.compile(r"(?<![.:\w\"'])([A-Z][A-Za-z0-9]{4,})\b(?=\s*[.:\[])")


def strip(line):
    line = re.sub(r"--.*$", "", line)
    return re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)


def guarded(name, window):
    n = re.escape(name)
    return re.search(rf"\bif\s+(?:not\s+)?{n}\b(?!\s*\()|\b{n}\s+and\b|\band\s+{n}\b(?!\s*[(.:])|type\(\s*{n}\s*\)|\bnot\s+{n}\b(?!\s*\()", window) is not None


def main(prefix):
    mods = sorted(d for d in os.listdir(ADDONS) if os.path.isdir(os.path.join(ADDONS, d)) and d.startswith(prefix))
    print(f"events seen on this client so far: {len(SEEN)}\n")
    for mod in mods:
        secure, frames, events, retail = 0, defaultdict(int), defaultdict(int), defaultdict(int)
        for dirpath, dirnames, names in os.walk(os.path.join(ADDONS, mod)):
            dirnames[:] = [x for x in dirnames if x.lower() not in ("libs", "lib")]
            for n in names:
                if not n.lower().endswith(".lua"):
                    continue
                lines = open(os.path.join(dirpath, n), encoding="utf-8", errors="replace").read().splitlines()
                own = set(re.findall(r"CreateFrame\(\s*\"\w+\"\s*,\s*\"([A-Za-z0-9_]+)\"", "\n".join(lines)))
                own |= set(re.findall(r"(?:^|\s)local\s+([A-Za-z_][A-Za-z0-9_]*)", "\n".join(lines)))
                clean = [strip(l) for l in lines]
                for i, ln in enumerate(clean):
                    window = " ".join(clean[max(0, i - 2):i + 1])
                    if SECURE.search(ln):
                        secure += 1
                    for m in EVENT.finditer(ln):
                        ev = m.group(1)
                        if ev not in SEEN and RETAIL_EVENT.search(ev):
                            events[ev] += 1
                    for m in RETAIL_API.finditer(ln):
                        if not guarded(m.group(0).rstrip("."), window):
                            retail[m.group(1)] += 1
                    for m in FRAMEREF.finditer(ln):
                        name = m.group(1)
                        if name in FRAMES or name in FUNCS or name in NS or name in own:
                            continue
                        if name.startswith(("EUI", "Ellesmere", "Enum", "Constants", "Settings", "Menu", "C_")) or not re.search(r"(Frame|Button|Panel|Manager|Tracker|Viewer|Bar|Tooltip|Dialog|Popup|Mixin)$", name):
                            continue
                        if guarded(name, window):
                            continue
                        frames[name] += 1
        flag = "  " if not (secure or frames or events or retail) else "!!"
        print(f"{flag} {mod:<32} secure={secure:<3} missingFrames={sum(frames.values()):<3} retailEvents={sum(events.values()):<2} retailAPI={sum(retail.values())}")
        for k, v in sorted(frames.items(), key=lambda kv: -kv[1])[:6]:
            print(f"        frame  {k} x{v}")
        for k, v in sorted(events.items(), key=lambda kv: -kv[1])[:6]:
            print(f"        event  {k} x{v}")
        for k, v in sorted(retail.items(), key=lambda kv: -kv[1])[:6]:
            print(f"        api    {k} x{v}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "EllesmereUI")
