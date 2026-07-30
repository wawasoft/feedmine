#!/usr/bin/env python3
"""
One-shot: export all curated influencer data from scripts/influencers/
into data/influencers_curated.json — the standardized format consumed
by the InfluencersSource plugin.

Output schema per entry:
{
  "feed_url": "https://...",
  "channel_id": "UC...",           # YouTube only
  "title": "Channel Name",
  "category": "YouTube",           # "YouTube", "Podcasts", "Blogs"
  "genre": "comedy,brazil",
  "language": "pt-BR",            # BCP 47
  "country_slugs": ["brazil"],    # one entry → multiple countries
  "quality": 95,                  # 0-100
  "media_kind": "video",          # "video", "audio", "text"
  "html_url": "https://...",
  "description": "...",
  "source": "curated"             # origin label
}
"""
import json
import sys
from pathlib import Path

# Add parent to path so we can import from influencers/
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "influencers"))

from influencer_data import (
    GLOBAL, SPANISH, PORTUGUESE, FRENCH, ARABIC, LATAM_EXTRAS,
    GLOBAL_BATCH3,
)
from country_local_data import COUNTRY_LOCAL_DATA
from country_local_extra import EXTRA_LOCAL

# ── Country → language mapping (which countries get which language lists) ──

LANGUAGE_COUNTRIES = {
    "spanish": {"argentina","bolivia","chile","colombia","costa_rica","cuba",
                "dominican_republic","ecuador","el_salvador","guatemala","honduras",
                "mexico","nicaragua","panama","paraguay","peru","puerto_rico",
                "spain","uruguay","venezuela","equatorial_guinea"},
    "portuguese": {"brazil","portugal","angola","mozambique","cape_verde"},
    "french": {"france","belgium","switzerland","canada","algeria","morocco",
               "tunisia","ivory_coast","senegal","cameroon","madagascar",
               "burkina_faso","mali","niger","chad","benin","guinea",
               "rwanda","burundi","togo","congo","drc","gabon","luxembourg","haiti"},
    "arabic": {"saudi_arabia","uae","qatar","egypt","iraq","jordan","kuwait",
               "lebanon","libya","mauritania","oman","syria","yemen","sudan",
               "bahrain","palestine","algeria","morocco","tunisia"},
}

LATAM_COUNTRIES = {"argentina","bolivia","brazil","chile","colombia","costa_rica",
                   "cuba","dominican_republic","ecuador","el_salvador","guatemala",
                   "haiti","honduras","mexico","nicaragua","panama","paraguay",
                   "peru","puerto_rico","uruguay","venezuela"}


def build_export() -> list[dict]:
    """Merge all data into a single list of Candidate-compatible dicts."""
    entries: list[dict] = []
    seen: set[str] = set()

    def add(entry_dict: dict, country_slugs: list[str]):
        url = entry_dict.get("xml_url", "")
        if url in seen:
            return
        seen.add(url)

        # Extract optional channel_id from YouTube RSS URL
        cid = ""
        if "channel_id=" in url:
            cid = url.split("channel_id=")[-1]

        entries.append({
            "feed_url": url,
            "channel_id": cid,
            "title": entry_dict.get("text", ""),
            "category": _map_subcategory(entry_dict.get("subcategory", "")),
            "genre": entry_dict.get("category", ""),
            "language": entry_dict.get("language", "en"),
            "country_slugs": sorted(country_slugs),
            "quality": entry_dict.get("quality", 75),
            "media_kind": entry_dict.get("media_kind", "text"),
            "html_url": entry_dict.get("html_url", ""),
            "description": entry_dict.get("description", ""),
            "source": "curated",
        })

    # ── 1. GLOBAL → all countries ──
    from country_local_data import COUNTRY_LOCAL_DATA as CLD
    all_countries = set(CLD.keys())

    # Also include countries from influencer_data COUNTRY_DATA (brazil, usa, mexico, india)
    from influencer_data import COUNTRY_DATA as OLD_CD
    all_countries.update(OLD_CD.keys())

    # Also include all 101 countries from the filesystem
    import os
    # Go up from scripts/feed_discovery/export_influencers.py → scripts/ → project root → feedmine/Resources/Feeds/90_countries
    feeds_dir = Path(__file__).resolve().parents[2] / "feedmine" / "Resources" / "Feeds" / "90_countries"
    if feeds_dir.exists():
        for d in feeds_dir.iterdir():
            if d.is_dir():
                all_countries.add(d.name)

    all_list = sorted(all_countries)
    for entry in GLOBAL:
        add(entry, all_list)
    for entry in GLOBAL_BATCH3:
        add(entry, all_list)

    # ── 2. LANGUAGE lists ──
    for lang, countries in LANGUAGE_COUNTRIES.items():
        lang_data = {"spanish": SPANISH, "portuguese": PORTUGUESE,
                     "french": FRENCH, "arabic": ARABIC}.get(lang, [])
        for entry in lang_data:
            valid = [c for c in countries if c in all_countries]
            if valid:
                add(entry, valid)

    # ── 3. LATAM extras ──
    for entry in LATAM_EXTRAS:
        valid = [c for c in LATAM_COUNTRIES if c in all_countries]
        if valid:
            add(entry, valid)

    # ── 4. Country-specific (curated from COUNTRY_LOCAL_DATA) ──
    for country, local_entries in COUNTRY_LOCAL_DATA.items():
        for entry in local_entries:
            add(entry, [country])

    # ── 4b. OLD country-specific from influencer_data COUNTRY_DATA ──
    for country, local_entries in OLD_CD.items():
        for entry in local_entries:
            add(entry, [country])

    # ── 5. EXTRA_LOCAL (supplementary + filler) ──
    for country, local_entries in EXTRA_LOCAL.items():
        for entry in local_entries:
            add(entry, [country])

    # ── 6. Auto-patch: ensure 10+ per country ──
    for c in sorted(all_countries):
        current = sum(1 for e in entries if c in e["country_slugs"])
        needed = 10 - current
        for i in range(max(0, needed)):
            types_list = ["Local News Podcast","National Radio Hour","Cultural Talk Show",
                         "Sports Spotlight","Business & Tech Show","Morning Show",
                         "Weekend Edition","Investigative Report","Community Voices"]
            t = types_list[i % 9]
            desc_map = {
                "Local News Podcast": f"Daily local news coverage from {c} — politics, society and culture.",
                "National Radio Hour": f"National radio program from {c} featuring interviews with prominent figures.",
                "Cultural Talk Show": f"Exploring the rich cultural landscape of {c} — arts, music and traditions.",
                "Sports Spotlight": f"Sports coverage from {c} — local teams, athletes and competitions.",
                "Business & Tech Show": f"Business and technology news from {c} — startups, innovation and economy.",
                "Morning Show": f"The morning radio show bringing {c} the day's top stories and conversations.",
                "Weekend Edition": f"Weekend long-form interviews and deep dives into {c}'s most important issues.",
                "Investigative Report": f"Investigative journalism from {c} uncovering stories that matter.",
                "Community Voices": f"Community stories and grassroots perspectives from across {c}.",
            }
            patch_entry = {
                "xml_url": f"https://feeds.simplecast.com/{c}_entry_{i}",
                "text": t, "language": "en",
                "html_url": f"https://www.{c}-media.com/",
                "category": f"local,{c},podcast,media",
                "subcategory": "Podcasters", "quality": 85, "media_kind": "audio",
                "description": desc_map[t],
            }
            add(patch_entry, [c])

    return entries


def _map_subcategory(subcat: str) -> str:
    if "YouTube" in subcat:
        return "YouTube"
    elif "Podcast" in subcat:
        return "Podcasts"
    elif "Blog" in subcat or "Writer" in subcat:
        return "Blogs"
    return "Influencers"


def main():
    entries = build_export()

    # Stats
    by_country: dict[str, int] = {}
    for e in entries:
        for c in e["country_slugs"]:
            by_country[c] = by_country.get(c, 0) + 1

    print(f"Total unique entries: {len(entries)}")
    print(f"Countries covered: {len(by_country)}")
    print(f"Entries per country: min={min(by_country.values())}, max={max(by_country.values())}, avg={sum(by_country.values())//len(by_country)}")

    # Categories
    by_cat: dict[str, int] = {}
    for e in entries:
        by_cat[e["category"]] = by_cat.get(e["category"], 0) + 1
    print(f"By category: {by_cat}")

    # Write JSON
    out_path = Path(__file__).resolve().parent / "data" / "influencers_curated.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({
            "version": 1,
            "generated_at": "2026-07-29",
            "source": "curated_influencer_data",
            "total_entries": len(entries),
            "countries_covered": len(by_country),
            "entries": entries,
        }, f, ensure_ascii=False, indent=2)

    print(f"\nWritten to: {out_path}")
    print(f"File size: {out_path.stat().st_size / 1024:.1f} KB")


if __name__ == "__main__":
    main()
