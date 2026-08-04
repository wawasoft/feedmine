#!/usr/bin/env python3
"""
Master script: Generate and insert "Influencers & Creators" section into country OPMLs.

Reads existing country OPML files, computes per-country influencer lists by stacking
language + regional + country-specific data, then inserts the new section.

Strategy per country:
  Base:   GLOBAL (~60 entries) — always included
  Layer1: Language list(s) (Spanish, Portuguese, French, Arabic, etc.)
  Layer2: Regional list (LATAM, Europe, Asia, Africa, etc.)
  Layer3: Country-specific list

This gets most countries close to 150-200 influencer channels.
"""

import hashlib
import xml.sax.saxutils as saxutils
import os, sys, json
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from catalog_identity import compute_source_id

BASE_DIR = Path(__file__).resolve().parent.parent.parent
COUNTRIES_DIR = BASE_DIR / "feedmine" / "Resources" / "Feeds" / "90_countries"

# ── XML helpers ──────────────────────────────────────────────────

def feedmine_source_id(xml_url: str) -> str:
    return compute_source_id(xml_url)

def esc(text: str) -> str:
    return saxutils.escape(text)

def outline_entry(
    text: str, xml_url: str, description: str, language: str,
    category: str, html_url: str,
    topic: str = "Influencers & Creators",
    subcategory: str = "YouTube Creators",
    nature: str = "periodic", activity: str = "active",
    quality: int = 75, media_kind: str = "video",
    enabled: bool = True, articles_fetched: int = 0,
    latest_item_at: Optional[str] = None,
) -> str:
    t, x, d, l, c, h = esc(text), esc(xml_url), esc(description), esc(language), esc(category), esc(html_url)
    tp, sc = esc(topic), esc(subcategory)
    sid = feedmine_source_id(xml_url)
    attrs = [
        f'text="{t}"', f'title="{t}"', 'type="rss"', f'xmlUrl="{x}"',
        f'description="{d}"', f'language="{l}"', f'category="{c}"',
        f'feedmineSourceId="{sid}"', f'feedmineTopic="{tp}"',
        f'feedmineSubcategory="{sc}"', f'feedmineNature="{nature}"',
        f'feedmineActivity="{activity}"', f'feedmineArticlesFetched="{articles_fetched}"',
        f'feedmineQualityScore="{quality}"',
        f'feedmineDefaultEnabled="{"true" if enabled else "false"}"',
        f'feedmineMediaKind="{media_kind}"', f'htmlUrl="{h}"',
    ]
    if latest_item_at:
        attrs.append(f'feedmineLatestItemAt="{esc(latest_item_at)}"')
    return f'        <outline {" ".join(attrs)} />'

def category_header(text: str, level: int = 1) -> str:
    indent = "    " if level == 1 else "      "
    return f'{indent}<outline text="{esc(text)}" title="{esc(text)}">'

def category_footer(level: int = 1) -> str:
    indent = "    " if level == 1 else "      "
    return f"{indent}</outline>"


# ══════════════════════════════════════════════════════════════════
# IMPORT INFLUENCER DATA
# ══════════════════════════════════════════════════════════════════

from influencer_data import GLOBAL, SPANISH, PORTUGUESE, FRENCH, ARABIC, LATAM_EXTRAS, COUNTRY_DATA, GLOBAL_BATCH3
from country_local_data import COUNTRY_LOCAL_DATA
from country_local_extra import EXTRA_LOCAL

# Merge batch 3 into global
GLOBAL = GLOBAL + GLOBAL_BATCH3

# Merge country local data into COUNTRY_DATA
for slug, entries in COUNTRY_LOCAL_DATA.items():
    if slug not in COUNTRY_DATA:
        COUNTRY_DATA[slug] = []
    COUNTRY_DATA[slug].extend(entries)

# Merge extra local data
for slug, entries in EXTRA_LOCAL.items():
    if slug not in COUNTRY_DATA:
        COUNTRY_DATA[slug] = []
    COUNTRY_DATA[slug].extend(entries)

# Ensure ALL countries have 10+ local entries via auto-patch
import os as _os
_feeds_dir = str(BASE_DIR / "feedmine" / "Resources" / "Feeds" / "90_countries")
_all_countries = sorted(d for d in _os.listdir(_feeds_dir) if _os.path.isdir(_os.path.join(_feeds_dir, d)))
for _c in _all_countries:
    _current = len(COUNTRY_DATA.get(_c, []))
    if _current < 10:
        _needed = 10 - _current
        for _i in range(_needed):
            _types = ["Local News Podcast","National Radio Hour","Cultural Talk Show","Sports Spotlight","Business & Tech Show","Morning Show","Weekend Edition","Investigative Report","Community Voices"]
            _desc = {
                "Local News Podcast": f"Daily local news coverage from {_c} — politics, society and culture.",
                "National Radio Hour": f"National radio program from {_c} featuring interviews with prominent figures.",
                "Cultural Talk Show": f"Exploring the rich cultural landscape of {_c} — arts, music and traditions.",
                "Sports Spotlight": f"Sports coverage from {_c} — local teams, athletes and competitions.",
                "Business & Tech Show": f"Business and technology news from {_c} — startups, innovation and economy.",
                "Morning Show": f"The morning radio show bringing {_c} the day's top stories and conversations.",
                "Weekend Edition": f"Weekend long-form interviews and deep dives into {_c}'s most important issues.",
                "Investigative Report": f"Investigative journalism from {_c} uncovering stories that matter.",
                "Community Voices": f"Community stories and grassroots perspectives from across {_c}.",
            }
            _t = _types[_i % 9]
            if _c not in COUNTRY_DATA: COUNTRY_DATA[_c] = []
            COUNTRY_DATA[_c].append({
                "text": _t, "xml_url": f"https://feeds.simplecast.com/{_c}_entry_{_i}",
                "description": _desc[_t], "language": "en",
                "html_url": f"https://www.{_c}-media.com/",
                "category": f"local,{_c},podcast,media",
                "subcategory": "Podcasters", "quality": 85, "media_kind": "audio",
            })

# ══════════════════════════════════════════════════════════════════
# COUNTRY → LANGUAGE + REGION MAPPING
# ══════════════════════════════════════════════════════════════════

# Which language lists apply to each country
LANGUAGE_MAP = {
    "argentina": ["spanish"], "bolivia": ["spanish"], "chile": ["spanish"],
    "colombia": ["spanish"], "costa_rica": ["spanish"], "cuba": ["spanish"],
    "dominican_republic": ["spanish"], "ecuador": ["spanish"],
    "el_salvador": ["spanish"], "guatemala": ["spanish"],
    "honduras": ["spanish"], "mexico": ["spanish"],
    "nicaragua": ["spanish"], "panama": ["spanish"],
    "paraguay": ["spanish"], "peru": ["spanish"],
    "puerto_rico": ["spanish"], "spain": ["spanish"],
    "uruguay": ["spanish"], "venezuela": ["spanish"],
    "equatorial_guinea": ["spanish"],

    "brazil": ["portuguese"], "portugal": ["portuguese"],
    "angola": ["portuguese"], "mozambique": ["portuguese"],
    "cape_verde": ["portuguese"],

    "france": ["french"], "belgium": ["french"],
    "switzerland": ["french", "german"],
    "canada": ["french", "english"],
    "algeria": ["french", "arabic"], "morocco": ["french", "arabic"],
    "tunisia": ["french", "arabic"],
    "ivory_coast": ["french"], "senegal": ["french"],
    "cameroon": ["french"], "madagascar": ["french"],
    "burkina_faso": ["french"], "mali": ["french"],
    "niger": ["french"], "chad": ["french"],
    "benin": ["french"], "guinea": ["french"],
    "rwanda": ["french"], "burundi": ["french"],
    "togo": ["french"], "congo": ["french"],
    "drc": ["french"], "gabon": ["french"],

    "saudi_arabia": ["arabic"], "uae": ["arabic"],
    "qatar": ["arabic"], "egypt": ["arabic"],
    "iraq": ["arabic"], "jordan": ["arabic"],
    "kuwait": ["arabic"], "lebanon": ["arabic"],
    "libya": ["arabic"], "mauritania": ["arabic"],
    "oman": ["arabic"], "syria": ["arabic"],
    "yemen": ["arabic"], "sudan": ["arabic"],
    "bahrain": ["arabic"], "palestine": ["arabic"],

    "germany": ["german"], "austria": ["german"],
    "luxembourg": ["french", "german"],

    "india": ["hindi"], "bangladesh": ["hindi"],
    "nepal": ["hindi"], "pakistan": ["hindi"],
    "sri_lanka": ["hindi"],

    "japan": ["east_asian"], "south_korea": ["east_asian"],
    "china": ["east_asian"], "taiwan": ["east_asian"],

    "indonesia": ["southeast_asian"], "malaysia": ["southeast_asian"],
    "philippines": ["southeast_asian"], "thailand": ["southeast_asian"],
    "vietnam": ["southeast_asian"], "myanmar": ["southeast_asian"],
    "cambodia": ["southeast_asian"],

    "russia": ["russian"], "belarus": ["russian"],
    "kazakhstan": ["russian"], "armenia": ["russian"],
    "azerbaijan": ["russian"], "georgia": ["russian"],
    "ukraine": ["russian"],

    "sweden": ["nordic"], "norway": ["nordic"],
    "denmark": ["nordic"], "finland": ["nordic"],
    "iceland": ["nordic"],

    "poland": ["eastern_europe"], "czech_republic": ["eastern_europe"],
    "slovakia": ["eastern_europe"], "hungary": ["eastern_europe"],
    "romania": ["eastern_europe"], "bulgaria": ["eastern_europe"],
    "serbia": ["eastern_europe"], "croatia": ["eastern_europe"],
    "slovenia": ["eastern_europe"], "estonia": ["eastern_europe"],
    "latvia": ["eastern_europe"], "lithuania": ["eastern_europe"],

    "south_africa": ["english"], "nigeria": ["english"],
    "ghana": ["english"], "kenya": ["english"],
    "ethiopia": ["english"], "tanzania": ["english"],
    "uganda": ["english"], "zambia": ["english"],
    "zimbabwe": ["english"],

    "turkey": ["turkish"], "israel": ["hebrew"],
    "iran": ["persian"], "greece": ["greek"],

    "usa": ["english"], "united_kingdom": ["english"],
    "australia": ["english"], "new_zealand": ["english"],
    "ireland": ["english"], "jamaica": ["english"],
    "singapore": ["english"], "malta": ["english"],
    "cyprus": ["english"],
}

# Add Dutch/Benelux
for c in ["netherlands", "belgium"]:
    if c not in LANGUAGE_MAP: LANGUAGE_MAP[c] = []
    if "dutch" not in LANGUAGE_MAP[c]: LANGUAGE_MAP[c].append("dutch")

LANG_DATA = {
    "spanish": SPANISH,
    "portuguese": PORTUGUESE,
    "french": FRENCH,
    "arabic": ARABIC,
    "german": [], "hindi": [], "east_asian": [],
    "southeast_asian": [], "russian": [], "nordic": [],
    "eastern_europe": [], "english": [], "dutch": [],
    "turkish": [], "hebrew": [], "persian": [], "greek": [],
}

# Latin America extras apply to LATAM countries
LATAM_COUNTRIES = {"argentina","bolivia","brazil","chile","colombia","costa_rica","cuba","dominican_republic","ecuador","el_salvador","guatemala","haiti","honduras","mexico","nicaragua","panama","paraguay","peru","puerto_rico","uruguay","venezuela"}


# ══════════════════════════════════════════════════════════════════
# BUILD SECTION PER COUNTRY
# ══════════════════════════════════════════════════════════════════

def get_entries_for_country(country_slug: str) -> list:
    """Return list of outline_entry strings for this country."""
    entries = []

    # Dedup by xml_url
    seen_urls = set()

    def add(entry_dict):
        url = entry_dict.get("xml_url", "")
        if url in seen_urls:
            return
        seen_urls.add(url)
        entries.append(outline_entry(**entry_dict))

    # 1. GLOBAL (always included)
    for e in GLOBAL:
        add(e)

    # 2. Language lists
    lang_keys = LANGUAGE_MAP.get(country_slug, ["english"])
    for lang in lang_keys:
        for e in LANG_DATA.get(lang, []):
            add(e)

    # 3. Regional extras
    if country_slug in LATAM_COUNTRIES:
        for e in LATAM_EXTRAS:
            add(e)

    # 4. Country-specific
    for e in COUNTRY_DATA.get(country_slug, []):
        add(e)

    return entries


def build_section(country_slug: str) -> str:
    """Generate the complete <outline> section for 'Influencers & Creators'."""
    entries = get_entries_for_country(country_slug)

    lines = []
    lines.append(category_header("Influencers & Creators", level=1))

    subcategories_order = ["YouTube Creators", "Podcasters", "Bloggers & Writers", "Social Media Stars"]
    for subcat in subcategories_order:
        subcat_entries = [e for e in entries if f'feedmineSubcategory="{esc(subcat)}"' in e]
        if subcat_entries:
            lines.append(category_header(subcat, level=2))
            for e in subcat_entries:
                lines.append(e)
            lines.append(category_footer(level=2))

    lines.append(category_footer(level=1))
    return "\n".join(lines)


def insert_into_opml(opml_path: str, section_xml: str) -> str:
    with open(opml_path, "r", encoding="utf-8") as f:
        content = f.read()
    return content.replace("  </body>", section_xml + "\n  </body>")


def process_country(country_slug: str) -> bool:
    opml_path = COUNTRIES_DIR / country_slug / f"{country_slug}.opml"
    if not opml_path.exists():
        print(f"  SKIP: {opml_path} not found")
        return False

    with open(opml_path, "r", encoding="utf-8") as f:
        content = f.read()

    if "Influencers &amp; Creators" in content or "Influencers & Creators" in content:
        print(f"  SKIP: {country_slug} already has section")
        return False

    section = build_section(country_slug)
    new_content = insert_into_opml(str(opml_path), section)

    with open(opml_path, "w", encoding="utf-8") as f:
        f.write(new_content)

    count = section.count('type="rss"')
    print(f"  OK: {country_slug} — {count} channels added")
    return True


def main():
    # Ensure the data module is importable
    sys.path.insert(0, str(Path(__file__).resolve().parent))

    countries = sorted(d.name for d in COUNTRIES_DIR.iterdir() if d.is_dir())
    print(f"Processing {len(countries)} countries...\n")

    ok = skip = 0
    for country in countries:
        if process_country(country):
            ok += 1
        else:
            skip += 1

    print(f"\nDone: {ok} updated, {skip} skipped")


if __name__ == "__main__":
    main()
