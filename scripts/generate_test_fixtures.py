#!/usr/bin/env python3
"""
Deterministic FeedMine test fixture generator.

Generates synthetic FeedSource and FeedItem datasets for performance
and functional testing at various scales: smoke (1K), typical (10K),
heavy (100K), extreme (1M).

Usage:
    python3 scripts/generate_test_fixtures.py \\
        --profile typical \\
        --seed 42 \\
        --output-dir Artifacts/Validation/Fixtures

Output:
    - catalog-{profile}-seed{seed}.sqlite    (SQLite catalog database)
    - manifest-{profile}-seed{seed}.json     (checksums, counts, profile)
    - items-{profile}-seed{seed}.sqlite      (feed items database)

The generator is deterministic: same profile + seed → identical output.
"""
import argparse
import hashlib
import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------------------
# Profile definitions
# ---------------------------------------------------------------------------

PROFILES = {
    "empty": {"sources": 0, "items": 0, "followed": 0},
    "smoke": {"sources": 1_000, "items": 1_000, "followed": 10},
    "typical": {"sources": 10_000, "items": 25_000, "followed": 100},
    "heavy": {"sources": 100_000, "items": 100_000, "followed": 500},
    "extreme": {"sources": 1_000_000, "items": 500_000, "followed": 1_000},
    "opml-smoke": {"sources": 100, "items": 0, "followed": 0},
    "opml-typical": {"sources": 1_000, "items": 0, "followed": 0},
    "opml-heavy": {"sources": 10_000, "items": 0, "followed": 0},
    "opml-extreme": {"sources": 100_000, "items": 0, "followed": 0},
}

CATEGORIES = [
    "News & Current Affairs", "Technology", "Sports", "Entertainment",
    "Science", "Business", "Health", "Arts & Culture", "Education",
    "Politics", "Environment", "Music", "Food & Cooking", "Travel",
    "Fashion & Beauty", "Gaming", "Comedy", "History", "Philosophy",
    "Religion & Spirituality",
]

MEDIA_KINDS = ["text", "podcast", "video"]
LANGUAGES = ["en", "pt-BR", "ja", "ar", "fr", "de", "zh-Hans", "ko", "hi", "th"]
REGIONS = ["global"] + [f"countries/{c}" for c in [
    "US", "BR", "JP", "GB", "FR", "DE", "IN", "KR", "CA", "AU",
    "MX", "ES", "IT", "NL", "SE", "NO", "DK", "FI", "PL", "TR",
    "SA", "AE", "SG", "ID", "TH", "VN", "PH", "NG", "ZA", "KE",
]]

FEED_SOURCE_TAGS = [
    "journalism", "news", "analysis", "opinion", "interview",
    "investigative", "local", "regional", "national", "international",
    "expert", "beginner", "tutorial", "review", "podcast",
    "video", "daily", "weekly", "monthly",
]


class Xoshiro256:
    """Xoshiro256+ PRNG — deterministic, matches Swift implementation."""

    def __init__(self, seed: int):
        z = (seed + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9 & 0xFFFFFFFFFFFFFFFF
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB & 0xFFFFFFFFFFFFFFFF
        z = z ^ (z >> 31)
        self.state = [
            (z + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF,
            z, z, z,
        ]
        for _ in range(8):
            self.next()

    def next(self) -> int:
        s = self.state
        result = (s[0] + s[3]) & 0xFFFFFFFFFFFFFFFF
        t = (s[1] << 17) & 0xFFFFFFFFFFFFFFFF
        s[2] ^= s[0]
        s[3] ^= s[1]
        s[1] ^= s[2]
        s[0] ^= s[3]
        s[2] ^= t
        s[3] = ((s[3] << 45) | (s[3] >> 19)) & 0xFFFFFFFFFFFFFFFF
        return result

    def pick(self, items: list):
        return items[self.next() % len(items)]

    def int_range(self, lo: int, hi: int) -> int:
        return lo + (self.next() % (hi - lo))


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

CATALOG_SCHEMA = """
CREATE TABLE IF NOT EXISTS feed_source (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    feed_url TEXT NOT NULL UNIQUE,
    site_url TEXT,
    display_host TEXT,
    category TEXT,
    region TEXT DEFAULT 'global',
    media_kind TEXT DEFAULT 'text',
    language TEXT,
    source_description TEXT,
    tags TEXT,
    default_enabled INTEGER DEFAULT 1,
    quality_score INTEGER,
    activity TEXT DEFAULT 'active',
    feed_type TEXT
);

CREATE VIRTUAL TABLE IF NOT EXISTS feed_source_fts USING fts5(
    title, category, tags, source_description, content='feed_source',
    content_rowid='id'
);

CREATE INDEX IF NOT EXISTS idx_feed_source_category ON feed_source(category);
CREATE INDEX IF NOT EXISTS idx_feed_source_region ON feed_source(region);
CREATE INDEX IF NOT EXISTS idx_feed_source_language ON feed_source(language);
CREATE INDEX IF NOT EXISTS idx_feed_source_media_kind ON feed_source(media_kind);
"""

ITEMS_SCHEMA = """
CREATE TABLE IF NOT EXISTS feed_item (
    id TEXT PRIMARY KEY,
    source_title TEXT NOT NULL,
    source_url TEXT NOT NULL,
    category TEXT,
    title TEXT NOT NULL,
    excerpt TEXT,
    url TEXT NOT NULL,
    image_url TEXT,
    published_at REAL NOT NULL,
    audio_url TEXT,
    duration REAL,
    region TEXT DEFAULT 'global',
    language TEXT,
    updated_at REAL,
    is_read INTEGER DEFAULT 0,
    is_bookmarked INTEGER DEFAULT 0,
    section_day_offset INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_feed_item_published ON feed_item(published_at);
CREATE INDEX IF NOT EXISTS idx_feed_item_source ON feed_item(source_url);
CREATE INDEX IF NOT EXISTS idx_feed_item_region ON feed_item(region);
CREATE INDEX IF NOT EXISTS idx_feed_item_language ON feed_item(language);
"""


# ---------------------------------------------------------------------------
# Generator
# ---------------------------------------------------------------------------

def generate_sources(rng: Xoshiro256, count: int) -> list[dict]:
    """Generate deterministic FeedSource rows."""
    sources = []
    for i in range(count):
        lang = rng.pick(LANGUAGES)
        category = rng.pick(CATEGORIES)
        region = rng.pick(REGIONS)
        media_kind = rng.pick(["text"] * 5 + ["podcast"] * 2 + ["video"])  # 5:2:1 ratio
        n_tags = rng.int_range(1, 6)
        tags = ",".join(sorted(set(rng.pick(FEED_SOURCE_TAGS) for _ in range(n_tags))))

        sources.append({
            "title": f"Source {i}: {rng.pick(CATEGORIES)} Update",
            "feed_url": f"https://source-{i}.example/feed.xml",
            "site_url": f"https://source-{i}.example",
            "display_host": f"source-{i}.example",
            "category": category,
            "region": region,
            "media_kind": media_kind,
            "language": lang,
            "source_description": f"Test fixture source #{i} — {category} coverage in {lang}",
            "tags": tags,
            "quality_score": rng.int_range(50, 100),
            "activity": rng.pick(["active", "active", "active", "dormant"]),
        })
    return sources


def generate_items(rng: Xoshiro256, count: int, sources: list[dict]) -> list[dict]:
    """Generate deterministic FeedItem rows referencing existing sources."""
    if not sources:
        return []
    items = []
    base_date = datetime(2026, 8, 1, 12, 0, 0, tzinfo=timezone.utc)
    for i in range(count):
        src = sources[i % len(sources)]
        offset_seconds = rng.int_range(0, 7 * 86400)  # up to 7 days ago
        pub_date = base_date - timedelta(seconds=offset_seconds)
        has_image = rng.next() % 100 < 50  # 50% have images
        has_audio = rng.next() % 100 < 10   # 10% have audio
        has_video = rng.next() % 100 < 10   # 10% have video (YouTube)
        item_id = hashlib.sha256(
            f"{src['feed_url']}|{pub_date.isoformat()}|Story {i}".encode()
        ).hexdigest()

        items.append({
            "id": item_id,
            "source_title": src["title"],
            "source_url": src["feed_url"],
            "category": src["category"],
            "title": f"Story {i}: A compelling headline about {src['category']}",
            "excerpt": (
                f"Detailed analysis and reporting on {src['category']} "
                f"with expert perspective and original research findings."
            ),
            "url": f"https://source-{i % len(sources)}.example/article-{i}",
            "image_url": f"https://source-{i % len(sources)}.example/image-{i}.jpg" if has_image else None,
            "published_at": pub_date.timestamp(),
            "audio_url": f"https://source-{i % len(sources)}.example/audio-{i}.mp3" if has_audio else None,
            "duration": float(rng.int_range(60, 3600)) if has_audio else None,
            "region": src["region"],
            "language": src["language"],
            "section_day_offset": offset_seconds // 86400,
        })
    return items


def write_sqlite(path: str, schema: str, rows: list[dict], table: str):
    """Write rows to SQLite database."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    conn = sqlite3.connect(path)
    conn.executescript(schema)
    if rows:
        columns = list(rows[0].keys())
        placeholders = ",".join("?" * len(columns))
        col_names = ",".join(columns)
        conn.executemany(
            f"INSERT OR IGNORE INTO {table} ({col_names}) VALUES ({placeholders})",
            [tuple(r[c] for c in columns) for r in rows],
        )
    conn.commit()
    return conn


def write_manifest(path: str, profile: str, seed: int, sources: int, items: int,
                   source_db: str, items_db: str):
    """Write JSON manifest with checksums."""
    manifest = {
        "version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "profile": profile,
        "seed": seed,
        "counts": {
            "sources": sources,
            "items": items,
        },
        "files": {},
    }
    for label, fpath in [("catalog", source_db), ("items", items_db)]:
        sha = hashlib.sha256()
        with open(fpath, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                sha.update(chunk)
        manifest["files"][label] = {
            "path": fpath,
            "sha256": sha.hexdigest(),
            "size_bytes": os.path.getsize(fpath),
        }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(manifest, f, indent=2)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="FeedMine test fixture generator")
    parser.add_argument("--profile", default="typical", choices=list(PROFILES.keys()),
                        help="Data volume profile")
    parser.add_argument("--seed", type=int, default=42,
                        help="Deterministic PRNG seed")
    parser.add_argument("--output-dir", default="Artifacts/Validation/Fixtures",
                        help="Output directory")
    args = parser.parse_args()

    profile = PROFILES[args.profile]
    rng = Xoshiro256(args.seed)

    print(f"Generating profile '{args.profile}' (seed={args.seed})")
    print(f"  Sources: {profile['sources']:,}")
    print(f"  Items:   {profile['items']:,}")

    t0 = time.time()

    # Generate sources (streaming for large profiles)
    sources = generate_sources(rng, profile["sources"])
    source_db = os.path.join(args.output_dir, f"catalog-{args.profile}-seed{args.seed}.sqlite")
    write_sqlite(source_db, CATALOG_SCHEMA, sources, "feed_source")
    print(f"  Catalog written to {source_db}")

    # Generate items
    items = generate_items(rng, profile["items"], sources)
    items_db = os.path.join(args.output_dir, f"items-{args.profile}-seed{args.seed}.sqlite")
    write_sqlite(items_db, ITEMS_SCHEMA, items, "feed_item")
    print(f"  Items written to {items_db}")

    # Manifest
    manifest_path = os.path.join(args.output_dir, f"manifest-{args.profile}-seed{args.seed}.json")
    write_manifest(manifest_path, args.profile, args.seed,
                   len(sources), len(items), source_db, items_db)
    print(f"  Manifest written to {manifest_path}")

    elapsed = time.time() - t0
    print(f"Done in {elapsed:.1f}s")

    # Prevent huge files in git
    if profile["sources"] >= 100_000:
        print("\n⚠️  Extreme profile generated. Remember:")
        print("   - Do NOT commit .sqlite files to Git")
        print("   - Add Artifacts/ to .gitignore")
        print("   - Only the generator script + seed should be versioned")


if __name__ == "__main__":
    main()
