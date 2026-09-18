#!/usr/bin/env python3
"""guard_secure_snippets.py -- make secure-snippet sites no-ops on the Forever
beta client instead of errors.
Author: Thunderz

Build 1.60.1.69893 lacks loadstring_untainted, so every WrapScript /
SetAttribute("_onstate-...") / SecureHandlerExecute call throws "attempt to
call a nil value" from Blizzard's RestrictedExecution.lua -- once when set up
and again on every state change. The features behind them cannot work on this
build regardless; the errors only burn BugGrabber's cap and trigger the
"degraded experience" warning.

This wraps each such statement in `if loadstring_untainted then ... end` in the
BETA copies only. When Blizzard restores the function the guards become true
and the original behaviour returns, no re-port needed.

Usage: python guard_secure_snippets.py [--dry] Folder [Folder ...]
"""
import os
import re
import sys

ADDONS = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
TAG = "FOREVER-BETA"
START = re.compile(r"^(\s*)(?!if\s)(.*?(?:WrapScript\(|SecureHandlerWrapScript\(|SecureHandlerExecute\(|SetAttribute\(\s*\"_(?:on|child|wrap|adopt)|SetAttribute\(\s*\"_onstate-|SetAttribute\(\s*\"initialConfigFunction\"|SetAttributeNoHandler\(\s*\"|:RunAttribute\(|:Execute\()).*$")


CALL = re.compile(r"WrapScript\(|SecureHandlerWrapScript\(|SecureHandlerExecute\(|SetAttribute\(\s*\"_(?:on|child|wrap|adopt)|SetAttribute\(\s*\"initialConfigFunction\"|SetAttributeNoHandler\(\s*\"|:RunAttribute\(|:Execute\(")


def statement_end(lines, i, startcol=0):
    """Index of the line where the statement starting at lines[i] closes:
    parentheses balanced from `startcol` on, with long strings skipped."""
    depth, in_long, close = 0, False, "]]"
    for j in range(i, len(lines)):
        s = lines[j]
        k = startcol if j == i else 0
        while k < len(s):
            if in_long:
                if s.startswith(close, k):
                    in_long = False
                    k += len(close)
                    continue
                k += 1
                continue
            lm = re.match(r"\[(=*)\[", s[k:])
            if lm:
                in_long = True
                close = "]" + lm.group(1) + "]"
                k += lm.end()
                continue
            if s.startswith("--", k):
                break
            c = s[k]
            if c == '"' or c == "'":
                q = c
                k += 1
                while k < len(s) and s[k] != q:
                    k += 2 if s[k] == "\\" else 1
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return j
            k += 1
    return None


def patch_file(path, dry):
    raw = open(path, "rb").read()
    crlf = b"\r\n" in raw
    text = raw.decode("utf-8", errors="surrogateescape").replace("\r\n", "\n")
    lines = text.split("\n")
    out, i, n = [], 0, 0
    in_long = False   # inside a [[ ... ]] / [=[ ... ]=] long string at top level?
    long_close = None
    while i < len(lines):
        line = lines[i]
        m = START.match(line) if not in_long else None
        already = out and out[-1].strip().startswith("if loadstring_untainted then")
        call = CALL.search(line) if m else None
        before = line[: call.start()] if call else ""
        skip = (not call or already or line.lstrip().startswith("--")
                or line.lstrip().startswith("local ")            # snippet text in a local constant
                or "[[" in before or "[=[" in before              # match is inside a string
                or '"' in before.split("--")[0].replace('\\"', "") and before.count('"') % 2 == 1)
        if m and not skip:
            end = statement_end(lines, i, line.index("(", call.start()))
            if end is not None:
                indent = m.group(1)
                out.append(f"{indent}if loadstring_untainted then -- {TAG}: secure snippet, cannot compile on this build")
                out.extend(lines[i:end + 1])
                out.append(f"{indent}end")
                n += 1
                i = end + 1
                continue
        out.append(line)
        # Track long strings so lines INSIDE a snippet body are never touched.
        k = 0
        while k < len(line):
            if in_long:
                j = line.find(long_close, k)
                if j == -1:
                    break
                in_long, k = False, j + len(long_close)
            else:
                if line.startswith("--", k):
                    break
                lm = re.match(r"\[(=*)\[", line[k:])
                if lm:
                    in_long, long_close = True, "]" + lm.group(1) + "]"
                    k += lm.end()
                elif line[k] in "\"'":
                    q = line[k]
                    k += 1
                    while k < len(line) and line[k] != q:
                        k += 2 if line[k] == "\\" else 1
                    k += 1
                else:
                    k += 1
        i += 1
    if n and not dry:
        new = "\n".join(out)
        if crlf:
            new = new.replace("\n", "\r\n")
        open(path, "wb").write(new.encode("utf-8", errors="surrogateescape"))
    return n, "patched" if not dry else "would patch"


def main(argv):
    dry = "--dry" in argv
    folders = [a for a in argv if a != "--dry"]
    for folder in folders:
        root = os.path.join(ADDONS, folder)
        for dirpath, dirnames, names in os.walk(root):
            dirnames[:] = [d for d in dirnames if d.lower() not in ("libs", "lib")]
            for name in names:
                if name.lower().endswith(".lua"):
                    n, status = patch_file(os.path.join(dirpath, name), dry)
                    if n:
                        print(f"{status:<12} {n:>3} sites  {folder}\\{name}")


if __name__ == "__main__":
    main(sys.argv[1:])
