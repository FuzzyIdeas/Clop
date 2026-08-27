#!/usr/bin/env python3
"""Attach a `.searchAnchor("<entry id>")` to the control each settings-index entry describes.

Search results scroll to the anchor and flash it, so an entry without one lands the user on the right
pane and leaves them to find the row. With 125 entries that is most of the value of searching.

    Scripts/place_search_anchors.py --map /tmp/anchor_map.json          # place them
    Scripts/place_search_anchors.py --map /tmp/anchor_map.json --check  # report, change nothing

The map is {entry id: [file, line]}. It comes from the `source` field the index entries were authored
with, which points at the control the copy was read from.

The insert walks the view expression with a real delimiter scan (respecting strings and comments) and
then swallows any chained modifier lines after it, so the anchor lands on the whole control rather
than in the middle of it. A shape it cannot safely wrap is skipped and reported rather than guessed at.
"""
import argparse
import json
import os
import re
import sys

# `TableColumn` is not a View, so a modifier on it does not compile. Anything else that turns out not
# to be a View shows up as a build error and belongs here too.
SKIP_TOKENS = {"TableColumn"}


def scan(lines, start):
    """Index of the last line of the expression beginning at `start`, chained modifiers included."""
    depth = 0
    in_str = False
    i = start
    opened = False

    while i < len(lines):
        line = lines[i]
        j = 0
        while j < len(line):
            ch = line[j]
            if in_str:
                if ch == "\\":
                    j += 2
                    continue
                if ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch == "/" and j + 1 < len(line) and line[j + 1] == "/":
                break
            elif ch in "([{":
                depth += 1
                opened = True
            elif ch in ")]}":
                depth -= 1
            j += 1

        if opened and depth <= 0:
            # Chained modifiers sit on their own lines after the control. They are part of the same
            # expression, so the anchor goes after the last of them or it wraps only half the view.
            k = i + 1
            while k < len(lines) and lines[k].lstrip().startswith("."):
                k = scan(lines, k) + 1
            return k - 1
        i += 1
    return start


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", required=True)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    anchors = json.load(open(args.map, encoding="utf-8"))

    by_file = {}
    for eid, (path, line) in anchors.items():
        by_file.setdefault(path, []).append((eid, line))

    placed = skipped = already = 0
    notes = []

    for path, items in by_file.items():
        full = os.path.join(root, path)
        lines = open(full, encoding="utf-8").read().splitlines()
        if "searchAnchor" in "\n".join(lines):
            pass  # some may already be placed; each is checked individually below

        # Bottom up, so an insert never moves a line we have not reached yet.
        inserts = []
        for eid, line in sorted(items, key=lambda x: -x[1]):
            idx = line - 1
            if idx < 0 or idx >= len(lines):
                notes.append(f"{eid}: line {line} out of range in {path}")
                skipped += 1
                continue
            token = re.match(r"\s*([A-Za-z_]+)", lines[idx])
            if token and token.group(1) in SKIP_TOKENS:
                notes.append(f"{eid}: {token.group(1)} is not a View, skipped")
                skipped += 1
                continue
            end = scan(lines, idx)
            window = "\n".join(lines[idx:end + 1])
            if "searchAnchor" in window:
                already += 1
                continue
            indent = re.match(r"\s*", lines[idx]).group(0)
            inserts.append((end + 1, f'{indent}    .searchAnchor("{eid}")'))
            placed += 1

        if not args.check:
            for at, text in sorted(inserts, key=lambda x: -x[0]):
                lines.insert(at, text)
            open(full, "w", encoding="utf-8").write("\n".join(lines) + "\n")

    print(f"{placed} placed, {already} already present, {skipped} skipped")
    for n in notes:
        print(f"  {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
