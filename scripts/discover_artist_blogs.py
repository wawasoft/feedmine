#!/usr/bin/env python3
"""
Multi-strategy artist/musician/actor blog RSS feed discovery for each Feedmine country.

Strategies:
  1. Seed from famous_people.txt  — curated names with known platforms
  2. Localized web search          — "cantor blog RSS" etc. via DuckDuckGo
  3. Platform-specific             — Substack, Medium, WordPress, Ghost, Blogspot, Blogger
  4. Wikidata SPARQL               — musicians, actors, artists by country with websites
  5. Social-profile → website      — Instagram/Twitter/YouTube bio links → feed discovery

Output: per-country JSON cache + OPML ready for editorial review.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional
from urllib.parse import urljoin, urlparse

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:
    from catalog_identity import compute_source_id

# ---------------------------------------------------------------------------
# Language → artist / musician / actor / singer / performer terms
# ---------------------------------------------------------------------------

ARTIST_TERMS: dict[str, list[str]] = {
    "en": [
        "musician", "singer", "actor", "actress", "artist", "painter",
        "sculptor", "photographer", "filmmaker", "composer", "songwriter",
        "rapper", "DJ", "producer", "performer", "director", "dancer",
        "choreographer", "conductor", "band",
    ],
    "es": [
        "músico", "cantante", "actor", "actriz", "artista", "pintor",
        "escultor", "fotógrafo", "cineasta", "compositor", "cantautor",
        "rapero", "DJ", "productor", "bailarín", "director", "banda",
    ],
    "pt": [
        "músico", "cantor", "cantora", "ator", "atriz", "artista", "pintor",
        "escultor", "fotógrafo", "cineasta", "compositor", "cantautor",
        "rapper", "DJ", "produtor", "dançarino", "diretor", "banda",
    ],
    "fr": [
        "musicien", "chanteur", "chanteuse", "acteur", "actrice", "artiste",
        "peintre", "sculpteur", "photographe", "cinéaste", "compositeur",
        "rappeur", "DJ", "producteur", "danseur", "réalisateur", "groupe",
    ],
    "de": [
        "Musiker", "Sänger", "Sängerin", "Schauspieler", "Schauspielerin",
        "Künstler", "Maler", "Bildhauer", "Fotograf", "Filmemacher",
        "Komponist", "Rapper", "DJ", "Produzent", "Tänzer", "Regisseur", "Band",
    ],
    "it": [
        "musicista", "cantante", "attore", "attrice", "artista", "pittore",
        "scultore", "fotografo", "regista", "compositore", "cantautore",
        "rapper", "DJ", "produttore", "ballerino", "band",
    ],
    "ar": [
        "موسيقي", "مغني", "ممثل", "فنان", "رسام", "نحات", "مصور",
        "ملحن", "مخرج", "راقص", "فرقة", "دي جي", "منتج", "مؤلف",
    ],
    "ru": [
        "музыкант", "певец", "актёр", "актриса", "художник", "скульптор",
        "фотограф", "композитор", "режиссёр", "танцор", "диджей",
        "продюсер", "рэпер", "группа", "исполнитель",
    ],
    "zh": [
        "音乐家", "歌手", "演员", "艺术家", "画家", "雕塑家", "摄影师",
        "作曲家", "导演", "舞者", "乐队", "制作人", "说唱歌手", "DJ",
    ],
    "ja": [
        "ミュージシャン", "歌手", "俳優", "女優", "アーティスト", "画家",
        "写真家", "作曲家", "映画監督", "ダンサー", "バンド", "DJ",
        "プロデューサー", "ラッパー", "演出家",
    ],
    "ko": [
        "음악가", "가수", "배우", "아티스트", "화가", "사진작가", "작곡가",
        "감독", "댄서", "밴드", "DJ", "프로듀서", "래퍼", "연주자",
    ],
    "hi": [
        "संगीतकार", "गायक", "अभिनेता", "कलाकार", "चित्रकार", "फोटोग्राफर",
        "संगीत", "निर्देशक", "नर्तक", "बैंड", "डीजे", "रैपर",
    ],
    "tr": [
        "müzisyen", "şarkıcı", "oyuncu", "sanatçı", "ressam", "fotoğrafçı",
        "besteci", "yönetmen", "dansçı", "grup", "DJ", "prodüktör", "rapçi",
    ],
    "nl": [
        "muzikant", "zanger", "acteur", "actrice", "kunstenaar", "schilder",
        "fotograaf", "componist", "regisseur", "danser", "band", "DJ", "producer",
    ],
    "pl": [
        "muzyk", "piosenkarz", "aktor", "aktorka", "artysta", "malarz",
        "fotograf", "kompozytor", "reżyser", "tancerz", "zespół", "DJ", "producent",
    ],
    "vi": [
        "nhạc sĩ", "ca sĩ", "diễn viên", "nghệ sĩ", "họa sĩ", "nhiếp ảnh gia",
        "nhà soạn nhạc", "đạo diễn", "vũ công", "ban nhạc", "DJ", "nhà sản xuất",
    ],
    "th": [
        "นักดนตรี", "นักร้อง", "นักแสดง", "ศิลปิน", "จิตรกร", "ช่างภาพ",
        "นักแต่งเพลง", "ผู้กำกับ", "นักเต้น", "วงดนตรี", "ดีเจ", "โปรดิวเซอร์",
    ],
    "id": [
        "musisi", "penyanyi", "aktor", "aktris", "seniman", "pelukis",
        "fotografer", "komposer", "sutradara", "penari", "band", "DJ", "produser",
    ],
    "fa": [
        "موسیقی‌دان", "خواننده", "بازیگر", "هنرمند", "نقاش", "عکاس",
        "آهنگساز", "کارگردان", "رقاص", "گروه", "دی‌جی", "تهیه‌کننده",
    ],
    "uk": [
        "музикант", "співак", "актор", "актриса", "художник", "скульптор",
        "фотограф", "композитор", "режисер", "танцюрист", "гурт", "діджей",
    ],
    "sv": [
        "musiker", "sångare", "skådespelare", "konstnär", "målare", "fotograf",
        "kompositör", "regissör", "dansare", "band", "DJ", "producent",
    ],
    "el": [
        "μουσικός", "τραγουδιστής", "ηθοποιός", "καλλιτέχνης", "ζωγράφος",
        "φωτογράφος", "συνθέτης", "σκηνοθέτης", "χορευτής", "συγκρότημα", "DJ",
    ],
    "cs": [
        "hudebník", "zpěvák", "herec", "herečka", "umělec", "malíř",
        "fotograf", "skladatel", "režisér", "tanečník", "kapela", "DJ",
    ],
    "hu": [
        "zenész", "énekes", "színész", "színésznő", "művész", "festő",
        "fotós", "zeneszerző", "rendező", "táncos", "zenekar", "DJ",
    ],
    "ro": [
        "muzician", "cântăreț", "actor", "actriță", "artist", "pictor",
        "fotograf", "compozitor", "regizor", "dansator", "trupă", "DJ",
    ],
    "he": [
        "מוזיקאי", "זמר", "שחקן", "אמן", "צייר", "צלם", "מלחין", "במאי",
        "רקדן", "להקה", "די ג׳יי", "מפיק",
    ],
    "sw": [
        "mwanamuziki", "mwimbaji", "muigizaji", "msanii", "mpiga picha",
        "mtunzi", "mkurugenzi", "bendi", "DJ", "mtayarishaji",
    ],
}

BLOG_TERMS: dict[str, str] = {
    "en": "blog", "es": "blog", "pt": "blog", "fr": "blog", "de": "Blog",
    "it": "blog", "ar": "مدونة", "ru": "блог", "zh": "博客", "ja": "ブログ",
    "ko": "블로그", "hi": "ब्लॉग", "bn": "ব্লগ", "tr": "blog",
    "nl": "blog", "pl": "blog", "vi": "blog", "th": "บล็อก",
    "id": "blog", "ms": "blog", "fa": "وبلاگ", "uk": "блог",
    "sv": "blogg", "no": "blogg", "da": "blog", "fi": "blogi",
    "el": "ιστολόγιο", "cs": "blog", "sk": "blog", "hu": "blog",
    "ro": "blog", "bg": "блог", "sr": "блог", "hr": "blog",
    "sl": "blog", "lt": "blogas", "lv": "blogs", "et": "blogi",
    "he": "בלוג", "sw": "blogu",
}

# Languages spoken per country
COUNTRY_LANGS: dict[str, list[str]] = {
    "algeria": ["ar", "fr"], "angola": ["pt"], "argentina": ["es"],
    "armenia": ["hy"], "australia": ["en"], "austria": ["de"],
    "azerbaijan": ["az", "ru"], "bangladesh": ["bn", "en"],
    "belarus": ["be", "ru"], "belgium": ["nl", "fr", "de"],
    "bolivia": ["es"], "brazil": ["pt"], "bulgaria": ["bg"],
    "cambodia": ["km"], "canada": ["en", "fr"], "chile": ["es"],
    "china": ["zh"], "colombia": ["es"], "costa_rica": ["es"],
    "croatia": ["hr"], "cuba": ["es"], "cyprus": ["el"],
    "czech_republic": ["cs"], "denmark": ["da"],
    "dominican_republic": ["es"], "ecuador": ["es"], "egypt": ["ar"],
    "el_salvador": ["es"], "estonia": ["et"], "ethiopia": ["am"],
    "finland": ["fi", "sv"], "france": ["fr"], "georgia": ["ka"],
    "germany": ["de"], "ghana": ["en"], "greece": ["el"],
    "guatemala": ["es"], "haiti": ["fr", "ht"], "honduras": ["es"],
    "hungary": ["hu"], "iceland": ["is"], "india": ["hi", "en"],
    "indonesia": ["id"], "iran": ["fa"], "iraq": ["ar"],
    "ireland": ["en"], "israel": ["he", "ar"], "italy": ["it"],
    "ivory_coast": ["fr"], "jamaica": ["en"], "japan": ["ja"],
    "kazakhstan": ["kk", "ru"], "kenya": ["en", "sw"],
    "latvia": ["lv"], "lithuania": ["lt"], "luxembourg": ["fr", "de"],
    "malaysia": ["ms", "en"], "malta": ["mt", "en"], "mexico": ["es"],
    "morocco": ["ar", "fr"], "myanmar": ["my"], "nepal": ["ne"],
    "netherlands": ["nl"], "new_zealand": ["en"],
    "nicaragua": ["es"], "nigeria": ["en"], "norway": ["no"],
    "pakistan": ["ur", "en"], "panama": ["es"], "paraguay": ["es"],
    "peru": ["es"], "philippines": ["tl", "en"], "poland": ["pl"],
    "portugal": ["pt"], "puerto_rico": ["es"], "qatar": ["ar"],
    "romania": ["ro"], "russia": ["ru"], "saudi_arabia": ["ar"],
    "serbia": ["sr"], "singapore": ["en", "zh", "ms", "ta"],
    "slovakia": ["sk"], "slovenia": ["sl"],
    "south_africa": ["en", "af", "zu", "xh"],
    "south_korea": ["ko"], "spain": ["es"], "sri_lanka": ["si", "ta", "en"],
    "sudan": ["ar"], "sweden": ["sv"], "switzerland": ["de", "fr", "it"],
    "taiwan": ["zh"], "thailand": ["th"], "tunisia": ["ar", "fr"],
    "turkey": ["tr"], "uae": ["ar"], "ukraine": ["uk"],
    "united_kingdom": ["en"], "uruguay": ["es"], "usa": ["en"],
    "venezuela": ["es"], "vietnam": ["vi"],
}


# ---------------------------------------------------------------------------
# Seed data: parse famous_people.txt for artist/musician/actor entries
# ---------------------------------------------------------------------------

def parse_famous_people(famous_path: Path) -> dict[str, list[dict]]:
    """Parse famous_people.txt and return per-country artist entries.

    Only pulls entries from categories: Arts & Culture, Music & Audio,
    Entertainment, Music (extra).
    Returns dict[country_slug_lower] -> list of {name, known_for, platforms}.
    """
    ARTIST_CATEGORIES = {
        "arts & culture", "music & audio", "entertainment",
        "music (extra)", "music", "arts", "culture",
    }

    by_country: dict[str, list[dict]] = {}
    current_country: str | None = None
    current_category: str | None = None

    # Country name → slug mapping (from countries.json patterns)
    country_name_to_slug: dict[str, str] = {}

    if not famous_path.exists():
        print(f"  [warn] famous_people.txt not found at {famous_path}", file=sys.stderr)
        return by_country

    content = famous_path.read_text(encoding="utf-8")

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("==="):
            continue

        # Section headers: # --- BRAZIL (50+) ---
        country_match = re.match(r'^#\s*---\s*(.+?)\s*\(', line)
        if country_match:
            raw_name = country_match.group(1).strip()
            current_country = raw_name.lower().replace(" ", "_")
            continue

        # Category headers: # Music & Audio
        cat_match = re.match(r'^#\s*(.+)', line)
        if cat_match and not re.search(r'[|]', line):
            current_category = cat_match.group(1).strip().lower()
            continue

        # Data lines: Name | known for | platform1, platform2
        if "|" in line and current_country and current_category:
            if current_category in ARTIST_CATEGORIES:
                parts = [p.strip() for p in line.split("|")]
                if len(parts) >= 2:
                    name = parts[0]
                    known_for = parts[1]
                    platforms = parts[2] if len(parts) > 2 else ""
                    by_country.setdefault(current_country, []).append({
                        "name": name,
                        "known_for": known_for,
                        "platforms": platforms,
                    })

    return by_country


# ---------------------------------------------------------------------------
# Wikidata SPARQL — find artists with personal websites by country
# ---------------------------------------------------------------------------

WIKIDATA_SPARQL_URL = "https://query.wikidata.org/sparql"

# ISO2 → Wikidata Q-ID cache
COUNTRY_QID_MAP: dict[str, str] = {}

ARTIST_SPARQL_QUERIES = {
    "musicians": """
        SELECT DISTINCT ?item ?itemLabel ?website WHERE {{
          ?item wdt:P106 wd:{occupation}.
          ?item wdt:P17 wd:{country_qid}.
          OPTIONAL {{ ?item wdt:P856 ?website. }}
          SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{lang},en". }}
        }}
        LIMIT 200
    """,
    "actors": """
        SELECT DISTINCT ?item ?itemLabel ?website WHERE {{
          ?item wdt:P106 wd:{occupation}.
          ?item wdt:P17 wd:{country_qid}.
          OPTIONAL {{ ?item wdt:P856 ?website. }}
          SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{lang},en". }}
        }}
        LIMIT 200
    """,
    "painters": """
        SELECT DISTINCT ?item ?itemLabel ?website WHERE {{
          ?item wdt:P106 wd:{occupation}.
          ?item wdt:P17 wd:{country_qid}.
          OPTIONAL {{ ?item wdt:P856 ?website. }}
          SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{lang},en". }}
        }}
        LIMIT 100
    """,
}

# Wikidata occupation Q-IDs
OCCUPATION_QIDS = {
    "musicians": ["Q639669", "Q177220", "Q488205", "Q753110", "Q36834", "Q2252262"],
    "actors": ["Q33999", "Q10800557"],
    "painters": ["Q1028181", "Q1281618", "Q33231"],
}


def _resolve_country_qid(iso2: str) -> str | None:
    """Resolve ISO2 country code to Wikidata Q-ID via SPARQL."""
    if iso2 in COUNTRY_QID_MAP:
        return COUNTRY_QID_MAP[iso2]

    query = f"""
        SELECT ?country WHERE {{
          ?country wdt:P297 "{iso2.upper()}".
        }}
        LIMIT 1
    """
    try:
        req = urllib.request.Request(
            WIKIDATA_SPARQL_URL + "?format=json&query=" + urllib.parse.quote(query),
            headers={"User-Agent": "Feedmine/1.0", "Accept": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
        bindings = data.get("results", {}).get("bindings", [])
        if bindings:
            qid_url = bindings[0]["country"]["value"]
            qid = qid_url.split("/")[-1]
            COUNTRY_QID_MAP[iso2] = qid
            return qid
    except Exception as e:
        print(f"  [warn] Wikidata QID lookup failed for {iso2}: {e}", file=sys.stderr)
    return None


def query_wikidata_artists(country_slug: str, iso2: str, lang: str) -> list[dict]:
    """Query Wikidata for artists from a country with websites."""
    country_qid = _resolve_country_qid(iso2)
    if not country_qid:
        return []

    results: list[dict] = []

    for category, qids in OCCUPATION_QIDS.items():
        for qid in qids[:1]:  # just use the primary QID per category
            query = ARTIST_SPARQL_QUERIES["musicians"].format(
                occupation=qid, country_qid=country_qid, lang=lang
            )
            try:
                url = WIKIDATA_SPARQL_URL + "?format=json&query=" + urllib.parse.quote(query)
                req = urllib.request.Request(
                    url,
                    headers={"User-Agent": "Feedmine/1.0", "Accept": "application/json"},
                )
                with urllib.request.urlopen(req, timeout=20) as resp:
                    data = json.loads(resp.read())
            except Exception as e:
                print(f"  [warn] Wikidata query failed: {e}", file=sys.stderr)
                continue

            for binding in data.get("results", {}).get("bindings", []):
                name = binding.get("itemLabel", {}).get("value", "")
                website = binding.get("website", {}).get("value", "")
                if website and name:
                    results.append({
                        "name": name,
                        "website": website,
                        "source": f"wikidata:{category}",
                    })

            time.sleep(0.5)  # be nice to Wikidata

    return results


# ---------------------------------------------------------------------------
# DuckDuckGo search
# ---------------------------------------------------------------------------

def _safe_import_ddgs():
    try:
        from ddgs import DDGS
        return DDGS
    except ImportError:
        return None


def search_ddg(query: str, region: str, max_results: int = 20) -> list[str]:
    """Search DuckDuckGo and return list of URLs."""
    DDGS = _safe_import_ddgs()
    if DDGS is None:
        print("  [warn] ddgs not installed; pip install ddgs", file=sys.stderr)
        return []
    urls: list[str] = []
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, region=region, max_results=max_results))
        for row in results:
            u = (row.get("href") or row.get("url") or row.get("link") or "").strip()
            if u.startswith(("http://", "https://")):
                urls.append(u)
    except Exception as e:
        print(f"  [warn] DDG search failed for '{query}': {e}", file=sys.stderr)
        # Retry without region
        try:
            with DDGS() as ddgs:
                results = list(ddgs.text(query, region="wt-wt", max_results=max_results))
            for row in results:
                u = (row.get("href") or row.get("url") or row.get("link") or "").strip()
                if u.startswith(("http://", "https://")):
                    urls.append(u)
        except Exception:
            pass
    return urls


# Platform-specific search prefixes
PLATFORM_SEARCHES = [
    ("substack.com", "site:substack.com"),
    ("medium.com", "site:medium.com"),
    ("wordpress.com", "site:*.wordpress.com OR site:wordpress.com"),
    ("ghost.io", "site:ghost.io"),
    ("blogspot.com", "site:blogspot.com"),
    ("blogger.com", "site:blogger.com"),
]

# Country-specific blogging platforms
COUNTRY_PLATFORMS: dict[str, list[tuple[str, str]]] = {
    "japan": [("ameblo.jp", "site:ameblo.jp"), ("note.com", "site:note.com")],
    "china": [("zhihu.com", "site:zhihu.com/column"), ("jianshu.com", "site:jianshu.com")],
    "russia": [("livejournal.com", "site:livejournal.com"), ("dzen.ru", "site:dzen.ru")],
    "south_korea": [("tistory.com", "site:tistory.com"), ("naver.com", "site:blog.naver.com")],
    "brazil": [("blogger.com.br", "site:blogger.com.br"), ("uol.com.br", "site:blogdo")],
    "france": [("over-blog.com", "site:over-blog.com"), ("canalblog.com", "site:canalblog.com")],
    "iran": [("blog.ir", "site:blog.ir"), ("virgool.io", "site:virgool.io")],
    "vietnam": [("blogspot.com", 'site:blogspot.com "Việt Nam"')],
    "india": [("blogger.com", 'site:blogger.com "India"')],
}


# ---------------------------------------------------------------------------
# Feed validation
# ---------------------------------------------------------------------------

def is_likely_feed_url(url: str) -> bool:
    """Check if a URL is likely an RSS/Atom feed."""
    patterns = [
        r'/feed/?$', r'/rss/?$', r'/atom/?$', r'\.xml$',
        r'/feeds/', r'\.rss$', r'\.atom$',
        r'index\.xml$', r'rss\.xml$', r'atom\.xml$',
    ]
    return any(re.search(p, url, re.I) for p in patterns)


def extract_feeds_from_page(url: str, timeout: int = 10) -> list[str]:
    """Fetch a page and extract RSS/Atom feed URLs from <link> tags."""
    feeds: list[str] = []
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0 (RSS discovery; +https://feedmine.app)"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return feeds
            html_text = resp.read().decode("utf-8", errors="replace")[:500_000]
    except Exception:
        return feeds

    # Look for <link> feed tags
    link_pattern = re.compile(
        r'<link[^>]*\b(?:rel|type)=["\'][^"\']*(?:alternate|feed|rss|atom)[^"\']*["\'][^>]*\bhref=["\']([^"\']+)["\']',
        re.I,
    )
    for m in link_pattern.finditer(html_text):
        feed_url = urljoin(url, m.group(1))
        feeds.append(feed_url)

    # Also check for common feed paths on the domain root
    parsed = urlparse(url)
    base = f"{parsed.scheme}://{parsed.netloc}"
    common_paths = ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml"]
    for path in common_paths:
        feeds.append(f"{base}{path}")

    return feeds


def validate_feed_url(url: str, timeout: int = 8) -> tuple[bool, str]:
    """Check if a URL returns valid RSS/Atom XML."""
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return False, f"HTTP {resp.status}"
            data = resp.read(50_000)
            text = data.decode("utf-8", errors="replace")[:2000].strip().lower()
            has_rss = "<rss" in text or "<feed" in text or "<rdf" in text
            if not has_rss:
                return False, "no RSS/Atom markers"
            return True, "valid"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)[:100]


# ---------------------------------------------------------------------------
# Main discovery orchestrator
# ---------------------------------------------------------------------------

def discover_for_country(
    country_slug: str,
    country_name: str,
    cctld: str,
    ddg_region: str,
    iso2: str,
    langs: list[str],
    existing_urls: set[str],
    famous_entries: list[dict],
    cache_dir: Path,
    max_per_strategy: int = 20,
    delay: float = 2.0,
    fresh: bool = False,
) -> list[dict]:
    """Run all discovery strategies for one country."""
    cache_file = cache_dir / f"{country_slug}_artists.json"
    if not fresh and cache_file.exists():
        try:
            cached = json.loads(cache_file.read_text(encoding="utf-8"))
            if cached:
                print(f"  [cache] Loaded {len(cached)} cached candidates")
                return cached
        except Exception:
            pass

    all_candidates: list[dict] = []
    seen_urls: set[str] = set()

    def add_candidate(url: str, title: str = "", source: str = "", name: str = ""):
        url = url.strip().rstrip("/")
        norm = url.lower().split("#")[0]
        if norm in seen_urls or norm in existing_urls:
            return
        seen_urls.add(norm)
        all_candidates.append({
            "url": url,
            "title": title or name or url,
            "source": source,
            "name": name,
        })

    # Build artist term set for this country's languages
    artist_terms_set: set[str] = set()
    for lang in langs:
        terms = ARTIST_TERMS.get(lang, ARTIST_TERMS.get("en", []))
        artist_terms_set.update(terms)
        if lang != "en":
            artist_terms_set.update(ARTIST_TERMS.get("en", [])[:4])

    terms = list(artist_terms_set)[:10]

    blog_term_map = {}
    for lang in langs:
        bt = BLOG_TERMS.get(lang, "blog")
        blog_term_map[lang] = bt

    # ── Strategy 0: Famous people seed URLs ────────────────────────────
    print(f"  [0/5] Seed from famous_people.txt ({len(famous_entries)} entries)...")
    blog_platforms = {"blog", "substack", "website", "newsletter"}
    for entry in famous_entries:
        platforms = {p.strip().lower() for p in entry["platforms"].split(",")}
        if platforms & blog_platforms:
            name = entry["name"]
            # Search for the person's blog/website
            for lang in langs[:2]:
                bt = blog_term_map.get(lang, "blog")
                query = f'"{name}" {bt}'
                urls = search_ddg(query, ddg_region, max_results=5)
                for u in urls:
                    add_candidate(u, name, f"famous-seed:{name}", name)
                time.sleep(delay * 0.5)

    # ── Strategy 1: Direct artist blog search ──────────────────────────
    print(f"  [1/5] Direct artist blog search queries...")
    for term in terms[:6]:
        for lang in langs[:2]:
            bt = blog_term_map.get(lang, "blog")
            query = f'"{term}" {bt} RSS'
            if cctld and len(cctld) <= 3:
                query += f" site:.{cctld}"
            urls = search_ddg(query, ddg_region, max_results=15)
            for u in urls:
                add_candidate(u, "", f"ddg:{query}")
            time.sleep(delay)

    # ── Strategy 2: Platform-specific searches ─────────────────────────
    print(f"  [2/5] Platform-specific searches...")

    # Standard platforms
    all_platforms = list(PLATFORM_SEARCHES)
    # Add country-specific platforms
    for plat in COUNTRY_PLATFORMS.get(country_slug, []):
        all_platforms.append(plat)

    for platform_domain, site_op in all_platforms:
        for term in terms[:3]:
            for lang in langs[:2]:
                bt = blog_term_map.get(lang, "blog")
                query = f'{term} {bt} {site_op}'
                if country_name:
                    query += f' "{country_name}"'
                urls = search_ddg(query, ddg_region, max_results=10)
                for u in urls:
                    add_candidate(u, "", f"platform:{platform_domain}:{term}")
                time.sleep(delay * 0.8)

    # ── Strategy 3: "{artist_type} blog {country}" ─────────────────────
    print(f"  [3/5] Artist blog + country queries...")
    for term in terms[:4]:
        for lang in langs[:2]:
            bt = blog_term_map.get(lang, "blog")
            # Official/personal site indicators
            for modifier in ["oficial", "official", "personal", "site", "página"]:
                query = f'{term} {bt} {modifier} "{country_name}"'
                urls = search_ddg(query, ddg_region, max_results=8)
                for u in urls:
                    add_candidate(u, "", f"artist-blog:{term}:{modifier}")
                time.sleep(delay * 0.5)

    # ── Strategy 4: Wikidata SPARQL ────────────────────────────────────
    print(f"  [4/5] Wikidata SPARQL queries...")
    if iso2:
        wikidata_artists = query_wikidata_artists(country_slug, iso2, langs[0])
        for entry in wikidata_artists[:100]:
            add_candidate(entry["website"], entry["name"], entry["source"], entry["name"])

    # ── Strategy 5: Known artist names → find their websites ──────────
    print(f"  [5/5] Named artist website discovery...")
    # Use famous_people entries as search anchors
    for entry in famous_entries[:30]:
        name = entry["name"]
        if "(estate)" in name or "(legacy)" in name:
            continue
        for lang in langs[:1]:
            query = f'"{name}" website oficial OR blog OR site'
            urls = search_ddg(query, ddg_region, max_results=5)
            for u in urls:
                add_candidate(u, name, f"named-search:{name}", name)
            time.sleep(delay * 0.6)

    # Save cache
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(
        json.dumps(all_candidates, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    return all_candidates


# ---------------------------------------------------------------------------
# Feed validation pass
# ---------------------------------------------------------------------------

def validate_candidates(
    candidates: list[dict],
) -> list[dict]:
    """Validate discovered URLs — resolve to actual RSS feeds, check liveness."""
    validated: list[dict] = []
    print(f"  Validating {len(candidates)} candidates...")

    for i, c in enumerate(candidates):
        url = c["url"]
        # If URL is already a feed URL, validate directly
        if is_likely_feed_url(url):
            is_valid, msg = validate_feed_url(url)
            if is_valid:
                validated.append({**c, "validated": True, "note": msg})
        else:
            # Try to discover feeds from the page
            feeds = extract_feeds_from_page(url)
            for feed_url in feeds:
                is_valid, msg = validate_feed_url(feed_url)
                if is_valid:
                    validated.append({
                        **c,
                        "url": feed_url,
                        "page_url": url,
                        "validated": True,
                        "note": "discovered from page",
                    })
                    break  # one good feed per page is enough

        if (i + 1) % 20 == 0:
            print(f"    ... {i+1}/{len(candidates)} checked, {len(validated)} valid")

    print(f"  ✓ {len(validated)} valid feeds out of {len(candidates)} candidates")
    return validated


# ---------------------------------------------------------------------------
# OPML generation
# ---------------------------------------------------------------------------

def generate_opml(
    country_name: str,
    feeds: list[dict],
    existing_urls: set[str],
) -> str:
    """Generate an OPML snippet with the new artist blog feeds."""
    lines = []
    for f in feeds:
        url = f["url"]
        norm = url.lower().split("#")[0].rstrip("/")
        if norm in existing_urls:
            continue
        title = f.get("title", "") or f.get("name", "") or url
        # Clean title
        title_esc = (
            title.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
        )
        url_esc = (
            url.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
        )

        source_id = compute_source_id(url)

        # Determine topic based on name clues
        name_lower = f.get("name", "").lower()
        if any(w in name_lower for w in ["singer", "cantor", "cantante", "song", "band", "music"]):
            topic = "Music &amp; Audio"
            subcategory = "Artist Blogs"
        elif any(w in name_lower for w in ["actor", "actress", "film", "director"]):
            topic = "Entertainment"
            subcategory = "Artist Blogs"
        else:
            topic = "Arts &amp; Culture"
            subcategory = "Artist Blogs"

        lines.append(
            f'                        <outline text="{title_esc}" title="{title_esc}" '
            f'type="rss" xmlUrl="{url_esc}" '
            f'description="Artist blog from {country_name}." '
            f'language="" '
            f'category="artist,blog,personal,{country_name.lower()}" '
            f'feedmineSourceId="{source_id}" '
            f'feedmineTopic="{topic}" '
            f'feedmineSubcategory="{subcategory}" '
            f'feedmineNature="personal" '
            f'feedmineActivity="active" '
            f'feedmineArticlesFetched="0" '
            f'feedmineQualityScore="70" '
            f'feedmineDefaultEnabled="true" '
            f'feedmineMediaKind="text" '
            f'htmlUrl="{url_esc}" />'
        )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Discover artist/musician/actor blog feeds for Feedmine countries"
    )
    parser.add_argument("--country", help="Country slug (e.g. brazil, france)")
    parser.add_argument("--all", action="store_true", help="Process all countries")
    parser.add_argument("--validate", action="store_true", help="Validate discovered feeds")
    parser.add_argument("--opml", action="store_true", help="Generate OPML output")
    parser.add_argument("--max-strategy", type=int, default=20, help="Max results per strategy")
    parser.add_argument("--delay", type=float, default=2.0, help="Delay between searches (seconds)")
    parser.add_argument("--fresh", action="store_true", help="Ignore caches")
    parser.add_argument("--output-dir", default=None, help="Output directory for OPML files")
    parser.add_argument("--max-countries", type=int, default=None, help="Limit number of countries")
    parser.add_argument("--skip-wikidata", action="store_true", help="Skip Wikidata queries (faster)")
    args = parser.parse_args()

    # Resolve paths
    repo_root = Path(__file__).resolve().parents[1]
    countries_json = repo_root / "scripts" / "feed_discovery" / "data" / "countries.json"
    countries_dir = repo_root / "feedmine" / "Resources" / "Feeds" / "90_countries"
    cache_dir = repo_root / "scripts" / "feed_discovery" / "data" / "artist_cache"
    famous_path = repo_root / "scripts" / "feed_discovery" / "data" / "famous_people.txt"

    # Load countries
    with open(countries_json, encoding="utf-8") as f:
        countries = json.load(f)

    if args.country:
        slugs = [args.country]
    elif args.all:
        slugs = list(countries.keys())
        if args.max_countries:
            slugs = slugs[:args.max_countries]
    else:
        slugs = list(countries.keys())[:3]  # default: first 3 for testing
        print(f"Testing with first {len(slugs)} countries. Use --all for full run.\n")

    # Parse famous people seed data
    famous_by_country = parse_famous_people(famous_path)
    print(f"Loaded {sum(len(v) for v in famous_by_country.values())} famous people entries "
          f"across {len(famous_by_country)} countries\n")

    total_found = 0
    total_validated = 0

    for slug in slugs:
        meta = countries[slug]
        name = meta["name"]
        cctld = meta.get("cctld", "")
        iso2 = meta.get("iso2", "")
        ddg_region = meta.get("ddg_region", f"{cctld}-{meta['lang']}")
        langs = COUNTRY_LANGS.get(slug, [meta["lang"]])

        # Gather existing feed URLs to avoid duplicates
        country_dir = countries_dir / slug
        existing_urls: set[str] = set()
        opml_file = country_dir / f"{slug}.opml"
        if opml_file.exists():
            try:
                content = opml_file.read_text(encoding="utf-8")
                for m in re.finditer(r'xmlUrl="([^"]+)"', content):
                    existing_urls.add(m.group(1).strip().rstrip("/").lower())
            except Exception:
                pass

        # Famous people for this country (match by slug or common names)
        slug_lower = slug.lower()
        famous_entries = famous_by_country.get(slug_lower, [])
        # Also try matching by country name
        name_lower = name.lower()
        if not famous_entries and name_lower in famous_by_country:
            famous_entries = famous_by_country[name_lower]

        print(f"\n{'='*60}")
        print(f"🎨 {name} ({slug}) — langs: {langs} — "
              f"{len(existing_urls)} existing feeds — {len(famous_entries)} famous names")
        print(f"{'='*60}")

        # Discover
        candidates = discover_for_country(
            slug, name, cctld, ddg_region, iso2, langs,
            existing_urls, famous_entries, cache_dir,
            max_per_strategy=args.max_strategy,
            delay=args.delay,
            fresh=args.fresh,
        )
        print(f"  → {len(candidates)} raw candidates found")

        # Validate
        validated = []
        if args.validate and candidates:
            validated = validate_candidates(candidates)
        else:
            validated = candidates
            print(f"  [skip] Validation disabled. Use --validate to check feed liveness.")

        print(f"  → {len(validated)} feeds after validation")

        # OPML output
        if args.opml and validated:
            opml_snippet = generate_opml(name, validated, existing_urls)
            output_dir = Path(args.output_dir) if args.output_dir else cache_dir / "opml"
            output_dir.mkdir(parents=True, exist_ok=True)
            output_file = output_dir / f"{slug}_artist_blogs.opml"
            output_file.write_text(opml_snippet, encoding="utf-8")
            print(f"  → OPML written to {output_file}")

        total_found += len(candidates)
        total_validated += len(validated)

    print(f"\n{'='*60}")
    print(f"Total: {total_found} raw candidates, {total_validated} validated "
          f"across {len(slugs)} countries")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
