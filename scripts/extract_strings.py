#!/usr/bin/env python3
"""
Extract ALL localizable strings from FeedMine Swift source files.

Scans every .swift file and finds:
  - Text("..."), Text("...", comment: ...)
  - String(localized: "...", comment: "...")
  - Button("..."), Toggle("...", ...), Label("...", ...)
  - Section("..."), .navigationTitle("..."), .alert("...", ...)
  - .confirmationDialog("...", ...), TextField("...", ...)
  - Menu("..."), .sheet / fullScreenCover item titles
  - Picker titles and segment labels
  - LocalizedStringKey("...")

Output: A clean JSON template ready for translation.
"""
import re, json, os, sys
from pathlib import Path
from collections import defaultdict

ROOT = Path(__file__).resolve().parent.parent / "feedmine"
OUTPUT = Path(__file__).resolve().parent.parent / "feedmine" / "Resources" / "string_template.json"

# ── Patterns ──
# Each pattern is (regex, group_index_for_string, optional_comment_group)
# We look for string literals used in localization contexts
PATTERNS = [
    # String(localized: "string", comment: "comment")
    (r'String\(\s*localized:\s*"((?:[^"\\]|\\.)*)"\s*,\s*comment:\s*"((?:[^"\\]|\\.)*)"',
     1, 2),

    # String(localized: "string")   — no comment variant
    (r'String\(\s*localized:\s*"((?:[^"\\]|\\.)*)"\s*\)',
     1, None),

    # Text(verbatim:) — NOT localized, EXCLUDE
    # We don't match these.

    # Text("string") or Text("string", comment: "...")  — NOT verbatim
    # Must NOT be preceded by "verbatim:"
    (r'(?<!verbatim:\s)Text\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # LocalizedStringKey("string")
    (r'LocalizedStringKey\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # Button("string") or Button("string", ...)
    (r'Button\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # Label("string", systemImage:) or Label("string", image:)
    (r'Label\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # Toggle("string", ...)
    (r'Toggle\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # TextField("string", ...)
    (r'TextField\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # Section("string") or Section("string") { — header as string literal
    (r'Section\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # Menu("string", ...)
    (r'Menu\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # Picker("string", ...)
    (r'Picker\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # .navigationTitle("string")
    (r'\.navigationTitle\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # .navigationBarTitle("string")
    (r'\.navigationBarTitle\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # .alert("string", isPresented:)
    (r'\.alert\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # .confirmationDialog("string", isPresented:)
    (r'\.confirmationDialog\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # .sheet / fullScreenCover titles in toolbar
    # .searchable("string")
    (r'\.searchable\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # .accessibilityLabel("string")
    (r'\.accessibilityLabel\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),

    # Link("string", destination:)
    (r'Link\(\s*"((?:[^"\\]|\\.)*)"',
     1, None),
]

# Strings to EXCLUDE (separators, format-only, non-translatable)
EXCLUDE = {
    "", " ", "  ", " · ", "·",
}

def is_translatable(string: str) -> bool:
    """Return True if this string should be translated."""
    if string in EXCLUDE:
        return False
    # Skip strings with Swift string interpolation — the compiler handles those
    if "\\(" in string:
        return False
    # Skip purely format specifiers / separators
    if re.match(r'^[%@#\s\.·🎧⏳✓⟳↓\[\]\(\)\{\}<>/\\|_\-+=*&^%$!~`;:,?]+$', string):
        return False
    # Skip numeric strings
    if re.match(r'^\d+(\.\d+)?$', string):
        return False
    # Skip file paths / URLs
    if string.startswith("http") or string.startswith("/"):
        return False
    return True

def extract_from_file(filepath: Path) -> dict:
    """Extract all localizable strings from a Swift file."""
    try:
        content = filepath.read_text()
    except Exception:
        return {}

    found = {}
    relpath = str(filepath.relative_to(ROOT.parent))

    for pattern, str_group, comment_group in PATTERNS:
        for m in re.finditer(pattern, content):
            raw = m.group(str_group)
            # Resolve escape sequences
            string = raw.replace('\\"', '"').replace('\\n', '\n').replace('\\t', '\t')
            string = string.strip()
            if not is_translatable(string):
                continue

            comment = None
            if comment_group:
                comment = m.group(comment_group)

            line_no = content[:m.start()].count('\n') + 1
            if string not in found:
                found[string] = {
                    "files": [],
                    "comment": comment,
                }
            found[string]["files"].append(f"{relpath}:{line_no}")
            if comment and not found[string]["comment"]:
                found[string]["comment"] = comment

    return found


def main():
    all_strings = {}

    # Walk all .swift files
    for swift_file in sorted(ROOT.rglob("*.swift")):
        found = extract_from_file(swift_file)
        for key, info in found.items():
            if key not in all_strings:
                all_strings[key] = info
            else:
                all_strings[key]["files"].extend(info["files"])
                if info["comment"] and not all_strings[key]["comment"]:
                    all_strings[key]["comment"] = info["comment"]

    # Sort alphabetically
    sorted_strings = dict(sorted(all_strings.items(), key=lambda x: x[0].lower()))

    # Build output
    output = {
        "_meta": {
            "total_strings": len(sorted_strings),
            "source_language": "en",
            "instructions": "Add translations under each string key. "
                           "Use the 'comment' field for context. "
                           "Run translate.py to convert this into Localizable.xcstrings."
        },
        "strings": {}
    }

    for key, info in sorted_strings.items():
        entry = {
            "files": info["files"],
        }
        if info["comment"]:
            entry["comment"] = info["comment"]
        output["strings"][key] = entry

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT, 'w') as f:
        json.dump(output, f, indent=2, ensure_ascii=False)

    print(f"Extracted {len(sorted_strings)} unique strings from .swift files")
    print(f"Template saved to: {OUTPUT}")

    # Show a sample
    for i, (k, v) in enumerate(sorted_strings.items()):
        if i < 15:
            files = v["files"][:2]
            loc = ", ".join(files)
            comment = f'  # {v["comment"]}' if v.get("comment") else ''
            print(f"  [{k}]{comment}")
            print(f"    → {loc}")

if __name__ == "__main__":
    main()
