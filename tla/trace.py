#!/usr/bin/env python3
"""Print a TLC counterexample as per-step diffs of the TraceView alias."""
import re, sys

text = sys.stdin.read()
m = re.search(r"^Error: (Invariant \S+ is violated|Temporal propert\S+ \S* ?was violated|Temporal properties were violated)", text, re.M)
print(m.group(0) if m else "No violation found.")
blocks = re.split(r"^State (\d+): ", text, flags=re.M)[1:]
prev = {}
for num, body in zip(blocks[0::2], blocks[1::2]):
    header, _, rest = body.partition("\n")
    action = re.sub(r" line \d+, col \d+ to line \d+, col \d+ of module \w+", "", header).strip("<> ")
    fields, key = {}, None
    for line in rest.splitlines():
        if line.startswith("/\\ "):
            key, _, val = line[3:].partition(" = ")
            fields[key] = val
        elif key and line.strip() and not line.startswith(("Error", "Back to", "Stuttering")):
            fields[key] += " " + line.strip()
        else:
            key = None
    print(f"\n[{num}] {action}")
    for k, v in fields.items():
        v = re.sub(r"\s+", " ", v)
        if prev.get(k) != v:
            print(f"    {k:14} {v}")
    prev = fields
if "Back to state" in text:
    print("\n" + re.search(r"^Back to state.*$", text, re.M).group(0))
