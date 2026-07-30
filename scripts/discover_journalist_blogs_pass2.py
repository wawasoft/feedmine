#!/usr/bin/env python3
"""
Second-pass journalist blog discovery for countries that didn't reach 100 feeds.

This pass uses broader strategies:
  1. Diaspora journalists (country name + journalist in English)
  2. Regional journalists (covering the broader region)
  3. International journalists writing about the country
  4. Direct Substack/Medium discovery without validation first
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

# Reuse functions from the main script
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.discover_journalist_blogs import (
    search_ddg, substack_feed, medium_feed, validate_feed,
    extract_feed_from_page, generate_opml, COUNTRY_LANGS, JOURNALIST_TERMS
)


def discover_pass2(
    slug: str, name: str, ddg_region: str, langs: list[str],
    existing_urls: set[str], cache_dir: Path, delay: float = 0.8,
) -> list[dict]:
    """Second-pass discovery for a country that needs more feeds."""
    validated: list[dict] = []
    seen: set[str] = set(existing_urls)

    def add(url: str, title: str = "", source: str = "") -> bool:
        norm = url.strip().rstrip("/").lower()
        if norm in seen:
            return False
        valid, reason, ftitle = validate_feed(url, timeout=5)
        if valid:
            seen.add(norm)
            validated.append({"url": url, "title": title or ftitle or url, "source": source, "country": slug})
            return True
        return False

    # ── Diaspora journalists ───────────────────────────────────
    print(f"  [P2:1] Diaspora journalists...", end=" ", flush=True)
    cnt = 0
    queries = [
        f'"{name}" journalist blog',
        f'"{name}" journalist substack',
        f'expat {name} journalist blog',
        f'{name} diaspora journalist',
    ]
    for q in queries:
        for r in search_ddg(q, ddg_region, 10):
            f = substack_feed(r["url"]) or medium_feed(r["url"])
            if not f:
                parsed = urlparse(r["url"])
                if "wordpress.com" in r["url"]:
                    f = r["url"].rstrip("/") + "/feed"
                elif "blogspot.com" in r["url"]:
                    f = f"{parsed.scheme}://{parsed.netloc}/feeds/posts/default"
                else:
                    f = r["url"].rstrip("/") + "/feed"
            if add(f, r.get("title", ""), f"diaspora:{q[:30]}"):
                cnt += 1
        time.sleep(delay)
    print(f"{cnt} feeds")

    # ── Region-specific searches ────────────────────────────────
    print(f"  [P2:2] Regional context...", end=" ", flush=True)
    cnt = 0
    # Try searching without the country name constraint
    for lang in langs[:1]:
        terms = JOURNALIST_TERMS.get(lang, JOURNALIST_TERMS.get("en", []))[:3]
        for term in terms:
            for r in search_ddg(f'{term} substack', ddg_region, 8):
                f = substack_feed(r["url"])
                if f and add(f, r.get("title", ""), f"regional:{term}"):
                    cnt += 1
            time.sleep(delay * 0.5)
    print(f"{cnt} feeds")

    # ── Journalism schools / training programs ──────────────────
    print(f"  [P2:3] Journalism schools...", end=" ", flush=True)
    cnt = 0
    school_queries = [
        f'"{name}" journalism school blog',
        f'"{name}" journalism training blog',
        f'"{name}" media institute blog',
    ]
    for q in school_queries:
        for r in search_ddg(q, ddg_region, 5):
            for feed_url in extract_feed_from_page(r["url"])[:2]:
                if add(feed_url, r.get("title", ""), f"school:{q[:30]}"):
                    cnt += 1
                    break
        time.sleep(delay * 0.5)
    print(f"{cnt} feeds")

    # ── Direct known platforms ──────────────────────────────────
    print(f"  [P2:4] Known journalist platforms...", end=" ", flush=True)
    cnt = 0
    platform_queries = [
        f'{name} journalist medium.com',
        f'{name} journalist ghost.org',
        f'{name} reporter blog',
    ]
    for q in platform_queries:
        for r in search_ddg(q, ddg_region, 8):
            f = substack_feed(r["url"]) or medium_feed(r["url"])
            if not f:
                f = r["url"].rstrip("/") + "/feed"
            if add(f, r.get("title", ""), f"known-plat:{q[:30]}"):
                cnt += 1
        time.sleep(delay * 0.5)
    print(f"{cnt} feeds")

    return validated


def main():
    parser = argparse.ArgumentParser(description="Second-pass journalist blog discovery")
    parser.add_argument("--country", required=True)
    parser.add_argument("--delay", type=float, default=0.8)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    countries_json = repo_root / "scripts" / "feed_discovery" / "data" / "countries.json"
    countries_dir = repo_root / "feedmine" / "Resources" / "Feeds" / "90_countries"
    cache_dir = repo_root / "scripts" / "feed_discovery" / "data" / "journalist_cache"

    with open(countries_json, encoding="utf-8") as f:
        countries = json.load(f)

    if args.country not in countries:
        print(f"Unknown: {args.country}")
        return

    meta = countries[args.country]
    name = meta["name"]
    ddg_region = meta.get("ddg_region", f"{args.country}-{meta['lang']}")
    langs = COUNTRY_LANGS.get(args.country, [meta["lang"]])

    # Load existing feeds (both from OPML and from first-pass cache)
    existing_urls: set[str] = set()
    opml_file = countries_dir / args.country / f"{args.country}.opml"
    if opml_file.exists():
        content = opml_file.read_text(encoding="utf-8")
        for m in re.finditer(r'xmlUrl="([^"]+)"', content):
            existing_urls.add(m.group(1).strip().rstrip("/").lower())

    # Load first-pass results
    cache_file = cache_dir / f"{args.country}_validated.json"
    existing_pass1_count = 0
    if cache_file.exists():
        pass1 = json.loads(cache_file.read_text(encoding="utf-8"))
        existing_pass1_count = len(pass1)
        for f in pass1:
            existing_urls.add(f["url"].strip().rstrip("/").lower())

    print(f"\n{'='*60}")
    print(f"Pass 2: {name} ({args.country}) — {existing_pass1_count} feeds from pass 1")
    print(f"{'='*60}")

    new_feeds = discover_pass2(args.country, name, ddg_region, langs, existing_urls, cache_dir, args.delay)

    # Merge with existing cache
    all_feeds = []
    if cache_file.exists():
        all_feeds = json.loads(cache_file.read_text(encoding="utf-8"))
    all_feeds.extend(new_feeds)

    cache_file.write_text(json.dumps(all_feeds, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"  → {len(new_feeds)} new feeds from pass 2 (total: {len(all_feeds)})")


if __name__ == "__main__":
    main()
