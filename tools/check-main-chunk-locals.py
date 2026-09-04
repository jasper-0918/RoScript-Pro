#!/usr/bin/env python3
"""Guard against Luau's 200-local-register cap on the plugin's main chunk.

RoScriptPro.lua ships as ONE Luau chunk, and a chunk is a function: every
column-0 `local` holds a register from its declaration to end of file. Cross
200 and Studio refuses to compile the whole plugin with

    Out of local registers when trying to allocate <name>: exceeded limit 200

which reads like a runtime error but means nothing loaded at all. v2 shipped
206 and was dead on arrival. Registers are also needed for temporaries, so the
budget here is 190, not 200.

Add tunables to the CFG table, not as new column-0 locals -- table fields cost
no register.

    python tools/check-main-chunk-locals.py studio-plugin/RoScriptPro.lua
"""
import re
import sys

BUDGET = 190
HARD_CAP = 200


def mask_strings_and_comments(s):
    """Blank out strings and comments so Luau inside a system prompt (the
    SYS_BASE / SYS_GOAL long strings hold example code) is never counted."""
    n = len(s)
    out = list(s)

    def long_bracket(idx):
        if idx >= n or s[idx] != "[":
            return None
        j, eq = idx + 1, 0
        while j < n and s[j] == "=":
            eq, j = eq + 1, j + 1
        return (eq, j + 1) if j < n and s[j] == "[" else None

    def blank(a, b):
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    i = 0
    while i < n:
        c = s[i]
        if c == "\n":
            i += 1
        elif s.startswith("--", i):
            lb = long_bracket(i + 2)
            if lb:
                close = "]" + "=" * lb[0] + "]"
                end = s.find(close, lb[1])
                end = n if end == -1 else end + len(close)
            else:
                end = s.find("\n", i)
                end = n if end == -1 else end
            blank(i, end)
            i = end
        elif long_bracket(i):
            eq, start = long_bracket(i)
            close = "]" + "=" * eq + "]"
            end = s.find(close, start)
            end = n if end == -1 else end + len(close)
            blank(i, end)
            i = end
        elif c in "\"'":
            j = i + 1
            while j < n:
                if s[j] == "\\":
                    j += 2
                    continue
                if s[j] == c:
                    j += 1
                    break
                if s[j] == "\n":
                    break
                j += 1
            blank(i, j)
            i = j
        else:
            i += 1
    return "".join(out)


def main(path):
    src = open(path, encoding="utf-8", newline="").read()
    masked = mask_strings_and_comments(src)

    names = []
    for lineno, line in enumerate(masked.replace("\r\n", "\n").split("\n"), 1):
        if not line.startswith("local "):
            continue
        rest = line[6:]
        fn = re.match(r"function\s+([A-Za-z_]\w*)", rest)
        if fn:
            names.append((lineno, fn.group(1)))
            continue
        decl = re.match(r"((?:[A-Za-z_]\w*\s*,\s*)*[A-Za-z_]\w*)", rest)
        if decl:
            names.extend((lineno, n.strip()) for n in decl.group(1).split(","))

    total = len(names)
    print(f"{path}: {total} main-chunk locals (budget {BUDGET}, Luau cap {HARD_CAP})")

    if total > BUDGET:
        print(f"\nover budget by {total - BUDGET}. The last few declared:")
        for lineno, name in names[-12:]:
            print(f"  L{lineno}: {name}")
        print("\nMove scalars into the CFG table, or group related helpers onto")
        print("an existing namespace table (UI, Tools, Store, Agent, Goal).")
        return 1

    print(f"headroom: {BUDGET - total}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
