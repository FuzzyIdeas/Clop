#!/usr/bin/env python3
"""Pull a first draft of the settings index out of the SwiftUI that renders it.

The point of the index is that an agent reads what the user reads, so the titles, subtitles and
sections come from the actual controls rather than being invented. This walks the settings views,
finds every control bound to a `$key`, and records the label text, the subtitle Text beside it, and
the Section header it sits under.

    Scripts/extract_settings_index.py            # writes docs/specs/settings-index-draft.json
    Scripts/extract_settings_index.py --report   # plus a summary of what it could not place

The draft is a starting point, NOT the committed index: keywords have to be written by hand, and a
control whose label is built at runtime comes out blank and needs filling in.
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "docs", "specs", "settings-index-draft.json")

# Which view struct belongs to which Settings tab. The tab is not derivable from the file, so this is
# the one hand-maintained part of the extraction.
VIEW_TO_TAB = {
    "GeneralSettingsView": "general",
    "ClipboardSettingsView": "clipboard",
    "FileHandlingSettingsView": "files",
    "VideoSettingsView": "video",
    "AudioSettingsView": "audio",
    "ImagesSettingsView": "images",
    "PDFSettingsView": "pdf",
    "DropZoneSettingsView": "dropzone",
    "PresetZonesSettingsView": "presetZones",
    "FloatingSettingsView": "floating",
    "KeysSettingsView": "keys",
    "PipelinesSettingsView": "pipelines",
    "AutomationSettingsView": "automation",
    "MCPSettingsView": "mcp",
    "LicenseUpdatesSettingsView": "licenseUpdates",
    "AboutSettingsView": "about",
}

FILES = ["Clop/SettingsView.swift", "Clop/PipelineEditorViews.swift", "Clop/MCPSettingsPane.swift",
         "Clop/DropZone.swift", "Clop/BatchCropButton.swift"]

STRUCT_RE = re.compile(r'^\s*struct (\w+)\s*:\s*View\b')
SECTION_RE = re.compile(r'SectionHeader\(\s*title:\s*"((?:[^"\\]|\\.)*)"(?:\s*,\s*subtitle:\s*"((?:[^"\\]|\\.)*)")?')
# Toggle(isOn: $key) / Picker(selection: $key) / Picker("Title", selection: $key) / TextField(..., text: $key)
BIND_RE = re.compile(r'\b(Toggle|Picker|TextField|Slider|Stepper|ColorPicker)\('
                     r'(?:\s*"((?:[^"\\]|\\.)*)"\s*,)?'
                     r'[^)]*?\$(\w+)')
TEXT_RE = re.compile(r'Text\("((?:[^"\\]|\\.)*)"\)')


def strip_comments(src):
    """Drop // and /* */ before scanning.

    `downscaleRetinaImages` is commented out in Settings.swift along with its Toggle, and the first run
    of this script happily produced an index entry for it. The audit caught it; this stops it at source.
    """
    src = re.sub(r'/\*[\s\S]*?\*/', '', src)
    return re.sub(r'^(\s*)//.*$', r'\1', src, flags=re.M)


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\") if s else s


def label_after(lines, i):
    """The title and subtitle Texts belonging to the control starting on line i.

    Clop writes them as one concatenated Text: `Text("Title")... + Text("\\nSubtitle")...`, so the
    first two string literals are what the user reads.

    Two shapes. A Toggle carries its label right after the opening brace. A Picker built as
    `Picker(selection:) { options } label: { ... }` carries it AFTER the options, and the options are
    themselves Texts, so reading forward blindly returns the first option instead of the title. When a
    `label: {` turns up before the next control, the search starts from there.
    """
    window = lines[i:i + 40]
    chunk = "\n".join(window)
    # Stop at the next control so a label is never stolen from the row below. The search has to start
    # past the FIRST LINE, not past character 1: the control we are describing lives on that line and
    # would otherwise match itself, collapsing every window to nothing.
    head = chunk.find("\n")
    nxt = BIND_RE.search(chunk, head + 1) if head >= 0 else None
    if nxt:
        chunk = chunk[:nxt.start()]
    lab = re.search(r'\}\s*label:\s*\{', chunk)
    if lab:
        chunk = chunk[lab.end():]
    else:
        chunk = "\n".join(chunk.split("\n")[:8])
    texts = [unescape(t) for t in TEXT_RE.findall(chunk)]
    title = texts[0].strip() if texts else ""
    subtitle = ""
    for t in texts[1:]:
        if t.startswith("\n"):
            subtitle = t.strip()
            break
    return title, subtitle


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()

    keys_src = strip_comments(open(os.path.join(ROOT, "Clop", "Settings.swift"), encoding="utf-8").read())
    all_keys = {}
    # Non-greedy up to `>("`, or `Key<Set<UTType>>` loses its last angle bracket.
    for m in re.finditer(r'static let (\w+) = Key<(.+?)>\("([^"]+)"', keys_src):
        all_keys[m.group(1)] = m.group(2).strip()

    entries = []
    seen = set()

    for rel in FILES:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        lines = strip_comments(open(path, encoding="utf-8").read()).splitlines()
        view = None
        section_title = section_sub = ""
        for i, line in enumerate(lines):
            sm = STRUCT_RE.match(line)
            if sm:
                view = sm.group(1)
                section_title = section_sub = ""
            hm = SECTION_RE.search(line)
            if hm:
                section_title = unescape(hm.group(1))
                section_sub = unescape(hm.group(2) or "")
            bm = BIND_RE.search(line)
            if not bm:
                continue
            key = bm.group(3)
            if key not in all_keys:
                continue
            inline_title = unescape(bm.group(2) or "")
            title, subtitle = label_after(lines, i)
            if inline_title:
                title, subtitle = inline_title, (subtitle or "")
            tab = VIEW_TO_TAB.get(view or "", "")
            entry_id = f"{tab or 'unknown'}.{re.sub(r'[^a-z0-9]+', '', (section_title or 'main').lower())[:20] or 'main'}.{key}"
            if entry_id in seen:
                continue
            seen.add(entry_id)
            entries.append({
                "id": entry_id,
                "keys": [key],
                "type": all_keys[key],
                "title": title,
                "subtitle": subtitle,
                "section": section_title,
                "sectionSubtitle": section_sub,
                "tab": tab,
                "keywords": [],
                "source": f"{rel}:{i + 1}",
            })

    covered = {k for e in entries for k in e["keys"]}
    missing = sorted(set(all_keys) - covered)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"entries": entries, "uncovered": [{"key": k, "type": all_keys[k]} for k in missing]},
                  f, indent=2, ensure_ascii=False)

    print(f"{len(all_keys)} keys defined")
    print(f"{len(entries)} entries extracted, covering {len(covered)} keys")
    print(f"{len(missing)} keys with no control found")
    blank = [e["id"] for e in entries if not e["title"]]
    print(f"{len(blank)} entries with a blank title (label built at runtime)")
    print(f"\nwrote {os.path.relpath(OUT, ROOT)}")

    if args.report:
        print("\n--- uncovered keys ---")
        for k in missing:
            print(f"  {k}: {all_keys[k]}")
        if blank:
            print("\n--- blank titles ---")
            for b in blank:
                print(f"  {b}")


if __name__ == "__main__":
    main()
