#!/usr/bin/env python3
"""Keep the settings index honest about what Clop actually has.

The index is hand-maintained, and nothing in the compiler notices when it drifts: a renamed key leaves
an entry pointing at nothing, and a new setting gets no entry at all. Either way an agent confidently
reads or writes something that stopped existing, and the Settings search field quietly stops finding a
control that is right there.

    Scripts/settings-index-audit.py            # errors only, exit 1 on drift
    Scripts/settings-index-audit.py --coverage # plus which keys still have no entry

Errors (exit 1):
  - an index entry names a key that Settings.swift does not define
  - the MCP key registry names a key that Settings.swift does not define
  - a key in the MCP registry has no index entry, so it has no title for anyone to search
  - two entries share an id

Coverage (never fails): keys with no entry yet. The index is being filled in a tab at a time, so this
is a progress report rather than a problem.
"""
import argparse
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def strip_comments(src):
    """Drop // and /* */ so a commented-out key never counts as defined.

    `downscaleRetinaImages` is commented out in Settings.swift along with its Toggle, and counting it
    is how an entry for a setting that no longer exists gets written.
    """
    src = re.sub(r'/\*[\s\S]*?\*/', '', src)
    return re.sub(r'^\s*//.*$', '', src, flags=re.M)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--coverage", action="store_true")
    args = ap.parse_args()

    settings = strip_comments(read("Clop/Settings.swift"))
    # Non-greedy up to `>("`, or `Key<Set<UTType>>` loses its last angle bracket.
    defined = set(re.findall(r'static let (\w+) = Key<.+?>\("', settings))

    index_src = read("Clop/SettingsSearchIndex.swift")
    entries = re.findall(r'id: "([^"]+)", keys: \[([^\]]*)\]', index_src)
    ids = [e[0] for e in entries]
    indexed = set()
    entry_of = {}
    for eid, keylist in entries:
        for k in re.findall(r'"([^"]+)"', keylist):
            indexed.add(k)
            entry_of.setdefault(k, eid)

    registry_src = strip_comments(read("Clop/MCPSettings.swift"))
    # bool("name", .name) / int(...) / behaviour(...) / enumCases("name", ...)
    registered = set(re.findall(r'\b(?:bool|int|double|string|rawValue|enumCases|behaviour)\(\s*"([^"]+)"', registry_src))

    errors = []

    for k in sorted(indexed - defined):
        errors.append(f"index entry {entry_of[k]!r} names key {k!r}, which Settings.swift does not define")
    for k in sorted(registered - defined):
        errors.append(f"MCP registry names key {k!r}, which Settings.swift does not define")
    for k in sorted(registered - indexed):
        errors.append(f"key {k!r} is writable through MCP but has no index entry, so it has no title")

    dupes = {i for i in ids if ids.count(i) > 1}
    for d in sorted(dupes):
        errors.append(f"duplicate entry id {d!r}")

    print(f"{len(defined)} keys defined, {len(indexed)} indexed, {len(registered)} writable through MCP")

    if args.coverage:
        missing = sorted(defined - indexed)
        print(f"\n{len(missing)} keys with no index entry yet:")
        for k in missing:
            print(f"  {k}")

    if errors:
        print(f"\n{len(errors)} problem(s):", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1

    print("no drift")
    return 0


if __name__ == "__main__":
    sys.exit(main())
