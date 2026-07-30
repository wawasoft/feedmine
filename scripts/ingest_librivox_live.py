#!/usr/bin/env python3
"""Filter librivox-pod verify report → clean OPMLs → catalog.sqlite

Reads the feedmine-verify JSON report, keeps only ok+redirected feeds,
reconstructs clean OPML files grouped by source, and runs build_catalog.py.
"""

from __future__ import annotations

import json
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


LIVE_STATUSES = {"ok", "redirected"}

OPML_DIR = Path.home() / "Downloads" / "librivox-pod"
REPORT_PATH = OPML_DIR.with_name("librivox-pod_verify_report.json")
OUTPUT_FEEDS = Path("/tmp/feedmine-ingest/Feeds")
CATALOG_OUTPUT = Path("/tmp/feedmine-ingest/catalog.sqlite")
BUILD_CATALOG = Path(__file__).resolve().parent / "build_catalog.py"


def main() -> int:
    if not REPORT_PATH.exists():
        print(f"Report not found: {REPORT_PATH}", file=sys.stderr)
        return 1

    print(f"📄 Loading report: {REPORT_PATH}")
    with open(REPORT_PATH) as f:
        report = json.load(f)

    results = report["results"]
    total = len(results)
    print(f"   {total} total results")

    # Group live feeds by source file
    live_by_file: dict[str, list[dict]] = defaultdict(list)
    dead_count = 0
    error_count = 0

    for r in results:
        if r["status"] in LIVE_STATUSES:
            for sf in r["source_files"]:
                live_by_file[sf].append(r)
        elif r["status"] == "dead":
            dead_count += 1
        else:
            error_count += 1

    live_total = sum(len(v) for v in live_by_file.values())
    print(f"   {live_total} live occurrences across {len(live_by_file)} files")
    print(f"   {dead_count} dead, {error_count} errors skipped")
    print()

    # Rebuild clean OPML files
    OUTPUT_FEEDS.mkdir(parents=True, exist_ok=True)

    file_counts: dict[str, int] = {}
    for rel_path, feeds in sorted(live_by_file.items()):
        # Read original OPML to get head metadata
        src_path = OPML_DIR / rel_path
        dest_path = OUTPUT_FEEDS / rel_path
        dest_path.parent.mkdir(parents=True, exist_ok=True)

        if not src_path.exists():
            print(f"   ⚠️  Source not found: {src_path}, skipping")
            continue

        # Parse live URLs set for this file
        live_urls = {r["url"] for r in feeds}

        # Parse original OPML
        try:
            tree = ET.parse(str(src_path))
            root = tree.getroot()
        except ET.ParseError as e:
            print(f"   ❌ Parse error in {rel_path}: {e}")
            continue

        # Find body
        body = root.find("body")
        if body is None:
            print(f"   ⚠️  No body in {rel_path}, skipping")
            continue

        # Remove dead outlines (keep containers/categories)
        _filter_dead_outlines(body, live_urls)

        # Write filtered OPML
        ET.indent(root, space="  ")
        tree.write(str(dest_path), encoding="utf-8", xml_declaration=True, short_empty_elements=True)

        # Count remaining feeds
        remaining = sum(1 for _ in root.iter("outline") if _.get("xmlUrl"))
        file_counts[rel_path] = remaining

    print("📊 Clean OPMLs written:")
    for fname, count in sorted(file_counts.items(), key=lambda x: -x[1])[:15]:
        print(f"   {fname:50s} {count:6d} feeds")
    if len(file_counts) > 15:
        print(f"   ... and {len(file_counts) - 15} more")
    print()

    # --- Run build_catalog.py ---
    if not BUILD_CATALOG.exists():
        print(f"❌ build_catalog.py not found at {BUILD_CATALOG}", file=sys.stderr)
        return 1

    print(f"🔨 Building catalog with: {BUILD_CATALOG}")
    print(f"   Feeds root: {OUTPUT_FEEDS}")
    print(f"   Output:     {CATALOG_OUTPUT}")
    print()

    result = subprocess.run(
        [
            sys.executable, str(BUILD_CATALOG),
            "--feeds-root", str(OUTPUT_FEEDS),
            "--output", str(CATALOG_OUTPUT),
            "--json",
        ],
        capture_output=True, text=True,
    )

    if result.returncode != 0:
        print(f"❌ build_catalog failed (exit {result.returncode}):")
        print(result.stderr)
        return 1

    try:
        catalog_info = json.loads(result.stdout)
    except json.JSONDecodeError:
        print(result.stdout)
        return 1

    print("✅ Catalog built successfully!")
    for k, v in catalog_info.items():
        if k == "output":
            size_mb = catalog_info.get("size_bytes", 0) / (1024 * 1024)
            print(f"   {k}: {v} ({size_mb:.1f} MB)")
        else:
            print(f"   {k}: {v}")

    print()
    print(f"📦 Catalog ready: {CATALOG_OUTPUT}")
    print(f"   To use in feedmine, copy to: feedmine/Resources/FeedEngine/catalog.sqlite")
    return 0


def _filter_dead_outlines(element: ET.Element, live_urls: set[str]) -> None:
    """Remove <outline> elements whose xmlUrl is not in live_urls.
    Preserves container outlines (no xmlUrl) that still have children.
    """
    to_remove = []
    for child in list(element):
        if child.tag != "outline":
            continue
        xml_url = (child.get("xmlUrl") or "").strip()
        if xml_url:
            if xml_url not in live_urls:
                to_remove.append(child)
        else:
            # Container — recurse, then remove if empty
            _filter_dead_outlines(child, live_urls)
            # Check if any live feed remains as descendant
            has_live = any(
                (desc.get("xmlUrl") or "").strip() in live_urls
                for desc in child.iter("outline")
            )
            if not has_live:
                to_remove.append(child)

    for child in to_remove:
        element.remove(child)


if __name__ == "__main__":
    raise SystemExit(main())
