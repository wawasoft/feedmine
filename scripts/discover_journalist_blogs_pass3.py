#!/usr/bin/env python3
"""
Third-pass journalist blog discovery — aggressive broad strategies
for countries that are still well below 100 feeds.

Strategies that cast a WIDER net:
  1. No country constraint — search for journalists in the local language globally
  2. Feed directories — search known feed aggregator sites
  3. Regional umbrella — search for journalists in the broader region
  4. Topic-based — search for country-specific topics that journalists cover
  5. Language-specific — use only the language, no location constraint
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.discover_journalist_blogs import (
    search_ddg, substack_feed, medium_feed, validate_feed,
    extract_feed_from_page, COUNTRY_LANGS, JOURNALIST_TERMS, BLOG_KW
)


def discover_pass3(
    slug: str, name: str, ddg_region: str, langs: list[str],
    existing_urls: set[str], cache_dir: Path, delay: float = 0.6,
) -> list[dict]:
    """Aggressive third-pass discovery."""
    validated: list[dict] = []
    seen: set[str] = set(existing_urls)

    def add(url: str, title: str = "", source: str = "") -> bool:
        norm = url.strip().rstrip("/").lower()
        if norm in seen or not url.startswith("http"):
            return False
        valid, reason, ftitle = validate_feed(url, timeout=5)
        if valid:
            seen.add(norm)
            validated.append({"url": url, "title": title or ftitle or url, "source": source, "country": slug})
            return True
        return False

    terms = []
    for lang in langs:
        for t in JOURNALIST_TERMS.get(lang, JOURNALIST_TERMS.get("en", []))[:4]:
            if t not in terms:
                terms.append(t)

    # ── P3:1 — Language-only search (no country constraint) ──────
    print(f"  [P3:1] Language-only search...", end=" ", flush=True)
    cnt = 0
    for lang in langs[:2]:
        lang_terms = JOURNALIST_TERMS.get(lang, [])[:3]
        bw = BLOG_KW.get(lang, "blog")
        for term in lang_terms:
            # Just the journalist term + blog + RSS, no country
            for r in search_ddg(f'{term} {bw} RSS', ddg_region, 12):
                u = r["url"]
                f = substack_feed(u) or medium_feed(u)
                if not f:
                    f = u if re.search(r'(/feed|/rss|\.xml)', u, re.I) else u.rstrip("/") + "/feed"
                if add(f, r.get("title", ""), f"lang-only:{term}"):
                    cnt += 1
            time.sleep(delay * 0.4)
    print(f"{cnt} feeds")

    # ── P3:2 — Feed directories / aggregators ────────────────────
    print(f"  [P3:2] Feed directories...", end=" ", flush=True)
    cnt = 0
    dir_queries = [
        f'site:feedspot.com "{name}" RSS',
        f'site:blogarama.com "{name}"',
        f'"{name}" site:rss.com',
        f'"{name}" site:feedly.com',
    ]
    for q in dir_queries:
        for r in search_ddg(q, ddg_region, 8):
            f = r["url"].rstrip("/") + "/feed"
            if add(f, r.get("title", ""), f"dir:{q[:25]}"):
                cnt += 1
        time.sleep(delay * 0.3)
    print(f"{cnt} feeds")

    # ── P3:3 — Regional umbrella ─────────────────────────────────
    print(f"  [P3:3] Regional search...", end=" ", flush=True)
    cnt = 0
    # Define regions
    regions = {
        "baltics": "Latvia Lithuania Estonia",
        "scandinavia": "Sweden Norway Denmark Finland Iceland",
        "balkans": "Serbia Croatia Bosnia Slovenia Montenegro Macedonia",
        "central_asia": "Kazakhstan Uzbekistan Kyrgyzstan Turkmenistan Tajikistan",
        "caucasus": "Georgia Armenia Azerbaijan",
        "southeast_asia": "Thailand Vietnam Cambodia Laos Myanmar",
        "east_africa": "Kenya Tanzania Uganda Rwanda Ethiopia",
        "west_africa": "Nigeria Ghana Ivory Coast Senegal",
        "central_america": "Guatemala Honduras El Salvador Nicaragua Costa Rica Panama",
        "andes": "Bolivia Peru Ecuador Colombia",
        "maghreb": "Morocco Algeria Tunisia",
        "gulf": "UAE Qatar Saudi Arabia Kuwait Bahrain Oman",
    }
    for reg_name, reg_countries in regions.items():
        if name.lower() in reg_countries.lower() or any(
            c.lower() in reg_countries.lower() for c in [name]
        ):
            reg_terms = reg_countries.replace(name, "").strip()
            for term in terms[:2]:
                for r in search_ddg(f'{term} blog "{reg_terms.split()[0]}"', ddg_region, 6):
                    f = substack_feed(r["url"]) or medium_feed(r["url"])
                    if not f:
                        f = r["url"].rstrip("/") + "/feed"
                    if add(f, r.get("title", ""), f"regional:{reg_name}"):
                        cnt += 1
                time.sleep(delay * 0.4)
            break  # only match first region
    print(f"{cnt} feeds")

    # ── P3:4 — Topic-based journalist search ─────────────────────
    print(f"  [P3:4] Topic-based...", end=" ", flush=True)
    cnt = 0
    # Search for journalists covering topics relevant to this country
    topics = [name, f"{name} politics", f"{name} news", f"{name} media"]
    for topic in topics[:2]:
        for r in search_ddg(f'"{topic}" journalist substack', ddg_region, 8):
            f = substack_feed(r["url"])
            if f and add(f, r.get("title", ""), f"topic:{topic[:20]}"):
                cnt += 1
        time.sleep(delay * 0.4)
        for r in search_ddg(f'"{topic}" reporter blog', ddg_region, 6):
            f = r["url"].rstrip("/") + "/feed"
            if add(f, r.get("title", ""), f"topic-blog:{topic[:20]}"):
                cnt += 1
        time.sleep(delay * 0.4)
    print(f"{cnt} feeds")

    # ── P3:5 — Direct RSS search ─────────────────────────────────
    print(f"  [P3:5] Direct RSS search...", end=" ", flush=True)
    cnt = 0
    for term in terms[:2]:
        for lang in langs[:1]:
            bw = BLOG_KW.get(lang, "blog")
            for r in search_ddg(f'{term} {bw} "RSS feed" site:substack.com', ddg_region, 8):
                f = substack_feed(r["url"])
                if f and add(f, r.get("title", ""), f"direct-rss:{term}"):
                    cnt += 1
            time.sleep(delay * 0.4)
    print(f"{cnt} feeds")

    return validated


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--country", required=True)
    parser.add_argument("--delay", type=float, default=0.6)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    countries_json = repo_root / "scripts" / "feed_discovery" / "data" / "countries.json"
    countries_dir = repo_root / "feedmine" / "Resources" / "Feeds" / "90_countries"
    cache_dir = repo_root / "scripts" / "feed_discovery" / "data" / "journalist_cache"

    with open(countries_json, encoding="utf-8") as f:
        countries = json.load(f)

    meta = countries[args.country]
    name = meta["name"]
    ddg_region = meta.get("ddg_region", f"{args.country}-{meta['lang']}")
    langs = COUNTRY_LANGS.get(args.country, [meta["lang"]])

    existing_urls: set[str] = set()
    opml_file = countries_dir / args.country / f"{args.country}.opml"
    if opml_file.exists():
        for m in re.finditer(r'xmlUrl="([^"]+)"', opml_file.read_text(encoding="utf-8")):
            existing_urls.add(m.group(1).strip().rstrip("/").lower())

    cache_file = cache_dir / f"{args.country}_validated.json"
    if cache_file.exists():
        for f in json.loads(cache_file.read_text(encoding="utf-8")):
            existing_urls.add(f["url"].strip().rstrip("/").lower())

    print(f"\nPass 3: {name} ({args.country})")
    new = discover_pass3(args.country, name, ddg_region, langs, existing_urls, cache_dir, args.delay)

    all_feeds = []
    if cache_file.exists():
        all_feeds = json.loads(cache_file.read_text(encoding="utf-8"))
    all_feeds.extend(new)
    cache_file.write_text(json.dumps(all_feeds, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"  → {len(new)} new (total: {len(all_feeds)})")


if __name__ == "__main__":
    main()
