#!/usr/bin/env python3
"""sv_bridge.py -- make addon settings persist on the WoW: Forever beta client.
Author: Thunderz

THE BUG (measured 2026-09-17, build 1.60.1.69893): the beta client writes addon
SavedVariables on exit but never reads them back at the next launch. A seeded
value was nil from main chunk through logout, in every candidate WTF folder.
Every addon therefore starts from defaults on every launch.

THE WORKAROUND: a SavedVariables file is only Lua that assigns globals. The
client will not run it, but an addon can. "!!ForeverCompat" sorts first in the
load order and lists one seed file per bridged addon in its TOC, so the globals
exist before the real addon loads and it behaves as if its settings had loaded.

This script is the other half. It copies what the client saved on exit (or on
/reload) back into the seeds, so changes made in game carry over:

    WTF\\Account\\<acct>\\SavedVariables\\<Addon>.lua  ->  !!ForeverCompat\\seeds\\<Addon>.lua

Safety: a seed is never replaced by a file under 25% of its size unless
--force (a broken session writes near-empty defaults); every replaced seed is
kept in Forever\\sv-backups\\<Addon>\\ (newest 40).

Usage:
    python sv_bridge.py                 refresh seeds from the client's saved files
    python sv_bridge.py --init-retail   (re)seed from the Retail account's files
    python sv_bridge.py --status
"""
import glob
import os
import shutil
import subprocess
import sys
import time

ROOT = r"C:\Program Files (x86)\World of Warcraft"
BETA = os.path.join(ROOT, "_classic_beta_")
BETA_SV = os.path.join(BETA, "WTF", "Account", "<BETA_ACCOUNT>", "SavedVariables")
RETAIL_SV = os.path.join(ROOT, "_retail_", "WTF", "Account", "<RETAIL_ACCOUNT>", "SavedVariables")
HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
COMPAT_SRC = next((c for c in (os.path.join(PROJECT, "addons", "ForeverCompat"),
                               os.path.join(PROJECT, "ForeverCompat")) if os.path.isdir(c)),
                  os.path.join(PROJECT, "ForeverCompat"))
COMPAT_DST = os.path.join(BETA, "Interface", "AddOns", "!!ForeverCompat")
BACKUPS = os.path.join(PROJECT, "sv-backups")
LOG = os.path.join(HERE, "sv_bridge.log")

# Addons whose account-wide settings are bridged. The file name is the addon
# folder name; add more here as they are ported.
BRIDGED = ["EllesmereUI", "BugSack", "SpeedyAutoLoot", "DialogueUI", "ForeverCDM"]
EXE = "WowB.exe"

TOC = """## Interface: 16001
## Title: |cffd2621fForever|r Compat + Settings Loader
## Notes: Retail API wrappers the Forever client lacks, plus a loader that restores addon settings the beta client never reads back. Managed by Forever\\tools\\sv_bridge.py.
## Author: Thunderz
## Version: 0.1.0

Compat.lua
ActionPlace.lua
{seeds}
"""


def log(msg):
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + msg
    print(line)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")


# Adjust if luac lives elsewhere; without it a brace-balance check is used instead.
LUAC = os.path.expandvars(r"%LOCALAPPDATA%\Programs\Lua\bin\luac.exe")


def valid_lua(path):
    """Reject a file caught mid-write. Uses luac when present, else a brace balance."""
    if os.path.exists(LUAC):
        r = subprocess.run([LUAC, "-p", path], capture_output=True,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return r.returncode == 0
    text = open(path, encoding="utf-8", errors="replace").read()
    return text.count("{") == text.count("}") and text.rstrip().endswith("}")


def backup(addon, path):
    d = os.path.join(BACKUPS, addon)
    os.makedirs(d, exist_ok=True)
    shutil.copyfile(path, os.path.join(d, time.strftime("%Y%m%d-%H%M%S") + ".lua"))
    old = sorted(glob.glob(os.path.join(d, "*.lua")))
    for p in old[:-40]:
        os.remove(p)


def write_addon():
    os.makedirs(os.path.join(COMPAT_DST, "seeds"), exist_ok=True)
    for name in ("Compat.lua", "ActionPlace.lua"):
        shutil.copyfile(os.path.join(COMPAT_SRC, name), os.path.join(COMPAT_DST, name))
    seeds = sorted(f for f in os.listdir(os.path.join(COMPAT_DST, "seeds")) if f.lower().endswith(".lua"))
    toc = TOC.format(seeds="\n".join("seeds\\" + s for s in seeds))
    with open(os.path.join(COMPAT_DST, "!!ForeverCompat.toc"), "w", encoding="ascii", newline="\r\n") as f:
        f.write(toc)
    return seeds


def put_seed(addon, src, force=False, why=""):
    dst = os.path.join(COMPAT_DST, "seeds", addon + ".lua")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        if open(dst, "rb").read() == open(src, "rb").read():
            return False
        if not force and os.path.getsize(src) < 0.25 * os.path.getsize(dst):
            log(f"{addon}: REFUSED {os.path.getsize(src)} B over a {os.path.getsize(dst)} B seed "
                f"(looks like a defaults-only save). Use --force to accept.")
            return False
        backup(addon, dst)
    shutil.copyfile(src, dst)
    log(f"{addon}: seed updated from {why} ({os.path.getsize(dst) // 1024} KB)")
    return True


def main(argv):
    force = "--force" in argv
    if "--status" in argv:
        for a in BRIDGED:
            seed = os.path.join(COMPAT_DST, "seeds", a + ".lua")
            sv = os.path.join(BETA_SV, a + ".lua")
            for label, p in (("seed", seed), ("saved", sv)):
                if os.path.exists(p):
                    print(f"  {a:<14} {label:<6} {os.path.getsize(p) // 1024:>5} KB  "
                          f"{time.strftime('%m-%d %H:%M:%S', time.localtime(os.path.getmtime(p)))}")
        return
    if "--init-retail" in argv:
        for a in BRIDGED:
            src = os.path.join(RETAIL_SV, a + ".lua")
            if os.path.exists(src):
                put_seed(a, src, force=True, why="Retail account")
        log("TOC lists: " + ", ".join(write_addon()))
        return
    # No "is the game running" gate: the file on disk is always a complete
    # earlier save, and seeds are only read when an addon loads. The one real
    # hazard is a file caught mid-write, which valid_lua() rejects.
    changed = False
    for a in BRIDGED:
        sv = os.path.join(BETA_SV, a + ".lua")
        seed = os.path.join(COMPAT_DST, "seeds", a + ".lua")
        if not os.path.exists(sv):
            continue
        if os.path.exists(seed) and os.path.getmtime(sv) <= os.path.getmtime(seed):
            continue
        if time.time() - os.path.getmtime(sv) < 5 or not valid_lua(sv):
            continue  # still being written; next run will take it
        changed |= put_seed(a, sv, force=force, why="the client's last save")
    if changed or not os.path.exists(os.path.join(COMPAT_DST, "!!ForeverCompat.toc")):
        write_addon()


if __name__ == "__main__":
    main(sys.argv[1:])
