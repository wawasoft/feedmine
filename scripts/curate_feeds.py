#!/usr/bin/env python3
"""
Curate feed candidates from 4 discovery groups:
  1. Artist candidates  (artist_candidates/)
  2. Influencers curated (influencers_curated.json)
  3. Radio podcasts     (radio_podcasts_by_country.json)
  4. Universities       (universities/by_country/)

Actions:
  - Normalize all to Candidate format
  - Deduplicate within group, across groups, and against production OPML feeds
  - Separate outliers / inappropriate feeds to a removed/ directory
  - Point out missing content (no new discovery work)
  - Output cleaned per-country JSON files ready for enrichment pipeline

Output:
  scripts/feed_discovery/data/curated/
    artists/{country}.json
    influencers/{country}.json
    radio/{country}.json
    universities/{country}.json       (only those with feed URLs)
    universities_needs_discovery/{country}.json  (have website but no feed)
    combined/{country}.json           (all groups merged, final dedup)
    removed/{reason}_{group}.json     (feeds removed + why)
    report.json                       (summary counts & flags)
"""

import json
import os
import re
import sys
import hashlib
from collections import Counter, defaultdict
from dataclasses import dataclass, field, asdict
from pathlib import Path

try:
    from scripts.catalog_identity import canonical_url, compute_source_id
except ModuleNotFoundError:
    from catalog_identity import canonical_url, compute_source_id
from typing import Optional
from urllib.parse import urlparse, urlunparse, parse_qs, urlencode

# ── paths ──────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / "scripts" / "feed_discovery" / "data"
FEEDS_DIR = PROJECT_ROOT / "feedmine" / "Resources" / "Feeds"

ARTIST_DIR    = DATA_DIR / "artist_candidates"
INFLUENCER_F  = DATA_DIR / "influencers_curated.json"
RADIO_F       = DATA_DIR / "radio_podcasts_by_country.json"
UNIVERSITY_DIR = DATA_DIR / "universities" / "by_country"

OUTPUT_DIR    = DATA_DIR / "curated"

# Categories for the pipeline
VALID_CATEGORIES = {
    "News", "Sports", "Technology", "Science", "Culture", "Movies", "Music",
    "Food", "Gaming", "Travel", "Blogs", "Design", "Environment", "DIY",
    "History", "Architecture", "Programming", "Business", "Podcasts",
    "Photography", "Health", "Education", "Politics", "Humor", "Apple", "YouTube",
}


# ── data model ─────────────────────────────────────────────────────────
@dataclass
class Candidate:
    url: str
    category: str
    title: str = ""
    genre: str = ""
    source_page: str = ""
    national: bool = True
    national_reason: str = ""
    is_live: bool = False
    status_code: int = 0
    is_new: bool = True


@dataclass
class RemovedFeed:
    url: str
    title: str
    reason: str
    group: str
    country: str
    original_data: dict = field(default_factory=dict)


# ── URL normalization (matching OPMLParser.normalizeURL logic) ───────
TRACKING_PARAMS = {
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "fbclid", "gclid", "ref", "source",
}


def normalize_url(raw: str) -> str:
    return canonical_url(raw)


def url_to_source_id(url: str) -> str:
    return compute_source_id(url)


# ── helpers ────────────────────────────────────────────────────────────
def normalize_country_slug(slug: str) -> str:
    """Normalize country slugs to consistent hyphen format.
    Converts underscores to hyphens so all four data sources align.
    """
    return slug.strip().lower().replace("_", "-")


def slugify(name: str) -> str:
    """Convert a country name to a file-safe slug."""
    return normalize_country_slug(name.lower().replace(" ", "_").replace("&", "and"))


def clean_category(cat: str) -> str:
    """Map category strings to valid pipeline categories."""
    if not cat:
        return "General"
    cat = cat.strip()
    # Direct match
    if cat in VALID_CATEGORIES:
        return cat
    # Case-insensitive match
    for vc in VALID_CATEGORIES:
        if vc.lower() == cat.lower():
            return vc
    # Heuristic mappings
    mapping = {
        "sociedade e cultura": "Culture",
        "notícias esportivas": "Sports",
        "news commentary": "News",
        "culture": "Culture",
        "music": "Music",
        "movies": "Movies",
        "youtube": "YouTube",
        "podcasts": "Podcasts",
        "education": "Education",
        "technology": "Technology",
        "science": "Science",
    }
    return mapping.get(cat.lower(), "General")


def is_valid_feed_url(url: str) -> bool:
    """Check if a URL looks like a valid feed URL."""
    if not url:
        return False
    if not (url.startswith("http://") or url.startswith("https://")):
        return False
    # Must have a reasonable domain
    try:
        parsed = urlparse(url)
        if not parsed.hostname or "." not in parsed.hostname:
            return False
    except Exception:
        return False
    return True


def is_likely_website_not_feed(url: str) -> bool:
    """Heuristic: does this URL look like a website homepage, not a feed?"""
    if not url:
        return True
    lower = url.lower()
    feed_indicators = [
        "/rss", "/feed", "/atom", "feeds/videos.xml", "feeds/posts/default",
        "/podcast", "anchor.fm", "omnycontent.com", "feeds.soundcloud",
        "feeds.transistor.fm", "feeds.buzzsprout", "feeds.libsyn",
        "feeds.megaphone.fm", "feeds.simplecast", "rss.", "feed.",
        "podcast.rss", "feeds/acast", "spreaker.com", "ivoox",
        "feeds.blubrry", "content.redcircle", "pinecast.com/feed",
        "feeds.captivate", "feeds.podiant", "feeds.podbean",
        "feeds.podserve", "/publication/", "/xml/", "/rss/", "/feed/",
        "/podcast/", "/atom/",
    ]
    for ind in feed_indicators:
        if ind in lower:
            return False
    # If no feed indicator and has a TLD, likely a website
    return True


# ── production feed extraction ─────────────────────────────────────────
def extract_production_urls() -> set[str]:
    """Extract all xmlUrl values from production OPML files (not _incoming, not .bak)."""
    urls: set[str] = set()
    if not FEEDS_DIR.exists():
        print(f"  WARNING: Feeds dir not found: {FEEDS_DIR}")
        return urls

    opml_files: list[Path] = []
    for root, dirs, files in os.walk(FEEDS_DIR):
        # Skip _incoming_librivox
        if "_incoming_librivox" in root:
            continue
        for f in files:
            if f.endswith(".opml") and not f.endswith(".opml.bak"):
                opml_files.append(Path(root) / f)

    print(f"  Scanning {len(opml_files)} production OPML files...")
    for fp in opml_files:
        try:
            content = fp.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        # Extract xmlUrl attributes
        for m in re.finditer(r'xmlUrl="([^"]*)"', content):
            url = normalize_url(m.group(1))
            if url:
                urls.add(url)
    return urls


# ── group loaders ──────────────────────────────────────────────────────
def load_artist_candidates() -> tuple[dict[str, list[Candidate]], list[RemovedFeed]]:
    """Load artist candidates. Already in Candidate format. File per country."""
    results: dict[str, list[Candidate]] = defaultdict(list)
    removed: list[RemovedFeed] = []

    if not ARTIST_DIR.exists():
        print(f"  Artist dir not found: {ARTIST_DIR}")
        return results, removed

    files = sorted([f for f in os.listdir(ARTIST_DIR) if f.endswith(".json")])
    print(f"  Loading {len(files)} artist country files...")

    for fname in files:
        country = normalize_country_slug(fname.replace(".json", ""))
        with open(ARTIST_DIR / fname) as fh:
            data = json.load(fh)

        for entry in data:
            url = normalize_url(entry.get("url", ""))
            if not is_valid_feed_url(url):
                removed.append(RemovedFeed(
                    url=entry.get("url", ""), title=entry.get("title", ""),
                    reason="invalid_feed_url", group="artists", country=country,
                    original_data=entry,
                ))
                continue

            cat = clean_category(entry.get("category", "Culture"))
            genre = entry.get("genre", "Artist Blogs")

            # Force category to "Music" for artist blogs if appropriate
            if genre == "Artist Blogs" and cat == "Culture":
                cat = "Music"

            cand = Candidate(
                url=url,
                category=cat,
                title=entry.get("title", ""),
                genre=genre,
                source_page=entry.get("source_page", ""),
                national=entry.get("national", True),
                national_reason=entry.get("national_reason", f"artist_candidates/{country}"),
                is_live=entry.get("is_live", False),
                status_code=entry.get("status_code", 0),
                is_new=True,
            )
            results[country].append(cand)

    return results, removed


def load_influencers() -> tuple[dict[str, list[Candidate]], list[RemovedFeed]]:
    """Load influencers curated. 634 YouTube channels, all assigned to every country."""
    results: dict[str, list[Candidate]] = defaultdict(list)
    removed: list[RemovedFeed] = []

    if not INFLUENCER_F.exists():
        print(f"  Influencer file not found: {INFLUENCER_F}")
        return results, removed

    with open(INFLUENCER_F) as fh:
        data = json.load(fh)

    entries = data.get("entries", [])
    print(f"  Loading {len(entries)} influencer entries...")

    # Get the set of all target countries from radio/artist data
    # (we'll fill this later, for now use country_slugs from entries)
    all_countries: set[str] = set()
    for entry in entries:
        slugs = entry.get("country_slugs", [])
        all_countries.update(slugs)

    for entry in entries:
        feed_url = normalize_url(entry.get("feed_url", ""))
        if not is_valid_feed_url(feed_url):
            removed.append(RemovedFeed(
                url=entry.get("feed_url", ""), title=entry.get("title", ""),
                reason="invalid_feed_url", group="influencers",
                country="global", original_data=entry,
            ))
            continue

        cat = clean_category(entry.get("category", "YouTube"))
        genre = entry.get("genre", "")
        title = entry.get("title", "")
        html_url = entry.get("html_url", "")
        quality = entry.get("quality", 0)

        # Low-quality entries
        if quality < 50:
            removed.append(RemovedFeed(
                url=feed_url, title=title,
                reason=f"low_quality_score_{quality}", group="influencers",
                country="global", original_data=entry,
            ))
            continue

        country_slugs = [normalize_country_slug(s) for s in entry.get("country_slugs", [])]

        for country in country_slugs:
            cand = Candidate(
                url=feed_url,
                category=cat,
                title=title,
                genre=genre,
                source_page=html_url,
                national=True,
                national_reason=f"influencers_curated/{quality}",
                is_live=False,
                status_code=0,
                is_new=True,
            )
            results[country].append(cand)

    return results, removed


def load_radio_podcasts() -> tuple[dict[str, list[Candidate]], list[RemovedFeed]]:
    """Load radio podcasts. Nested structure with per-country candidates."""
    results: dict[str, list[Candidate]] = defaultdict(list)
    removed: list[RemovedFeed] = []

    if not RADIO_F.exists():
        print(f"  Radio file not found: {RADIO_F}")
        return results, removed

    with open(RADIO_F) as fh:
        data = json.load(fh)

    countries = data.get("countries", {})
    print(f"  Loading {len(countries)} radio country entries...")

    for country_code, country_data in countries.items():
        country_code = normalize_country_slug(country_code)
        candidates = country_data.get("candidates", [])
        for entry in candidates:
            url = normalize_url(entry.get("url", ""))
            if not is_valid_feed_url(url):
                removed.append(RemovedFeed(
                    url=entry.get("url", ""), title=entry.get("title", ""),
                    reason="invalid_feed_url", group="radio",
                    country=country_code, original_data=entry,
                ))
                continue

            cat = clean_category(entry.get("genre", "Podcasts"))
            title = entry.get("title", "")
            artist = entry.get("artist", "")
            source = entry.get("source", "itunes")

            cand = Candidate(
                url=url,
                category=cat if cat != "General" else "Podcasts",
                title=title,
                genre=f"Radio & Podcasts ({artist})" if artist else "Radio & Podcasts",
                source_page="",
                national=True,
                national_reason=f"radio_podcasts/{source}",
                is_live=False,
                status_code=0,
                is_new=True,
            )
            results[country_code].append(cand)

    return results, removed


def load_universities() -> tuple[dict[str, list[Candidate]], dict[str, list[dict]], list[RemovedFeed]]:
    """Load universities.
    Returns:
      - with_feeds: those with YouTube → Candidate (YouTube feed URL)
      - needs_discovery: those with website but no YouTube → needs feed discovery
      - removed: stubs with no website and no social
    """
    with_feeds: dict[str, list[Candidate]] = defaultdict(list)
    needs_discovery: dict[str, list[dict]] = defaultdict(list)
    removed: list[RemovedFeed] = []

    if not UNIVERSITY_DIR.exists():
        print(f"  University dir not found: {UNIVERSITY_DIR}")
        return with_feeds, needs_discovery, removed

    files = sorted([f for f in os.listdir(UNIVERSITY_DIR) if f.endswith(".json")])
    print(f"  Loading {len(files)} university country files...")

    for fname in files:
        country = normalize_country_slug(fname.replace(".json", ""))
        with open(UNIVERSITY_DIR / fname) as fh:
            data = json.load(fh)

        for entry in data:
            name = entry.get("name", "")
            website = entry.get("website", "")
            youtube = entry.get("youtube", "")
            wikidata_id = entry.get("wikidata_id", "")

            # Remove stubs: name is just a Q-ID
            if name.startswith("Q") and name[1:].isdigit():
                # Check if it has any usable data
                if not website and not youtube:
                    removed.append(RemovedFeed(
                        url="", title=name,
                        reason="wikidata_stub_no_data", group="universities",
                        country=country, original_data=entry,
                    ))
                    continue

            # Remove entries with NO website AND NO social media at all
            has_any = bool(website or youtube or entry.get("instagram") or entry.get("twitter"))
            if not has_any:
                removed.append(RemovedFeed(
                    url="", title=name,
                    reason="no_website_no_social", group="universities",
                    country=country, original_data=entry,
                ))
                continue

            # University WITH YouTube channel → can create a feed URL
            if youtube:
                feed_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={youtube}"
                cand = Candidate(
                    url=feed_url,
                    category="Education",
                    title=f"{name} (YouTube)",
                    genre="University",
                    source_page=website or entry.get("wikipedia_url", ""),
                    national=True,
                    national_reason=f"universities/youtube/{country}",
                    is_live=False,
                    status_code=0,
                    is_new=True,
                )
                with_feeds[country].append(cand)
            else:
                # Has website but no YouTube → needs feed discovery
                needs_discovery[country].append({
                    "name": name,
                    "website": website,
                    "wikidata_id": wikidata_id,
                    "wikipedia_url": entry.get("wikipedia_url", ""),
                    "country": country,
                })

    return with_feeds, needs_discovery, removed


# ── deduplication ──────────────────────────────────────────────────────
def dedup_within_group(group_data: dict[str, list[Candidate]], label: str) -> dict[str, list[Candidate]]:
    """Deduplicate within each country for a single group."""
    deduped: dict[str, list[Candidate]] = {}
    total_before = 0
    total_after = 0

    for country, candidates in group_data.items():
        total_before += len(candidates)
        seen: set[str] = set()
        unique: list[Candidate] = []
        for c in candidates:
            norm = normalize_url(c.url)
            if norm not in seen:
                seen.add(norm)
                unique.append(c)
        deduped[country] = unique
        total_after += len(unique)

    dupes = total_before - total_after
    if dupes:
        print(f"  [{label}] intra-group dedup: {dupes} removed ({total_before}→{total_after})")
    return deduped


def dedup_across_groups(
    *groups: tuple[str, dict[str, list[Candidate]]]
) -> tuple[dict[str, list[Candidate]], dict[str, int]]:
    """Merge groups, keeping the first occurrence across groups (by group priority).
    Returns: (merged per-country data, cross-group removal counts per group)
    """
    # Global URL → (first_group, first_country, candidate)
    global_seen: dict[str, tuple[str, str, Candidate]] = {}
    cross_removed: dict[str, int] = defaultdict(int)

    for group_name, group_data in groups:
        for country, candidates in group_data.items():
            for c in candidates:
                norm = normalize_url(c.url)
                if norm in global_seen:
                    cross_removed[group_name] += 1
                else:
                    global_seen[norm] = (group_name, country, c)

    # Build merged per-country
    merged: dict[str, list[Candidate]] = defaultdict(list)
    for norm, (grp, country, cand) in global_seen.items():
        merged[country].append(cand)

    for grp, count in cross_removed.items():
        if count:
            print(f"  [{grp}] cross-group dedup: {count} removed (already in higher-priority group)")

    return merged, dict(cross_removed)


def dedup_against_production(
    group_data: dict[str, list[Candidate]], prod_urls: set[str], label: str
) -> tuple[dict[str, list[Candidate]], int]:
    """Remove feeds that already exist in production OPML files."""
    deduped: dict[str, list[Candidate]] = {}
    removed_count = 0

    for country, candidates in group_data.items():
        unique: list[Candidate] = []
        for c in candidates:
            norm = normalize_url(c.url)
            if norm in prod_urls:
                removed_count += 1
            else:
                unique.append(c)
        if unique:
            deduped[country] = unique

    if removed_count:
        print(f"  [{label}] production dedup: {removed_count} removed (already in OPML)")
    return deduped, removed_count


# ── outlier detection ──────────────────────────────────────────────────
def detect_outliers(group_data: dict[str, list[Candidate]], label: str) -> dict[str, dict]:
    """Flag countries with unusually high or low counts."""
    counts = {c: len(v) for c, v in group_data.items()}
    if not counts:
        return {}

    avg = sum(counts.values()) / len(counts)
    outliers = {}
    for country, count in counts.items():
        if count > avg * 5:  # 5x above average
            outliers[country] = {"count": count, "avg": avg, "flag": "high_outlier"}
        elif avg > 0 and count < max(1, avg * 0.05):  # 5% of average
            outliers[country] = {"count": count, "avg": avg, "flag": "low_outlier"}
    return outliers


# ── output writer ──────────────────────────────────────────────────────
def write_candidates(group_dir: Path, group_data: dict[str, list[Candidate]]):
    """Write per-country Candidate JSON files."""
    group_dir.mkdir(parents=True, exist_ok=True)
    for country, candidates in sorted(group_data.items()):
        out = [asdict(c) for c in candidates]
        out.sort(key=lambda x: (x["category"], x["title"]))
        (group_dir / f"{country}.json").write_text(
            json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8"
        )
    total = sum(len(v) for v in group_data.values())
    print(f"  Wrote {total} candidates to {group_dir}/ ({len(group_data)} countries)")


def write_removed(removed_dir: Path, removed: list[RemovedFeed], label: str):
    """Write removed feeds with reasons."""
    removed_dir.mkdir(parents=True, exist_ok=True)
    out = [asdict(r) for r in removed]
    # Group by reason
    by_reason: dict[str, list] = defaultdict(list)
    for r in out:
        by_reason[r["reason"]].append(r)
    for reason, items in by_reason.items():
        fname = f"{label}_{reason}.json"
        (removed_dir / fname).write_text(
            json.dumps(items, indent=2, ensure_ascii=False), encoding="utf-8"
        )
    print(f"  Wrote {len(removed)} removed feeds to {removed_dir}/ ({len(by_reason)} reason files)")


# ── main ───────────────────────────────────────────────────────────────
def main():
    print("=" * 70)
    print("FEED CURATION PIPELINE")
    print("=" * 70)

    # ── Step 0: Extract production URLs ──
    print("\n[0] Extracting production feed URLs...")
    prod_urls = extract_production_urls()
    print(f"  → {len(prod_urls):,} unique production feed URLs")

    # ── Step 1: Load all groups ──
    print("\n[1] Loading curation groups...")

    print("  Artists:")
    artists, artist_removed = load_artist_candidates()
    total_artists = sum(len(v) for v in artists.values())
    print(f"    → {total_artists:,} candidates, {len(artist_removed)} removed")

    print("  Influencers:")
    influencers, influencer_removed = load_influencers()
    total_influencers = sum(len(v) for v in influencers.values())
    print(f"    → {total_influencers:,} candidate assignments, {len(influencer_removed)} removed")

    print("  Radio:")
    radio, radio_removed = load_radio_podcasts()
    total_radio = sum(len(v) for v in radio.values())
    print(f"    → {total_radio:,} candidates, {len(radio_removed)} removed")

    print("  Universities:")
    unis_with_feeds, unis_needs_disc, uni_removed = load_universities()
    total_uni_feeds = sum(len(v) for v in unis_with_feeds.values())
    total_uni_needs = sum(len(v) for v in unis_needs_disc.values())
    total_uni_removed = len(uni_removed)
    print(f"    → {total_uni_feeds:,} with feeds (YouTube), {total_uni_needs:,} need discovery, {total_uni_removed:,} removed")

    # ── Step 2: Intra-group dedup ──
    print("\n[2] Intra-group deduplication...")
    artists = dedup_within_group(artists, "artists")
    influencers = dedup_within_group(influencers, "influencers")
    radio = dedup_within_group(radio, "radio")
    unis_with_feeds = dedup_within_group(unis_with_feeds, "universities")

    # ── Step 3: Cross-group dedup (priority: artists > radio > influencers > universities) ──
    print("\n[3] Cross-group deduplication...")
    # Priority order: artists (most specific), then radio, then influencers (global/generic), then universities
    merged, cross_removed = dedup_across_groups(
        ("artists", artists),
        ("radio", radio),
        ("influencers", influencers),
        ("universities", unis_with_feeds),
    )

    # ── Step 4: Dedup against production ──
    print("\n[4] Production deduplication...")
    artists_final, artists_prod_removed = dedup_against_production(artists, prod_urls, "artists")
    radio_final, radio_prod_removed = dedup_against_production(radio, prod_urls, "radio")
    influencers_final, influencer_prod_removed = dedup_against_production(influencers, prod_urls, "influencers")
    unis_final, unis_prod_removed = dedup_against_production(unis_with_feeds, prod_urls, "universities")
    merged_final, merged_prod_removed = dedup_against_production(merged, prod_urls, "merged")

    # ── Step 5: Outlier detection ──
    print("\n[5] Outlier detection...")
    artist_outliers = detect_outliers(artists_final, "artists")
    radio_outliers = detect_outliers(radio_final, "radio")
    influencer_outliers = detect_outliers(influencers_final, "influencers")
    uni_outliers = detect_outliers(unis_final, "universities")

    for label, outliers in [("artists", artist_outliers), ("radio", radio_outliers),
                             ("influencers", influencer_outliers), ("universities", uni_outliers)]:
        if outliers:
            print(f"  [{label}] outliers:")
            for country, info in outliers.items():
                print(f"    {country}: {info['count']} feeds (avg: {info['avg']:.0f}, flag: {info['flag']})")

    # ── Step 6: Write outputs ──
    print("\n[6] Writing outputs...")
    OUT_DIR = OUTPUT_DIR
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print("  Per-group outputs:")
    write_candidates(OUT_DIR / "artists", artists_final)
    write_candidates(OUT_DIR / "radio", radio_final)
    write_candidates(OUT_DIR / "influencers", influencers_final)
    write_candidates(OUT_DIR / "universities", unis_final)

    # Universities needing discovery
    if unis_needs_disc:
        disc_dir = OUT_DIR / "universities_needs_discovery"
        disc_dir.mkdir(parents=True, exist_ok=True)
        for country, entries in unis_needs_disc.items():
            (disc_dir / f"{country}.json").write_text(
                json.dumps(entries, indent=2, ensure_ascii=False), encoding="utf-8"
            )
        print(f"  Wrote {total_uni_needs:,} needs-discovery entries to {disc_dir}/ ({len(unis_needs_disc)} countries)")

    # Combined
    write_candidates(OUT_DIR / "combined", merged_final)

    # Removed feeds
    all_removed = artist_removed + influencer_removed + radio_removed + list(uni_removed)
    write_removed(OUT_DIR / "removed", all_removed, "all")

    # ── Step 7: Report ──
    print("\n[7] Generating report...")

    # Stats
    def count_feeds(d: dict) -> int:
        return sum(len(v) for v in d.values())

    report = {
        "generated_at": "2026-07-29",
        "pipeline_format": "Candidate (models.py)",
        "production_feeds_scanned": len(prod_urls),
        "groups": {
            "artists": {
                "candidates_loaded": total_artists,
                "after_intra_dedup": count_feeds(artists),
                "after_prod_dedup": count_feeds(artists_final),
                "countries": len(artists_final),
                "outliers": artist_outliers,
            },
            "influencers": {
                "candidates_loaded": total_influencers,
                "unique_channels": len({normalize_url(c.url) for clist in influencers.values() for c in clist}),
                "after_intra_dedup": count_feeds(influencers),
                "after_prod_dedup": count_feeds(influencers_final),
                "countries": len(influencers_final),
                "outliers": influencer_outliers,
                "note": "634 global YouTube channels, assigned to all countries. After cross-group dedup, reduced by overlap with artists/radio.",
            },
            "radio": {
                "candidates_loaded": total_radio,
                "after_intra_dedup": count_feeds(radio),
                "after_prod_dedup": count_feeds(radio_final),
                "countries": len(radio_final),
                "outliers": radio_outliers,
            },
            "universities": {
                "with_feeds_loaded": total_uni_feeds,
                "after_prod_dedup": count_feeds(unis_final),
                "needs_discovery": total_uni_needs,
                "removed_stubs": total_uni_removed,
                "countries_with_feeds": len(unis_final),
                "countries_needs_discovery": len(unis_needs_disc),
                "outliers": uni_outliers,
                "note": "Universities don't have feed URLs natively. Only YouTube channels converted to feeds. Websites saved separately for future discovery.",
            },
        },
        "combined": {
            "total_candidates": count_feeds(merged_final),
            "countries": len(merged_final),
            "dedup_priority": ["artists", "radio", "influencers", "universities"],
            "cross_group_removals": cross_removed,
            "production_removals": {
                "artists": artists_prod_removed,
                "radio": radio_prod_removed,
                "influencers": influencer_prod_removed,
                "universities": unis_prod_removed,
            },
        },
        "missing_content": {
            "universities_without_feeds": {
                "total": total_uni_needs,
                "description": "Universities with websites but no RSS/YouTube feed. Needs feed discovery pass.",
                "top_countries": sorted(
                    [(c, len(v)) for c, v in unis_needs_disc.items()],
                    key=lambda x: -x[1]
                )[:10],
            },
            "universities_removed": {
                "total": total_uni_removed,
                "description": "Entries with no website, no social media, or Wikidata stubs with only a Q-ID.",
            },
            "removed_feeds_total": len(all_removed),
        },
        "warnings": [],
    }

    # Add warnings
    if uni_outliers:
        for country, info in uni_outliers.items():
            report["warnings"].append(
                f"University outlier: {country} ({info['count']} feeds vs avg {info['avg']:.0f})"
            )

    # Check for countries with very few feeds
    country_counts = {c: len(v) for c, v in merged_final.items()}
    low_countries = [(c, n) for c, n in country_counts.items() if n < 5]
    if low_countries:
        report["warnings"].append(f"Countries with <5 combined feeds: {low_countries}")

    # India university note
    report["warnings"].append(
        "India universities: 24,327 entries loaded, but most were Wikidata stubs (removed). "
        "Original data dominated by affiliated colleges. Review remaining entries manually."
    )

    report_path = OUT_DIR / "report.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"  Report: {report_path}")

    # ── Summary ──
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print(f"  Artists:      {count_feeds(artists_final):>8,} feeds across {len(artists_final):>3} countries")
    print(f"  Radio:        {count_feeds(radio_final):>8,} feeds across {len(radio_final):>3} countries")
    print(f"  Influencers:  {count_feeds(influencers_final):>8,} assignments across {len(influencers_final):>3} countries")
    print(f"  Universities: {count_feeds(unis_final):>8,} feeds across {len(unis_final):>3} countries (+{total_uni_needs:,} need discovery)")
    print(f"  ─────────────────────────────")
    print(f"  COMBINED:     {count_feeds(merged_final):>8,} total unique feeds across {len(merged_final):>3} countries")
    print(f"  Removed:      {len(all_removed):>8,} feeds ({len(artist_removed)} artists, {len(influencer_removed)} influencers, {len(radio_removed)} radio, {total_uni_removed} universities)")
    print(f"  Production overlap: {artists_prod_removed + radio_prod_removed + influencer_prod_removed + unis_prod_removed} feeds already in OPML")
    print()

    return report


if __name__ == "__main__":
    main()
