#!/usr/bin/env python3
"""
Batch artist blog discovery using DDG search + URL construction + concurrent validation.

No Wikidata dependency. For each country:
  1. DDG search for artist blogs using localized queries
  2. Feed discovery from result pages
  3. Direct Substack/Blogspot/WordPress URL construction from discovered names
  4. Concurrent HTTP validation

Processes countries in a single batch. Designed to be run per-country or all-at-once.
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

REPO_ROOT = Path(__file__).resolve().parents[1]
CACHE_DIR = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "artist_batch"
COUNTRIES_JSON = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "countries.json"
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"

# ---------------------------------------------------------------------------
# Language terms
# ---------------------------------------------------------------------------

ARTIST_TERMS = {
    "en": ["musician", "singer", "actor", "artist", "painter", "rapper", "composer", "band"],
    "es": ["músico", "cantante", "actor", "artista", "pintor", "rapero", "banda"],
    "pt": ["músico", "cantor", "ator", "artista", "pintor", "rapper", "banda"],
    "fr": ["musicien", "chanteur", "acteur", "artiste", "peintre", "rappeur", "groupe"],
    "de": ["Musiker", "Sänger", "Schauspieler", "Künstler", "Maler", "Rapper", "Band"],
    "it": ["musicista", "cantante", "attore", "artista", "pittore", "rapper", "band"],
    "ar": ["موسيقي", "مغني", "ممثل", "فنان", "رسام", "ملحن"],
    "ru": ["музыкант", "певец", "актёр", "художник", "композитор", "рэпер"],
    "zh": ["音乐家", "歌手", "演员", "艺术家", "画家", "作曲家"],
    "ja": ["ミュージシャン", "歌手", "俳優", "アーティスト", "作曲家"],
    "ko": ["음악가", "가수", "배우", "아티스트", "작곡가"],
    "tr": ["müzisyen", "şarkıcı", "oyuncu", "sanatçı", "ressam"],
    "nl": ["muzikant", "zanger", "acteur", "kunstenaar", "schilder"],
    "pl": ["muzyk", "piosenkarz", "aktor", "artysta", "malarz"],
    "vi": ["nhạc sĩ", "ca sĩ", "diễn viên", "nghệ sĩ", "họa sĩ"],
    "th": ["นักดนตรี", "นักร้อง", "นักแสดง", "ศิลปิน"],
    "id": ["musisi", "penyanyi", "aktor", "seniman", "band"],
    "fa": ["موسیقی‌دان", "خواننده", "بازیگر", "هنرمند"],
    "uk": ["музикант", "співак", "актор", "художник"],
    "sv": ["musiker", "sångare", "skådespelare", "konstnär"],
    "el": ["μουσικός", "τραγουδιστής", "ηθοποιός", "καλλιτέχνης"],
    "cs": ["hudebník", "zpěvák", "herec", "umělec"],
    "hu": ["zenész", "énekes", "színész", "művész"],
    "ro": ["muzician", "cântăreț", "actor", "artist"],
    "he": ["מוזיקאי", "זמר", "שחקן", "אמן"],
    "sw": ["mwanamuziki", "mwimbaji", "muigizaji", "msanii"],
}

BLOG_TERM = {
    "en": "blog", "es": "blog", "pt": "blog", "fr": "blog", "de": "Blog",
    "it": "blog", "ar": "مدونة", "ru": "блог", "zh": "博客", "ja": "ブログ",
    "ko": "블로그", "tr": "blog", "nl": "blog", "pl": "blog", "vi": "blog",
    "th": "บล็อก", "id": "blog", "fa": "وبلاگ", "uk": "блог", "sv": "blogg",
    "el": "ιστολόγιο", "cs": "blog", "hu": "blog", "ro": "blog", "he": "בלוג",
    "sw": "blogu",
}

COUNTRY_LANGS = {
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
# DDG search
# ---------------------------------------------------------------------------

def _ddgs():
    try:
        from ddgs import DDGS
        return DDGS
    except ImportError:
        return None


def ddg_search(query: str, region: str, n: int = 12) -> list[str]:
    DDGS = _ddgs()
    if DDGS is None:
        return []
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, region=region, max_results=n))
        return [(r.get("href") or r.get("url") or "").strip()
                for r in results if (r.get("href") or r.get("url") or "").startswith("http")]
    except Exception:
        return []


# ---------------------------------------------------------------------------
# Feed validation + discovery
# ---------------------------------------------------------------------------

def is_feed(url: str) -> bool:
    return bool(re.search(
        r'/feed/?$|/rss/?$|/atom/?$|\.xml$|/feeds/|\.rss$|\.atom$|/rss\.xml$|/feed\.xml$',
        url, re.I
    ))


def extract_feeds(html: str, base: str) -> list[str]:
    feeds = []
    for m in re.finditer(
        r'<link[^>]*(?:rel|type)=["\'][^"\']*(?:alternate|feed|rss|atom)[^"\']*["\'][^>]*href=["\']([^"\']+)["\']',
        html, re.I,
    ):
        fu = urljoin(base, m.group(1))
        if "/comments/" not in fu:
            feeds.append(fu)
    p = urlparse(base)
    root = f"{p.scheme}://{p.netloc}"
    for path in ["/feed", "/rss", "/feed.xml", "/rss.xml"]:
        feeds.append(root + path)
    return list(dict.fromkeys(feeds))


def validate(url: str, timeout: int = 6) -> tuple[bool, str]:
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return False, f"HTTP {resp.status}"
            data = resp.read(80000)
            text = data.decode("utf-8", errors="replace")[:3000].strip().lower()
            if "<rss" in text or "<feed" in text or "<rdf" in text:
                title = ""
                try:
                    import xml.etree.ElementTree as ET
                    root = ET.fromstring(data)
                    if root.tag == "rss" and (ch := root.find("channel")):
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
# Name → slug → URL construction
# ---------------------------------------------------------------------------

def name_to_slugs(name: str) -> list[str]:
    name = name.lower().strip()
    name = re.sub(r'\(.*?\)', '', name)
    accents = str.maketrans('áãâàäéêèëíîìïóõôòöúûùüçñśšłž', 'aaaaaeeeeiiiiooooouuuucnssls')
    name = name.translate(accents)
    dashed = re.sub(r'[^a-z0-9]+', '-', name).strip('-')
    flat = re.sub(r'[^a-z0-9]+', '', name)
    slugs = [dashed, flat] if dashed else [flat]
    parts = [p for p in name.split() if len(p) > 1]
    if len(parts) >= 2:
        slugs.append(f"{parts[0]}-{parts[-1]}")
        slugs.append(f"{parts[0]}{parts[-1]}")
    return list(dict.fromkeys(s.replace('--', '-') for s in slugs if s and len(s) > 2))


# ---------------------------------------------------------------------------
# Country discovery
# ---------------------------------------------------------------------------

def discover_country(slug: str, meta: dict, existing: set[str]) -> list[dict]:
    name = meta["name"]
    cctld = meta.get("cctld", "")
    region = meta.get("ddg_region", f"{cctld}-{meta['lang']}")
    langs = COUNTRY_LANGS.get(slug, [meta["lang"]])
    iso2 = meta.get("iso2", "")

    candidates: list[dict] = []  # [{url, name, source}]
    seen = set()

    print(f"  [ddg] Searching {len(langs)} languages...")

    for lang in langs[:2]:
        terms = ARTIST_TERMS.get(lang, ARTIST_TERMS.get("en", []))[:4]
        bt = BLOG_TERM.get(lang, "blog")

        for term in terms[:4]:
            # Query 1: "{artist_type} blog {country}"
            for query in [
                f'"{term}" {bt} "{name}"',
                f'{term} {bt} site:.{cctld}' if cctld else f'{term} {bt} "{name}"',
            ]:
                for u in ddg_search(query, region, n=10):
                    nurl = u.rstrip("/")
                    if nurl not in seen and nurl not in existing:
                        seen.add(nurl)
                        candidates.append({"url": nurl, "name": "", "source": f"ddg:{term}"})
                time.sleep(1.0)

            # Query 2: Platform-specific
            for platform, site_q in [
                ("substack", f'site:substack.com {bt} "{name}"'),
                ("blogspot", f'site:blogspot.com {bt} "{name}"'),
                ("wordpress", f'site:wordpress.com {bt} "{name}"'),
            ]:
                for u in ddg_search(site_q, region, n=8):
                    nurl = u.rstrip("/")
                    if nurl not in seen and nurl not in existing:
                        seen.add(nurl)
                        candidates.append({"url": nurl, "name": "", "source": f"ddg:{platform}"})
                time.sleep(0.7)

        # Query 3: Famous artists by country
        for u in ddg_search(f'famous {name} {bt} RSS', region, n=10):
            nurl = u.rstrip("/")
            if nurl not in seen and nurl not in existing:
                seen.add(nurl)
                candidates.append({"url": nurl, "name": "", "source": "ddg:famous"})
        time.sleep(1.0)

    # Extract names from found domains and construct direct URLs
    names_found: set[str] = set()
    for c in candidates:
        if c["name"]:
            names_found.add(c["name"])
        # Extract possible name from URL domain
        pu = urlparse(c["url"])
        domain = pu.netloc.replace("www.", "").split(".")[0]
        if len(domain) > 2 and not domain.startswith(("site", "blog", "www")):
            names_found.add(domain.replace("-", " "))

    # Build direct URLs from discovered names
    print(f"  [direct] Building URLs from {len(names_found)} discovered names...")
    for nm in list(names_found)[:50]:
        for slug_v in name_to_slugs(nm)[:3]:
            for pat_url, pat_src in [
                (f"https://{slug_v}.substack.com/feed", "substack"),
                (f"https://{slug_v}.blogspot.com/feeds/posts/default", "blogspot"),
                (f"https://{slug_v}.wordpress.com/feed/", "wordpress"),
            ]:
                if pat_url not in seen and pat_url not in existing:
                    seen.add(pat_url)
                    candidates.append({"url": pat_url, "name": nm, "source": f"direct:{pat_src}"})

    # Also build URLs from country name + common artist words
    for word in ["music", "jazz", "rock", "art", "film", "cinema", "theatre"]:
        slug_v = f"{word}-{slug.replace('_', '-')}"
        for pat_url, pat_src in [
            (f"https://{slug_v}.blogspot.com/feeds/posts/default", "blogspot"),
            (f"https://{slug_v}.wordpress.com/feed/", "wordpress"),
        ]:
            if pat_url not in seen and pat_url not in existing:
                seen.add(pat_url)
                candidates.append({"url": pat_url, "name": f"{word} {name}", "source": f"direct:country-{pat_src}"})

    print(f"  → {len(candidates)} candidate URLs to validate")

    # Concurrent validation
    feeds: list[dict] = []
    found_set: set[str] = set()

    def check_one(c: dict) -> dict | None:
        url = c["url"]
        if is_feed(url[:100]):
            ok, title = validate(url)
            if ok:
                return {"url": url, "title": title, "name": c["name"], "source": c["source"]}
        else:
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "Feedmine/1.0"})
                with urllib.request.urlopen(req, timeout=6) as resp:
                    if resp.status == 200:
                        html = resp.read().decode("utf-8", errors="replace")[:200_000]
                for fu in extract_feeds(html, url):
                    ok, title = validate(fu)
                    if ok:
                        return {"url": fu, "title": title, "name": c["name"],
                                "source": f"found:{c['source']}"}
                # Probe root
                p = urlparse(url)
                root = f"{p.scheme}://{p.netloc}"
                for path in ["/feed", "/rss", "/feed.xml"]:
                    fu = root + path
                    ok, title = validate(fu)
                    if ok:
                        return {"url": fu, "title": title, "name": c["name"],
                                "source": f"probe:{c['source']}"}
            except Exception:
                pass
        return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
        futures = {executor.submit(check_one, c): c for c in candidates}
        done = 0
        for future in concurrent.futures.as_completed(futures):
            done += 1
            r = future.result()
            if r:
                n = r["url"].lower().rstrip("/")
                if n not in found_set:
                    found_set.add(n)
                    feeds.append(r)
                    if len(feeds) <= 15 or len(feeds) % 10 == 0:
                        print(f"  ✅ [{len(feeds)}] {r['title'] or r['name'][:40]} — {r['source']}")
            if done % 80 == 0:
                print(f"  ... {done}/{len(candidates)} checked, {len(feeds)} found")

    return feeds


# ---------------------------------------------------------------------------
# OPML
# ---------------------------------------------------------------------------

def make_opml(country_name: str, feeds: list[dict]) -> str:
    lines = []
    for f in feeds:
        u = f["url"]
        title = f.get("title") or f.get("name") or u
        te = title.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        ue = u.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        sid = hashlib.sha256(u.encode()).hexdigest()
        lines.append(
            f'                        <outline text="{te}" title="{te}" '
            f'type="rss" xmlUrl="{ue}" '
            f'description="Artist blog from {country_name}." '
            f'language="" category="artist,blog,personal,{country_name.lower()}" '
            f'feedmineSourceId="{sid}" feedmineTopic="Arts &amp; Culture" '
            f'feedmineSubcategory="Artist Blogs" feedmineNature="personal" '
            f'feedmineActivity="active" feedmineArticlesFetched="0" '
            f'feedmineQualityScore="60" feedmineDefaultEnabled="true" '
            f'feedmineMediaKind="text" htmlUrl="{ue}" />'
        )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Load all existing feeds across caches to avoid duplicates
# ---------------------------------------------------------------------------

def load_all_existing(slug: str) -> set[str]:
    urls: set[str] = set()
    # Country OPML
    opml = COUNTRIES_DIR / slug / f"{slug}.opml"
    if opml.exists():
        try:
            for m in re.finditer(r'xmlUrl="([^"]+)"', opml.read_text(encoding="utf-8")):
                urls.add(m.group(1).strip().rstrip("/").lower())
        except Exception:
            pass
    # All cache versions
    for cache_dir_name in ["artist_cache_v3", "artist_v4", "artist_batch", "artist_broad", "artist_cache_v2"]:
        cf = REPO_ROOT / "scripts" / "feed_discovery" / "data" / cache_dir_name / f"{slug}_feeds.json"
        if cf.exists():
            try:
                for f in json.loads(cf.read_text(encoding="utf-8")):
                    urls.add(f["url"].lower().rstrip("/"))
            except Exception:
                pass
    return urls


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Batch artist blog discovery")
    parser.add_argument("--country", help="Single country slug")
    parser.add_argument("--all", action="store_true", help="All countries")
    parser.add_argument("--opml", action="store_true", help="Write OPML")
    parser.add_argument("--output-dir", default=None)
    parser.add_argument("--max-countries", type=int, default=None)
    parser.add_argument("--start-from", default=None)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    with open(COUNTRIES_JSON, encoding="utf-8") as f:
        countries = json.load(f)

    if args.country:
        slugs = [args.country]
    elif args.all:
        slugs = sorted(countries.keys())
        if args.start_from and args.start_from in slugs:
            slugs = slugs[slugs.index(args.start_from):]
        if args.max_countries:
            slugs = slugs[:args.max_countries]
    else:
        # Default: countries NOT covered by v3 (famous_people.txt)
        v3_covered = {'argentina', 'australia', 'brazil', 'canada', 'france',
                      'germany', 'india', 'japan', 'mexico', 'nigeria', 'usa'}
        slugs = [s for s in sorted(countries.keys()) if s not in v3_covered][:3]
        print(f"Testing uncovered countries: {slugs}\nUse --all for full run.\n")

    if args.dry_run:
        for slug in slugs:
            meta = countries[slug]
            print(f"  {meta['name']} ({slug})")
        return

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    total = 0

    for slug in slugs:
        meta = countries[slug]
        cname = meta["name"]

        cache_file = CACHE_DIR / f"{slug}_feeds.json"
        if cache_file.exists():
            try:
                feeds = json.loads(cache_file.read_text(encoding="utf-8"))
                print(f"\n📦 {cname} ({slug}): {len(feeds)} cached feeds")
                total += len(feeds)
                # Also ensure OPML exists
                if args.opml:
                    out_dir = Path(args.output_dir) if args.output_dir else CACHE_DIR / "opml"
                    out_dir.mkdir(parents=True, exist_ok=True)
                    opml_file = out_dir / f"{slug}_artist_blogs.opml"
                    if not opml_file.exists():
                        opml_file.write_text(make_opml(cname, feeds), encoding="utf-8")
                continue
            except Exception:
                pass

        print(f"\n🔍 {cname} ({slug})")
        existing = load_all_existing(slug)
        print(f"  → {len(existing)} existing feeds tracked")

        feeds = discover_country(slug, meta, existing)

        # Deduplicate
        final = []
        sf = set()
        for f in feeds:
            n = f["url"].lower().rstrip("/")
            if n not in sf:
                sf.add(n)
                final.append(f)

        cache_file.write_text(json.dumps(final, ensure_ascii=False, indent=2), encoding="utf-8")

        if args.opml and final:
            out_dir = Path(args.output_dir) if args.output_dir else CACHE_DIR / "opml"
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / f"{slug}_artist_blogs.opml").write_text(make_opml(cname, final), encoding="utf-8")

        total += len(final)
        print(f"  ✅ {cname}: {len(final)} feeds (total: {total})")

    print(f"\n{'='*60}")
    print(f"✅ Total: {total} new feeds across {len(slugs)} countries")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
