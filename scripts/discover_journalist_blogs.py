#!/usr/bin/env python3
"""
Parallel multi-strategy journalist blog RSS feed discovery for Feedmine countries.

Uses concurrent.futures to process multiple countries in parallel.
Each country goes through 7 search strategies, with automatic English fallback
and country-specific platform searches for countries that need more results.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional
from urllib.parse import urljoin, urlparse

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:
    from catalog_identity import compute_source_id

# ---------------------------------------------------------------------------
# Language data
# ---------------------------------------------------------------------------

JOURNALIST_TERMS: dict[str, list[str]] = {
    "af": ["joernalis", "verslaggewer"], "am": ["ጋዜጠኛ", "ዘጋቢ"],
    "ar": ["صحفي", "مراسل", "كاتب صحفي"],
    "az": ["jurnalist", "müxbir"], "be": ["журналіст", "рэпарцёр"],
    "bg": ["журналист", "репортер"],
    "bn": ["সাংবাদিক", "প্রতিবেদক"], "cs": ["novinář", "reportér"],
    "da": ["journalist", "reporter"], "de": ["Journalist", "Reporter", "Kolumnist"],
    "el": ["δημοσιογράφος", "ρεπόρτερ"], "en": ["journalist", "reporter", "columnist"],
    "es": ["periodista", "reportero", "columnista"],
    "et": ["ajakirjanik", "reporter"], "fa": ["روزنامه‌نگار", "خبرنگار"],
    "fi": ["toimittaja", "reportteri"], "fr": ["journaliste", "reporter", "chroniqueur"],
    "he": ["עיתונאי", "כתב"], "hi": ["पत्रकार", "संवाददाता"],
    "hr": ["novinar", "reporter"], "ht": ["jounalis", "repòtè"],
    "hu": ["újságíró", "riporter"], "hy": ["լրագրող", "թղթակից"],
    "id": ["jurnalis", "wartawan"], "is": ["blaðamaður", "fréttaritari"],
    "it": ["giornalista", "reporter", "cronista"],
    "ja": ["ジャーナリスト", "記者", "コラムニスト"],
    "ka": ["ჟურნალისტი", "რეპორტიორი"],
    "kk": ["журналист", "тілші"], "km": ["អ្នកកាសែត", "អ្នកយកព័ត៌មាន"],
    "ko": ["기자", "저널리스트", "언론인"],
    "lt": ["žurnalistas", "reporteris"], "lv": ["žurnālists", "reportieris"],
    "ms": ["wartawan", "pemberita"], "mt": ["ġurnalist", "reporter"],
    "my": ["သတင်းစာဆရာ", "သတင်းထောက်"],
    "ne": ["पत्रकार", "संवाददाता"],
    "nl": ["journalist", "verslaggever"], "no": ["journalist", "reporter"],
    "pl": ["dziennikarz", "reporter", "publicysta"],
    "pt": ["jornalista", "repórter", "colunista"],
    "ro": ["jurnalist", "reporter", "ziarist"],
    "ru": ["журналист", "репортер", "обозреватель"],
    "si": ["මාධ්‍යවේදී", "වාර්තාකරු"],
    "sk": ["novinár", "reportér"], "sl": ["novinar", "reporter"],
    "sr": ["новинар", "репортер"], "sv": ["journalist", "reporter"],
    "sw": ["mwandishi wa habari", "ripota"],
    "ta": ["பத்திரிகையாளர்", "நிருபர்"],
    "te": ["విలేఖరి", "జర్నలిస్ట్"], "th": ["นักข่าว", "ผู้สื่อข่าว"],
    "tl": ["mamamahayag", "reporter"], "tr": ["gazeteci", "muhabir"],
    "uk": ["журналіст", "репортер", "оглядач"],
    "ur": ["صحافی", "نامہ نگار"], "vi": ["nhà báo", "phóng viên"],
    "xh": ["intatheli", "umsasazi"], "zh": ["记者", "新闻工作者", "专栏作家"],
    "zu": ["intatheli", "umbiki"],
}

BLOG_KW: dict[str, str] = {
    "ar": "مدونة", "bn": "ব্লগ", "de": "Blog", "el": "ιστολόγιο",
    "fa": "وبلاگ", "fi": "blogi", "he": "בלוג", "hi": "ब्लॉग",
    "ja": "ブログ", "ko": "블로그", "lt": "blogas", "lv": "blogs",
    "no": "blogg", "ru": "блог", "sv": "blogg", "th": "บล็อก",
    "uk": "блог", "bg": "блог", "sr": "блог",
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
    "hungary": ["hu"], "iceland": ["is"], "india": ["hi", "en", "bn", "ta"],
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
    "south_africa": ["en", "af", "zu"],
    "south_korea": ["ko"], "spain": ["es"],
    "sri_lanka": ["si", "ta", "en"], "sudan": ["ar"],
    "sweden": ["sv"], "switzerland": ["de", "fr", "it"],
    "taiwan": ["zh"], "thailand": ["th"], "tunisia": ["ar", "fr"],
    "turkey": ["tr"], "uae": ["ar"], "ukraine": ["uk"],
    "united_kingdom": ["en"], "uruguay": ["es"], "usa": ["en"],
    "venezuela": ["es"], "vietnam": ["vi"],
}

# Country-specific blog platforms
COUNTRY_PLATFORMS: dict[str, list[tuple[str, str]]] = {
    "jp": [("note.com", "/rss"), ("fc2.com", "?xml"), ("ameblo.jp", "/rss")],
    "ru": [("livejournal.com", "/data/rss"), ("habr.com", "/ru/rss/")],
    "cn": [("jianshu.com", "/feeds")],
    "kr": [("tistory.com", "/rss"), ("egloos.com", "/rss")],
    "br": [("uol.com.br", "/feed")],
    "ir": [("virgool.io", "/feed")],
    "vn": [("blogspot.com", "/feeds/posts/default")],
    "th": [("bloggang.com", "/rss")],
    "id": [("kompasiana.com", "/rss")],
    "ua": [("livejournal.com", "/data/rss")],
    "in": [("blogadda.com", "/feed")],
}


# ---------------------------------------------------------------------------
# Search & Feed utilities
# ---------------------------------------------------------------------------

def search_ddg(query: str, region: str, max_results: int = 20) -> list[dict]:
    """Search DuckDuckGo, return [{url, title, snippet}]."""
    from ddgs import DDGS
    results: list[dict] = []
    try:
        with DDGS() as ddgs:
            rows = list(ddgs.text(query, region=region, max_results=max_results))
        for row in rows:
            u = (row.get("href") or row.get("url") or row.get("link") or "").strip()
            if u.startswith(("http://", "https://")):
                results.append({
                    "url": u,
                    "title": (row.get("title") or "").strip(),
                    "snippet": (row.get("body") or row.get("snippet") or "").strip(),
                })
    except Exception:
        try:
            with DDGS() as ddgs:
                rows = list(ddgs.text(query, region="wt-wt", max_results=max_results))
            for row in rows:
                u = (row.get("href") or row.get("url") or row.get("link") or "").strip()
                if u.startswith(("http://", "https://")):
                    results.append({
                        "url": u, "title": (row.get("title") or "").strip(),
                        "snippet": (row.get("body") or row.get("snippet") or "").strip(),
                    })
        except Exception:
            pass
    return results


def substack_feed(url: str) -> Optional[str]:
    parsed = urlparse(url)
    if "substack.com" in parsed.netloc:
        parts = parsed.netloc.split(".")
        if len(parts) >= 3 and parts[-2:] == ["substack", "com"]:
            name = parts[0]
            if name not in ("www", "api", "cdn", "support"):
                return f"https://{name}.substack.com/feed"
    return None


def medium_feed(url: str) -> Optional[str]:
    parsed = urlparse(url)
    if "medium.com" in parsed.netloc:
        path = parsed.path.strip("/")
        if path and not path.startswith(("feed/", "search", "tagged", "topics", "m/")):
            return f"https://medium.com/feed/{path}"
    return None


def validate_feed(url: str, timeout: int = 5) -> tuple[bool, str, str]:
    """Check if URL returns valid RSS/Atom. Returns (valid, reason, title)."""
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return False, f"HTTP {resp.status}", ""
            data = resp.read(80000)
            text = data.decode("utf-8", errors="replace")
            tl = text[:3000].lower().strip()
            if not ("<rss" in tl or "<feed" in tl or "<rdf" in tl):
                return False, "not XML feed", ""
            title = ""
            m = re.search(r'<title[^>]*>([^<]+)</title>', text[:2000], re.I)
            if m:
                title = m.group(1).strip()
            return True, "valid", title
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}", ""
    except Exception as e:
        return False, str(e)[:100], ""


def extract_feed_from_page(page_url: str, timeout: int = 6) -> list[str]:
    """Fetch page and extract RSS feed URLs from <link> tags."""
    feeds: list[str] = []
    try:
        req = urllib.request.Request(page_url, headers={
            "User-Agent": "Feedmine/1.0 (RSS discovery)"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return feeds
            html = resp.read().decode("utf-8", errors="replace")[:300_000]
    except Exception:
        return feeds

    for m in re.finditer(
        r'<link[^>]*\brel=["\'][^"\']*(?:alternate|feed)["\'][^>]*\bhref=["\']([^"\']+)["\']',
        html, re.I
    ):
        feeds.append(urljoin(page_url, m.group(1)))

    if not feeds:
        parsed = urlparse(page_url)
        base = f"{parsed.scheme}://{parsed.netloc}"
        for p in ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml"]:
            feeds.append(f"{base}{p}")
    return feeds


# ---------------------------------------------------------------------------
# Discovery for one country
# ---------------------------------------------------------------------------

def discover_country(
    slug: str,
    name: str,
    ddg_region: str,
    langs: list[str],
    existing_urls: set[str],
    cache_dir: Path,
    delay: float = 0.8,
    fresh: bool = False,
) -> tuple[str, int]:
    """Discover journalist blogs for one country. Returns (country_slug, count)."""
    cache_file = cache_dir / f"{slug}_validated.json"
    if not fresh and cache_file.exists():
        try:
            existing = json.loads(cache_file.read_text(encoding="utf-8"))
            if existing:
                return slug, len(existing)
        except Exception:
            pass

    # Gather localized terms
    terms: list[str] = []
    for lang in langs:
        for t in JOURNALIST_TERMS.get(lang, []):
            if t not in terms:
                terms.append(t)
    if not terms:
        terms = JOURNALIST_TERMS.get("en", [])
    terms = terms[:6]

    blog_words: list[str] = []
    for lang in langs:
        bw = BLOG_KW.get(lang, "blog")
        if bw not in blog_words:
            blog_words.append(bw)

    validated: list[dict] = []
    seen: set[str] = set(existing_urls)

    def add_if_valid(url: str, title: str = "", source: str = "") -> bool:
        norm = url.strip().rstrip("/").lower()
        if norm in seen or not url.startswith("http"):
            return False
        valid, reason, ftitle = validate_feed(url, timeout=5)
        if valid:
            seen.add(norm)
            validated.append({
                "url": url, "title": title or ftitle or url,
                "source": source, "country": slug,
            })
            return True
        return False

    strategies_found = []

    # 1 — Substack
    cnt = 0
    for term in terms[:4]:
        for r in search_ddg(f'"{term}" site:substack.com "{name}"', ddg_region, 12):
            f = substack_feed(r["url"])
            if f and add_if_valid(f, r.get("title", ""), f"substack:{term}"):
                cnt += 1
        time.sleep(delay)
    strategies_found.append(("Substack", cnt))

    # 2 — Medium
    cnt = 0
    for term in terms[:3]:
        for r in search_ddg(f'{term} site:medium.com "{name}"', ddg_region, 10):
            f = medium_feed(r["url"])
            if f and add_if_valid(f, r.get("title", ""), f"medium:{term}"):
                cnt += 1
        time.sleep(delay)
    strategies_found.append(("Medium", cnt))

    # 3 — General blog search
    cnt = 0
    for term in terms[:4]:
        bw = blog_words[0] if blog_words else "blog"
        for r in search_ddg(f'"{term}" {bw} RSS', ddg_region, 10):
            u = r["url"]
            if re.search(r'(/feed|/rss|\.xml$|/atom)', u, re.I):
                if add_if_valid(u, r.get("title", ""), f"direct:{term}"):
                    cnt += 1
            else:
                for feed_url in extract_feed_from_page(u)[:2]:
                    if add_if_valid(feed_url, r.get("title", ""), f"page:{term}"):
                        cnt += 1
                        break
        time.sleep(delay)
    strategies_found.append(("General", cnt))

    # 4 — WordPress
    cnt = 0
    for term in terms[:3]:
        for r in search_ddg(f'"{term}" site:wordpress.com "{name}"', ddg_region, 8):
            if "wordpress.com" in r["url"]:
                if add_if_valid(r["url"].rstrip("/") + "/feed", r.get("title", ""), f"wp:{term}"):
                    cnt += 1
        time.sleep(delay)
    strategies_found.append(("WordPress", cnt))

    # 5 — Ghost & Blogger
    cnt = 0
    for plat_domain, feed_suffix in [("ghost.io", "/rss"), ("blogspot.com", "/feeds/posts/default")]:
        for term in terms[:2]:
            for r in search_ddg(f'"{term}" site:{plat_domain} "{name}"', ddg_region, 6):
                if plat_domain in r["url"]:
                    parsed = urlparse(r["url"])
                    feed_url = f"{parsed.scheme}://{parsed.netloc}{feed_suffix}"
                    if add_if_valid(feed_url, r.get("title", ""), f"platform:{plat_domain}"):
                        cnt += 1
            time.sleep(delay * 0.5)
    strategies_found.append(("Ghost/Blogger", cnt))

    # 6 — Press associations (1-2 languages only)
    cnt = 0
    assoc_map = {
        "en": f'journalist association members blog "{name}"',
        "es": f'asociacion de periodistas blog "{name}"',
        "pt": f'associação de jornalistas blog "{name}"',
        "fr": f'association des journalistes blog "{name}"',
        "de": f'Journalistenverband Blog "{name}"',
        "ar": f'رابطة الصحفيين مدونة "{name}"',
        "ru": f'союз журналистов блог "{name}"',
        "ja": f'記者クラブ "{name}"',
        "it": f'associazione giornalisti blog "{name}"',
        "nl": f'journalisten vereniging blog "{name}"',
        "tr": f'gazeteciler cemiyeti blog "{name}"',
        "pl": f'stowarzyszenie dziennikarzy blog "{name}"',
        "vi": f'hội nhà báo blog "{name}"',
        "ko": f'기자협회 "{name}"',
        "sv": f'journalistförbund blogg "{name}"',
        "no": f'journalistlag blogg "{name}"',
        "el": f'ένωση δημοσιογράφων ιστολόγιο "{name}"',
        "he": f'אגודת העיתונאים בלוג "{name}"',
        "id": f'aliansi jurnalis blog "{name}"',
        "uk": f'спілка журналістів "{name}"',
        "fa": f'انجمن صنفی روزنامه نگاران "{name}"',
        "hu": f'újságíró szövetség blog "{name}"',
        "ro": f'uniunea jurnalistilor blog "{name}"',
        "cs": f'syndikát novinářů blog "{name}"',
        "fi": f'journalistiliitto blogi "{name}"',
    }
    for lang in langs[:1]:
        q = assoc_map.get(lang)
        if q:
            for r in search_ddg(q, ddg_region, 5):
                for feed_url in extract_feed_from_page(r["url"])[:2]:
                    if add_if_valid(feed_url, r.get("title", ""), f"assoc:{lang}"):
                        cnt += 1
                        break
            time.sleep(delay)
    strategies_found.append(("Associations", cnt))

    # 7 — YouTube (quick pass)
    cnt = 0
    for term in terms[:2]:
        for r in search_ddg(f'{term} site:youtube.com "{name}"', ddg_region, 6):
            m = re.search(r'youtube\.com/@([^/?]+)', r["url"])
            if m:
                # Try channel feed URL with handle
                feed_url = f"https://www.youtube.com/feeds/videos.xml?user={m.group(1)}"
                if add_if_valid(feed_url, r.get("title", ""), f"youtube:{term}"):
                    cnt += 1
        time.sleep(delay * 0.5)
    strategies_found.append(("YouTube", cnt))

    total = len(validated)

    # Fallback — English if < 90 and English not already used
    if total < 90 and "en" not in langs:
        cnt = 0
        for term in JOURNALIST_TERMS["en"][:3]:
            for r in search_ddg(f'{term} substack "{name}"', ddg_region, 8):
                f = substack_feed(r["url"])
                if f and add_if_valid(f, r.get("title", ""), f"en-fb:{term}"):
                    cnt += 1
            time.sleep(delay * 0.4)
            for r in search_ddg(f'{term} site:wordpress.com "{name}"', ddg_region, 6):
                if "wordpress.com" in r["url"]:
                    if add_if_valid(r["url"].rstrip("/") + "/feed", r.get("title", ""), f"en-fb-wp:{term}"):
                        cnt += 1
            time.sleep(delay * 0.4)
        strategies_found.append(("EN-fallback", cnt))
        total = len(validated)

    # Fallback — broad search if still < 95
    if total < 95:
        cnt = 0
        for query in [f'site:substack.com "{name}"', f'site:blogspot.com "{name}"',
                       f'site:wordpress.com "{name}"']:
            for r in search_ddg(query, ddg_region, 8):
                f = substack_feed(r["url"]) or medium_feed(r["url"])
                if not f:
                    parsed = urlparse(r["url"])
                    if "blogspot.com" in r["url"]:
                        f = f"{parsed.scheme}://{parsed.netloc}/feeds/posts/default"
                    else:
                        f = r["url"].rstrip("/") + "/feed"
                if add_if_valid(f, r.get("title", ""), f"broad:{query[:30]}"):
                    cnt += 1
            time.sleep(delay * 0.3)
        strategies_found.append(("Broad", cnt))
        total = len(validated)

    # Fallback — country-specific platforms if still < 100
    if total < 100:
        cnt = 0
        iso2 = ddg_region.split("-")[0] if "-" in ddg_region else slug[:2]
        platforms = COUNTRY_PLATFORMS.get(iso2, COUNTRY_PLATFORMS.get(slug, []))
        if not platforms:
            platforms = [("blogspot.com", "/feeds/posts/default")]
        for plat_domain, feed_suffix in platforms[:3]:
            for r in search_ddg(f'site:{plat_domain} "{name}"', ddg_region, 6):
                parsed = urlparse(r["url"])
                feed_url = f"{parsed.scheme}://{parsed.netloc}{feed_suffix}"
                if add_if_valid(feed_url, r.get("title", ""), f"local:{plat_domain}"):
                    cnt += 1
            time.sleep(delay * 0.3)
        strategies_found.append(("Local-plat", cnt))
        total = len(validated)

    # Log results
    strategy_summary = " | ".join(f"{s}:{c}" for s, c in strategies_found)
    print(f"  [{slug}] {strategy_summary} → {total} total")

    # Save cache
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps(validated, ensure_ascii=False, indent=2), encoding="utf-8")
    return slug, total


# ---------------------------------------------------------------------------
# OPML generation
# ---------------------------------------------------------------------------

def generate_opml(country_name: str, feeds: list[dict]) -> str:
    """Generate OPML outline entries."""
    lines = []
    for f in feeds:
        title = (f.get("title") or f["url"]).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        url_esc = f["url"].replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        sid = compute_source_id(f["url"])
        cn = (country_name or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        lines.append(
            f'                        <outline text="{title}" title="{title}" '
            f'type="rss" xmlUrl="{url_esc}" '
            f'description="Journalist blog from {cn}." '
            f'language="" '
            f'category="journalism,blog,personal" '
            f'feedmineSourceId="{sid}" '
            f'feedmineTopic="News &amp; Current Affairs" '
            f'feedmineSubcategory="Journalism &amp; Media" '
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
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Parallel journalist blog discovery for Feedmine")
    parser.add_argument("--country", help="Single country slug")
    parser.add_argument("--all", action="store_true", help="All 101 countries")
    parser.add_argument("--workers", type=int, default=4, help="Parallel workers (default: 4)")
    parser.add_argument("--delay", type=float, default=0.8, help="Delay between DDG searches")
    parser.add_argument("--fresh", action="store_true", help="Ignore caches")
    parser.add_argument("--opml-dir", help="Output directory for OPML")
    parser.add_argument("--limit", type=int, default=0, help="Limit to N countries")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    countries_json = repo_root / "scripts" / "feed_discovery" / "data" / "countries.json"
    countries_dir = repo_root / "feedmine" / "Resources" / "Feeds" / "90_countries"
    cache_dir = repo_root / "scripts" / "feed_discovery" / "data" / "journalist_cache"

    with open(countries_json, encoding="utf-8") as f:
        all_countries = json.load(f)

    if args.country:
        slugs = [args.country]
    elif args.all:
        slugs = list(all_countries.keys())
        if args.limit:
            slugs = slugs[:args.limit]
    else:
        slugs = list(all_countries.keys())[:5]
        print(f"Testing first {len(slugs)} countries. Use --all for full run.")

    # Prepare tasks
    tasks: list[tuple] = []
    for slug in slugs:
        meta = all_countries[slug]
        name = meta["name"]
        ddg_region = meta.get("ddg_region", f"{slug}-{meta['lang']}")
        langs = COUNTRY_LANGS.get(slug, [meta["lang"]])

        # Load existing URLs
        existing_urls: set[str] = set()
        opml_file = countries_dir / slug / f"{slug}.opml"
        if opml_file.exists():
            try:
                content = opml_file.read_text(encoding="utf-8")
                for m in re.finditer(r'xmlUrl="([^"]+)"', content):
                    existing_urls.add(m.group(1).strip().rstrip("/").lower())
            except Exception:
                pass

        tasks.append((slug, name, ddg_region, langs, existing_urls, cache_dir, args.delay, args.fresh))

    total_feeds = 0
    results: dict[str, int] = {}

    if len(tasks) == 1:
        # Sequential for single country
        slug, count = discover_country(*tasks[0])
        results[slug] = count
        total_feeds += count
    else:
        # Parallel
        print(f"\nProcessing {len(tasks)} countries with {args.workers} workers...\n")
        completed = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
            futures = {executor.submit(discover_country, *t): t[0] for t in tasks}
            for future in concurrent.futures.as_completed(futures):
                slug = futures[future]
                try:
                    slug, count = future.result()
                    results[slug] = count
                    total_feeds += count
                    completed += 1
                    if completed % 10 == 0:
                        print(f"  [{completed}/{len(tasks)}] running total: {total_feeds} feeds")
                except Exception as e:
                    print(f"  [{slug}] ERROR: {e}")

    # Generate OPML files
    opml_dir = Path(args.opml_dir) if args.opml_dir else cache_dir / "opml"
    opml_dir.mkdir(parents=True, exist_ok=True)

    feeds_written = 0
    for slug in slugs:
        cache_file = cache_dir / f"{slug}_validated.json"
        if cache_file.exists():
            try:
                feeds = json.loads(cache_file.read_text(encoding="utf-8"))
                if feeds:
                    name = all_countries[slug]["name"]
                    snippet = generate_opml(name, feeds)
                    out_file = opml_dir / f"{slug}_journalist_blogs.opml"
                    out_file.write_text(snippet, encoding="utf-8")
                    feeds_written += len(feeds)
            except Exception:
                pass

    # Summary
    print(f"\n{'='*60}")
    print(f"SUMMARY: {total_feeds} feeds across {len(results)} countries")
    print(f"         OPML written for {feeds_written} feeds")
    print(f"         Files in: {opml_dir}")

    # Show countries below target
    below_100 = [(s, c) for s, c in results.items() if c < 100]
    below_80 = [(s, c) for s, c in results.items() if c < 80]
    below_50 = [(s, c) for s, c in results.items() if c < 50]

    if below_50:
        print(f"\n⚠️  Below 50 feeds ({len(below_50)} countries):")
        for s, c in sorted(below_50, key=lambda x: x[1]):
            print(f"    {s}: {c}")
    if below_80:
        print(f"\n⚠️  Below 80 feeds ({len(below_80)} countries):")
        for s, c in sorted(below_80, key=lambda x: x[1]):
            print(f"    {s}: {c}")
    if below_100:
        print(f"\n📊 Below 100 target ({len(below_100)}/{len(results)} countries)")
    else:
        print(f"\n✅ All countries reached 100+ feeds!")

    print(f"{'='*60}")


if __name__ == "__main__":
    main()
