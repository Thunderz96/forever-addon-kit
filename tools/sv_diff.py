#!/usr/bin/env python3
"""sv_diff.py -- structural diff of two SavedVariables files.
Author: Thunderz

Usage: python sv_diff.py old.lua new.lua [dotted.path.prefix] [--depth N]

Parses the Lua table literal WoW writes (strings, numbers, booleans, nested
tables) into Python and reports added / removed / changed paths. Meant for
answering "what did the addon rewrite between these two saves?".
"""
import re
import sys

TOKEN = re.compile(r'\s*(?:(--[^\n]*)|(\{)|(\})|(\[)|(\])|(=)|(,)|"((?:[^"\\]|\\.)*)"|(-?[0-9][0-9a-fA-Fx.eE+-]*)|([A-Za-z_][A-Za-z0-9_]*))')


def tokens(text):
    pos = 0
    n = len(text)
    while pos < n:
        m = TOKEN.match(text, pos)
        if not m:
            if text[pos:].strip() == "":
                return
            raise ValueError(f"cannot tokenize at {pos}: {text[pos:pos + 40]!r}")
        pos = m.end()
        if m.group(1) is not None:
            continue
        for kind, idx in (("{", 2), ("}", 3), ("[", 4), ("]", 5), ("=", 6), (",", 7)):
            if m.group(idx) is not None:
                yield kind, None
                break
        else:
            if m.group(8) is not None:
                yield "str", m.group(8)
            elif m.group(9) is not None:
                yield "num", m.group(9)
            else:
                yield "name", m.group(10)


class Parser:
    def __init__(self, text):
        self.toks = list(tokens(text))
        self.i = 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def take(self):
        t = self.peek()
        self.i += 1
        return t

    def value(self):
        kind, val = self.take()
        if kind == "{":
            return self.table()
        if kind == "str":
            return val
        if kind == "num":
            try:
                return float(val) if any(c in val for c in ".eE") and not val.startswith("0x") else int(val, 0)
            except ValueError:
                return val
        if kind == "name":
            return {"true": True, "false": False, "nil": None}.get(val, val)
        raise ValueError(f"unexpected token {kind}")

    def table(self):
        out = {}
        index = 1
        while True:
            kind, val = self.peek()
            if kind == "}":
                self.take()
                return out
            if kind == "[":
                self.take()
                key = self.value()
                self.take()  # ]
                self.take()  # =
                out[str(key)] = self.value()
            else:
                out[str(index)] = self.value()
                index += 1
            if self.peek()[0] == ",":
                self.take()

    def globals(self):
        out = {}
        while self.peek()[0] == "name":
            name = self.take()[1]
            self.take()  # =
            out[name] = self.value()
        return out


def load(path):
    return Parser(open(path, encoding="utf-8", errors="replace").read()).globals()


def walk(a, b, path, depth, out):
    if isinstance(a, dict) and isinstance(b, dict) and depth != 0:
        for k in sorted(set(a) | set(b)):
            p = f"{path}.{k}" if path else k
            if k not in a:
                out.append(("+", p, summary(b[k])))
            elif k not in b:
                out.append(("-", p, summary(a[k])))
            else:
                walk(a[k], b[k], p, depth - 1, out)
    elif a != b:
        out.append(("~", path, f"{summary(a)} -> {summary(b)}"))


def summary(v):
    if isinstance(v, dict):
        return f"{{table, {count(v)} leaves}}"
    s = repr(v)
    return s if len(s) < 70 else s[:67] + "..."


def count(v):
    return sum(count(x) for x in v.values()) if isinstance(v, dict) else 1


def main(argv):
    depth = -1
    if "--depth" in argv:
        i = argv.index("--depth")
        depth = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    a, b = load(argv[0]), load(argv[1])
    prefix = argv[2] if len(argv) > 2 else ""
    for part in [p for p in prefix.split(".") if p]:
        a = a.get(part, {}) if isinstance(a, dict) else {}
        b = b.get(part, {}) if isinstance(b, dict) else {}
    out = []
    walk(a, b, prefix, depth, out)
    print(f"{len(out)} differences under '{prefix or '<root>'}'  (old {count(a)} leaves, new {count(b)} leaves)")
    for sign, path, text in out[:400]:
        print(f" {sign} {path}  {text}")


if __name__ == "__main__":
    main(sys.argv[1:])
