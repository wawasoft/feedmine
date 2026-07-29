#!/usr/bin/env python3
"""
ZERO-SEARCH artist blog discovery — no DDG, no Wikidata, pure URL construction.

For each of the 101 countries:
  1. Generate 50-100 blog URLs from country name + artist keywords in local language
  2. Validate all URLs concurrently (20 workers)
  3. Save per-country cache + OPML

Structure: {keyword}-{country}.blogspot.com, {country}{keyword}.substack.com, etc.
Uses PER-LANGUAGE keywords for better hit rates.

Estimated: 5-15 seconds per country (HTTP validation only).
"""

import concurrent.futures, hashlib, json, os, re, sys, time
import urllib.request, urllib.error
from pathlib import Path
from urllib.parse import urlparse

REPO_ROOT = Path(__file__).resolve().parents[1]
CACHE_DIR = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "artist_zero"
COUNTRIES_JSON = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "countries.json"
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"

# Per-language music/art keywords
LANG_KEYWORDS = {
    "en": ["music","musician","singer","actor","artist","band","rapper","jazz","rock","pop",
           "folk","blues","hiphop","soul","guitar","piano","film","cinema","theatre","dance",
           "painter","photo","gallery","composer","songwriter","dj","producer","director"],
    "es": ["musica","musico","cantante","actor","artista","banda","rapper","jazz","rock",
           "pop","folk","cine","teatro","danza","pintor","foto","galeria","compositor","dj"],
    "pt": ["musica","musico","cantor","ator","artista","banda","rapper","jazz","rock",
           "pop","samba","mpb","cine","teatro","danca","pintor","foto","galeria","compositor"],
    "fr": ["musique","musicien","chanteur","acteur","artiste","groupe","rappeur","jazz",
           "rock","pop","cinema","theatre","danse","peintre","photo","galerie","compositeur"],
    "de": ["musik","musiker","sanger","schauspieler","kunstler","band","rapper","jazz",
           "rock","pop","kino","theater","tanz","maler","foto","galerie","komponist"],
    "it": ["musica","musicista","cantante","attore","artista","band","rapper","jazz",
           "rock","pop","cinema","teatro","danza","pittore","foto","galleria","compositore"],
    "ar": ["موسيقى","مغني","ممثل","فنان","فرقة","راب","جاز","روك","بوب","سينما","مسرح","رقص"],
    "ru": ["музыка","певец","актер","художник","группа","рэп","джаз","рок","поп","кино"],
    "zh": ["音乐","歌手","演员","艺术家","乐队","说唱","爵士","摇滚","流行","电影"],
    "ja": ["音楽","歌手","俳優","アーティスト","バンド","ラップ","ジャズ","ロック","映画"],
    "ko": ["음악","가수","배우","아티스트","밴드","랩","재즈","록","영화"],
    "tr": ["muzik","sarkici","oyuncu","sanatci","grup","rap","caz","rock","pop","sinema"],
    "nl": ["muziek","zanger","acteur","kunstenaar","band","rap","jazz","rock","pop","film"],
    "pl": ["muzyka","piosenkarz","aktor","artysta","zespol","rap","jazz","rock","pop","film"],
    "vi": ["am nhac","ca si","dien vien","nghe si","ban nhac","rap","nhac","rock","pop","phim"],
    "th": ["ดนตรี","นักร้อง","นักแสดง","ศิลปิน","วง","แร็พ","แจ๊ส","ร็อค","ป๊อป","หนัง"],
    "id": ["musik","penyanyi","aktor","seniman","band","rap","jazz","rock","pop","film"],
    "fa": ["موسیقی","خواننده","بازیگر","هنرمند","گروه","رپ","جاز","راک","پاپ","فیلم"],
    "uk": ["музика","співак","актор","художник","гурт","реп","джаз","рок","поп","кіно"],
    "sv": ["musik","sangare","skadespelare","konstnar","band","rap","jazz","rock","pop","film"],
    "el": ["μουσική","τραγουδιστής","ηθοποιός","καλλιτέχνης","συγκρότημα","ραπ","τζαζ","ροκ"],
    "cs": ["hudba","zpevak","herec","umelec","kapela","rap","jazz","rock","pop","film"],
    "hu": ["zene","enekes","szinesz","muvesz","zenekar","rap","jazz","rock","pop","film"],
    "ro": ["muzica","cantaret","actor","artist","trupa","rap","jazz","rock","pop","film"],
    "he": ["מוזיקה","זמר","שחקן","אמן","להקה","ראפ","ג'אז","רוק","פופ","קולנוע"],
    "sw": ["muziki","mwimbaji","muigizaji","msanii","bendi","rap","jazz","rock","pop","filamu"],
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


def slugify(s):
    s = s.lower().strip().replace(' ','-').replace('_','-')
    s = re.sub(r'[^a-z0-9-]','',s)
    return re.sub(r'-+','-',s).strip('-')


def validate(url, timeout=5):
    try:
        req = urllib.request.Request(url, headers={"User-Agent":"Feedmine/1.0",
            "Accept":"application/rss+xml, application/atom+xml, application/xml, text/xml, */*"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if r.status != 200: return False,""
            d = r.read(80000)
            t = d.decode("utf-8",errors="replace")[:3000].strip().lower()
            if "<rss" in t or "<feed" in t or "<rdf" in t:
                title = ""
                try:
                    import xml.etree.ElementTree as ET
                    root = ET.fromstring(d)
                    if root.tag=="rss" and (ch:=root.find("channel")) and (ti:=ch.find("title")) and ti.text:
                        title = ti.text.strip()
                    elif "feed" in root.tag:
                        for el in root:
                            if el.tag.endswith("title") or el.tag=="title":
                                title = (el.text or "").strip(); break
                except: pass
                return True, title or "valid"
    except: pass
    return False,""


def construct_urls(country_slug, country_name, langs):
    """Build URLs from country + keywords. Returns [(url, label)]."""
    urls = []
    seen = set()
    cs = slugify(country_slug)
    cn = slugify(country_name)

    for lang in langs[:2]:
        keywords = LANG_KEYWORDS.get(lang, LANG_KEYWORDS["en"])[:12]

        for kw in keywords[:12]:
            kw_slug = slugify(kw)

            # Blogspot: {kw}-{country}.blogspot.com
            for pat in [f"{kw_slug}-{cs}", f"{cs}-{kw_slug}", f"{kw_slug}-{cn}", f"{cn}-{kw_slug}",
                        f"{kw_slug}{cs}", f"{cs}{kw_slug}"]:
                url = f"https://{pat}.blogspot.com/feeds/posts/default"
                if url not in seen:
                    seen.add(url)
                    urls.append((url, f"{kw} in {country_name}"))

            # Substack
            for pat in [f"{kw_slug}-{cs}", f"{cs}-{kw_slug}", f"{kw_slug}{cs}"]:
                url = f"https://{pat}.substack.com/feed"
                if url not in seen:
                    seen.add(url)
                    urls.append((url, f"{kw} in {country_name}"))

            # WordPress
            for pat in [f"{kw_slug}{cs}", f"{cs}{kw_slug}", f"{kw_slug}-{cs}"]:
                url = f"https://{pat}.wordpress.com/feed/"
                if url not in seen:
                    seen.add(url)
                    urls.append((url, f"{kw} in {country_name}"))

    return urls


def load_existing(slug):
    urls = set()
    opml = COUNTRIES_DIR / slug / f"{slug}.opml"
    if opml.exists():
        try:
            for m in re.finditer(r'xmlUrl="([^"]+)"', opml.read_text(encoding="utf-8")):
                urls.add(m.group(1).strip().rstrip("/").lower())
        except: pass
    for dn in ["artist_cache_v3","artist_v4","artist_batch","artist_broad","artist_cache_v2","artist_fast","artist_zero"]:
        cf = REPO_ROOT / "scripts" / "feed_discovery" / "data" / dn / f"{slug}_feeds.json"
        if cf.exists():
            try:
                for f in json.loads(cf.read_text(encoding="utf-8")):
                    urls.add(f["url"].lower().rstrip("/"))
            except: pass
    return urls


def process_country(slug, meta):
    name = meta["name"]
    langs = COUNTRY_LANGS.get(slug, [meta["lang"]])

    existing = load_existing(slug)
    urls = construct_urls(slug, name, langs)
    print(f"  → {len(urls)} URLs to validate")

    feeds = []
    fs = set()

    def check(item):
        url, label = item
        ok, title = validate(url)
        if ok:
            return {"url":url,"title":title,"name":label,"source":"zero-search"}
        return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=25) as ex:
        futs = {ex.submit(check, u): u for u in urls}
        for i, f in enumerate(concurrent.futures.as_completed(futs)):
            r = f.result()
            if r:
                n = r["url"].lower().rstrip("/")
                if n not in fs:
                    fs.add(n)
                    feeds.append(r)
            if (i+1) % 100 == 0:
                print(f"    ... {i+1}/{len(urls)} checked, {len(feeds)} found")

    return feeds


def make_opml(cname, feeds):
    lines = []
    for f in feeds:
        u = f["url"]
        t = f.get("title") or f.get("name") or u
        te = t.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;")
        ue = u.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;")
        sid = hashlib.sha256(u.encode()).hexdigest()
        lines.append(f'      <outline text="{te}" title="{te}" type="rss" xmlUrl="{ue}" description="Artist blog from {cname}." language="" category="artist,blog,personal,{cname.lower()}" feedmineSourceId="{sid}" feedmineTopic="Arts &amp; Culture" feedmineSubcategory="Artist Blogs" feedmineNature="personal" feedmineActivity="active" feedmineArticlesFetched="0" feedmineQualityScore="50" feedmineDefaultEnabled="true" feedmineMediaKind="text" htmlUrl="{ue}" />')
    return lines


def main():
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--country")
    p.add_argument("--all", action="store_true")
    p.add_argument("--opml", action="store_true")
    p.add_argument("--skip-cached", action="store_true", default=True)
    args = p.parse_args()

    with open(COUNTRIES_JSON, encoding="utf-8") as f:
        countries = json.load(f)

    if args.country:
        slugs = [args.country]
    elif args.all:
        slugs = sorted(countries.keys())
    else:
        slugs = sorted(countries.keys())[:5]
        print(f"Testing {slugs}. Use --all for full run.\n")

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    total = 0

    for slug in slugs:
        meta = countries[slug]
        cname = meta["name"]

        cf = CACHE_DIR / f"{slug}_feeds.json"
        if args.skip_cached and cf.exists():
            try:
                feeds = json.loads(cf.read_text(encoding="utf-8"))
                print(f"📦 {cname} ({slug}): {len(feeds)} cached")
                total += len(feeds)
                continue
            except: pass

        print(f"🔍 {cname} ({slug})")
        feeds = process_country(slug, meta)
        dedup = []
        sf = set()
        for f in feeds:
            n = f["url"].lower().rstrip("/")
            if n not in sf:
                sf.add(n)
                dedup.append(f)
        cf.write_text(json.dumps(dedup, ensure_ascii=False, indent=2), encoding="utf-8")
        total += len(dedup)
        print(f"  ✅ {len(dedup)} feeds")

        if args.opml and dedup:
            od = CACHE_DIR / "opml"
            od.mkdir(parents=True, exist_ok=True)
            lines = make_opml(cname, dedup)
            (od / f"{slug}_artist_blogs.opml").write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n<opml version="2.0">\n  <head><title>Artist Blogs</title></head>\n  <body>\n    <outline text="Artist Blogs" title="Artist Blogs">\n'
                + "\n".join(lines) +
                '\n    </outline>\n  </body>\n</opml>'
            )

    print(f"\n✅ TOTAL: {total} feeds across {len(slugs)} countries")


if __name__ == "__main__":
    main()
