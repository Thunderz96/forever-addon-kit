#!/usr/bin/env python3
"""fb_extract.py -- ForeverBeacon SavedVariables -> JSON + CSV/JSONL per domain.
Author: Thunderz

Usage:
    python fb_extract.py [path\\to\\ForeverBeacon.lua] [--out DIR]

With no path it finds the newest ForeverBeacon.lua under every WoW flavor
folder (_classic_era_, _classic_beta_, whatever the Forever beta installs as).

Only the ["payload"] JSON string is read, so nothing here parses Lua tables.
Output lands in DIR (default: ..\\data\\<timestamp>\\):
    payload.json          the whole document, pretty-printed
    <domain>.csv          flattened catalogs and logs, one row per entity/event
    <domain>.jsonl        same rows with nested fields kept intact
"""
import csv
import glob
import json
import os
import sys
import time

WOW_ROOT = r"C:\Program Files (x86)\World of Warcraft"
PAYLOAD_KEY = b'["payload"] = "'
LUA_UNESCAPE = {b"n": b"\n", b"r": b"\r", b"t": b"\t", b'"': b'"', b"\\": b"\\", b"a": b"\a", b"b": b"\b", b"f": b"\f", b"v": b"\v"}


def find_newest():
    pattern = os.path.join(WOW_ROOT, "_*_", "WTF", "Account", "*", "SavedVariables", "ForeverBeacon.lua")
    found = glob.glob(pattern)
    if not found:
        sys.exit("no ForeverBeacon.lua found under %s. Run /fb flush then /reload in game." % WOW_ROOT)
    found.sort(key=os.path.getmtime, reverse=True)
    return found[0]


def extract_payload(raw: bytes) -> str:
    start = raw.find(PAYLOAD_KEY)
    if start == -1:
        raise ValueError('no ["payload"] key -- run /fb flush then /reload in game')
    i = start + len(PAYLOAD_KEY)
    out = bytearray()
    n = len(raw)
    while i < n:
        c = raw[i:i + 1]
        if c == b"\\":
            nxt = raw[i + 1:i + 2]
            if nxt.isdigit():
                j = i + 1
                digits = b""
                while j < n and raw[j:j + 1].isdigit() and len(digits) < 3:
                    digits += raw[j:j + 1]
                    j += 1
                out.append(int(digits))
                i = j
                continue
            out += LUA_UNESCAPE.get(nxt, nxt)
            i += 2
            continue
        if c == b'"':
            return out.decode("utf-8", errors="replace")
        out += c
        i += 1
    raise ValueError("payload string never terminated -- file truncated?")


def flatten(value, prefix="", out=None):
    """Nested dict -> dotted keys; lists of scalars -> joined; lists of dicts -> JSON."""
    out = {} if out is None else out
    if isinstance(value, dict):
        for k, v in value.items():
            flatten(v, f"{prefix}{k}." if prefix else f"{k}.", out) if isinstance(v, dict) \
                else out.__setitem__(f"{prefix}{k}", scalar(v))
    return out


def scalar(v):
    if isinstance(v, list):
        if all(not isinstance(x, (dict, list)) for x in v):
            return " | ".join("" if x is None else str(x) for x in v)
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, dict):
        return json.dumps(v, ensure_ascii=False)
    return v


def rows_for(domain, value):
    """Catalogs (dict keyed by id) and logs (list) both become a list of row dicts."""
    if isinstance(value, dict):
        rows = []
        for key, rec in value.items():
            if isinstance(rec, dict):
                row = {"_key": key}
                row.update(rec)
            else:
                row = {"_key": key, "value": rec}
            rows.append(row)
        return rows
    if isinstance(value, list):
        return [r if isinstance(r, dict) else {"value": r} for r in value]
    return [{"value": value}]


def write_domain(out_dir, domain, rows):
    if not rows:
        return 0
    with open(os.path.join(out_dir, f"{domain}.jsonl"), "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    flat = [flatten(r) for r in rows]
    cols = []
    for r in flat:
        for k in r:
            if k not in cols:
                cols.append(k)
    with open(os.path.join(out_dir, f"{domain}.csv"), "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in flat:
            w.writerow(r)
    return len(rows)


# Domains that are worth expanding one level deeper: npcAbilities is
# npcID -> spellID -> stats, so a row per (npc, spell) is what you want.
def explode_npc_abilities(value):
    rows = []
    for npc_id, spells in value.items():
        name = spells.get("name") if isinstance(spells, dict) else None
        for spell_id, ab in (spells or {}).items():
            if spell_id == "name" or not isinstance(ab, dict):
                continue
            row = {"npcID": npc_id, "npcName": name, "spellID": spell_id}
            row.update(ab)
            rows.append(row)
    return rows


def explode_vendor_items(value):
    rows = []
    for npc_id, v in value.items():
        for item in v.get("items", []):
            row = {"npcID": npc_id, "vendor": v.get("name"), "t": v.get("t")}
            row.update(item)
            rows.append(row)
    return rows


def explode_loot(value):
    rows = []
    for ev in value:
        for item in ev.get("items", []):
            row = {k: v for k, v in ev.items() if k != "items"}
            row.update(item)
            rows.append(row)
    return rows


def explode_traits(value):
    """configID -> trees -> nodes -> entries  =>  one row per entry."""
    rows = []
    for config_id, cfg in value.items():
        for tree_id, tree in (cfg.get("trees") or {}).items():
            for node in tree.get("nodes", []):
                entries = node.get("entries") or [{}]
                for e in entries:
                    rows.append({
                        "configID": config_id, "kind": cfg.get("kind"), "configName": cfg.get("name"),
                        "class": cfg.get("class"), "treeID": tree_id, "systemID": tree.get("systemID"),
                        "nodeID": node.get("id"), "x": node.get("x"), "y": node.get("y"),
                        "nodeType": node.get("type"), "maxRanks": node.get("maxRanks"),
                        "ranks": node.get("ranks"), "visible": node.get("visible"),
                        "available": node.get("available"), "edges": node.get("edges"),
                        "cost": node.get("cost"), "entryID": e.get("id"), "spellID": e.get("spellID"),
                        "name": e.get("name") or e.get("overrideName"),
                        "desc": e.get("desc") or e.get("overrideDesc"),
                    })
    return rows


SPECIAL = {
    "traits": explode_traits,
    "npcAbilities": explode_npc_abilities,
    "vendors": explode_vendor_items,
    "lootEvents": explode_loot,
}


def main(argv):
    path = None
    out_dir = None
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--out":
            out_dir = args.pop(0)
        else:
            path = a
    path = path or find_newest()
    raw = open(path, "rb").read()
    doc = json.loads(extract_payload(raw))

    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(doc.get("generated", time.time())))
    out_dir = out_dir or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", stamp)
    os.makedirs(out_dir, exist_ok=True)

    with open(os.path.join(out_dir, "payload.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)

    client = doc.get("client", {})
    print(f"source : {path}")
    print(f"client : {client.get('version')} build {client.get('build')} interface {client.get('interface')} project {client.get('project')}")
    print(f"output : {out_dir}")

    skip = {"schema", "generated", "client"}
    for domain, value in doc.items():
        if domain in skip or value in ({}, [], None):
            continue
        if domain in SPECIAL:
            n = write_domain(out_dir, domain, SPECIAL[domain](value))
            if domain == "vendors":
                write_domain(out_dir, "vendors_raw", rows_for(domain, value))
        else:
            n = write_domain(out_dir, domain, rows_for(domain, value))
        print(f"  {domain:<14} {n:>7} rows")


if __name__ == "__main__":
    main(sys.argv[1:])
