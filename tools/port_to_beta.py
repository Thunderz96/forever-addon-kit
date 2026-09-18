#!/usr/bin/env python3
"""port_to_beta.py -- copy Retail addons into the WoW: Forever beta client.
Author: Thunderz

Usage: python port_to_beta.py Bartender4 ElvUI "!BugGrabber" ...
       (folder-name prefixes are matched, so "Details" also takes Details_*)

The Forever beta (1.60.x, interface 16001) runs the Retail API, so the copy
keeps only each addon's Mainline TOC: flavor TOCs (_Vanilla, _Mists, ...) are
removed from the COPY so the client cannot pick a Classic file list. 16001 is
added to the Interface line. The Retail originals are never touched.
"""
import os
import re
import shutil
import sys

ROOT = r"C:\Program Files (x86)\World of Warcraft"
SRC = os.path.join(ROOT, "_retail_", "Interface", "AddOns")
DST = os.path.join(ROOT, "_classic_beta_", "Interface", "AddOns")
INTERFACE = "16001"
FLAVORS = ("_Vanilla", "_Classic", "_TBC", "_BCC", "_Wrath", "_WOTLKC", "_Cata", "_Mists", "_Era")


def fix_tocs(folder):
    name = os.path.basename(folder)
    tocs = [f for f in os.listdir(folder) if f.lower().endswith(".toc")]
    base = os.path.join(folder, name + ".toc")
    mainline = os.path.join(folder, name + "_Mainline.toc")
    if os.path.exists(mainline):
        if os.path.exists(base):
            os.remove(base)
        os.rename(mainline, base)
    removed = []
    for t in tocs:
        stem = t[:-4]
        if any(stem.endswith(fl) for fl in FLAVORS):
            p = os.path.join(folder, t)
            if os.path.exists(p):
                os.remove(p)
                removed.append(t)
    if not os.path.exists(base):
        return f"{name}: NO MAINLINE TOC -- left as is", False
    raw = open(base, "rb").read()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig", errors="replace")

    def add(m):
        nums = [n.strip() for n in m.group(2).split(",") if n.strip()]
        if INTERFACE not in nums:
            nums.insert(0, INTERFACE)
        return m.group(1) + ", ".join(nums)

    text, n = re.subn(r"(?im)^(##\s*Interface:\s*)(.*)$", add, text, count=1)
    data = text.encode("utf-8")
    open(base, "wb").write((b"\xef\xbb\xbf" if bom else b"") + data)
    return f"{name}: ok (removed {len(removed)} flavor TOCs)", True


# The Forever client reports interface 16001 but runs the Retail 12.x API, so
# the usual "is this a modern client?" test -- select(4, GetBuildInfo()) >= N --
# gives the wrong answer and addons load Classic code paths or refuse to start.
# In the COPY, that idiom is replaced with the Retail number it should behave as.
BUILD_IDIOM = re.compile(r"select\s*\(\s*4\s*,\s*GetBuildInfo\s*\(\s*\)\s*\)")
PRETEND_INTERFACE = "120100"


def patch_build_checks(folder):
    patched = 0
    for dirpath, _, files in os.walk(folder):
        for f in files:
            if not f.lower().endswith(".lua"):
                continue
            p = os.path.join(dirpath, f)
            raw = open(p, "rb").read()
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                continue
            new, n = BUILD_IDIOM.subn(PRETEND_INTERFACE, text)
            if n:
                open(p, "wb").write(new.encode("utf-8"))
                patched += n
    return patched


def main(prefixes):
    os.makedirs(DST, exist_ok=True)
    for prefix in prefixes:
        matches = [d for d in os.listdir(SRC)
                   if os.path.isdir(os.path.join(SRC, d)) and (d == prefix or d.startswith(prefix + "_"))]
        if not matches:
            print(f"{prefix}: not found in Retail AddOns")
            continue
        for d in matches:
            target = os.path.join(DST, d)
            if os.path.exists(target):
                shutil.rmtree(target)
            shutil.copytree(os.path.join(SRC, d), target)
            msg, _ = fix_tocs(target)
            n = patch_build_checks(target)
            print("  " + msg + (f", {n} build checks patched" if n else ""))


if __name__ == "__main__":
    main(sys.argv[1:])
