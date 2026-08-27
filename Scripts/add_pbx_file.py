#!/usr/bin/env python3
"""Add Swift source files (and resources) to Clop.xcodeproj/project.pbxproj.

The Clop project uses an explicit file list, not a synchronized folder group, so a new
Clop/Foo.swift is silently NOT compiled until it appears in four places in the pbxproj. A build
still succeeds until something references the missing symbols, which makes this easy to miss.

    Scripts/add_pbx_file.py Foo.swift Bar.swift          # sources
    Scripts/add_pbx_file.py --resource clop_mcp.py       # bundled resource

Each file gets two fresh 24-hex-uppercase UUIDs and four entries: a PBXBuildFile, a
PBXFileReference, a child of the Clop group, and a member of the Sources (or Resources) build phase.
Anchors are validated to appear exactly once before anything is written, and the file is left
untouched when a name is already present.
"""
import argparse
import os
import random
import re
import sys

PROJ = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Clop.xcodeproj", "project.pbxproj")

# An existing file whose four lines are unambiguous, used to locate each list.
ANCHOR = "CropWindow.swift"
# A resource already in the Copy Bundle Resources phase. Needed because ANCHOR only appears in the
# Sources phase, so --resource used to add the file to Sources with a "in Resources" label, which
# builds fine and quietly ships nothing.
RESOURCE_ANCHOR = "bin.tar.lrz"

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".py": "text.script.python",
    ".sh": "text.script.sh",
    ".json": "text.json",
}


def uuid(existing):
    while True:
        u = "".join(random.choice("0123456789ABCDEF") for _ in range(24))
        if u not in existing:
            existing.add(u)
            return u


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--resource", action="store_true",
                    help="add to the Resources build phase instead of Sources")
    args = ap.parse_args()

    with open(PROJ, encoding="utf-8") as f:
        text = f.read()

    phase = "Resources" if args.resource else "Sources"

    # Locate the anchor's four lines. Each must be unique or the insert point is a guess.
    anchors = {
        "build": re.compile(r"^(\t\t[0-9A-F]{24} /\* %s in Sources \*/ = \{isa = PBXBuildFile.*\n)" % re.escape(ANCHOR), re.M),
        "ref": re.compile(r"^(\t\t[0-9A-F]{24} /\* %s \*/ = \{isa = PBXFileReference.*\n)" % re.escape(ANCHOR), re.M),
        "group": re.compile(r"^(\t\t\t\t[0-9A-F]{24} /\* %s \*/,\n)" % re.escape(ANCHOR), re.M),
        "phase": re.compile(
            r"^(\t\t\t\t[0-9A-F]{24} /\* %s in %s \*/,\n)"
            % (re.escape(RESOURCE_ANCHOR if args.resource else ANCHOR), phase), re.M),
    }
    for name, pat in anchors.items():
        n = len(pat.findall(text))
        if n != 1:
            sys.exit(f"anchor '{name}' for {ANCHOR} matched {n} times, expected exactly 1")

    existing = set(re.findall(r"\b[0-9A-F]{24}\b", text))
    added = []

    for path in args.files:
        name = os.path.basename(path)
        if re.search(r"/\* %s \*/ = \{isa = PBXFileReference" % re.escape(name), text):
            print(f"skip {name}, already in the project")
            continue
        ext = os.path.splitext(name)[1]
        ftype = FILE_TYPES.get(ext)
        if not ftype:
            sys.exit(f"unknown file type for {name}")

        b, f_ = uuid(existing), uuid(existing)
        text = anchors["build"].sub(
            lambda m: m.group(1) + f"\t\t{b} /* {name} in {phase} */ = {{isa = PBXBuildFile; fileRef = {f_} /* {name} */; }};\n",
            text, count=1)
        text = anchors["ref"].sub(
            lambda m: m.group(1) + f"\t\t{f_} /* {name} */ = {{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = {ftype}; path = {name}; sourceTree = \"<group>\"; }};\n",
            text, count=1)
        text = anchors["group"].sub(
            lambda m: m.group(1) + f"\t\t\t\t{f_} /* {name} */,\n", text, count=1)
        text = anchors["phase"].sub(
            lambda m: m.group(1) + f"\t\t\t\t{b} /* {name} in {phase} */,\n", text, count=1)
        added.append(name)

    if not added:
        print("nothing to add")
        return

    with open(PROJ, "w", encoding="utf-8") as f:
        f.write(text)
    for name in added:
        print(f"added {name}")
    print("\nConfirm with: rg -c '<name>' Clop.xcodeproj/project.pbxproj  (expect 4)")


if __name__ == "__main__":
    main()
