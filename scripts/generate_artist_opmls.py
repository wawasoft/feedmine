#!/usr/bin/env python3
"""
Generate candidate OPMLs from artist Candidate JSONs using the pipeline's emit_opml().

Reads:  scripts/feed_discovery/data/artist_candidates/{slug}.json
Output: scripts/feed_discovery/candidates/artist_{slug}.opml
"""

import json, sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from scripts.feed_discovery.opml import emit_opml
from scripts.feed_discovery.models import Candidate

DATA_DIR = REPO_ROOT / "scripts" / "feed_discovery" / "data"
CANDIDATES_DIR = DATA_DIR / "artist_candidates"
OUT_DIR = REPO_ROOT / "scripts" / "feed_discovery" / "candidates"
COUNTRIES_JSON = DATA_DIR / "countries.json"

# Use pipeline's own category order
from scripts.feed_discovery.registry import CATEGORIES as CATEGORY_ORDER


def main():
    with open(COUNTRIES_JSON, encoding="utf-8") as f:
        countries = json.load(f)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    total = 0

    for json_file in sorted(CANDIDATES_DIR.glob("*.json")):
        slug = json_file.stem
        if slug not in countries:
            print(f"  skip unknown: {slug}")
            continue

        cname = countries[slug]["name"]
        candidates_raw = json.loads(json_file.read_text(encoding="utf-8"))

        # Reconstruct Candidate objects
        candidates: list[Candidate] = []
        for c in candidates_raw:
            candidates.append(Candidate(
                url=c["url"],
                category=c.get("category", "Arts &amp; Culture"),
                title=c.get("title", ""),
                genre=c.get("genre", ""),
                source_page=c.get("source_page", ""),
                national=c.get("national", True),
                national_reason=c.get("national_reason", ""),
                is_live=c.get("is_live", True),
                status_code=c.get("status_code", 200),
                is_new=c.get("is_new", True),
            ))

        # Group by category: {category: [(title, url, genre), ...]}
        feeds_by_cat: dict[str, list[tuple[str, str, str]]] = {}
        seen = set()
        for cand in candidates:
            if not (cand.is_new and cand.national and cand.is_live):
                continue
            norm = cand.url.strip().lower().rstrip("/")
            if norm in seen:
                continue
            seen.add(norm)
            cat = cand.category or "Arts &amp; Culture"
            feeds_by_cat.setdefault(cat, []).append(
                (cand.title or cand.url, cand.url, cand.genre or "")
            )

        if not feeds_by_cat:
            continue

        # Generate OPML via pipeline function
        opml_text = emit_opml(cname, feeds_by_cat, CATEGORY_ORDER)

        out_file = OUT_DIR / f"artist_{slug}.opml"
        out_file.write_text(opml_text, encoding="utf-8")
        count = sum(len(v) for v in feeds_by_cat.values())
        print(f"📄 {cname:25s} ({slug:22s}): {count} feeds → {out_file.name}")
        total += count

    print(f"\n✅ {total} total feeds in {OUT_DIR}")
    print(f"   Next: editorial review → integrate into country OPMLs")


if __name__ == "__main__":
    main()
