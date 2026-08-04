#!/usr/bin/env python3
"""
Curate iTunes podcast search results into the parquet pipeline.

Reads raw iTunes search JSONs from scripts/scripts/feed_discovery/cache/subregion/*/itunes/,
deduplicates by feedUrl, maps iTunes country codes → FeedMine country slugs,
and injects new feeds into feeds_corpus_sources.parquet as pending.

Usage:
  python scripts/curate_itunes_podcasts.py --dry-run
  python scripts/curate_itunes_podcasts.py --write
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

try:
    from scripts.catalog_identity import canonical_url, compute_source_id, request_url
except ModuleNotFoundError:
    from catalog_identity import canonical_url, compute_source_id, request_url

REPO_ROOT = Path(__file__).resolve().parents[1]
CACHE_BASE = REPO_ROOT / "scripts" / "scripts" / "feed_discovery" / "cache" / "subregion"
SOURCES_PATH = REPO_ROOT / "feeds_corpus_sources.parquet"
MEMBERSHIPS_PATH = REPO_ROOT / "feeds_corpus_source_memberships.parquet"

# iTunes 3-letter ISO → FeedMine country slug
ISO3_TO_SLUG = {
    "IDN": "indonesia",
    "ROU": "romania",
    "IND": "india",
    "CHN": "china",
    "PHL": "philippines",
    "RUS": "russia",
    "NGA": "nigeria",
    "PAK": "pakistan",
    "ETH": "ethiopia",
    "BGD": "bangladesh",
    "EGY": "egypt",
    "ECU": "ecuador",
}


def stable_id(namespace: str, value: str) -> str:
    import hashlib
    return hashlib.sha256(f"{namespace}:{value}".encode("utf-8")).hexdigest()


def compute_canonical_xml_url(url: str) -> str:
    return canonical_url(url)


def make_membership_id(source_id: str, collection: str, topic: str, subcategory: str,
                       claimed_language: str, region: str, claimed_country: str,
                       opml_file: str, opml_title: str, claimed_media_kind: str) -> str:
    identity = "|".join([
        collection, topic, subcategory,
        claimed_language, region, claimed_country,
        opml_file, opml_title, claimed_media_kind,
    ])
    return stable_id("membership", f"{source_id}|{identity}")


def _norm_canonical(u: str) -> str:
    return canonical_url(u)


def main():
    write_mode = "--write" in sys.argv

    if not write_mode:
        print("🔍 DRY RUN — use --write to apply\n")
    else:
        print("✍️  WRITE MODE\n")

    # --- Load existing parquet ---
    sources_table = pq.read_table(SOURCES_PATH)
    sources_df = sources_table.to_pandas()
    memberships_table = pq.read_table(MEMBERSHIPS_PATH)
    memberships_df = memberships_table.to_pandas()

    print(f"Existing sources: {len(sources_df):,}")
    print(f"Existing memberships: {len(memberships_df):,}")

    # Dedup sets
    existing_canonical = set(_norm_canonical(u) for u in sources_df["canonical_xml_url"])
    seen_membership = set(str(m) for m in memberships_df["membership_id"])

    # --- Scan iTunes cache ---
    podcasts = {}  # feedUrl → podcast info

    for root, dirs, files in os.walk(CACHE_BASE):
        if "itunes" not in root:
            continue
        # Determine country from parent dir: e.g. "ethiopia-sidama" → "ethiopia"
        parent = Path(root).parent.name
        subregion_country = parent.split("-")[0] if "-" in parent else parent

        for fname in files:
            if not fname.endswith(".json"):
                continue
            fpath = os.path.join(root, fname)
            try:
                data = json.loads(Path(fpath).read_text(encoding="utf-8"))
            except Exception:
                continue

            for result in data.get("results", []):
                feed_url = result.get("feedUrl", "").strip()
                if not feed_url:
                    continue

                # Dedup by feedUrl — keep first occurrence
                if feed_url.lower() in podcasts:
                    continue

                itunes_country = result.get("country", "")
                country_slug = ISO3_TO_SLUG.get(itunes_country, subregion_country)

                podcasts[feed_url.lower()] = {
                    "feed_url": feed_url,
                    "title": result.get("collectionName", "") or result.get("trackName", ""),
                    "artist": result.get("artistName", ""),
                    "genre": result.get("primaryGenreName", ""),
                    "country": country_slug,
                    "itunes_country": itunes_country,
                    "track_count": result.get("trackCount", 0),
                }

    print(f"\niTunes podcasts found: {len(podcasts):,}")

    # --- Filter to new feeds ---
    new_podcasts = {}
    for feed_url_lower, info in podcasts.items():
        canonical = compute_canonical_xml_url(info["feed_url"])
        if canonical in existing_canonical:
            continue
        existing_canonical.add(canonical)
        new_podcasts[feed_url_lower] = info

    print(f"New (not in parquet): {len(new_podcasts):,}")

    if not new_podcasts:
        print("Nothing to inject!")
        return

    # --- Build source rows ---
    new_sources = []
    new_memberships = []
    by_country = {}

    for feed_url_lower, info in new_podcasts.items():
        url = info["feed_url"]
        sid = compute_source_id(url)
        canonical = compute_canonical_xml_url(url)
        title = (info["title"] or info["artist"] or url)[:300]
        genre = info["genre"]
        country_slug = info["country"]
        country_fs = country_slug.replace("-", "_")

        new_sources.append({
            "source_id": sid,
            "source_title": str(title),
            "xml_url": request_url(url),
            "canonical_xml_url": canonical,
            "site_url": "",
            "feed_title": str(title),
            "feed_description": f"Podcast — {genre} from {country_slug} (iTunes)",
            "feed_reported_language": "",
            "status": "pending",
            "error_message": "",
            "parser_warning": "",
            "articles_fetched": 0,
            "attempt_count": 0,
            "attempted_at": None,
            "fetched_at": None,
            "fetch_duration_ms": None,
            "response_time_ms": None,
            "ttfb_ms": None,
            "http_status": 0,
            "response_bytes": None,
            "final_url": "",
            "content_type": "",
            "latest_item_at": None,
            "oldest_item_at": None,
            "ai_description": "",
            "ai_tags": "",
        })

        opml_file = f"90_countries/{country_fs}/{country_fs}.opml"
        mid = make_membership_id(
            source_id=sid,
            collection="90_countries",
            topic="Music & Audio",
            subcategory="Podcasts",
            claimed_language="",
            region="global",
            claimed_country=country_slug,
            opml_file=opml_file,
            opml_title=country_fs,
            claimed_media_kind="audio",
        )

        if mid in seen_membership:
            continue
        seen_membership.add(mid)

        new_memberships.append({
            "membership_id": mid,
            "source_id": sid,
            "collection": "90_countries",
            "topic": "Music & Audio",
            "subcategory": "Podcasts",
            "claimed_language": "",
            "region": "global",
            "claimed_country": country_slug,
            "opml_file": opml_file,
            "opml_title": country_fs,
            "claimed_media_kind": "audio",
        })

        by_country[country_slug] = by_country.get(country_slug, 0) + 1

    print(f"\nSources to inject: {len(new_sources):,}")
    print(f"Memberships to inject: {len(new_memberships):,}")
    print(f"\nBy country:")
    for c, n in sorted(by_country.items(), key=lambda x: -x[1]):
        print(f"  {c}: {n}")

    if not write_mode:
        print("\n🔍 DRY RUN complete. Use --write to apply.")
        return

    # --- Write ---
    shutil.copy2(SOURCES_PATH, SOURCES_PATH.with_name("feeds_corpus_sources.backup.parquet"))
    shutil.copy2(MEMBERSHIPS_PATH, MEMBERSHIPS_PATH.with_name("feeds_corpus_source_memberships.backup.parquet"))
    print("\nBackups created.")

    # Write sources
    new_sources_df = pd.DataFrame(new_sources)
    for col in sources_df.columns:
        if col not in new_sources_df.columns:
            new_sources_df[col] = None
    new_sources_df = new_sources_df[sources_df.columns]
    merged_sources = pd.concat([sources_df, new_sources_df], ignore_index=True)
    merged_sources_table = pa.Table.from_pandas(merged_sources, schema=sources_table.schema)
    tmp_src = SOURCES_PATH.with_name(f".{SOURCES_PATH.name}.tmp")
    pq.write_table(merged_sources_table, tmp_src, compression="zstd")
    os.replace(tmp_src, SOURCES_PATH)
    print(f"✅ Sources: {len(merged_sources):,} rows (+{len(new_sources_df):,})")

    # Write memberships
    new_mem_df = pd.DataFrame(new_memberships)
    for col in memberships_df.columns:
        if col not in new_mem_df.columns:
            new_mem_df[col] = ""
    new_mem_df = new_mem_df[memberships_df.columns]
    merged_mem = pd.concat([memberships_df, new_mem_df], ignore_index=True)
    merged_mem_table = pa.Table.from_pandas(merged_mem, schema=memberships_table.schema)
    tmp_mem = MEMBERSHIPS_PATH.with_name(f".{MEMBERSHIPS_PATH.name}.tmp")
    pq.write_table(merged_mem_table, tmp_mem, compression="zstd")
    os.replace(tmp_mem, MEMBERSHIPS_PATH)
    print(f"✅ Memberships: {len(merged_mem):,} rows (+{len(new_mem_df):,})")

    print(f"\n✅ Injection complete. Run fetch_new_feeds.py to fetch these podcasts.")


if __name__ == "__main__":
    main()
