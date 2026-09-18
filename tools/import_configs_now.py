#!/usr/bin/env python3
"""import_configs_now.py -- import Retail addon settings into the Forever beta.
Author: Thunderz

Run ONLY with the beta client closed (the script refuses otherwise).

Lesson from 2026-09-17: the client keeps <name>.lua.bak beside every
SavedVariables file and restores the backup when the main file looks older
than it. A copy that preserves the source timestamp (cp -p, shutil.copy2)
therefore gets silently replaced by the blank backup. So this copies WITHOUT
preserving times, stamps the file "now", and deletes the matching .bak.
"""
import glob
import os
import shutil
import subprocess
import sys
import time

ROOT = r"C:\Program Files (x86)\World of Warcraft"
SRC_ACCT = os.path.join(ROOT, "_retail_", "WTF", "Account", "<RETAIL_ACCOUNT>")
DST_ACCT = os.path.join(ROOT, "_classic_beta_", "WTF", "Account", "<BETA_ACCOUNT>")
SV_PATTERNS = ["EllesmereUI*.lua", "Bartender4.lua", "BugSack.lua", "Details.lua", "Details_Streamer.lua"]
SV_SKIP = ("MythicTimer",)
ACCOUNT_FILES = ["bindings-cache.wtf", "macros-cache.txt"]
EXE = "WowB.exe"


def running():
    out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {EXE}", "/NH"], capture_output=True, text=True).stdout
    return EXE.lower() in out.lower()


def put(src, dst):
    shutil.copyfile(src, dst)          # content only, no timestamps
    now = time.time()
    os.utime(dst, (now, now))
    for stale in (dst + ".bak", os.path.splitext(dst)[0] + ".old"):
        if os.path.exists(stale):
            os.remove(stale)


def main():
    if running():
        sys.exit(f"{EXE} is running. Exit the game completely first.")
    n = 0
    for pat in SV_PATTERNS:
        for p in glob.glob(os.path.join(SRC_ACCT, "SavedVariables", pat)):
            if any(s in os.path.basename(p) for s in SV_SKIP):
                continue
            put(p, os.path.join(DST_ACCT, "SavedVariables", os.path.basename(p)))
            n += 1
    for name in ACCOUNT_FILES:
        p = os.path.join(SRC_ACCT, name)
        if os.path.exists(p):
            put(p, os.path.join(DST_ACCT, name))
            n += 1
    # cache.md5 holds checksums for the account cache files; a stale one makes
    # the client distrust bindings/macros, so let it be rebuilt.
    md5 = os.path.join(DST_ACCT, "cache.md5")
    if os.path.exists(md5):
        os.remove(md5)
    print(f"imported {n} files with fresh timestamps; stale .bak/.old and cache.md5 removed")
    for f in ("EllesmereUI.lua", "Bartender4.lua", "Details.lua"):
        p = os.path.join(DST_ACCT, "SavedVariables", f)
        print(f"  {os.path.getsize(p) // 1024:>5} KB  {time.strftime('%H:%M:%S', time.localtime(os.path.getmtime(p)))}  {f}"
              f"  (bak present: {os.path.exists(p + '.bak')})")


if __name__ == "__main__":
    main()
