#!/usr/bin/env python3
"""
Complementary journalist blog discovery via Wikipedia.

For each country, queries the Wikipedia API for:
  1. Category pages like "Brazilian journalists" → list of journalist page titles
  2. Each journalist page → extract external links (official website, blog)
  3. Check those websites for RSS feeds

This approach is complementary to DDG search because it finds journalists who
have Wikipedia pages — typically prominent/established journalists.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import urllib.request
import urllib.error
import urllib.parse
from pathlib import Path
from typing import Optional
from urllib.parse import urljoin, urlparse


# Country → Wikipedia journalist category names (in the country's language + English)
# Format: [category_name, ...] where each is the Wikipedia category suffix
WIKI_JOURNALIST_CATEGORIES: dict[str, list[str]] = {
    "algeria": ["Algerian journalists", "Journalistes algériens", "صحفيون جزائريون"],
    "angola": ["Angolan journalists", "Jornalistas de Angola"],
    "argentina": ["Argentine journalists", "Periodistas de Argentina"],
    "armenia": ["Armenian journalists", "Հայ լրագրողներ"],
    "australia": ["Australian journalists"],
    "austria": ["Austrian journalists", "Journalist (Österreich)"],
    "azerbaijan": ["Azerbaijani journalists", "Azərbaycan jurnalistləri"],
    "bangladesh": ["Bangladeshi journalists", "বাংলাদেশী সাংবাদিক"],
    "belarus": ["Belarusian journalists", "Белорусские журналисты"],
    "belgium": ["Belgian journalists", "Journaliste belge", "Belgische journalist"],
    "bolivia": ["Bolivian journalists", "Periodistas de Bolivia"],
    "brazil": ["Brazilian journalists", "Jornalistas do Brasil"],
    "bulgaria": ["Bulgarian journalists", "Български журналисти"],
    "cambodia": ["Cambodian journalists", "អ្នកកាសែតខ្មែរ"],
    "canada": ["Canadian journalists", "Journalistes canadiens"],
    "chile": ["Chilean journalists", "Periodistas de Chile"],
    "china": ["Chinese journalists", "中国记者"],
    "colombia": ["Colombian journalists", "Periodistas de Colombia"],
    "costa_rica": ["Costa Rican journalists", "Periodistas de Costa Rica"],
    "croatia": ["Croatian journalists", "Hrvatski novinari"],
    "cuba": ["Cuban journalists", "Periodistas de Cuba"],
    "cyprus": ["Cypriot journalists", "Κύπριοι δημοσιογράφοι"],
    "czech_republic": ["Czech journalists", "Čeští novináři"],
    "denmark": ["Danish journalists", "Danske journalister"],
    "dominican_republic": ["Dominican Republic journalists", "Periodistas de República Dominicana"],
    "ecuador": ["Ecuadorian journalists", "Periodistas de Ecuador"],
    "egypt": ["Egyptian journalists", "صحفيون مصريون"],
    "el_salvador": ["Salvadoran journalists", "Periodistas de El Salvador"],
    "estonia": ["Estonian journalists", "Eesti ajakirjanikud"],
    "ethiopia": ["Ethiopian journalists"],
    "finland": ["Finnish journalists", "Suomalaiset toimittajat"],
    "france": ["French journalists", "Journalistes français"],
    "georgia": ["Georgian journalists", "ჟურნალისტები (საქართველო)"],
    "germany": ["German journalists", "Journalist (Deutschland)"],
    "ghana": ["Ghanaian journalists"],
    "greece": ["Greek journalists", "Έλληνες δημοσιογράφοι"],
    "guatemala": ["Guatemalan journalists", "Periodistas de Guatemala"],
    "haiti": ["Haitian journalists", "Journalistes haïtiens"],
    "honduras": ["Honduran journalists", "Periodistas de Honduras"],
    "hungary": ["Hungarian journalists", "Magyar újságírók"],
    "iceland": ["Icelandic journalists", "Íslenskir blaðamenn"],
    "india": ["Indian journalists", "भारतीय पत्रकार"],
    "indonesia": ["Indonesian journalists", "Wartawan Indonesia"],
    "iran": ["Iranian journalists", "روزنامه‌نگاران اهل ایران"],
    "iraq": ["Iraqi journalists", "صحفيون عراقيون"],
    "ireland": ["Irish journalists"],
    "israel": ["Israeli journalists", "עיתונאים ישראלים"],
    "italy": ["Italian journalists", "Giornalisti italiani"],
    "ivory_coast": ["Ivorian journalists", "Journalistes ivoiriens"],
    "jamaica": ["Jamaican journalists"],
    "japan": ["Japanese journalists", "日本のジャーナリスト"],
    "kazakhstan": ["Kazakhstani journalists", "Казахстанские журналисты"],
    "kenya": ["Kenyan journalists"],
    "latvia": ["Latvian journalists", "Latvijas žurnālisti"],
    "lithuania": ["Lithuanian journalists", "Lietuvos žurnalistai"],
    "luxembourg": ["Luxembourgian journalists", "Journalistes luxembourgeois"],
    "malaysia": ["Malaysian journalists", "Wartawan Malaysia"],
    "malta": ["Maltese journalists"],
    "mexico": ["Mexican journalists", "Periodistas de México"],
    "morocco": ["Moroccan journalists", "صحفيون مغاربة", "Journalistes marocains"],
    "myanmar": ["Burmese journalists", "မြန်မာ သတင်းစာဆရာများ"],
    "nepal": ["Nepalese journalists", "नेपाली पत्रकार"],
    "netherlands": ["Dutch journalists", "Nederlands journalist"],
    "new_zealand": ["New Zealand journalists"],
    "nicaragua": ["Nicaraguan journalists", "Periodistas de Nicaragua"],
    "nigeria": ["Nigerian journalists"],
    "norway": ["Norwegian journalists", "Norske journalister"],
    "pakistan": ["Pakistani journalists", "پاکستانی صحافی"],
    "panama": ["Panamanian journalists", "Periodistas de Panamá"],
    "paraguay": ["Paraguayan journalists", "Periodistas de Paraguay"],
    "peru": ["Peruvian journalists", "Periodistas del Perú"],
    "philippines": ["Filipino journalists"],
    "poland": ["Polish journalists", "Polscy dziennikarze"],
    "portugal": ["Portuguese journalists", "Jornalistas de Portugal"],
    "puerto_rico": ["Puerto Rican journalists", "Periodistas de Puerto Rico"],
    "qatar": ["Qatari journalists", "صحفيون قطريون"],
    "romania": ["Romanian journalists", "Jurnaliști români"],
    "russia": ["Russian journalists", "Журналисты России"],
    "saudi_arabia": ["Saudi Arabian journalists", "صحفيون سعوديون"],
    "serbia": ["Serbian journalists", "Српски новинари"],
    "singapore": ["Singaporean journalists"],
    "slovakia": ["Slovak journalists", "Slovenskí novinári"],
    "slovenia": ["Slovenian journalists", "Slovenski novinarji"],
    "south_africa": ["South African journalists"],
    "south_korea": ["South Korean journalists", "대한민국의 기자"],
    "spain": ["Spanish journalists", "Periodistas de España"],
    "sri_lanka": ["Sri Lankan journalists"],
    "sudan": ["Sudanese journalists", "صحفيون سودانيون"],
    "sweden": ["Swedish journalists", "Svenska journalister"],
    "switzerland": ["Swiss journalists", "Journalistes suisses", "Schweizer Journalist"],
    "taiwan": ["Taiwanese journalists", "台灣記者"],
    "thailand": ["Thai journalists", "นักข่าวชาวไทย"],
    "tunisia": ["Tunisian journalists", "صحفيون تونسيون", "Journalistes tunisiens"],
    "turkey": ["Turkish journalists", "Türk gazeteciler"],
    "uae": ["Emirati journalists", "صحفيون إماراتيون"],
    "ukraine": ["Ukrainian journalists", "Журналісти України"],
    "united_kingdom": ["British journalists"],
    "uruguay": ["Uruguayan journalists", "Periodistas de Uruguay"],
    "usa": ["American journalists"],
    "venezuela": ["Venezuelan journalists", "Periodistas de Venezuela"],
    "vietnam": ["Vietnamese journalists", "Nhà báo Việt Nam"],
}

WIKI_API = "https://en.wikipedia.org/w/api.php"

# Also try local-language Wikipedias for better coverage
WIKI_LANG_MAP = {
    "ar": "ar.wikipedia.org", "de": "de.wikipedia.org", "es": "es.wikipedia.org",
    "fr": "fr.wikipedia.org", "it": "it.wikipedia.org", "ja": "ja.wikipedia.org",
    "ko": "ko.wikipedia.org", "nl": "nl.wikipedia.org", "pl": "pl.wikipedia.org",
    "pt": "pt.wikipedia.org", "ru": "ru.wikipedia.org", "sv": "sv.wikipedia.org",
    "tr": "tr.wikipedia.org", "uk": "uk.wikipedia.org", "vi": "vi.wikipedia.org",
    "zh": "zh.wikipedia.org", "fa": "fa.wikipedia.org", "he": "he.wikipedia.org",
    "id": "id.wikipedia.org", "cs": "cs.wikipedia.org", "fi": "fi.wikipedia.org",
    "no": "no.wikipedia.org", "da": "da.wikipedia.org", "hu": "hu.wikipedia.org",
    "ro": "ro.wikipedia.org", "bg": "bg.wikipedia.org", "sr": "sr.wikipedia.org",
    "hr": "hr.wikipedia.org", "sk": "sk.wikipedia.org", "sl": "sl.wikipedia.org",
    "lt": "lt.wikipedia.org", "lv": "lv.wikipedia.org", "et": "et.wikipedia.org",
    "el": "el.wikipedia.org", "th": "th.wikipedia.org", "hi": "hi.wikipedia.org",
    "bn": "bn.wikipedia.org", "ta": "ta.wikipedia.org", "ms": "ms.wikipedia.org",
    "ka": "ka.wikipedia.org", "hy": "hy.wikipedia.org", "az": "az.wikipedia.org",
}


def wiki_api_call(api_url: str, params: dict, timeout: int = 15) -> Optional[dict]:
    """Make a Wikipedia API call and return JSON response."""
    param_str = urllib.parse.urlencode(params)
    url = f"{api_url}?{param_str}"
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0 (journalist discovery; +https://feedmine.app)"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return None


def get_journalist_pages(category_name: str, api_url: str = WIKI_API) -> list[str]:
    """Get list of page titles in a Wikipedia category."""
    pages: list[str] = []
    params = {
        "action": "query",
        "format": "json",
        "list": "categorymembers",
        "cmtitle": f"Category:{category_name}",
        "cmlimit": "max",
        "cmtype": "page",
    }
    data = wiki_api_call(api_url, params)
    if data and "query" in data:
        for member in data["query"].get("categorymembers", []):
            title = member.get("title", "")
            if title and not title.startswith(("Category:", "Template:", "Wikipedia:", "List of", "File:")):
                pages.append(title)
    return pages


def get_external_links(page_title: str, api_url: str = WIKI_API) -> list[str]:
    """Extract external links from a Wikipedia page (official website, blog links)."""
    links: list[str] = []
    # First try: parseLinks to get all external URLs
    params = {
        "action": "parse",
        "format": "json",
        "page": page_title,
        "prop": "externallinks",
        "ellimit": "max",
    }
    data = wiki_api_call(api_url, params)
    if data and "parse" in data:
        for link_data in data["parse"].get("externallinks", []):
            url = link_data if isinstance(link_data, str) else link_data.get("*", "")
            if url and url.startswith(("http://", "https://")) and "wikipedia.org" not in url:
                links.append(url)
    return links


def extract_feed_urls(page_url: str, timeout: int = 8) -> list[str]:
    """Check a webpage for RSS feed links."""
    feeds: list[str] = []
    try:
        req = urllib.request.Request(page_url, headers={
            "User-Agent": "Feedmine/1.0 (RSS discovery)"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            html = resp.read().decode("utf-8", errors="replace")[:300_000]
    except Exception:
        return feeds

    # <link> feed tags
    for m in re.finditer(
        r'<link[^>]*\brel=["\'](?:alternate|feed)["\'][^>]*\bhref=["\']([^"\']+)["\']',
        html, re.I
    ):
        feeds.append(urljoin(page_url, m.group(1)))

    # Common feed paths
    if not feeds:
        parsed = urlparse(page_url)
        base = f"{parsed.scheme}://{parsed.netloc}"
        for path in ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/feeds/posts/default"]:
            feeds.append(f"{base}{path}")

    return feeds


def validate_feed(url: str, timeout: int = 8) -> tuple[bool, str]:
    """Check if URL is a valid RSS/Atom feed."""
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return False, f"HTTP {resp.status}"
            text = resp.read(50000).decode("utf-8", errors="replace")[:3000].lower()
            has_rss = "<rss" in text or "<feed" in text or "<rdf" in text
            return has_rss, "valid" if has_rss else "no RSS markers"
    except Exception as e:
        return False, str(e)[:80]


def discover_via_wikipedia(
    country_slug: str,
    langs: list[str],
    existing_urls: set[str],
    cache_dir: Path,
    delay: float = 1.0,
) -> list[dict]:
    """Discover journalist blogs via Wikipedia for one country."""
    cache_file = cache_dir / f"{country_slug}_wikipedia.json"
    if cache_file.exists():
        try:
            return json.loads(cache_file.read_text(encoding="utf-8"))
        except Exception:
            pass

    categories = WIKI_JOURNALIST_CATEGORIES.get(country_slug, [])
    if not categories:
        # Build from country name
        from scripts.feed_discovery.data.countries import countries
        pass  # handled below

    all_feeds: list[dict] = []
    seen_urls: set[str] = set(existing_urls)

    # Try both English Wikipedia and local-language Wikipedia
    apis_to_try = [(WIKI_API, categories)]
    for lang in langs:
        if lang in WIKI_LANG_MAP:
            local_api = f"https://{WIKI_LANG_MAP[lang]}/w/api.php"
            apis_to_try.append((local_api, categories))

    print(f"  Wikipedia: searching {len(categories)} categories on {len(apis_to_try)} wiki(s)...")

    for api_url, cats in apis_to_try:
        for cat in cats[:3]:  # max 3 categories per wiki
            page_titles = get_journalist_pages(cat, api_url)
            if not page_titles:
                continue

            print(f"    Category '{cat}': {len(page_titles)} journalist pages")

            # Sample up to 50 journalists per category
            for page_title in page_titles[:50]:
                ext_links = get_external_links(page_title, api_url)
                for link in ext_links[:5]:  # first 5 external links per journalist
                    # Skip social media, wiki, news aggregators
                    skip_domains = ["twitter.com", "facebook.com", "instagram.com", "linkedin.com",
                                    "youtube.com", "wikipedia.org", "wikimedia.org", "imdb.com"]
                    parsed = urlparse(link)
                    if any(d in parsed.netloc for d in skip_domains):
                        continue

                    # Try to find RSS feed
                    feeds = extract_feed_urls(link)
                    for feed_url in feeds:
                        norm = feed_url.strip().rstrip("/").lower()
                        if norm in seen_urls:
                            continue
                        valid, reason = validate_feed(feed_url)
                        if valid:
                            seen_urls.add(norm)
                            all_feeds.append({
                                "url": feed_url,
                                "title": page_title,
                                "source": f"wikipedia:{cat}",
                                "country": country_slug,
                            })
                            break  # one feed per journalist
                time.sleep(delay * 0.3)

    print(f"  Wikipedia → {len(all_feeds)} feeds")
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps(all_feeds, ensure_ascii=False, indent=2), encoding="utf-8")
    return all_feeds


def main():
    parser = argparse.ArgumentParser(description="Discover journalist blogs via Wikipedia")
    parser.add_argument("--country", required=True, help="Country slug")
    parser.add_argument("--delay", type=float, default=1.0)
    parser.add_argument("--fresh", action="store_true")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    countries_json = repo_root / "scripts" / "feed_discovery" / "data" / "countries.json"
    countries_dir = repo_root / "feedmine" / "Resources" / "Feeds" / "90_countries"
    cache_dir = repo_root / "scripts" / "feed_discovery" / "data" / "journalist_cache"

    with open(countries_json, encoding="utf-8") as f:
        countries = json.load(f)

    if args.country not in countries:
        print(f"Unknown country: {args.country}")
        return

    meta = countries[args.country]
    name = meta["name"]
    langs = [meta["lang"]]  # Simplified - just use primary language

    existing_urls: set[str] = set()
    opml_file = countries_dir / args.country / f"{args.country}.opml"
    if opml_file.exists():
        try:
            content = opml_file.read_text(encoding="utf-8")
            for m in re.finditer(r'xmlUrl="([^"]+)"', content):
                existing_urls.add(m.group(1).strip().rstrip("/").lower())
        except Exception:
            pass

    print(f"\n{'='*60}")
    print(f"Wikipedia discovery: {name} ({args.country}) — {len(existing_urls)} existing")
    print(f"{'='*60}")

    if args.fresh:
        cache_file = cache_dir / f"{args.country}_wikipedia.json"
        if cache_file.exists():
            cache_file.unlink()

    feeds = discover_via_wikipedia(args.country, langs, existing_urls, cache_dir, args.delay)
    print(f"Total: {len(feeds)} feeds from Wikipedia")


if __name__ == "__main__":
    main()
