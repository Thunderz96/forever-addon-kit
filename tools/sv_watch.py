#!/usr/bin/env python3
"""sv_watch.py -- always-on, sub-second half of the Forever settings bridge.
Author: Thunderz

Why this exists (2026-09-17): on /reload the client writes SavedVariables and
then reloads every addon a second or two later. A bridge that runs every few
minutes leaves the loader's seeds stale across that reload, so the addon comes
back up on OLD settings, and the next save then makes the old settings the
truth. The copy has to land inside the gap between "client wrote the file" and
"addons load again". This polls file times every 100 ms and copies as soon as a
write has finished and the file parses.

Runs windowless under pythonw and holds a lock file so only one instance ever
runs; the scheduled task "ForeverSVBridge" simply tries to start it every five
minutes and at logon, and extra starts exit immediately.

Hold file: if tools\\sv_watch.hold exists, the NEXT change to each bridged file
is ignored once and the hold is cleared. Used to reload onto a known-good seed
without the reload's own save replacing it.
"""
import msvcrt
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sv_bridge as b  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "sv_watch.lock")
HOLD = os.path.join(HERE, "sv_watch.hold")
POLL = 0.10


def single_instance():
    fh = open(LOCK, "a+")
    try:
        msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        sys.exit(0)  # another watcher already holds the lock
    return fh


def stable(path):
    """True once the file has stopped growing and parses as Lua."""
    try:
        s1 = os.path.getsize(path)
        time.sleep(0.05)
        s2 = os.path.getsize(path)
    except OSError:
        return False
    return s1 == s2 and s1 > 0 and b.valid_lua(path)


def main():
    lock = single_instance()  # noqa: F841 - must stay referenced for the lock to hold
    b.log("sv_watch started")
    seen = {}
    for a in b.BRIDGED:
        p = os.path.join(b.BETA_SV, a + ".lua")
        seen[a] = os.path.getmtime(p) if os.path.exists(p) else 0
    held = set()
    while True:
        time.sleep(POLL)
        for a in b.BRIDGED:
            p = os.path.join(b.BETA_SV, a + ".lua")
            try:
                m = os.path.getmtime(p)
            except OSError:
                continue
            if m == seen[a]:
                continue
            deadline = time.time() + 3
            while not stable(p) and time.time() < deadline:
                time.sleep(0.03)
            seen[a] = os.path.getmtime(p)
            if os.path.exists(HOLD):
                held.add(a)
                b.log(f"{a}: change ignored once (hold file present)")
                if held >= {x for x in b.BRIDGED if os.path.exists(os.path.join(b.BETA_SV, x + '.lua'))}:
                    os.remove(HOLD)
                    held.clear()
                    b.log("hold cleared")
                continue
            try:
                if b.put_seed(a, p, why="the client's save (watch)"):
                    b.write_addon()
            except Exception as e:  # noqa: BLE001 - windowless; the log is the only output
                b.log(f"{a}: ERROR {e!r}")


if __name__ == "__main__":
    main()
