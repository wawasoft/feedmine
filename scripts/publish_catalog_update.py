#!/usr/bin/env python3
"""Publish the bundled OPML tree as a versioned FeedMine update snapshot."""

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
from urllib.parse import urlsplit, urlunsplit

try:
    from scripts.catalog_identity import canonical_url, compute_source_id, decode_url_entities
except ModuleNotFoundError:  # Direct ``python scripts/...`` execution.
    from catalog_identity import canonical_url, compute_source_id, decode_url_entities


SCHEMA_VERSION = 1


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def next_revision(destination: Path) -> int:
    manifest_path = destination / "manifest.json"
    if not manifest_path.exists():
        return 1
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    revision = manifest.get("revision")
    if not isinstance(revision, int) or revision < 1:
        raise ValueError(f"invalid existing revision in {manifest_path}")
    return revision + 1


def sync_opml_tree(source_root: Path, destination_root: Path, source_files: list[Path]) -> list[Path]:
    """Replace the complete Feeds tree with rollback on any failure."""
    destination_root.parent.mkdir(parents=True, exist_ok=True)
    stage_parent = Path(tempfile.mkdtemp(
        prefix=".feedmine-publish-stage-", dir=destination_root.parent
    ))
    staged_root = stage_parent / "Feeds"
    rollback_root = stage_parent / "previous-Feeds"
    try:
        for source_path in source_files:
            relative = source_path.relative_to(source_root)
            staged_path = staged_root / relative
            staged_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_path, staged_path)
        # Verify staged bytes before the old tree is moved.
        for source_path in source_files:
            relative = source_path.relative_to(source_root)
            if sha256(source_path) != sha256(staged_root / relative):
                raise IOError(f"staged copy hash mismatch: {relative}")

        had_previous = destination_root.exists()
        if had_previous:
            os.replace(destination_root, rollback_root)
        try:
            os.replace(staged_root, destination_root)
        except Exception:
            if had_previous and rollback_root.exists():
                os.replace(rollback_root, destination_root)
            raise
        if rollback_root.exists():
            shutil.rmtree(rollback_root)
    finally:
        shutil.rmtree(stage_parent, ignore_errors=True)
    return [destination_root / path.relative_to(source_root) for path in source_files]


def canonical_catalog_url(raw: str) -> str:
    return canonical_url(raw)


def validate_sources(paths: list[Path]) -> int:
    sources: set[str] = set()
    errors: list[str] = []
    for path in paths:
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as error:
            errors.append(f"{path}: invalid XML: {error}")
            continue
        for element in root.iter():
            url = element.attrib.get("xmlUrl")
            if url:
                identity = canonical_catalog_url(url)
                expected_source_id = compute_source_id(identity)
                actual_source_id = element.attrib.get("feedmineSourceId")
                if actual_source_id != expected_source_id:
                    errors.append(
                        f"{path}: {url!r}: feedmineSourceId does not match canonical identity"
                    )
                if decode_url_entities(url) != url:
                    errors.append(f"{path}: {url!r}: URL contains a residual XML entity")
                sources.add(identity)
    if errors:
        raise ValueError(
            f"catalog validation found {len(errors)} error(s):\n" + "\n".join(errors)
        )
    return len(sources)


def write_json_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def publish(args: argparse.Namespace) -> dict:
    source_root = args.source_root.resolve()
    destination = args.destination.resolve()
    catalog_metadata = json.loads(args.catalog_manifest.read_text(encoding="utf-8"))
    source_count = catalog_metadata.get("source_count")
    if not isinstance(source_count, int) or source_count < 1:
        raise ValueError("catalog manifest does not contain a positive source_count")

    source_files = sorted(path for path in source_root.rglob("*.opml") if path.is_file())
    if not source_files:
        raise ValueError(f"no OPML files found below {source_root}")
    expected_file_count = catalog_metadata.get("file_count")
    if expected_file_count != len(source_files):
        raise ValueError(
            f"catalog manifest file_count is {expected_file_count}; OPML tree has {len(source_files)}"
        )
    # Validate every source before writing a single destination file.
    actual_source_count = validate_sources(source_files)
    if actual_source_count != source_count:
        raise ValueError(
            f"catalog manifest source_count is {source_count}; OPML tree has {actual_source_count}"
        )
    revision = args.revision if args.revision is not None else next_revision(destination)
    if revision < 1:
        raise ValueError("revision must be positive")

    published_files = sync_opml_tree(source_root, destination / "Feeds", source_files)

    entries = []
    for path in published_files:
        relative = path.relative_to(destination).as_posix()
        entries.append({"bytes": path.stat().st_size, "path": relative, "sha256": sha256(path)})

    manifest = {
        "fileCount": len(entries),
        "files": entries,
        "generatedAt": args.generated_at
        or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "revision": revision,
        "schemaVersion": SCHEMA_VERSION,
        "sourceCount": source_count,
    }
    write_json_atomic(destination / "manifest.json", manifest)
    if args.bundle_manifest is not None:
        write_json_atomic(args.bundle_manifest.resolve(), manifest)
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path("feedmine/Resources/Feeds"),
        help="curated OPML root",
    )
    parser.add_argument(
        "--catalog-manifest",
        type=Path,
        default=Path("feedmine/Resources/FeedEngine/catalog-manifest.json"),
        help="compiled catalog metadata used to assert source count",
    )
    parser.add_argument("--destination", type=Path, required=True, help="feed-repository checkout")
    parser.add_argument("--revision", type=int, help="explicit monotonically increasing revision")
    parser.add_argument("--generated-at", help="fixed ISO-8601 timestamp (primarily for tests)")
    parser.add_argument(
        "--bundle-manifest",
        type=Path,
        default=Path("feedmine/Resources/FeedEngine/catalog-update-manifest.json"),
        help="manifest embedded as the app's bootstrap revision",
    )
    return parser.parse_args()


if __name__ == "__main__":
    result = publish(parse_args())
    print(
        f"published revision {result['revision']}: "
        f"{result['fileCount']} OPML files, {result['sourceCount']} unique sources"
    )
