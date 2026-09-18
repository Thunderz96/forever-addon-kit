#!/usr/bin/env python3
"""api_scan.py -- what will an addon be missing on the WoW: Forever client?
Author: Thunderz

Usage: python api_scan.py <AddOnsDir> <FolderPrefix> [<FolderPrefix> ...] [--json out.json]

Compares every global function call, C_Namespace.Function reference and
Blizzard frame reference in the addon's Lua against the API surface Forever
Beacon captured from the live client (ForeverBeacon\\data\\api-baseline\\forever_api.json).

It reports only UNGUARDED uses. A reference on a line (or within the two lines
above) that also tests the name for existence -- "if X then", "X and X(",
"type(X) ==" -- is treated as already safe.
"""
import json
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
def _find_baseline():
    """Kit layout (data/forever_api.json) or working-tree layout."""
    root = os.path.dirname(HERE)
    for cand in (os.path.join(root, "data", "forever_api.json"),
                 os.path.join(root, "ForeverBeacon", "data", "api-baseline", "forever_api.json")):
        if os.path.exists(cand):
            return cand
    return cand


BASELINE = _find_baseline()

LUA_BUILTINS = set("""assert collectgarbage date error gcinfo getfenv getmetatable ipairs loadstring next pairs
pcall print rawequal rawget rawset select setfenv setmetatable time tonumber tostring type unpack xpcall
abs ceil floor max min mod random sqrt format gsub strbyte strchar strfind strlen strlower strmatch strrep
strrev strsub strupper strjoin strsplit strtrim strconcat tinsert tremove wipe sort tContains
CreateFrame hooksecurefunc issecurevariable securecall geterrorhandler seterrorhandler debugstack
debugprofilestop issecretvalue canaccessvalue canaccesstable scrubsecretvalues secretwrap""".split())

CALL = re.compile(r"(?<![.:\w])([A-Z][A-Za-z0-9_]{3,})\s*\(")
NSREF = re.compile(r"\b(C_[A-Za-z0-9]+)\.([A-Za-z0-9_]+)")
FRAMEREF = re.compile(r"(?<![.:\w\"'])([A-Z][A-Za-z0-9]{5,}(?:Frame|Button|Bar|Tooltip|Page|Container|Manager|Tracker|Menu))\b(?=\s*[.:\[])")
DEFINED = re.compile(r"(?:^|\s)(?:local\s+function\s+|function\s+|local\s+)([A-Za-z_][A-Za-z0-9_]*)")
ASSIGN = re.compile(r"^\s*([A-Z][A-Za-z0-9_]*)\s*=")


def strip_comments_strings(line):
    line = re.sub(r"--.*$", "", line)
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"'(?:[^'\\]|\\.)*'", "''", line)
    return line


def guarded(name, window):
    n = re.escape(name)
    # A guard tests the NAME itself ("if X then", "X and X(...)", "type(X)"),
    # never a call to it: "if X(...)" is a use, not a guard.
    pats = [rf"\bif\s+(?:not\s+)?{n}\b(?!\s*\()", rf"\b{n}\s+and\b", rf"\band\s+{n}\b(?!\s*\()", rf"type\(\s*{n}\s*\)",
            rf"\b{n}\s+or\b", rf"\bor\s+{n}\b(?!\s*\()", rf"\bnot\s+{n}\b(?!\s*\()", rf"{n}\s*~=\s*nil", rf"{n}\s*==\s*nil"]
    return any(re.search(p, window) for p in pats)


def main(argv):
    out_json = None
    if "--json" in argv:
        i = argv.index("--json")
        out_json = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    addons_dir, prefixes = argv[0], argv[1:]
    api = json.load(open(BASELINE, encoding="utf-8"))
    functions = set(api["functions"])
    frames = set(api["frames"])
    ns = {k: set(v if isinstance(v, list) else []) for k, v in api["namespaces"].items()}

    folders = [d for d in sorted(os.listdir(addons_dir))
               if os.path.isdir(os.path.join(addons_dir, d)) and any(d == p or d.startswith(p) for p in prefixes)]
    files = []
    for d in folders:
        for dirpath, _, names in os.walk(os.path.join(addons_dir, d)):
            if os.sep + "libs" in dirpath.lower() + os.sep or os.sep + "lib" + os.sep in dirpath.lower() + os.sep:
                continue
            files += [os.path.join(dirpath, n) for n in names if n.lower().endswith(".lua")]

    # Names the addon defines itself are never "missing". Globals it assigns
    # ("function X(" / "X = ") count everywhere; "local X" only inside that
    # file -- a local alias in one file says nothing about a bare call elsewhere.
    own_global = set()
    own_local = {}
    sources = {}
    for f in files:
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
        sources[f] = lines
        loc = set()
        for ln in lines:
            for m in re.finditer(r"(?:^|\s)local\s+(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)", ln):
                loc.add(m.group(1))
            for m in re.finditer(r"(?:^|\s)local\s+([A-Za-z_][A-Za-z0-9_ ,]*)=", ln):
                for part in m.group(1).split(","):
                    loc.add(part.strip())
            m = re.match(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", ln)
            if m:
                own_global.add(m.group(1))
            m = ASSIGN.match(ln)
            if m:
                own_global.add(m.group(1))
        own_local[f] = loc

    missing_fn = defaultdict(list)
    missing_ns = defaultdict(list)
    missing_frame = defaultdict(list)
    for f, lines in sources.items():
        own = own_global | own_local[f]
        rel = os.path.relpath(f, addons_dir)
        clean = [strip_comments_strings(ln) for ln in lines]
        for i, ln in enumerate(clean):
            window = " ".join(clean[max(0, i - 2):i + 1])
            for m in CALL.finditer(ln):
                name = m.group(1)
                if name in functions or name in own or name in LUA_BUILTINS or name in frames or name.isupper():
                    continue
                if guarded(name, window):
                    continue
                missing_fn[name].append(f"{rel}:{i + 1}")
            for m in NSREF.finditer(ln):
                space, fn = m.group(1), m.group(2)
                full = f"{space}.{fn}"
                if space in ns and fn in ns[space]:
                    continue
                if guarded(full, window) or (space not in ns and guarded(space, window)):
                    continue
                missing_ns[full].append(f"{rel}:{i + 1}")
            for m in FRAMEREF.finditer(ln):
                name = m.group(1)
                if name in frames or name in own or name in functions:
                    continue
                if guarded(name, window):
                    continue
                missing_frame[name].append(f"{rel}:{i + 1}")

    def show(title, table):
        print(f"\n=== {title}: {len(table)} names, {sum(len(v) for v in table.values())} unguarded uses ===")
        for name, locs in sorted(table.items(), key=lambda kv: -len(kv[1])):
            mods = sorted({l.split(os.sep)[0] for l in locs})
            print(f"  {name:<48} x{len(locs):<4} {', '.join(m.replace('EllesmereUI', 'EUI') for m in mods)[:90]}")

    print(f"scanned {len(files)} files in {len(folders)} folders against Forever {api['client']['version']} ({api['client']['interface']})")
    show("GLOBAL FUNCTIONS missing on Forever", missing_fn)
    show("C_ NAMESPACE functions missing on Forever", missing_ns)
    show("BLIZZARD FRAMES missing on Forever", missing_frame)
    if out_json:
        json.dump({"functions": missing_fn, "namespaces": missing_ns, "frames": missing_frame},
                  open(out_json, "w", encoding="utf-8"), indent=1)


if __name__ == "__main__":
    main(sys.argv[1:])
