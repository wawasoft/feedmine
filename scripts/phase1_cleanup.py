#!/usr/bin/env python3
"""
Phase 1 Editorial Cleanup: "Stop the Bleeding"
==============================================
WS-3: Spam removal
WS-1: YouTube rationalization (3 tiers)
WS-2: Global non-YouTube dedup
WS-4: Keyword-matching decontamination
WS-6: Language metadata backfill + normalization

Run from repo root:
    python3 scripts/phase1_cleanup.py --worktree /path/to/worktree

Dry-run mode (default): reports what would change without modifying files.
Apply mode: python3 scripts/phase1_cleanup.py --apply
"""

import argparse
import copy
import csv
import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

# ── Spam signatures (WS-3) ────────────────────────────────────────────

SPAM_SOURCE_IDS = {
    "41b6a490c523fd8bb2d19a1a9000fd508c9ba25aa4a6290585c81fa96a82dc9e",  # STBEMU
}

SPAM_URL_PATTERNS = [
    re.compile(r"https?://ukemucodes\.blogspot\.com"),
    re.compile(r"https?://deseoaprenders\.blogspot\.com"),
    re.compile(r"https?://bruce-lab\.blogspot\.com"),
]

SPAM_TITLE_KEYWORDS = [
    "FREE UK STBEMU CODES",
    "Mastering Poker Chip Stacking",
    "Emerging AI Technologies for Hyper-Predictive SEO Automation",
]

# ── YouTube tier classification (WS-1) ─────────────────────────────────

YOUTUBE_URL_RE = re.compile(
    r"https?://www\.youtube\.com/feeds/videos\.xml\?channel_id=([\w-]+)"
)

# Language profile per country (from OPML metadata + CIA World Factbook)
COUNTRY_LANGUAGES = {
    "algeria": {"ar", "fr"},
    "angola": {"pt"},
    "argentina": {"es"},
    "armenia": {"hy"},
    "australia": {"en"},
    "austria": {"de"},
    "azerbaijan": {"az", "ru"},
    "bangladesh": {"bn", "en"},
    "belarus": {"be", "ru"},
    "belgium": {"nl", "fr", "de"},
    "bolivia": {"es", "qu"},
    "brazil": {"pt"},
    "bulgaria": {"bg"},
    "cambodia": {"km"},
    "canada": {"en", "fr"},
    "chile": {"es"},
    "china": {"zh"},
    "colombia": {"es"},
    "costa_rica": {"es"},
    "croatia": {"hr"},
    "cuba": {"es"},
    "cyprus": {"el", "tr"},
    "czech_republic": {"cs"},
    "denmark": {"da"},
    "dominican_republic": {"es"},
    "ecuador": {"es"},
    "egypt": {"ar"},
    "el_salvador": {"es"},
    "estonia": {"et"},
    "ethiopia": {"am"},
    "finland": {"fi", "sv"},
    "france": {"fr"},
    "georgia": {"ka"},
    "germany": {"de"},
    "ghana": {"en"},
    "greece": {"el"},
    "guatemala": {"es"},
    "haiti": {"fr", "ht"},
    "honduras": {"es"},
    "hungary": {"hu"},
    "iceland": {"is"},
    "india": {"hi", "en", "bn", "te", "mr", "ta", "ur", "gu", "kn", "ml", "or", "pa", "as", "mai"},
    "indonesia": {"id"},
    "iran": {"fa"},
    "iraq": {"ar", "ku"},
    "ireland": {"en", "ga"},
    "israel": {"he", "ar"},
    "italy": {"it"},
    "ivory_coast": {"fr"},
    "jamaica": {"en"},
    "japan": {"ja"},
    "kazakhstan": {"kk", "ru"},
    "kenya": {"en", "sw"},
    "latvia": {"lv"},
    "lithuania": {"lt"},
    "luxembourg": {"lb", "fr", "de"},
    "malaysia": {"ms", "en", "zh"},
    "malta": {"mt", "en"},
    "mexico": {"es"},
    "morocco": {"ar", "fr"},
    "myanmar": {"my"},
    "nepal": {"ne"},
    "netherlands": {"nl"},
    "new_zealand": {"en", "mi"},
    "nicaragua": {"es"},
    "nigeria": {"en", "ha", "yo", "ig"},
    "norway": {"no"},
    "pakistan": {"ur", "en"},
    "panama": {"es"},
    "paraguay": {"es", "gn"},
    "peru": {"es", "qu"},
    "philippines": {"tl", "en"},
    "poland": {"pl"},
    "portugal": {"pt"},
    "puerto_rico": {"es", "en"},
    "qatar": {"ar"},
    "romania": {"ro"},
    "russia": {"ru"},
    "saudi_arabia": {"ar"},
    "serbia": {"sr"},
    "singapore": {"en", "zh", "ms", "ta"},
    "slovakia": {"sk"},
    "slovenia": {"sl"},
    "south_africa": {"en", "af", "zu", "xh"},
    "south_korea": {"ko"},
    "spain": {"es"},
    "sri_lanka": {"si", "ta", "en"},
    "sudan": {"ar", "en"},
    "sweden": {"sv"},
    "switzerland": {"de", "fr", "it", "rm"},
    "taiwan": {"zh"},
    "thailand": {"th"},
    "tunisia": {"ar", "fr"},
    "turkey": {"tr"},
    "uae": {"ar", "en"},
    "ukraine": {"uk", "ru"},
    "united_kingdom": {"en"},
    "uruguay": {"es"},
    "usa": {"en"},
    "venezuela": {"es"},
    "vietnam": {"vi"},
}

# Regional clusters for YouTube Tier B (language/culture-based)
REGIONAL_CLUSTERS = {
    "latam": {"argentina", "bolivia", "chile", "colombia", "costa_rica", "cuba",
              "dominican_republic", "ecuador", "el_salvador", "guatemala", "honduras",
              "mexico", "nicaragua", "panama", "paraguay", "peru", "puerto_rico",
              "uruguay", "venezuela", "spain"},
    "mena": {"algeria", "egypt", "iraq", "morocco", "qatar", "saudi_arabia",
             "sudan", "tunisia", "uae"},
    "germanic": {"germany", "austria", "switzerland", "luxembourg"},
    "nordic": {"denmark", "finland", "iceland", "norway", "sweden"},
    "lusophone": {"brazil", "portugal", "angola"},
    "south_asia": {"india", "pakistan", "bangladesh", "nepal", "sri_lanka"},
    "southeast_asia": {"indonesia", "malaysia", "philippines", "thailand", "vietnam",
                       "cambodia", "myanmar"},
    "commonwealth": {"australia", "canada", "ireland", "jamaica", "kenya",
                     "new_zealand", "south_africa", "united_kingdom", "ghana",
                     "nigeria"},
    "eastern_europe": {"belarus", "bulgaria", "croatia", "czech_republic", "estonia",
                       "hungary", "latvia", "lithuania", "poland", "romania", "serbia",
                       "slovakia", "slovenia", "ukraine"},
    "east_asia": {"china", "japan", "south_korea", "taiwan"},
    "caucasus_central_asia": {"armenia", "azerbaijan", "georgia", "kazakhstan"},
}

# ── Language code normalization (WS-6) ──────────────────────────────────

LANG_CODE_MAP = {
    # case normalization
    "en-us": "en-US", "en-us": "en-US",
    "en-uk": "en-GB", "en-gb": "en-GB",
    "en-bw": "en",  # Botswana code used generically
    "pt-br": "pt-BR", "pt-pt": "pt-PT",
    "es-mx": "es-MX", "es-es": "es-ES", "es-ar": "es-AR",
    "fr-fr": "fr-FR", "fr-ca": "fr-CA",
    "de-de": "de-DE", "de-at": "de-AT", "de-ch": "de-CH",
    "ru-ru": "ru-RU",
    "it-it": "it-IT",
    "zh-tw": "zh-TW", "zh-cn": "zh-CN",
    "ja-jp": "ja-JP",
    "ko-kr": "ko-KR",
    "ar-ar": "ar", "ar-sa": "ar-SA",
    # obsolete codes
    "iw": "he", "iw-il": "he-IL",
    "in": "id", "in-id": "id-ID",
    "ji": "yi",
    "no-no": "nb-NO",
    "fil": "fil",  # keep
    # non-standard
    "zh-ha": "zh-TW",
    "da-da": "da-DK",
    "nl-nl": "nl-NL",
    "sv-se": "sv-SE",
}


def normalize_lang_code(code):
    """Normalize a language code to BCP-47."""
    if not code or not code.strip():
        return ""
    code = code.strip()
    # try exact match first
    if code.lower() in LANG_CODE_MAP:
        return LANG_CODE_MAP[code.lower()]
    if code in LANG_CODE_MAP:
        return LANG_CODE_MAP[code]
    # try case normalization: lowercase region
    parts = code.split("-", 1)
    if len(parts) == 2:
        base, region = parts
        return f"{base.lower()}-{region.upper()}"
    return code.lower()


# ── OPML loading & writing ─────────────────────────────────────────────

def load_opml(path):
    """Parse an OPML file, returning (tree, root_element)."""
    tree = ET.parse(path)
    return tree, tree.getroot()


def find_all_feeds(root):
    """Find all <outline> elements with type='rss' (i.e., actual feeds)."""
    feeds = []
    body = root.find("body")
    if body is None:
        return feeds

    def walk(element, depth=0):
        for child in element:
            if child.tag == "outline" and child.get("type") == "rss":
                feeds.append((child, element))  # (feed_element, parent_element)
            walk(child, depth + 1)

    walk(body)
    return feeds


def find_all_category_outlines(root):
    """Find all <outline> elements that are category containers (no type='rss')."""
    categories = []
    body = root.find("body")
    if body is None:
        return categories

    def walk(element, depth=0):
        for child in element:
            if child.tag == "outline" and child.get("type") != "rss":
                categories.append((child, element))
                walk(child, depth + 1)

    walk(body)
    return categories


def remove_feed(feed_elem, parent_elem):
    """Remove a feed <outline> from its parent."""
    parent_elem.remove(feed_elem)


def write_opml(tree, path):
    """Write an OPML tree to file with proper formatting.
    Matches the project convention from curate_opml_catalog.py and
    dedup_opml_categories.py."""
    root = tree.getroot()
    ET.indent(root, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True, short_empty_elements=True)


# ── WS-3: Spam removal ─────────────────────────────────────────────────

def is_spam(feed_elem):
    """Check if a feed is known spam."""
    source_id = feed_elem.get("feedmineSourceId", "")
    xml_url = feed_elem.get("xmlUrl", "")
    title = feed_elem.get("text", "")
    description = feed_elem.get("description", "")

    # signature match: sourceId
    if source_id in SPAM_SOURCE_IDS:
        return True, "sourceId_blacklist"

    # signature match: URL pattern
    for pattern in SPAM_URL_PATTERNS:
        if pattern.search(xml_url):
            return True, f"url_pattern:{pattern.pattern}"

    # keyword match in title or description
    combined = f"{title} {description}"
    for keyword in SPAM_TITLE_KEYWORDS:
        if keyword.lower() in combined.lower():
            return True, f"title_keyword:{keyword[:40]}"

    return False, ""


def remove_spam(root, report):
    """Remove all spam feeds from an OPML tree. Returns count removed."""
    removed = 0
    feeds = find_all_feeds(root)
    for feed_elem, parent_elem in feeds:
        is_spam_flag, reason = is_spam(feed_elem)
        if is_spam_flag:
            remove_feed(feed_elem, parent_elem)
            removed += 1
            report["spam_removed"].append({
                "url": feed_elem.get("xmlUrl", ""),
                "title": feed_elem.get("text", ""),
                "reason": reason,
            })
    return removed


# ── WS-1: YouTube rationalization ───────────────────────────────────────

def is_youtube_feed(feed_elem):
    """Check if a feed is a YouTube channel RSS."""
    xml_url = feed_elem.get("xmlUrl", "")
    return "youtube.com/feeds/videos.xml" in xml_url


def get_channel_id(feed_elem):
    """Extract YouTube channel ID from xmlUrl."""
    xml_url = feed_elem.get("xmlUrl", "")
    m = YOUTUBE_URL_RE.search(xml_url)
    return m.group(1) if m else None


def classify_youtube_tier(country, channel_id, country_feed_counts):
    """
    Classify a YouTube channel into tier for a given country.
    Returns one of: 'tier_a_global', 'tier_b_regional', 'tier_c_local', 'keep'
    """
    # Tier A: appears in 100+ countries → global, remove from country files
    # Tier B: appears in 76-84 countries → regional, only keep in language-matching clusters
    # Tier C: less than 76 → keep in country if language matches

    # This is decided by the global analysis already done:
    # 121 channels in 100 countries, 915 in 76-84 countries

    # For now, we use a heuristic based on what we measured:
    # - Tier A: the 121 channels identified as 100-country
    # - Tier B: the 915 channels identified as 76-84 country
    # Since we don't have the exact list of channel_ids for each tier,
    # we use the country count approach

    return None  # Will be set by pre-computed channel tiers


def build_youtube_channel_index(all_country_feeds):
    """
    Build a global index of YouTube channels and their country distribution.
    Returns: {channel_id: {countries: set(), ...}}
    """
    index = defaultdict(lambda: {"countries": set(), "feed_data": None})
    for country, feeds in all_country_feeds.items():
        for feed_elem in feeds:
            if is_youtube_feed(feed_elem):
                ch_id = get_channel_id(feed_elem)
                if ch_id:
                    index[ch_id]["countries"].add(country)
                    if index[ch_id]["feed_data"] is None:
                        index[ch_id]["feed_data"] = feed_elem
    return index


def compute_youtube_tiers(yt_index):
    """
    Classify each YouTube channel based on country reach.
    Returns: {channel_id: 'tier_a'|'tier_b'|'tier_c'}
    """
    tiers = {}
    for ch_id, data in yt_index.items():
        n = len(data["countries"])
        if n >= 100:
            tiers[ch_id] = "tier_a"
        elif n >= 76:
            tiers[ch_id] = "tier_b"
        else:
            tiers[ch_id] = "tier_c"
    return tiers


# ── WS-2: Global non-YouTube dedup ──────────────────────────────────────

def build_feed_country_index(all_country_feeds):
    """
    Build index of all non-YouTube feeds: {xmlUrl: {countries: set(), ...}}
    """
    index = defaultdict(lambda: {"countries": set(), "feed_data": None})
    for country, feeds in all_country_feeds.items():
        for feed_elem in feeds:
            if not is_youtube_feed(feed_elem):
                url = feed_elem.get("xmlUrl", "")
                if url:
                    index[url]["countries"].add(country)
                    if index[url]["feed_data"] is None:
                        index[url]["feed_data"] = feed_elem
    return index


# ── WS-4: Keyword decontamination ──────────────────────────────────────

# Known keyword-matching contamination patterns.
# These are NOT about feeds whose title mentions the country (that's correct!).
# These are about feeds MISASSIGNED to a country because a HOMONYM was found:
#   "Rodrigo Colombo" (person) → "Sri Lanka" (capital = Colombo)
#   "Malta Advogados" (Brazilian law firm) → "Malta" (country)
#   "Georgia Tech" (US university) → "Georgia" (country)
#
# The PRIMARY signal is language mismatch. We only flag when:
#   1. Feed language ≠ country profile languages, AND
#   2. TLD indicates a different country, OR
#   3. Known homonym contamination pattern matches

KNOWN_HOMONYM_CONTAMINATIONS = {
    "sri_lanka": {
        "words": ["colombo"],
        "note": "Colombo is a surname (Italian/Portuguese) confused with Sri Lanka's capital",
    },
    "malta": {
        "words": ["malta advogados", "cruz de malta", "malta fm", "malta radi",
                   "malta law", "malta lawyer"],
        "note": "Brazilian entities using 'Malta' as a name, matched to country Malta",
    },
    "georgia": {
        "words": ["georgia tech", "university of georgia", "georgia bulldogs",
                   "georgia state", "atlanta"],
        "note": "US state of Georgia confused with country Georgia",
    },
}

TLD_TO_COUNTRY = {
    "br": "brazil", "com.br": "brazil", "pt": "portugal", "com.pt": "portugal",
    "es": "spain", "com.es": "spain", "mx": "mexico", "com.mx": "mexico",
    "ar": "argentina", "com.ar": "argentina", "co": "colombia", "com.co": "colombia",
    "cl": "chile", "pe": "peru", "com.pe": "peru",
    "de": "germany", "at": "austria", "co.at": "austria", "ch": "switzerland",
    "fr": "france", "it": "italy", "jp": "japan", "co.jp": "japan",
    "kr": "south_korea", "co.kr": "south_korea", "in": "india", "co.in": "india",
    "ru": "russia", "uk": "united_kingdom", "co.uk": "united_kingdom",
    "au": "australia", "com.au": "australia", "ca": "canada",
    "nl": "netherlands", "be": "belgium", "se": "sweden", "no": "norway",
    "dk": "denmark", "fi": "finland", "pl": "poland", "cz": "czech_republic",
    "hu": "hungary", "ro": "romania", "bg": "bulgaria", "gr": "greece",
    "tr": "turkey", "sa": "saudi_arabia", "com.sa": "saudi_arabia",
    "ae": "uae", "eg": "egypt", "id": "indonesia", "co.id": "indonesia",
    "my": "malaysia", "com.my": "malaysia", "ph": "philippines", "com.ph": "philippines",
    "vn": "vietnam", "th": "thailand", "co.th": "thailand",
    "nz": "new_zealand", "co.nz": "new_zealand",
    "za": "south_africa", "co.za": "south_africa",
    "ng": "nigeria", "ke": "kenya", "co.ke": "kenya", "gh": "ghana",
    "cn": "china", "com.cn": "china", "tw": "taiwan", "com.tw": "taiwan",
}


def get_domain_tld(url):
    """Extract TLD from a URL."""
    if not url:
        return None
    m = re.search(r"\.([a-z]{2,3}(?:\.[a-z]{2})?)(?:/|$)", url)
    return m.group(1) if m else None


def is_likely_misplaced(feed_elem, country):
    """
    Check if a feed is likely misplaced via keyword-matching contamination.

    Conservative approach — requires STRONG evidence:
    1. Feed's language doesn't match country profile languages (primary gate)
    2. PLUS one of: TLD mismatch or known homonym contamination pattern
    """
    lang = feed_elem.get("language", "").strip()
    title = feed_elem.get("text", "")
    description = feed_elem.get("description", "")
    html_url = feed_elem.get("htmlUrl", "")
    xml_url = feed_elem.get("xmlUrl", "")

    country_langs = COUNTRY_LANGUAGES.get(country, set())
    country_lang_bases = {l.split("-")[0].lower() for l in country_langs}

    # Gate 1: Language must NOT match (primary signal)
    lang_mismatch = False
    if lang:
        normalized_lang = normalize_lang_code(lang)
        lang_base = normalized_lang.split("-")[0].lower()
        if lang_base not in country_lang_bases:
            lang_mismatch = True
        else:
            return False, ""  # Language matches country profile → correctly placed
    else:
        # No language attribute — can't determine, skip (not enough evidence)
        return False, ""

    # If we get here, language doesn't match. Look for secondary evidence.

    # Gate 2: TLD mismatch (domain from a different country)
    url_to_check = html_url or xml_url
    tld = get_domain_tld(url_to_check)
    if tld and tld in TLD_TO_COUNTRY:
        tld_country = TLD_TO_COUNTRY[tld]
        if tld_country != country:
            return True, f"tld_mismatch:{tld}→{tld_country}"

    # Gate 3: Known homonym contamination
    if country in KNOWN_HOMONYM_CONTAMINATIONS:
        combined = f"{title} {description}".lower()
        for word in KNOWN_HOMONYM_CONTAMINATIONS[country]["words"]:
            if word in combined:
                return True, f"homonym:{country}:{word}"

    # Language doesn't match but no secondary evidence — don't flag
    return False, ""


# ── WS-6: Language metadata ─────────────────────────────────────────────

def backfill_language(feed_elem, country):
    """Attempt to backfill a missing language attribute."""
    lang = feed_elem.get("language", "").strip()
    if lang:
        # Already has language — just normalize it
        normalized = normalize_lang_code(lang)
        if normalized != lang:
            feed_elem.set("language", normalized)
            return "normalized", f"{lang} → {normalized}"
        return None, ""

    # Try to infer from country profile
    country_langs = COUNTRY_LANGUAGES.get(country, set())
    if len(country_langs) == 1:
        inferred = list(country_langs)[0]
        feed_elem.set("language", inferred)
        return "inferred_from_country", inferred

    # Try htmlUrl TLD
    html_url = feed_elem.get("htmlUrl", "")
    tld_lang_map = {
        ".br": "pt-BR", ".pt": "pt-PT", ".es": "es", ".mx": "es-MX",
        ".de": "de", ".fr": "fr", ".it": "it", ".jp": "ja", ".kr": "ko",
        ".ru": "ru", ".cn": "zh-CN", ".tw": "zh-TW", ".in": "hi",
        ".uk": "en-GB", ".au": "en", ".ca": "en", ".us": "en-US",
        ".nl": "nl", ".se": "sv", ".no": "no", ".dk": "da", ".fi": "fi",
        ".pl": "pl", ".cz": "cs", ".hu": "hu", ".ro": "ro", ".bg": "bg",
        ".gr": "el", ".tr": "tr", ".sa": "ar", ".ae": "ar", ".eg": "ar",
        ".id": "id", ".my": "ms", ".ph": "tl", ".vn": "vi", ".th": "th",
    }
    for tld, lang_code in tld_lang_map.items():
        if tld in html_url:
            feed_elem.set("language", lang_code)
            return "inferred_from_tld", lang_code

    return None, ""


# ── Main pipeline ───────────────────────────────────────────────────────

def load_all_countries(base_path):
    """Load all country OPMLs into memory."""
    countries_dir = base_path / "90_countries"
    all_feeds = {}
    all_trees = {}
    for country_dir in sorted(countries_dir.iterdir()):
        if not country_dir.is_dir() or country_dir.name.startswith("."):
            continue
        country = country_dir.name
        opml_path = country_dir / f"{country}.opml"
        if not opml_path.exists():
            continue
        try:
            tree, root = load_opml(opml_path)
            feeds = find_all_feeds(root)
            all_feeds[country] = [f[0] for f in feeds]  # Just feed elements
            all_trees[country] = (tree, root, opml_path)
        except Exception as e:
            print(f"  ERROR loading {country}: {e}")
    return all_feeds, all_trees


def load_all_topics(base_path):
    """Load all topic OPMLs into memory."""
    topic_files = {}
    for entry in sorted(base_path.iterdir()):
        if entry.is_dir() and entry.name[0].isdigit():
            opml_path = entry / f"{entry.name}.opml"
            if opml_path.exists():
                try:
                    tree, root = load_opml(opml_path)
                    topic_files[entry.name] = (tree, root, opml_path)
                except Exception as e:
                    print(f"  ERROR loading topic {entry.name}: {e}")
    return topic_files


def find_or_create_topic_section(root, topic_name):
    """Find or create a topic section (<outline text='Topic'>) in the body."""
    body = root.find("body")
    if body is None:
        body = ET.SubElement(root, "body")

    # Look for existing section
    for child in body:
        if child.tag == "outline" and child.get("text") == topic_name:
            return child

    # Create new section
    section = ET.SubElement(body, "outline", {"text": topic_name, "title": topic_name})
    return section


def find_or_create_subcategory(parent_elem, subcat_name):
    """Find or create a subcategory outline under a parent."""
    for child in parent_elem:
        if child.tag == "outline" and child.get("text") == subcat_name:
            return child
    subcat = ET.SubElement(parent_elem, "outline", {"text": subcat_name, "title": subcat_name})
    return subcat


def assign_topic_subcategory(feed_elem, default_topic="General Interests"):
    """Assign YouTube channel to appropriate topic file subcategory."""
    title = feed_elem.get("text", "").lower()
    description = feed_elem.get("description", "").lower()
    category = feed_elem.get("category", "").lower()

    combined = f"{title} {description} {category}"

    # Music channels
    if any(w in combined for w in ["music", "song", "vevo", "official audio", "lyrical", "records"]):
        return "16_Music_&_Audio", "Culture & Heritage"

    # Gaming
    if any(w in combined for w in ["gaming", "game", "minecraft", "roblox", "fortnite", "gamer", "play"]):
        return "14_Games_&_Hobbies", "Gaming & eSports"

    # Sports
    if any(w in combined for w in ["sports", "nba", "nfl", "football", "soccer", "wwe", "wrestling", "fitness"]):
        return "07_Sports", "General Sports"

    # Entertainment
    if any(w in combined for w in ["entertainment", "comedy", "show", "tv", "movie", "film", "trailer",
                                    "react", "challenge", "vlog", "funny", "prank"]):
        return "03_Entertainment", "Comedy & Performance"

    # News
    if any(w in combined for w in ["news", "daily", "politics", "breaking", "report"]):
        return "01_News_&_Current_Affairs", "World News"

    # Tech/Science
    if any(w in combined for w in ["tech", "science", "gadget", "review", "coding", "programming",
                                    "engineering", "space"]):
        return "04_Technology_&_Science", "Gadgets & Engineering"

    # Education
    if any(w in combined for w in ["learn", "education", "tutorial", "how to", "explain", "lecture"]):
        return "11_Education_&_Knowledge", "Learning & Tutorials"

    # Kids
    if any(w in combined for w in ["kids", "children", "nursery", "baby", "cartoon", "toy", "rhyme"]):
        return "03_Entertainment", "Kids & Family"

    # Food
    if any(w in combined for w in ["cooking", "food", "recipe", "kitchen", "eat"]):
        return "08_Food_&_Drink", "Cooking & Recipes"

    # General
    return "17_General_Interests", "General"


def run_phase1(base_path, apply_changes=False):
    """Execute all Phase 1 workstreams."""
    report = {
        "spam_removed": [],
        "youtube_tier_a_moved": [],
        "youtube_tier_b_restricted": [],
        "global_dedup_moved": [],
        "decontaminated": [],
        "language_backfilled": [],
        "language_normalized": [],
    }

    base = Path(base_path)
    feeds_dir = base / "feedmine" / "Resources" / "Feeds"

    print("=" * 70)
    print("PHASE 1: Editorial Cleanup — 'Stop the Bleeding'")
    print("=" * 70)

    # ── Load all data ───────────────────────────────────────────────────
    print("\n[1/6] Loading all OPMLs...")
    all_feeds, all_trees = load_all_countries(feeds_dir)
    topic_files = load_all_topics(feeds_dir)
    total_countries = len(all_feeds)
    total_feeds = sum(len(f) for f in all_feeds.values())
    print(f"  Loaded {total_countries} countries, {total_feeds} feeds")
    print(f"  Loaded {len(topic_files)} topic files")

    # ── WS-3: Spam removal ─────────────────────────────────────────────
    print("\n[2/6] WS-3: Spam removal...")
    spam_total = 0
    for country, (tree, root, opml_path) in all_trees.items():
        removed = remove_spam(root, report)
        if removed > 0:
            spam_total += removed
            print(f"  {country}: removed {removed} spam feed(s)")
    print(f"  Total spam removed: {spam_total}")

    # ── WS-1: YouTube tier classification ──────────────────────────────
    print("\n[3/6] WS-1: YouTube rationalization...")
    yt_index = build_youtube_channel_index(all_feeds)
    yt_tiers = compute_youtube_tiers(yt_index)
    tier_a_count = sum(1 for t in yt_tiers.values() if t == "tier_a")
    tier_b_count = sum(1 for t in yt_tiers.values() if t == "tier_b")
    tier_c_count = sum(1 for t in yt_tiers.values() if t == "tier_c")
    print(f"  YouTube channels: Tier A={tier_a_count}, Tier B={tier_b_count}, Tier C={tier_c_count}")

    # Prepare topic files for receiving Tier A channels
    topic_insertions = defaultdict(list)  # {topic_key: [feed_elements]}

    yt_removed_from_countries = 0
    for country, (tree, root, opml_path) in all_trees.items():
        feeds = find_all_feeds(root)
        country_langs = COUNTRY_LANGUAGES.get(country, set())
        for feed_elem, parent_elem in feeds:
            if not is_youtube_feed(feed_elem):
                continue
            ch_id = get_channel_id(feed_elem)
            if not ch_id or ch_id not in yt_tiers:
                continue

            tier = yt_tiers[ch_id]

            if tier == "tier_a":
                # Remove from country, add to topic file
                topic_key, subcat = assign_topic_subcategory(feed_elem)
                feed_copy = copy.deepcopy(feed_elem)
                feed_copy.set("feedmineTopic", topic_key.replace("_", " & ").replace("0", "").replace("1", "").replace("2", "").replace("3", "").replace("4", "").replace("5", "").replace("6", "").replace("7", "").lstrip(" & "))
                topic_insertions[(topic_key, subcat)].append(feed_copy)
                remove_feed(feed_elem, parent_elem)
                yt_removed_from_countries += 1
                report["youtube_tier_a_moved"].append({
                    "channel_id": ch_id,
                    "from_country": country,
                    "to_topic": topic_key,
                    "title": feed_elem.get("text", ""),
                })

            elif tier == "tier_b":
                # Only keep if country is in a matching language cluster
                # Check if feed language matches country languages
                feed_lang = feed_elem.get("language", "").strip()
                normalized = normalize_lang_code(feed_lang) if feed_lang else ""
                lang_base = normalized.split("-")[0].lower() if normalized else ""

                keep = False
                country_lang_bases = {l.split("-")[0].lower() for l in country_langs}
                if lang_base and lang_base in country_lang_bases:
                    keep = True
                elif not lang_base:
                    # No language info — keep for now but flag
                    keep = True  # Keep but could be removed later

                if not keep:
                    remove_feed(feed_elem, parent_elem)
                    yt_removed_from_countries += 1
                    report["youtube_tier_b_restricted"].append({
                        "channel_id": ch_id,
                        "from_country": country,
                        "title": feed_elem.get("text", ""),
                        "reason": f"language mismatch: {lang_base} not in {country_langs}",
                    })

    print(f"  YouTube feeds removed from countries: {yt_removed_from_countries}")
    print(f"  Topic insertions prepared: {sum(len(v) for v in topic_insertions.values())}")

    # Insert Tier A channels into topic files
    if apply_changes:
        for (topic_key, subcat), feeds in topic_insertions.items():
            if topic_key not in topic_files:
                print(f"  WARNING: no topic file for {topic_key}, skipping {len(feeds)} feeds")
                continue
            tree, root, opml_path = topic_files[topic_key]
            topic_name = topic_key.split("_", 1)[1] if "_" in topic_key else topic_key
            section = find_or_create_topic_section(root, topic_name)
            subcat_elem = find_or_create_subcategory(section, subcat)
            for feed in feeds:
                subcat_elem.append(feed)
            print(f"  Added {len(feeds)} feeds to {topic_key}/{subcat}")

    # ── WS-2: Global non-YouTube dedup ─────────────────────────────────
    print("\n[4/6] WS-2: Global non-YouTube dedup...")
    non_yt_index = build_feed_country_index(all_feeds)
    global_non_yt = {url: data for url, data in non_yt_index.items()
                     if len(data["countries"]) >= 10}
    global_non_yt_by_count = Counter()
    for url, data in global_non_yt.items():
        global_non_yt_by_count[len(data["countries"])] += 1
    print(f"  Non-YouTube feeds in 10+ countries: {len(global_non_yt)}")
    print(f"  Distribution: {dict(sorted(global_non_yt_by_count.items())[:10])}")

    # For each global non-YouTube feed, move to appropriate topic file
    non_yt_moved = 0
    for url, data in global_non_yt.items():
        feed_data = data["feed_data"]
        if feed_data is None:
            continue
        topic_key, subcat = assign_topic_subcategory(feed_data)
        topic_insertions[(topic_key, subcat)].append(copy.deepcopy(feed_data))

        # Remove from all countries
        for country in data["countries"]:
            if country not in all_trees:
                continue
            tree, root, opml_path = all_trees[country]
            feeds = find_all_feeds(root)
            for feed_elem, parent_elem in feeds:
                if feed_elem.get("xmlUrl") == url:
                    remove_feed(feed_elem, parent_elem)
                    non_yt_moved += 1

    print(f"  Non-YouTube global feeds removed from countries: {non_yt_moved}")

    # ── WS-4: Keyword decontamination ──────────────────────────────────
    print("\n[5/6] WS-4: Keyword-matching decontamination...")
    decontamination_count = 0
    decontamination_candidates = []
    for country, (tree, root, opml_path) in all_trees.items():
        feeds = find_all_feeds(root)
        for feed_elem, parent_elem in feeds:
            is_misplaced, reason = is_likely_misplaced(feed_elem, country)
            if is_misplaced:
                decontamination_candidates.append({
                    "country": country,
                    "title": feed_elem.get("text", ""),
                    "url": feed_elem.get("xmlUrl", ""),
                    "language": feed_elem.get("language", ""),
                    "reason": reason,
                    "feed_elem": feed_elem,
                    "parent_elem": parent_elem,
                })

    print(f"  Decontamination candidates found: {len(decontamination_candidates)}")
    for c in decontamination_candidates[:20]:
        print(f"    [{c['country']}] {c['title'][:60]} — {c['reason']}")
    if len(decontamination_candidates) > 20:
        print(f"    ... and {len(decontamination_candidates) - 20} more")

    # In apply mode, remove the misplaced feeds
    if apply_changes:
        for c in decontamination_candidates:
            remove_feed(c["feed_elem"], c["parent_elem"])
            decontamination_count += 1
            report["decontaminated"].append({
                "country": c["country"],
                "title": c["title"],
                "url": c["url"],
                "reason": c["reason"],
            })
    else:
        decontamination_count = len(decontamination_candidates)
        report["decontaminated"] = decontamination_candidates

    print(f"  Feeds flagged for decontamination: {decontamination_count}")

    # ── WS-6: Language metadata ────────────────────────────────────────
    print("\n[6/6] WS-6: Language metadata backfill & normalization...")
    lang_backfilled = 0
    lang_normalized = 0
    lang_still_missing = 0
    for country, (tree, root, opml_path) in all_trees.items():
        feeds = find_all_feeds(root)
        for feed_elem, parent_elem in feeds:
            current_lang = feed_elem.get("language", "").strip()
            if not current_lang:
                action, detail = backfill_language(feed_elem, country)
                if action:
                    lang_backfilled += 1
            else:
                normalized = normalize_lang_code(current_lang)
                if normalized and normalized != current_lang:
                    feed_elem.set("language", normalized)
                    lang_normalized += 1

    print(f"  Language backfilled: {lang_backfilled}")
    print(f"  Language normalized: {lang_normalized}")

    # ── Write changes ──────────────────────────────────────────────────
    if apply_changes:
        print("\n" + "=" * 70)
        print("APPLYING CHANGES...")
        print("=" * 70)

        # Write country OPMLs
        for country, (tree, root, opml_path) in all_trees.items():
            write_opml(tree, opml_path)
        print(f"  Written {len(all_trees)} country OPMLs")

        # Write topic OPMLs (with new Tier A inserts)
        for topic_key, (tree, root, opml_path) in topic_files.items():
            write_opml(tree, opml_path)
        print(f"  Written {len(topic_files)} topic OPMLs")

        # Write report
        report_path = base / "scripts" / "phase1_cleanup_report.csv"
        with open(report_path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["workstream", "detail", "count"])
            writer.writerow(["WS-3_spam", "removed", spam_total])
            writer.writerow(["WS-1_youtube", "tier_a_moved", len(report["youtube_tier_a_moved"])])
            writer.writerow(["WS-1_youtube", "tier_b_restricted", len(report["youtube_tier_b_restricted"])])
            writer.writerow(["WS-2_dedup", "global_moved", non_yt_moved])
            writer.writerow(["WS-4_decontamination", "flagged", decontamination_count])
            writer.writerow(["WS-6_language", "backfilled", lang_backfilled])
            writer.writerow(["WS-6_language", "normalized", lang_normalized])
        print(f"  Report written to {report_path}")

        # Count final state
        all_feeds_final, _ = load_all_countries(feeds_dir)
        final_total = sum(len(f) for f in all_feeds_final.values())
        print(f"\n  Before: {total_feeds} feeds across {total_countries} countries")
        print(f"  After:  {final_total} feeds across {total_countries} countries")
        print(f"  Delta:  {final_total - total_feeds} ({((final_total - total_feeds) / total_feeds * 100):.1f}%)")
    else:
        print("\n" + "=" * 70)
        print("DRY RUN — no changes applied. Use --apply to execute.")
        print("=" * 70)
        print(f"\n  Would remove spam: {spam_total}")
        print(f"  Would move YouTube Tier A to topics: {yt_removed_from_countries}")
        print(f"  Would dedup non-YouTube globals: {non_yt_moved}")
        print(f"  Would flag for decontamination: {decontamination_count}")
        print(f"  Would backfill language: {lang_backfilled}")
        print(f"  Would normalize language: {lang_normalized}")

    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Feedmine Phase 1 Editorial Cleanup")
    parser.add_argument("--apply", action="store_true", help="Apply changes (default: dry-run)")
    parser.add_argument("--worktree", type=str, default=None,
                        help="Path to the git worktree root")
    args = parser.parse_args()

    if args.worktree:
        base_path = args.worktree
    else:
        # Auto-detect: find repo root
        script_dir = Path(__file__).resolve().parent
        base_path = script_dir.parent

    run_phase1(base_path, apply_changes=args.apply)
