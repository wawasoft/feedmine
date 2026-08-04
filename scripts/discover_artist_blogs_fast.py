#!/usr/bin/env python3
"""
Ultra-fast artist blog discovery — minimal DDG queries, aggressive concurrency.

For each country: 4-6 DDG queries → feed discovery → concurrent validation.
Designed to process a country in ~30-60 seconds. Use with parallel subprocesses.

Usage:
  python discover_artist_blogs_fast.py --countries algeria,angola,argentina
  python discover_artist_blogs_fast.py --all --workers 5  (5 countries at once)
"""

import argparse, concurrent.futures, hashlib, json, os, re, sys, time
import subprocess, urllib.request, urllib.error
from pathlib import Path
from urllib.parse import urljoin, urlparse

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:
    from catalog_identity import compute_source_id

REPO_ROOT = Path(__file__).resolve().parents[1]
CACHE_DIR = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "artist_fast"
COUNTRIES_JSON = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "countries.json"
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"

BLOG_TERMS = {
    "en":"blog","es":"blog","pt":"blog","fr":"blog","de":"Blog","it":"blog",
    "ar":"مدونة","ru":"блог","zh":"博客","ja":"ブログ","ko":"블로그","tr":"blog",
    "nl":"blog","pl":"blog","vi":"blog","th":"บล็อก","id":"blog","fa":"وبلاگ",
    "uk":"блог","sv":"blogg","el":"ιστολόγιο","cs":"blog","hu":"blog",
    "ro":"blog","he":"בלוג","sw":"blogu",
}

COUNTRY_LANGS = {
    "algeria":["ar","fr"],"angola":["pt"],"argentina":["es"],"armenia":["hy"],
    "australia":["en"],"austria":["de"],"azerbaijan":["az","ru"],
    "bangladesh":["bn","en"],"belarus":["be","ru"],"belgium":["nl","fr","de"],
    "bolivia":["es"],"brazil":["pt"],"bulgaria":["bg"],"cambodia":["km"],
    "canada":["en","fr"],"chile":["es"],"china":["zh"],"colombia":["es"],
    "costa_rica":["es"],"croatia":["hr"],"cuba":["es"],"cyprus":["el"],
    "czech_republic":["cs"],"denmark":["da"],"dominican_republic":["es"],
    "ecuador":["es"],"egypt":["ar"],"el_salvador":["es"],"estonia":["et"],
    "ethiopia":["am"],"finland":["fi","sv"],"france":["fr"],"georgia":["ka"],
    "germany":["de"],"ghana":["en"],"greece":["el"],"guatemala":["es"],
    "haiti":["fr","ht"],"honduras":["es"],"hungary":["hu"],"iceland":["is"],
    "india":["hi","en"],"indonesia":["id"],"iran":["fa"],"iraq":["ar"],
    "ireland":["en"],"israel":["he","ar"],"italy":["it"],
    "ivory_coast":["fr"],"jamaica":["en"],"japan":["ja"],
    "kazakhstan":["kk","ru"],"kenya":["en","sw"],"latvia":["lv"],
    "lithuania":["lt"],"luxembourg":["fr","de"],"malaysia":["ms","en"],
    "malta":["mt","en"],"mexico":["es"],"morocco":["ar","fr"],
    "myanmar":["my"],"nepal":["ne"],"netherlands":["nl"],
    "new_zealand":["en"],"nicaragua":["es"],"nigeria":["en"],"norway":["no"],
    "pakistan":["ur","en"],"panama":["es"],"paraguay":["es"],"peru":["es"],
    "philippines":["tl","en"],"poland":["pl"],"portugal":["pt"],
    "puerto_rico":["es"],"qatar":["ar"],"romania":["ro"],"russia":["ru"],
    "saudi_arabia":["ar"],"serbia":["sr"],
    "singapore":["en","zh","ms","ta"],"slovakia":["sk"],"slovenia":["sl"],
    "south_africa":["en","af","zu","xh"],"south_korea":["ko"],"spain":["es"],
    "sri_lanka":["si","ta","en"],"sudan":["ar"],"sweden":["sv"],
    "switzerland":["de","fr","it"],"taiwan":["zh"],"thailand":["th"],
    "tunisia":["ar","fr"],"turkey":["tr"],"uae":["ar"],"ukraine":["uk"],
    "united_kingdom":["en"],"uruguay":["es"],"usa":["en"],"venezuela":["es"],
    "vietnam":["vi"],
}


def ddg(q, region, n=6):
    try:
        from ddgs import DDGS
        with DDGS() as d:
            return [r.get("href") or r.get("url") or "" for r in d.text(q, region=region, max_results=n) if (r.get("href") or r.get("url") or "").startswith("http")]
    except:
        return []


def validate(url, timeout=5):
    try:
        req = urllib.request.Request(url, headers={"User-Agent":"Feedmine/1.0","Accept":"application/rss+xml, application/atom+xml, application/xml, text/xml, */*"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if r.status != 200: return False,""
            d = r.read(80000)
            t = d.decode("utf-8",errors="replace")[:3000].strip().lower()
            if "<rss" in t or "<feed" in t or "<rdf" in t:
                title = ""
                try:
                    import xml.etree.ElementTree as ET
                    root = ET.fromstring(d)
                    if root.tag == "rss" and (ch:=root.find("channel")) and (ti:=ch.find("title")) and ti.text:
                        title = ti.text.strip()
                    elif "feed" in root.tag:
                        for el in root:
                            if el.tag.endswith("title") or el.tag=="title":
                                title = (el.text or "").strip()
                                break
                except: pass
                return True, title or "valid"
    except: pass
    return False,""


def feed_discover(page_url, timeout=5):
    feeds = []
    try:
        req = urllib.request.Request(page_url, headers={"User-Agent":"Feedmine/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if r.status == 200:
                html = r.read().decode("utf-8",errors="replace")[:150000]
        for m in re.finditer(r'<link[^>]*(?:rel|type)=["\'][^"\']*(?:alternate|feed|rss|atom)[^"\']*["\'][^>]*href=["\']([^"\']+)["\']', html, re.I):
            fu = urljoin(page_url, m.group(1))
            if "/comments/" not in fu: feeds.append(fu)
        p = urlparse(page_url)
        base = f"{p.scheme}://{p.netloc}"
        for path in ["/feed","/rss","/feed.xml","/rss.xml"]:
            feeds.append(base+path)
    except: pass
    return list(dict.fromkeys(feeds))


def process_country(slug, meta, existing):
    name = meta["name"]
    cctld = meta.get("cctld","")
    region = meta.get("ddg_region", f"{cctld}-{meta['lang']}")
    langs = COUNTRY_LANGS.get(slug, [meta["lang"]])

    candidates = []
    seen = set()

    # 4-6 targeted DDG queries
    for lang in langs[:1]:
        bt = BLOG_TERMS.get(lang, "blog")
        for q in [
            f'{bt} musica "{name}" site:blogspot.com',
            f'{bt} {bt}er "{name}" site:substack.com',
            f'musico {bt} site:.{cctld}' if cctld else f'music {bt} {name}',
            f'artist {bt} {name}',
            f'singer {bt} RSS "{name}"',
            f'{bt} {name} site:wordpress.com',
        ]:
            for u in ddg(q, region, n=8):
                nu = u.rstrip("/")
                if nu not in seen and nu not in existing:
                    seen.add(nu)
                    candidates.append({"url": nu, "name": "", "source": f"ddg"})
            time.sleep(0.5)  # rate limit

    # Validate concurrently
    feeds = []
    fs = set()

    def check(c):
        url = c["url"]
        re_feed = re.search(r'/feed/?$|/rss/?$|\.xml$|/feeds/|\.rss$', url, re.I)
        if re_feed:
            ok, title = validate(url)
            if ok: return {"url":url,"title":title,"name":c["name"],"source":c["source"]}
        else:
            for fu in feed_discover(url):
                ok, title = validate(fu)
                if ok: return {"url":fu,"title":title,"name":c["name"],"source":f"found:{c['source']}"}
        return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=15) as ex:
        futs = {ex.submit(check, c): c for c in candidates}
        for f in concurrent.futures.as_completed(futs):
            r = f.result()
            if r:
                n = r["url"].lower().rstrip("/")
                if n not in fs:
                    fs.add(n)
                    feeds.append(r)

    return feeds


def make_opml(cname, feeds):
    lines = []
    for f in feeds:
        u = f["url"]
        t = f.get("title") or f.get("name") or u
        te = t.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;")
        ue = u.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;")
        sid = compute_source_id(u)
        lines.append(f'      <outline text="{te}" title="{te}" type="rss" xmlUrl="{ue}" description="Artist blog from {cname}." language="" category="artist,blog,personal,{cname.lower()}" feedmineSourceId="{sid}" feedmineTopic="Arts &amp; Culture" feedmineSubcategory="Artist Blogs" feedmineNature="personal" feedmineActivity="active" feedmineArticlesFetched="0" feedmineQualityScore="50" feedmineDefaultEnabled="true" feedmineMediaKind="text" htmlUrl="{ue}" />')
    return lines


def load_existing(slug):
    urls = set()
    opml = COUNTRIES_DIR / slug / f"{slug}.opml"
    if opml.exists():
        try:
            for m in re.finditer(r'xmlUrl="([^"]+)"', opml.read_text(encoding="utf-8")):
                urls.add(m.group(1).strip().rstrip("/").lower())
        except: pass
    # All caches
    for dn in ["artist_cache_v3","artist_v4","artist_batch","artist_broad","artist_cache_v2","artist_fast"]:
        cf = REPO_ROOT / "scripts" / "feed_discovery" / "data" / dn / f"{slug}_feeds.json"
        if cf.exists():
            try:
                for f in json.loads(cf.read_text(encoding="utf-8")):
                    urls.add(f["url"].lower().rstrip("/"))
            except: pass
    return urls


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--countries", help="Comma-separated country slugs")
    p.add_argument("--all", action="store_true")
    p.add_argument("--opml", action="store_true")
    p.add_argument("--skip-cached", action="store_true", default=True)
    args = p.parse_args()

    with open(COUNTRIES_JSON, encoding="utf-8") as f:
        countries = json.load(f)

    if args.countries:
        slugs = [s.strip() for s in args.countries.split(",")]
    elif args.all:
        slugs = sorted(countries.keys())
    else:
        # Countries not yet covered
        covered = {"argentina","australia","brazil","canada","france","germany","india","japan","mexico","nigeria","usa","spain"}
        slugs = [s for s in sorted(countries.keys()) if s not in covered][:5]
        print(f"Default: {slugs}")

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    total = 0

    for slug in slugs:
        meta = countries[slug]
        cname = meta["name"]

        cf = CACHE_DIR / f"{slug}_feeds.json"
        if args.skip_cached and cf.exists():
            try:
                feeds = json.loads(cf.read_text(encoding="utf-8"))
                print(f"📦 {cname}: {len(feeds)} cached")
                total += len(feeds)
                continue
            except: pass

        existing = load_existing(slug)
        print(f"🔍 {cname} ({slug}) — {len(existing)} existing")
        feeds = process_country(slug, meta, existing)
        dedup = []
        sf = set()
        for f in feeds:
            n = f["url"].lower().rstrip("/")
            if n not in sf:
                sf.add(n)
                dedup.append(f)

        cf.write_text(json.dumps(dedup, ensure_ascii=False, indent=2), encoding="utf-8")
        total += len(dedup)
        print(f"  ✅ {cname}: {len(dedup)} feeds")

        if args.opml:
            od = CACHE_DIR / "opml"
            od.mkdir(parents=True, exist_ok=True)
            lines = make_opml(cname, dedup)
            (od / f"{slug}_artist_blogs.opml").write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n<opml version="2.0">\n  <head>\n    <title>Artist Blogs</title>\n  </head>\n  <body>\n    <outline text="Artist Blogs" title="Artist Blogs">\n'
                + "\n".join(lines) +
                '\n    </outline>\n  </body>\n</opml>'
            )

    print(f"\n✅ TOTAL: {total} feeds across {len(slugs)} countries")


if __name__ == "__main__":
    main()
