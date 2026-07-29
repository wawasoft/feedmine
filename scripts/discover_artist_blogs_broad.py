#!/usr/bin/env python3
"""
Broad artist feed discovery for ALL Feedmine countries using Wikidata + DDG.

For each country:
  1. Wikidata SPARQL: find musicians/actors/artists with websites, extract URLs
  2. DDG search: "{musician/singer/actor} {blog} site:.cctld" in local language
  3. Feed auto-discovery: from each URL found, extract RSS feeds
  4. Concurrent validation

Handles all 101 countries. Uses per-language search terms.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import re
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from urllib.parse import urljoin, urlparse

# ---------------------------------------------------------------------------
# Country data
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[1]
COUNTRIES_JSON = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "countries.json"
CACHE_DIR = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "artist_broad"
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"

# ISO2 → Wikidata Q-ID cache
ISO2_TO_QID: dict[str, str] = {}

# ---------------------------------------------------------------------------
# Language terms
# ---------------------------------------------------------------------------

ARTIST_TERMS: dict[str, list[str]] = {
    "en": ["musician", "singer", "actor", "artist", "painter", "photographer",
           "composer", "rapper", "band", "filmmaker"],
    "es": ["músico", "cantante", "actor", "artista", "pintor", "fotógrafo",
           "compositor", "rapero", "banda", "cineasta"],
    "pt": ["músico", "cantor", "ator", "artista", "pintor", "fotógrafo",
           "compositor", "rapper", "banda", "cineasta"],
    "fr": ["musicien", "chanteur", "acteur", "artiste", "peintre", "photographe",
           "compositeur", "rappeur", "groupe", "cinéaste"],
    "de": ["Musiker", "Sänger", "Schauspieler", "Künstler", "Maler", "Fotograf",
           "Komponist", "Rapper", "Band", "Filmemacher"],
    "it": ["musicista", "cantante", "attore", "artista", "pittore", "fotografo",
           "compositore", "rapper", "band", "regista"],
    "ar": ["موسيقي", "مغني", "ممثل", "فنان", "رسام", "ملحن", "فرقة",
           "مخرج", "مصور"],
    "ru": ["музыкант", "певец", "актёр", "художник", "композитор", "режиссёр",
           "рэпер", "группа", "фотограф"],
    "zh": ["音乐家", "歌手", "演员", "艺术家", "画家", "作曲家", "导演", "乐队"],
    "ja": ["ミュージシャン", "歌手", "俳優", "アーティスト", "画家", "作曲家",
           "映画監督", "バンド", "写真家"],
    "ko": ["음악가", "가수", "배우", "아티스트", "화가", "작곡가", "감독", "밴드"],
    "hi": ["संगीतकार", "गायक", "अभिनेता", "कलाकार", "चित्रकार"],
    "tr": ["müzisyen", "şarkıcı", "oyuncu", "sanatçı", "ressam", "besteci"],
    "nl": ["muzikant", "zanger", "acteur", "kunstenaar", "schilder"],
    "pl": ["muzyk", "piosenkarz", "aktor", "artysta", "malarz", "kompozytor"],
    "vi": ["nhạc sĩ", "ca sĩ", "diễn viên", "nghệ sĩ", "họa sĩ"],
    "th": ["นักดนตรี", "นักร้อง", "นักแสดง", "ศิลปิน", "จิตรกร"],
    "id": ["musisi", "penyanyi", "aktor", "seniman", "pelukis", "band"],
    "fa": ["موسیقی‌دان", "خواننده", "بازیگر", "هنرمند", "نقاش", "آهنگساز"],
    "uk": ["музикант", "співак", "актор", "художник", "композитор"],
    "sv": ["musiker", "sångare", "skådespelare", "konstnär", "målare"],
    "el": ["μουσικός", "τραγουδιστής", "ηθοποιός", "καλλιτέχνης", "ζωγράφος"],
    "cs": ["hudebník", "zpěvák", "herec", "umělec", "malíř"],
    "hu": ["zenész", "énekes", "színész", "művész", "festő"],
    "ro": ["muzician", "cântăreț", "actor", "artist", "pictor"],
    "he": ["מוזיקאי", "זמר", "שחקן", "אמן", "צייר", "צלם", "מלחין"],
    "sw": ["mwanamuziki", "mwimbaji", "muigizaji", "msanii"],
}

BLOG_TERM: dict[str, str] = {
    "en": "blog", "es": "blog", "pt": "blog", "fr": "blog", "de": "Blog",
    "it": "blog", "ar": "مدونة", "ru": "блог", "zh": "博客", "ja": "ブログ",
    "ko": "블로그", "hi": "ब्लॉग", "tr": "blog", "nl": "blog", "pl": "blog",
    "vi": "blog", "th": "บล็อก", "id": "blog", "fa": "وبلاگ", "uk": "блог",
    "sv": "blogg", "no": "blogg", "da": "blog", "fi": "blogi",
    "el": "ιστολόγιο", "cs": "blog", "sk": "blog", "hu": "blog",
    "ro": "blog", "bg": "блог", "sr": "блог", "hr": "blog",
    "sl": "blog", "lt": "blogas", "lv": "blogs", "et": "blogi",
    "he": "בלוג", "sw": "blogu",
}

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
# Wikidata
# ---------------------------------------------------------------------------

WIKIDATA_SPARQL = "https://query.wikidata.org/sparql"

OCCUPATION_QUERIES = [
    ("Q639669", "musician"),   # musician
    ("Q177220", "singer"),      # singer
    ("Q33999", "actor"),        # actor
    ("Q1028181", "painter"),    # painter
    ("Q483501", "artist"),      # artist
    ("Q36834", "composer"),     # composer
]


def resolve_country_qid(iso2: str) -> str | None:
    if iso2 in ISO2_TO_QID:
        return ISO2_TO_QID[iso2]
    query = f"SELECT ?country WHERE {{ ?country wdt:P297 \"{iso2.upper()}\". }} LIMIT 1"
    try:
        url = WIKIDATA_SPARQL + "?format=json&query=" + urllib.parse.quote(query)
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0", "Accept": "application/json"
        })
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
        bindings = data.get("results", {}).get("bindings", [])
        if bindings:
            qid = bindings[0]["country"]["value"].split("/")[-1]
            ISO2_TO_QID[iso2] = qid
            return qid
    except Exception:
        pass
    return None


def wikidata_artists_by_country(iso2: str, lang: str, limit: int = 100) -> list[dict]:
    """Find artists with websites from Wikidata by country."""
    country_qid = resolve_country_qid(iso2)
    if not country_qid:
        return []

    all_results: list[dict] = []
    seen = set()

    for occupation_qid, category in OCCUPATION_QUERIES:
        query = f"""
            SELECT DISTINCT ?item ?itemLabel ?website WHERE {{
              ?item wdt:P106 wd:{occupation_qid}.
              ?item wdt:P17 wd:{country_qid}.
              OPTIONAL {{ ?item wdt:P856 ?website. }}
              SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{lang},en". }}
            }}
            LIMIT {limit}
        """
        try:
            url = WIKIDATA_SPARQL + "?format=json&query=" + urllib.parse.quote(query)
            req = urllib.request.Request(url, headers={
                "User-Agent": "Feedmine/1.0", "Accept": "application/json"
            })
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = json.loads(resp.read())
        except Exception:
            continue

        for binding in data.get("results", {}).get("bindings", []):
            name = binding.get("itemLabel", {}).get("value", "")
            website = binding.get("website", {}).get("value", "")
            if website and name and website not in seen:
                seen.add(website)
                all_results.append({
                    "name": name,
                    "website": website,
                    "source": f"wikidata:{category}",
                })

        time.sleep(0.5)  # rate limit

    return all_results


# ---------------------------------------------------------------------------
# DDG Search
# ---------------------------------------------------------------------------

def _safe_ddgs():
    try:
        from ddgs import DDGS
        return DDGS
    except ImportError:
        return None


def ddg_search(query: str, region: str, max_results: int = 10) -> list[str]:
    DDGS = _safe_ddgs()
    if DDGS is None:
        return []
    urls: list[str] = []
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, region=region, max_results=max_results))
        for row in results:
            u = (row.get("href") or row.get("url") or row.get("link") or "").strip()
            if u.startswith(("http://", "https://")):
                urls.append(u)
    except Exception:
        pass
    return urls


# ---------------------------------------------------------------------------
# Feed validation
# ---------------------------------------------------------------------------

def is_feed_url(url: str) -> bool:
    patterns = [r'/feed/?$', r'/rss/?$', r'/atom/?$', r'\.xml$',
                r'/feeds/', r'\.rss$', r'\.atom$', r'rss\.xml$', r'atom\.xml$',
                r'/feed\.xml$', r'/rss\.xml$']
    return any(re.search(p, url, re.I) for p in patterns)


def extract_feeds_from_html(url: str, timeout: int = 8) -> list[str]:
    feeds: list[str] = []
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return feeds
            html_text = resp.read().decode("utf-8", errors="replace")[:500_000]
    except Exception:
        return feeds

    link_re = re.compile(
        r'<link[^>]*(?:rel|type)=["\'][^"\']*(?:alternate|feed|rss|atom)[^"\']*["\'][^>]*href=["\']([^"\']+)["\']',
        re.I,
    )
    for m in link_re.finditer(html_text):
        feed_url = urljoin(url, m.group(1))
        if "/comments/" not in feed_url:
            feeds.append(feed_url)

    parsed = urlparse(url)
    base = f"{parsed.scheme}://{parsed.netloc}"
    for path in ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml"]:
        feeds.append(f"{base}{path}")

    return list(dict.fromkeys(feeds))


def validate_feed(url: str, timeout: int = 6) -> tuple[bool, str]:
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return False, f"HTTP {resp.status}"
            data = resp.read(100_000)
            text = data.decode("utf-8", errors="replace")[:3000].strip().lower()
            if "<rss" in text or "<feed" in text or "<rdf" in text:
                title = ""
                try:
                    import xml.etree.ElementTree as ET
                    root = ET.fromstring(data)
                    if root.tag == "rss":
                        ch = root.find("channel")
                        if ch is not None:
                            t = ch.find("title")
                            if t is not None and t.text:
                                title = t.text.strip()
                    elif "feed" in root.tag:
                        for el in root:
                            if el.tag.endswith("title") or el.tag == "title":
                                title = (el.text or "").strip()
                                break
                except Exception:
                    pass
                return True, title or "valid"
            return False, "no markers"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)[:80]


# ---------------------------------------------------------------------------
# Country discovery
# ---------------------------------------------------------------------------

def discover_country(slug: str, meta: dict, max_ddg_queries: int = 10) -> list[dict]:
    """Discover artist feeds for one country using Wikidata + DDG."""
    name = meta["name"]
    cctld = meta.get("cctld", "")
    iso2 = meta.get("iso2", "")
    ddg_region = meta.get("ddg_region", f"{cctld}-{meta['lang']}")
    langs = COUNTRY_LANGS.get(slug, [meta["lang"]])

    # Load existing feeds
    existing_urls: set[str] = set()
    country_opml = COUNTRIES_DIR / slug / f"{slug}.opml"
    if country_opml.exists():
        try:
            for m in re.finditer(r'xmlUrl="([^"]+)"', country_opml.read_text(encoding="utf-8")):
                existing_urls.add(m.group(1).strip().rstrip("/").lower())
        except Exception:
            pass

    # Also load v3 feeds
    v3_cache = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "artist_cache_v3" / f"{slug}_feeds.json"
    if v3_cache.exists():
        try:
            for f in json.loads(v3_cache.read_text(encoding="utf-8")):
                existing_urls.add(f["url"].lower().rstrip("/"))
        except Exception:
            pass

    candidates: list[dict] = []
    seen_websites: set[str] = set()

    # ── Strategy 1: Wikidata ──
    if iso2:
        print(f"  [wikidata] Querying artists with websites...")
        wd_artists = wikidata_artists_by_country(iso2, langs[0], limit=80)
        for a in wd_artists:
            website = a["website"].strip().rstrip("/")
            if website not in seen_websites:
                seen_websites.add(website)
                candidates.append({
                    "url": website,
                    "name": a["name"],
                    "source": a["source"],
                })
        print(f"    → {len(wd_artists)} Wikidata entries")

    # ── Strategy 2: DDG search ──
    blog_term = BLOG_TERM.get(langs[0], "blog")
    print(f"  [ddg] Searching for artist blogs ({len(langs)} languages)...")

    for lang in langs[:2]:
        terms = ARTIST_TERMS.get(lang, ARTIST_TERMS.get("en", []))[:4]
        bt = BLOG_TERM.get(lang, "blog")
        for term in terms[:3]:
            query = f'"{term}" {bt} RSS'
            if cctld and len(cctld) <= 3:
                query += f" site:.{cctld}"
            urls = ddg_search(query, ddg_region, max_results=10)
            for u in urls:
                norm = u.rstrip("/")
                if norm not in seen_websites:
                    seen_websites.add(norm)
                    candidates.append({
                        "url": norm,
                        "name": "",
                        "source": f"ddg:{term}",
                    })
            time.sleep(1.0)

        # Platform search
        for platform, site_op in [("substack.com", "site:substack.com"),
                                   ("blogspot.com", "site:blogspot.com"),
                                   ("wordpress.com", "site:wordpress.com")]:
            query = f'{bt} {site_op} "{name}"'
            urls = ddg_search(query, ddg_region, max_results=8)
            for u in urls:
                norm = u.rstrip("/")
                if norm not in seen_websites:
                    seen_websites.add(norm)
                    candidates.append({
                        "url": norm,
                        "name": "",
                        "source": f"ddg:platform:{platform}",
                    })
            time.sleep(0.8)

    print(f"  → {len(candidates)} candidate URLs to validate")

    # ── Validate feeds ──
    feeds: list[dict] = []
    found_urls: set[str] = set()

    def check_one(c: dict) -> dict | None:
        url = c["url"]
        if is_feed_url(url):
            ok, title = validate_feed(url)
            if ok:
                return {"url": url, "title": title, "name": c["name"], "source": c["source"]}
        else:
            discovered = extract_feeds_from_html(url)
            for feed_url in discovered:
                ok, title = validate_feed(feed_url)
                if ok:
                    return {"url": feed_url, "title": title, "name": c["name"],
                            "source": c["source"], "website": url}
        return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        futures = {executor.submit(check_one, c): c for c in candidates}
        for i, future in enumerate(concurrent.futures.as_completed(futures)):
            result = future.result()
            if result:
                norm = result["url"].lower().rstrip("/")
                if norm not in found_urls:
                    found_urls.add(norm)
                    feeds.append(result)
            if (i + 1) % 30 == 0:
                print(f"    ... {i+1}/{len(candidates)} checked, {len(feeds)} valid")

    print(f"  → {len(feeds)} valid feeds")
    return feeds


# ---------------------------------------------------------------------------
# OPML
# ---------------------------------------------------------------------------

def generate_opml(country_name: str, feeds: list[dict]) -> str:
    lines = []
    for f in feeds:
        url = f["url"]
        title = f.get("title") or f.get("name") or url
        title_esc = (title.replace("&", "&amp;").replace("<", "&lt;")
                     .replace(">", "&gt;").replace('"', "&quot;"))
        url_esc = (url.replace("&", "&amp;").replace("<", "&lt;")
                   .replace(">", "&gt;").replace('"', "&quot;"))
        source_id = hashlib.sha256(url.encode()).hexdigest()

        lines.append(
            f'                        <outline text="{title_esc}" title="{title_esc}" '
            f'type="rss" xmlUrl="{url_esc}" '
            f'description="Artist blog from {country_name}." '
            f'language="" '
            f'category="artist,blog,personal,{country_name.lower()}" '
            f'feedmineSourceId="{source_id}" '
            f'feedmineTopic="Arts &amp; Culture" '
            f'feedmineSubcategory="Artist Blogs" '
            f'feedmineNature="personal" '
            f'feedmineActivity="active" '
            f'feedmineArticlesFetched="0" '
            f'feedmineQualityScore="60" '
            f'feedmineDefaultEnabled="true" '
            f'feedmineMediaKind="text" '
            f'htmlUrl="{url_esc}" />'
        )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Broad artist feed discovery for ALL countries")
    parser.add_argument("--country", help="Single country slug")
    parser.add_argument("--all", action="store_true", help="All countries")
    parser.add_argument("--opml", action="store_true", help="Write OPML files")
    parser.add_argument("--output-dir", default=None)
    parser.add_argument("--limit", type=int, default=20, help="Max DDG queries per country")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    with open(COUNTRIES_JSON, encoding="utf-8") as f:
        countries = json.load(f)

    if args.country:
        slugs = [args.country]
    elif args.all:
        slugs = list(countries.keys())
    else:
        slugs = list(countries.keys())[:3]
        print(f"Testing {slugs}. Use --all for full run.\n")

    if args.dry_run:
        for slug in slugs:
            meta = countries[slug]
            print(f"  {meta['name']} ({slug}): cctld={meta.get('cctld','')}, iso2={meta.get('iso2','')}")
        return

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    total = 0

    for slug in slugs:
        meta = countries[slug]
        name = meta["name"]

        cache_file = CACHE_DIR / f"{slug}_feeds.json"
        if cache_file.exists():
            try:
                feeds = json.loads(cache_file.read_text(encoding="utf-8"))
                print(f"\n📦 {name} ({slug}): {len(feeds)} cached feeds")
                total += len(feeds)
                continue
            except Exception:
                pass

        print(f"\n🔍 {name} ({slug})")
        feeds = discover_country(slug, meta, max_ddg_queries=args.limit)

        cache_file.write_text(json.dumps(feeds, ensure_ascii=False, indent=2), encoding="utf-8")

        if args.opml and feeds:
            opml_text = generate_opml(name, feeds)
            out_dir = Path(args.output_dir) if args.output_dir else CACHE_DIR / "opml"
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / f"{slug}_artist_blogs.opml").write_text(opml_text, encoding="utf-8")
            print(f"  📄 OPML written")

        total += len(feeds)
        print(f"  ✅ {name}: {len(feeds)} feeds (total: {total})")

    print(f"\n{'='*60}")
    print(f"✅ Grand total: {total} artist blog feeds across {len(slugs)} countries")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
