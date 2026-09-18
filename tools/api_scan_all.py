#!/usr/bin/env python3
"""api_scan_all.py -- rank every addon in an AddOns folder by how cleanly it
would run on the WoW: Forever client.
Author: Thunderz

Usage: python api_scan_all.py [AddOnsDir] [--csv out.csv]

Groups multi-folder addons into families (BigWigs_*, DBM-*, EnhanceQoL*, ...),
scans each family's own Lua (embedded libs skipped) against the API surface
Forever Beacon captured, and counts UNGUARDED references to things Forever does
not have. Names the !!ForeverCompat shim defines are treated as present.
"""
import csv
import json
import os
import re
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import api_scan as A  # noqa: E402

DEFAULT_DIR = r"C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns"
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPAT = next((c for c in (os.path.join(_ROOT, "addons", "ForeverCompat", "Compat.lua"),
                           os.path.join(_ROOT, "ForeverCompat", "Compat.lua")) if os.path.exists(c)), "")


def families(names):
    names = sorted(names, key=lambda s: (s.lower().lstrip("!+"), s))
    fams = []
    for n in names:
        base = re.split(r"[_\-]", n, 1)[0]
        placed = False
        for fam in fams:
            root = fam[0]
            rbase = re.split(r"[_\-]", root, 1)[0]
            if (base == rbase and len(base) >= 3) or (len(rbase) >= 7 and n.startswith(rbase)):
                fam.append(n)
                placed = True
                break
        if not placed:
            fams.append([n])
    return fams


def lua_files(addons_dir, folders):
    out = []
    for d in folders:
        for dirpath, dirnames, names in os.walk(os.path.join(addons_dir, d)):
            dirnames[:] = [x for x in dirnames if x.lower() not in ("libs", "lib", "libraries", "externals", "ace3")]
            out += [os.path.join(dirpath, n) for n in names if n.lower().endswith(".lua")]
    return out


def scan(addons_dir, folders, functions, frames, ns):
    files = lua_files(addons_dir, folders)
    own, sources = set(), {}
    for f in files:
        try:
            lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        if len(lines) > 60000:      # data tables, not code
            continue
        sources[f] = lines
        for ln in lines:
            for m in A.DEFINED.finditer(ln):
                own.add(m.group(1))
            m = A.ASSIGN.match(ln)
            if m:
                own.add(m.group(1))
    miss = defaultdict(int)
    refs = 0
    for f, lines in sources.items():
        clean = [A.strip_comments_strings(ln) for ln in lines]
        for i, ln in enumerate(clean):
            window = " ".join(clean[max(0, i - 2):i + 1])
            for m in A.NSREF.finditer(ln):
                refs += 1
                space, fn = m.group(1), m.group(2)
                if space in ns and fn in ns[space]:
                    continue
                full = f"{space}.{fn}"
                if A.guarded(full, window) or A.guarded(space, window):
                    continue
                miss[full] += 1
            for m in A.CALL.finditer(ln):
                name = m.group(1)
                if name in own or name in A.LUA_BUILTINS or name.isupper():
                    continue
                if name in functions or name in frames:
                    refs += 1
                    continue
                if not re.match(r"^(Get|Set|Is|Has|Can|Unit|C_|Create|Toggle|Show|Hide|Load|Use|Pickup|Equip|Cast|Spell|Item|Quest|Num)", name):
                    continue            # probably addon-internal, not a WoW API
                refs += 1
                if A.guarded(name, window):
                    continue
                miss[name] += 1
    return len(sources), refs, miss


def main(argv):
    out_csv = None
    if "--csv" in argv:
        i = argv.index("--csv")
        out_csv = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    addons_dir = argv[0] if argv else DEFAULT_DIR
    api = json.load(open(A.BASELINE, encoding="utf-8"))
    functions = set(api["functions"])
    if os.path.exists(COMPAT):
        functions |= set(re.findall(r'define\("([A-Za-z0-9_]+)"', open(COMPAT, encoding="utf-8").read()))
    frames = set(api["frames"])
    ns = {k: set(v if isinstance(v, list) else []) for k, v in api["namespaces"].items()}

    names = [d for d in os.listdir(addons_dir) if os.path.isdir(os.path.join(addons_dir, d))]
    rows = []
    for fam in families(names):
        nfiles, refs, miss = scan(addons_dir, fam, functions, frames, ns)
        uses = sum(miss.values())
        top = ", ".join(f"{k} x{v}" for k, v in sorted(miss.items(), key=lambda kv: -kv[1])[:5])
        pct = 100.0 * (refs - uses) / refs if refs else 100.0
        rows.append({"addon": fam[0], "folders": len(fam), "files": nfiles, "api_refs": refs,
                     "missing_names": len(miss), "missing_uses": uses, "compat_pct": round(pct, 1), "top_missing": top})
    rows.sort(key=lambda r: (r["missing_names"], -r["api_refs"]))
    print(f"{'addon':<34}{'fold':>5}{'files':>6}{'refs':>7}{'miss':>6}{'uses':>6}{'ok%':>7}  top missing")
    for r in rows:
        print(f"{r['addon'][:33]:<34}{r['folders']:>5}{r['files']:>6}{r['api_refs']:>7}{r['missing_names']:>6}{r['missing_uses']:>6}{r['compat_pct']:>7}  {r['top_missing'][:110]}")
    if out_csv:
        with open(out_csv, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        print(f"\nwrote {out_csv}")


if __name__ == "__main__":
    main(sys.argv[1:])
