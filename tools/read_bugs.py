#!/usr/bin/env python3
"""read_bugs.py -- print the errors BugGrabber captured in the Forever beta client.
Author: Thunderz
"""
import glob
import os
import re
import sys

ROOT = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF\Account"


def main():
    files = glob.glob(os.path.join(ROOT, "*", "SavedVariables", "!BugGrabber.lua"))
    if not files:
        sys.exit("no !BugGrabber.lua in the beta client yet")
    path = max(files, key=os.path.getmtime)
    text = open(path, encoding="utf-8", errors="replace").read()
    string = r'"((?:[^"\\]|\\.)*)"'
    msgs = re.findall(r'\["message"\] = ' + string, text)
    stacks = re.findall(r'\["stack"\] = ' + string, text)
    counts = re.findall(r'\["counter"\] = (\d+)', text)
    print(f"{path}\n{len(msgs)} distinct errors\n")
    for i, m in enumerate(msgs):
        c = counts[i] if i < len(counts) else "?"
        print(f"[{i + 1}] x{c}  {m[:600]}")
        if i < len(stacks):
            for line in stacks[i].split("\\n")[:6]:
                print("      " + line[:200])
        print()


if __name__ == "__main__":
    main()
