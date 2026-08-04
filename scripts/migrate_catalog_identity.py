#!/usr/bin/env python3
"""Migrate OPML request URLs and FeedMine IDs using a real XML parser.

The command is a dry run unless ``--write`` is supplied.  A write first stages
and validates every changed XML document, records a journal, copies originals
to a recovery directory and then replaces files.  Any replacement failure
restores every file already touched.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

try:
    from scripts.catalog_identity import compute_source_id, request_url, valid_http_url
except ModuleNotFoundError:  # Direct ``python scripts/...`` execution.
    from catalog_identity import compute_source_id, request_url, valid_http_url


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def parse_document(payload: bytes) -> ET.ElementTree:
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    return ET.ElementTree(ET.fromstring(payload, parser=parser))


def migrate_document(payload: bytes, source: Path) -> tuple[bytes, int, list[str]]:
    tree = parse_document(payload)
    changes = 0
    errors: list[str] = []
    for element in tree.getroot().iter():
        if not isinstance(element.tag, str) or element.tag.rsplit("}", 1)[-1] != "outline":
            continue
        raw_url = element.attrib.get("xmlUrl")
        if not raw_url:
            continue
        fetch_url = request_url(raw_url)
        if not valid_http_url(fetch_url):
            errors.append(f"{source}: invalid xmlUrl {raw_url!r}")
            continue
        expected_id = compute_source_id(fetch_url)
        if fetch_url != raw_url:
            element.set("xmlUrl", fetch_url)
            changes += 1
        if element.attrib.get("feedmineSourceId") != expected_id:
            element.set("feedmineSourceId", expected_id)
            changes += 1

    if errors or changes == 0:
        return payload, changes, errors
    ET.indent(tree, space="  ")
    output = ET.tostring(tree.getroot(), encoding="utf-8", xml_declaration=True)
    # Parse the exact serialized bytes before they can be staged or published.
    parse_document(output)
    return output, changes, errors


def write_json_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def migrate(root: Path, *, write: bool, journal_path: Path) -> dict:
    root = root.resolve()
    files = sorted(path for path in root.rglob("*.opml") if path.is_file())
    if not files:
        raise ValueError(f"no OPML files found below {root}")

    staged_payloads: dict[Path, bytes] = {}
    total_changes = 0
    errors: list[str] = []
    entries: list[dict[str, object]] = []
    for path in files:
        original = path.read_bytes()
        migrated, changes, file_errors = migrate_document(original, path)
        errors.extend(file_errors)
        total_changes += changes
        if migrated != original:
            relative = path.relative_to(root)
            staged_payloads[relative] = migrated
            entries.append({
                "path": relative.as_posix(),
                "changes": changes,
                "before_sha256": sha256_bytes(original),
                "after_sha256": sha256_bytes(migrated),
            })
    if errors:
        raise ValueError("OPML identity migration rejected:\n" + "\n".join(errors))

    summary = {
        "files_scanned": len(files),
        "files_changed": len(staged_payloads),
        "attribute_changes": total_changes,
        "write": write,
    }
    if not write or not staged_payloads:
        return summary

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    recovery_root = root.parent / ".catalog-identity-backup" / timestamp
    stage_root = Path(tempfile.mkdtemp(prefix=".catalog-identity-stage-", dir=root.parent))
    journal = {
        **summary,
        "status": "preparing",
        "root": str(root),
        "recovery_root": str(recovery_root),
        "entries": entries,
    }
    try:
        for relative, payload in staged_payloads.items():
            staged = stage_root / relative
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_bytes(payload)
            parse_document(staged.read_bytes())
            original = root / relative
            backup = recovery_root / relative
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, backup)
        journal["status"] = "prepared"
        write_json_atomic(journal_path, journal)

        replaced: list[Path] = []
        try:
            for relative in sorted(staged_payloads):
                os.replace(stage_root / relative, root / relative)
                replaced.append(relative)
        except Exception:
            for relative in reversed(replaced):
                shutil.copy2(recovery_root / relative, root / relative)
            journal["status"] = "rolled_back"
            write_json_atomic(journal_path, journal)
            raise
        journal["status"] = "committed"
        write_json_atomic(journal_path, journal)
    finally:
        shutil.rmtree(stage_root, ignore_errors=True)
    return {**summary, "journal": str(journal_path), "recovery_root": str(recovery_root)}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("feedmine/Resources/Feeds"))
    parser.add_argument("--write", action="store_true")
    parser.add_argument(
        "--journal",
        type=Path,
        default=Path("build/catalog-identity-migration-journal.json"),
    )
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    print(json.dumps(
        migrate(arguments.root, write=arguments.write, journal_path=arguments.journal.resolve()),
        indent=2,
        sort_keys=True,
    ))
