#!/usr/bin/env python3
"""Inject extracted contact emails from parquet into OPML outline elements.

Matches sources by xmlUrl → source_id (SHA-256 of canonical URL), and patches
feedmineContactEmail/Name/Source/Type attributes into each matching <outline />
element in the production OPML tree.

NOTE on the join: the parquet ``source_id`` column holds feed URLs (the
``key`` field from ``catalog_source``), not hex digests. This script therefore
computes ``compute_source_id(url)`` at load time for each parquet row — the
same SHA-256 canonicalization applied to OPML ``xmlUrl`` values — and joins on
the resulting digests. This mirrors the identity function used by
``scripts/inject_enriched_metadata.py``.

Usage:
    python3 scripts/inject_contact_emails.py \
      --parquet build/feeds_corpus_contacts.parquet \
      --feeds-root feedmine/Resources/Feeds \
      --min-status verified   # "verified" | "unverified" | "all"
      --dry-run
"""

from __future__ import annotations

import argparse
import hashlib
import html
import re
import shutil
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import pandas as pd
import pyarrow.parquet as pq


def compute_source_id(url: str) -> str:
    """SHA-256 of canonical URL (mirrors catalog identity function)."""
    parsed = urlsplit(url)
    canonical = urlunsplit(
        (parsed.scheme.lower(),
         parsed.hostname.lower() if parsed.hostname else "",
         parsed.path, parsed.query, "")
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def _escape_xml(s: str) -> str:
    """Escape special XML characters in attribute values."""
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def inject(args: argparse.Namespace) -> dict:
    parquet_path: Path = args.parquet
    feeds_root: Path = args.feeds_root
    min_status: str = args.min_status

    if not parquet_path.exists():
        raise FileNotFoundError(f"Parquet not found: {parquet_path}")
    if not feeds_root.exists():
        raise FileNotFoundError(f"Feeds root not found: {feeds_root}")

    # ── 1. Read contacts parquet ───────────────────────────────────────
    table = pq.read_table(parquet_path)
    df = table.to_pandas()

    if "contact_status" in df.columns:
        if min_status == "verified":
            df = df[df["contact_status"] == "verified"]
        elif min_status == "unverified":
            # "at least unverified": verified + unverified
            df = df[df["contact_status"].isin(["verified", "unverified"])]

    print(f"Loaded {len(df)} contacts (min_status={min_status})")

    # Build source_id → contact data lookup.
    # The parquet source_id column contains feed URLs (catalog_source.key),
    # so hash each one at load time to join against compute_source_id(xmlUrl).
    contacts: dict[str, dict] = {}
    for _, row in df.iterrows():
        raw_sid = str(row["source_id"]).strip()
        if not raw_sid or raw_sid.lower() in ("nan", "none", "<na>"):
            continue
        # Defensive: if a future parquet already stores digests, use as-is.
        sid = raw_sid if re.fullmatch(r"[0-9a-f]{64}", raw_sid) else compute_source_id(raw_sid)
        email = row.get("contact_email")
        if email is None or pd.isna(email) or str(email).strip() == "":
            continue
        contacts[sid] = {
            "email": str(email),
            "name": str(row.get("contact_name", "") or ""),
            "source": str(row.get("contact_source", "") or ""),
            "type": str(row.get("contact_type", "") or ""),
        }
    print(f"Lookup built: {len(contacts)} unique source digests with emails")

    # ── 2. Scan OPML files and inject ──────────────────────────────────
    updated_count = 0
    skipped_count = 0
    files_touched = set()

    backup_dir = feeds_root.parent / "Feeds.backup.contact_inject"
    if not args.dry_run and not args.no_backup:
        if backup_dir.exists():
            shutil.rmtree(backup_dir)
        shutil.copytree(feeds_root, backup_dir)
        print(f"Backup: {backup_dir}")

    for opml_path in sorted(feeds_root.rglob("*.opml")):
        if not opml_path.is_file():
            continue

        content = opml_path.read_text(encoding="utf-8")
        modified = False

        def replace_outline(match):
            nonlocal modified
            element_str = match.group(0)
            url_match = re.search(r'xmlUrl="([^"]*)"', element_str)
            if not url_match:
                return element_str
            url = html.unescape(url_match.group(1))  # OPML stores &amp; for &
            source_id = compute_source_id(url)
            contact = contacts.get(source_id)
            if contact is None:
                return element_str
            if "feedmineContactEmail" in element_str:
                nonlocal skipped_count
                skipped_count += 1
                return element_str

            new_attrs = []
            new_attrs.append(f'feedmineContactEmail="{_escape_xml(contact["email"])}"')
            if contact["name"]:
                new_attrs.append(f'feedmineContactName="{_escape_xml(contact["name"])}"')
            if contact["source"]:
                new_attrs.append(f'feedmineContactSource="{_escape_xml(contact["source"])}"')
            if contact["type"]:
                new_attrs.append(f'feedmineContactType="{_escape_xml(contact["type"])}"')

            attr_str = element_str.rstrip("/>").rstrip()
            existing_attr_names = set(re.findall(r'(\S+)="[^"]*"', element_str))
            for attr in new_attrs:
                attr_name = attr.split("=")[0]
                if attr_name not in existing_attr_names:
                    attr_str += " " + attr
            attr_str += " />"
            modified = True
            nonlocal updated_count
            updated_count += 1
            return attr_str

        new_content = re.sub(r'<outline[^>]+/>', replace_outline, content)
        if modified and not args.dry_run:
            opml_path.write_text(new_content, encoding="utf-8")
            files_touched.add(str(opml_path.relative_to(feeds_root)))
        elif modified:
            files_touched.add(str(opml_path.relative_to(feeds_root)))

    print(f"\n{'='*60}")
    print(f"INJECTION RESULTS:")
    print(f"  Updated:       {updated_count}")
    print(f"  Skipped:       {skipped_count}")
    print(f"  Files touched: {len(files_touched)}")

    if args.dry_run:
        print("\n  DRY RUN — no files were modified")

    return {"updated": updated_count, "skipped": skipped_count, "files_touched": len(files_touched)}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--parquet", type=Path, required=True)
    p.add_argument("--feeds-root", type=Path, default=Path("feedmine/Resources/Feeds"))
    p.add_argument("--min-status", choices=["verified", "unverified", "all"], default="verified")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-backup", action="store_true")
    return p.parse_args()


if __name__ == "__main__":
    result = inject(parse_args())
    print(f"\nDone: {result}")
