"""Museum feed discovery — crawl museum websites for RSS/Atom feeds,
YouTube channels, and podcast feeds.

Uses Wikidata as the seed list (built by scripts/build_museum_list.py),
then crawls each museum's official website for:
1. RSS/Atom autodiscovery <link> tags
2. Common feed paths (/feed/, /rss.xml, /atom.xml, etc.)
3. YouTube channel links — with official-channel verification
4. Apple Podcast / Spotify links
5. Direct podcast RSS feeds

Official YouTube detection:
  - Wikidata P2397 provides ground truth for known official channels
  - For new channels found on pages, verifies name similarity with museum name
  - Channels are only accepted if they appear on the museum's own domain

All results are returned as Candidate objects compatible with the pipeline.

Strategy per museum:
  Phase 1 — Homepage + sub-pages: fetch root + /news, /exhibitions, /blog
  Phase 2 — YouTube verification: extract + validate channel ownership
  Phase 3 — Podcast discovery: Apple Podcasts, Spotify, Anchor.fm links
  Phase 4 — Feed probes: common feed paths if nothing found via autodiscovery
"""

from __future__ import annotations

import asyncio
import html as html_mod
import json
import re
import time
from difflib import SequenceMatcher
from pathlib import Path
from urllib.parse import urljoin, urlparse

import aiohttp

from .. import discover as _discover
from ..models import Candidate, Country

USER_AGENT = "FeedmineMuseumBot/1.0 (museum-feed-discovery)"
BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

_BROWSER_HEADERS = {
    "User-Agent": BROWSER_UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9,pt;q=0.8,es;q=0.7,fr;q=0.6,de;q=0.5,it;q=0.5,ja;q=0.4",
}

# Museum-specific sub-paths likely to contain news/blogs/exhibition feeds
MUSEUM_SUB_PATHS = [
    "/news", "/blog", "/blogs", "/exhibitions", "/exhibition",
    "/collection", "/visit", "/about", "/press", "/media",
    "/events", "/podcast", "/podcasts", "/articles", "/publications",
    "/whats-on", "/whatson", "/calendar", "/stories", "/journal",
    # Multilingual
    "/noticias", "/actualites", "/nachrichten", "/ausstellungen",
    "/sammlung", "/besuch", "/exposiciones", "/coleccion", "/visita",
    "/expositions", "/visiter", "/notizie", "/mostre", "/collezione",
    "/ニュース", "/展示", "/コレクション",
]

# Museum-specific feed probe paths
MUSEUM_FEED_PROBE_PATHS = [
    "/feed/", "/rss/", "/rss.xml", "/feed.xml", "/atom.xml", "/index.xml",
    "/news/feed/", "/news/rss.xml", "/news/feed.xml", "/news/atom.xml",
    "/blog/feed/", "/blog/rss.xml", "/blog/feed.xml", "/blog/atom.xml",
    "/feed", "/rss", "/atom",
    "/exhibitions/feed/", "/exhibitions/rss.xml",
    "/events/feed/", "/events/rss.xml",
    "/press/feed/", "/press/rss.xml",
    "/noticias/rss", "/noticias/feed", "/actualites/rss",
    "/notizie/rss", "/nachrichten/rss",
]

# Known feed hub paths
_FEED_HUB_PATHS = [
    "/rss", "/feeds", "/feeds/", "/subscribe",
    "/news/rss", "/news/feeds", "/press/rss",
    "/about/rss", "/rss-feeds", "/podcasts", "/podcast",
]

# YouTube patterns
_YT_CHANNEL_RE = re.compile(
    r"youtube\.com/(?:channel/UC[0-9A-Za-z_-]{22}|@[A-Za-z0-9._%-]+|c/[A-Za-z0-9._%-]+|user/[A-Za-z0-9._%-]+)",
    re.I,
)
_YT_CHANNEL_ID_RE = re.compile(r"youtube\.com/channel/(UC[0-9A-Za-z_-]{22})", re.I)
_YT_HANDLE_RE = re.compile(r"youtube\.com/@([A-Za-z0-9._%-]+)", re.I)

# Apple Podcast / Spotify / Anchor patterns
_APPLE_PODCAST_RE = re.compile(
    r"podcasts\.apple\.com/[^\"'\s<>]+/podcast/[^\"'\s<>]+/id(\d+)", re.I,
)
_SPOTIFY_PODCAST_RE = re.compile(
    r"open\.spotify\.com/show/[A-Za-z0-9]+", re.I,
)
_ANCHOR_FM_RE = re.compile(r"anchor\.fm/[A-Za-z0-9_-]+", re.I)

# <a href> links pointing to feeds
_A_HREF_FEED_RE = re.compile(
    r'<a\b[^>]*href\s*=\s*["\']([^"\']*(?:rss|feed|atom|podcast)[^"\']*)["\']', re.I,
)

_MAX_HTML_BYTES = 512 * 1024
_CONCURRENT_CRAWL = 3  # Reduced from 5 to avoid OOM with many TCP connections


# ── URL helpers ────────────────────────────────────────────────────────
def _normalize_url(url: str) -> str:
    parsed = urlparse(url)
    path = parsed.path.rstrip("/") or "/"
    return f"{parsed.scheme}://{parsed.netloc.lower()}{path}"


def _host_of(url: str) -> str:
    return urlparse(url).hostname or ""


def _is_valid_domain(url: str) -> bool:
    host = urlparse(url).hostname
    if not host:
        return False
    try:
        host.encode("idna")
        return True
    except UnicodeError:
        return False


# ── YouTube official-channel verification ──────────────────────────────
def _is_official_youtube_channel(
    found_channel_id: str,
    found_handle: str,
    wikidata_youtube: str,
    museum_name: str,
    page_domain: str,
) -> tuple[bool, str]:
    """Determine if a YouTube channel found on a museum page is the official one.

    Returns (is_official, reason).

    Verification cascade:
      1. Wikidata ground truth — if channel ID matches P2397, confirmed.
      2. If Wikidata has a channel but it doesn't match → suspicious (reject).
      3. If no Wikidata, check name similarity: museum name vs channel handle.
      4. Also confirm the channel was found on the museum's own domain.
    """
    wd_yt = wikidata_youtube.strip() if wikidata_youtube else ""

    # 1. Wikidata ground truth match
    if wd_yt:
        # Normalize Wikidata value — could be channel ID, handle, or full URL
        wd_channel_id = ""
        wd_handle = ""
        if re.match(r"^UC[0-9A-Za-z_-]{22}$", wd_yt):
            wd_channel_id = wd_yt
        elif wd_yt.startswith("@"):
            wd_handle = wd_yt.lstrip("@").lower()
        elif "youtube.com" in wd_yt:
            cid_m = _YT_CHANNEL_ID_RE.search(wd_yt)
            h_m = _YT_HANDLE_RE.search(wd_yt)
            if cid_m:
                wd_channel_id = cid_m.group(1)
            if h_m:
                wd_handle = h_m.group(1).lower()

        if wd_channel_id and found_channel_id == wd_channel_id:
            return True, "wikidata_match_channel_id"
        if wd_handle and found_handle.lower() == wd_handle:
            return True, "wikidata_match_handle"
        # Wikidata says there's a channel but it's different → suspicious
        if wd_channel_id or wd_handle:
            return False, f"wikidata_mismatch: expected {wd_yt}"

    # 2. Name similarity check (for new channels not in Wikidata)
    if found_handle:
        similarity = _name_similarity(museum_name, found_handle)
        if similarity >= 0.5:
            return True, f"name_similarity_{similarity:.2f}"

    # 3. Channel ID alone (no handle) — just trust it if on official domain
    if found_channel_id:
        return True, "channel_id_on_official_domain"

    return False, "failed_verification"


def _name_similarity(a: str, b: str) -> float:
    """Compute name similarity between museum name and YouTube handle/name."""
    # Normalize: lowercase, strip common prefixes
    a = a.lower().strip()
    b = b.lower().strip()

    # Remove common words that don't help matching
    stopwords = {"museum", "museo", "musée", "museu", "the", "de", "of", "di", "del",
                 "national", "nacional", "nationale", "gallery", "galerie", "galeria"}
    a_words = [w for w in re.split(r"[\s\-_.,;:!?]+", a) if w not in stopwords and len(w) > 1]
    b_words = [w for w in re.split(r"[\s\-_.,;:!?]+", b) if w not in stopwords and len(w) > 1]

    # Check if any significant word from museum name appears in channel handle
    if b_words:
        matches = sum(1 for aw in a_words if any(aw in bw or bw in aw for bw in b_words))
        word_score = matches / max(len(a_words), 1)
    else:
        word_score = 0

    # Also compute sequence similarity as fallback
    seq_score = SequenceMatcher(None, a, b).ratio()

    return max(word_score, seq_score * 0.7)  # Weight sequence lower


# ── HTML fetch ─────────────────────────────────────────────────────────
async def _fetch_html(
    session: aiohttp.ClientSession,
    url: str,
    timeout: int = 12,
    retries: int = 1,
) -> str:
    """Fetch HTML text from a URL, returns empty string on any error."""
    headers = dict(_BROWSER_HEADERS)
    for attempt in range(retries + 1):
        try:
            async with session.get(
                url,
                headers=headers,
                timeout=aiohttp.ClientTimeout(total=timeout),
                allow_redirects=True,
            ) as resp:
                if resp.status != 200:
                    if attempt < retries:
                        await asyncio.sleep(1.0 * (attempt + 1))
                        continue
                    return ""
                data = await resp.content.read(_MAX_HTML_BYTES)
                text = data.decode("utf-8", errors="ignore")
                if len(text) < 2000 and attempt < retries:
                    await asyncio.sleep(1.5 * (attempt + 1))
                    continue
                return text
        except (aiohttp.ClientError, UnicodeError, TimeoutError, asyncio.TimeoutError):
            if attempt < retries:
                await asyncio.sleep(1.0 * (attempt + 1))
                continue
            return ""
    return ""


# ── Feed extraction ────────────────────────────────────────────────────
def _find_feeds_from_a_hrefs(html_text: str, base_url: str) -> list[str]:
    """Find RSS/Atom feed URLs from <a href> links."""
    feeds: list[str] = []
    seen: set[str] = set()
    for m in _A_HREF_FEED_RE.finditer(html_text):
        href = m.group(1)
        full_url = urljoin(base_url, href)
        path = urlparse(full_url).path.lower()
        if any(ind in path for ind in ["/rss", "/feed", "/atom", ".xml", ".rss"]):
            norm = _normalize_url(full_url)
            if norm not in seen:
                seen.add(norm)
                feeds.append(full_url)
    return feeds


def _find_feed_hub_urls(html_text: str, base_url: str) -> list[str]:
    """Find pages that aggregate feeds."""
    hubs: list[str] = []
    seen: set[str] = set()
    for m in _A_HREF_FEED_RE.finditer(html_text):
        href = m.group(1)
        full_url = urljoin(base_url, href)
        path = urlparse(full_url).path.lower().rstrip("/")
        if any(path.endswith(hub.rstrip("/")) for hub in _FEED_HUB_PATHS):
            norm = _normalize_url(full_url)
            if norm not in seen:
                seen.add(norm)
                hubs.append(full_url)
    return hubs


def _extract_youtube_channels(html_text: str) -> list[dict]:
    """Extract YouTube channel URLs from HTML with channel ID and handle.

    Returns list of {url, channel_id, handle}.
    """
    results: list[dict] = []
    seen_ids: set[str] = set()

    for m in _YT_CHANNEL_RE.finditer(html_text):
        url = m.group(0)
        if not url.startswith("http"):
            url = "https://" + url

        cid_m = _YT_CHANNEL_ID_RE.search(url)
        h_m = _YT_HANDLE_RE.search(url)

        channel_id = cid_m.group(1) if cid_m else ""
        handle = h_m.group(1) if h_m else ""

        # Dedup by channel_id (most reliable)
        if channel_id and channel_id not in seen_ids:
            seen_ids.add(channel_id)
            results.append({"url": url, "channel_id": channel_id, "handle": handle})
        elif handle and handle not in seen_ids and not channel_id:
            seen_ids.add(handle)
            results.append({"url": url, "channel_id": "", "handle": handle})

    return results


def _extract_podcast_links(html_text: str) -> list[dict]:
    """Extract podcast links from HTML.

    Returns list of {url, type} where type is 'apple', 'spotify', 'anchor'.
    """
    results: list[dict] = []
    seen: set[str] = set()

    for pattern, ptype in [
        (_APPLE_PODCAST_RE, "apple_podcast"),
        (_SPOTIFY_PODCAST_RE, "spotify"),
        (_ANCHOR_FM_RE, "anchor"),
    ]:
        for m in pattern.finditer(html_text):
            url = m.group(0)
            if not url.startswith("http"):
                url = "https://" + url
            if url not in seen:
                seen.add(url)
                results.append({"url": url, "type": ptype})

    return results


# ── Feed validation ────────────────────────────────────────────────────
async def _is_live_feed(
    session: aiohttp.ClientSession, url: str, timeout: int
) -> bool:
    """Quick check: is this URL a valid, live RSS/Atom feed?"""
    from ..verify import parse_feed

    try:
        async with session.get(
            url,
            headers={"User-Agent": USER_AGENT},
            timeout=aiohttp.ClientTimeout(total=min(timeout, 10)),
            allow_redirects=True,
        ) as resp:
            if resp.status != 200:
                return False
            body = await resp.content.read(64 * 1024)
    except (aiohttp.ClientError, TimeoutError, asyncio.TimeoutError, UnicodeError):
        return False
    ok, _ = parse_feed(body)
    return ok


async def _probe_feed_paths(
    session: aiohttp.ClientSession,
    root_url: str,
    timeout: int,
) -> list[str]:
    """Probe candidate feed paths concurrently, return only live feed URLs."""
    urls = [urljoin(root_url.rstrip("/") + "/", p.lstrip("/")) for p in MUSEUM_FEED_PROBE_PATHS]
    sem = asyncio.Semaphore(8)

    async def _check(url: str) -> str | None:
        async with sem:
            live = await _is_live_feed(session, url, timeout)
            return url if live else None

    results = await asyncio.gather(*(_check(u) for u in urls))
    return [r for r in results if r is not None]


# ── Main per-museum crawl ──────────────────────────────────────────────
async def _crawl_one_museum(
    museum: dict,
    country: Country,
    session: aiohttp.ClientSession,
    timeout: int,
    cache_dir: Path | None = None,
) -> dict:
    """Crawl a single museum website for all feed types.

    Args:
        museum: Museum dict from Wikidata (name, website, youtube, instagram, twitter, wikipedia_url)
        country: Country model
        session: aiohttp session
        timeout: per-request timeout
        cache_dir: optional cache directory

    Returns:
        {feeds: [Candidate], youtube: [Candidate], podcasts: [Candidate]}
    """
    website = (museum.get("website") or "").strip()
    name = museum.get("name", "Unknown Museum")
    wikidata_id = museum.get("wikidata_id", "")
    wikidata_yt = museum.get("youtube", "")

    if not website:
        return {"feeds": [], "youtube": [], "podcasts": []}

    root = website.rstrip("/")
    if not root.startswith("http"):
        root = "https://" + root

    if not _is_valid_domain(root):
        return {"feeds": [], "youtube": [], "podcasts": []}

    result: dict = {"feeds": [], "youtube": [], "podcasts": []}
    feed_urls: list[str] = []
    seen_feeds: set[str] = set()
    hub_urls: list[str] = []
    page_domain = _host_of(root)

    # ── Phase 1: Homepage + autodiscovery ──
    homepage_html = await _fetch_html(session, root, timeout)

    if homepage_html:
        # 1a. Standard <link alternate> autodiscovery
        for feed_url in _discover.find_feeds_in_html(homepage_html, root):
            norm = _normalize_url(feed_url)
            if norm not in seen_feeds:
                seen_feeds.add(norm)
                feed_urls.append(feed_url)

        # 1b. <a href> links to feeds
        for feed_url in _find_feeds_from_a_hrefs(homepage_html, root):
            norm = _normalize_url(feed_url)
            if norm not in seen_feeds:
                seen_feeds.add(norm)
                feed_urls.append(feed_url)

        # 1c. Feed hub pages
        hub_urls = _find_feed_hub_urls(homepage_html, root)

    # ── Phase 2: Crawl sub-pages ──
    async def _crawl_sub(path: str):
        url = urljoin(root + "/", path.lstrip("/"))
        html_text = await _fetch_html(session, url, timeout)
        if not html_text:
            return
        # Autodiscovery
        for feed_url in _discover.find_feeds_in_html(html_text, url):
            norm = _normalize_url(feed_url)
            if norm not in seen_feeds and not _discover._is_junk_feed(feed_url):
                seen_feeds.add(norm)
                feed_urls.append(feed_url)
        # <a href> feeds
        for feed_url in _find_feeds_from_a_hrefs(html_text, url):
            norm = _normalize_url(feed_url)
            if norm not in seen_feeds:
                seen_feeds.add(norm)
                feed_urls.append(feed_url)

    priority_paths = ["/news", "/blog", "/exhibitions", "/events", "/press", "/podcast"]
    await asyncio.gather(*(_crawl_sub(p) for p in priority_paths))

    # ── Phase 2b: Crawl feed hub pages ──
    async def _crawl_hub(url: str):
        html_text = await _fetch_html(session, url, timeout)
        if html_text:
            for feed_url in _find_feeds_from_a_hrefs(html_text, url):
                norm = _normalize_url(feed_url)
                if norm not in seen_feeds:
                    seen_feeds.add(norm)
                    feed_urls.append(feed_url)

    if hub_urls:
        await asyncio.gather(*(_crawl_hub(u) for u in hub_urls[:3]))

    # ── Phase 2c: Probe well-known feed hub paths ──
    async def _probe_hub_path(path: str):
        url = urljoin(root + "/", path.lstrip("/"))
        html_text = await _fetch_html(session, url, timeout)
        if html_text and len(html_text) > 2000:
            for feed_url in _find_feeds_from_a_hrefs(html_text, url):
                norm = _normalize_url(feed_url)
                if norm not in seen_feeds:
                    seen_feeds.add(norm)
                    feed_urls.append(feed_url)
            for feed_url in _discover.find_feeds_in_html(html_text, url):
                norm = _normalize_url(feed_url)
                if norm not in seen_feeds and not _discover._is_junk_feed(feed_url):
                    seen_feeds.add(norm)
                    feed_urls.append(feed_url)

    default_hubs = ["/rss", "/feeds", "/podcasts", "/podcast"]
    await asyncio.gather(*(_probe_hub_path(h) for h in default_hubs))

    # ── Phase 3: YouTube channels — extract + verify ──
    all_html = [homepage_html]
    # Also collect from sub-pages we fetched
    verified_yt: set[str] = set()

    # First: Wikidata ground truth — always include if present in data
    if wikidata_yt:
        if re.match(r"^UC[0-9A-Za-z_-]{22}$", wikidata_yt):
            feed_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={wikidata_yt}"
            result["youtube"].append(_make_yt_candidate(feed_url, name, website, country.slug, "wikidata"))
            verified_yt.add(wikidata_yt)
        elif wikidata_yt.startswith("@"):
            feed_url = f"https://www.youtube.com/feeds/videos.xml?user={wikidata_yt.lstrip('@')}"
            result["youtube"].append(_make_yt_candidate(feed_url, name, website, country.slug, "wikidata"))
            verified_yt.add(wikidata_yt.lower())

    # Then: extract from page HTML, verify each
    for html_text in all_html:
        if not html_text:
            continue
        for yt_info in _extract_youtube_channels(html_text):
            cid = yt_info["channel_id"]
            handle = yt_info["handle"]

            # Skip if already processed via Wikidata
            if cid and cid in verified_yt:
                continue
            if handle and handle.lower() in verified_yt:
                continue

            is_official, reason = _is_official_youtube_channel(
                cid, handle, wikidata_yt, name, page_domain
            )

            if is_official:
                if cid:
                    feed_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}"
                    verified_yt.add(cid)
                else:
                    feed_url = f"https://www.youtube.com/feeds/videos.xml?user={handle}"
                    verified_yt.add(handle.lower())

                result["youtube"].append(
                    _make_yt_candidate(feed_url, name, website, country.slug, reason)
                )

    # ── Phase 4: Podcast links ──
    podcast_links: list[dict] = []
    for html_text in all_html:
        if html_text:
            podcast_links.extend(_extract_podcast_links(html_text))

    for pl in podcast_links:
        result["podcasts"].append(Candidate(
            url=pl["url"],
            category="Podcasts",
            title=f"{name} — Podcast",
            genre="Museum",
            source_page=website,
            national=True,
            national_reason=f"museum-podcast:{name}",
        ))

    # ── Phase 5: Probe common feed paths if nothing found ──
    if not feed_urls:
        probed = await _probe_feed_paths(session, root, timeout)
        for url in probed:
            norm = _normalize_url(url)
            if norm not in seen_feeds:
                seen_feeds.add(norm)
                feed_urls.append(url)

    # ── Phase 6: Validate feeds ──
    if feed_urls:
        checks = await asyncio.gather(*(
            _is_live_feed(session, u, timeout) for u in feed_urls
        ))
        for feed_url, ok in zip(feed_urls, checks):
            if ok:
                result["feeds"].append(Candidate(
                    url=feed_url,
                    category="Education",
                    title=f"{name} — Feed",
                    genre="Museum",
                    source_page=website,
                    national=True,
                    national_reason=f"museum-feed:{name}",
                ))

    return result


def _make_yt_candidate(feed_url: str, name: str, website: str, country_slug: str, reason: str) -> Candidate:
    """Create a Candidate for a verified museum YouTube channel."""
    return Candidate(
        url=feed_url,
        category="YouTube",
        title=f"{name} — YouTube",
        genre="Museum",
        source_page=website,
        national=True,
        national_reason=f"museum-youtube:{country_slug}:{reason}",
    )


# ── Main entry point ───────────────────────────────────────────────────
async def discover(
    country: Country,
    session: aiohttp.ClientSession,
    cfg,  # pipeline Config
) -> list[Candidate]:
    """Discover feeds, YouTube channels, and podcasts for all museums in a country.

    This is the main entry point called by the pipeline.
    """
    museum_data_dir = Path(__file__).resolve().parent.parent / "data/museums/by_country"
    museum_file = museum_data_dir / f"{country.slug}.json"

    if not museum_file.exists():
        print(f"  [museums] No data for {country.name}, skipping. "
              f"Run: python3 scripts/build_museum_list.py --country {country.slug}",
              file=__import__('sys').stderr)
        return []

    museums = json.loads(museum_file.read_text(encoding="utf-8"))

    # Filter to museums with websites
    museums_with_sites = [m for m in museums if m.get("website", "").strip()]
    if not museums_with_sites:
        return []

    timeout = getattr(cfg, "timeout", 15)
    cache_dir = getattr(cfg, "cache_dir", None)

    crawl_cache_dir = None
    if cache_dir:
        crawl_cache_dir = Path(cache_dir) / "museums" / country.slug
        crawl_cache_dir.mkdir(parents=True, exist_ok=True)

    sem = asyncio.Semaphore(_CONCURRENT_CRAWL)

    async def _crawl_cached(m: dict) -> dict:
        name_slug = "".join(ch if ch.isalnum() else "_" for ch in m.get("name", "unknown"))
        cache_file = crawl_cache_dir / f"{name_slug}.json" if crawl_cache_dir else None

        if cache_file and cache_file.exists() and not getattr(cfg, "fresh", False):
            try:
                cached = json.loads(cache_file.read_text(encoding="utf-8"))
                result = {"feeds": [], "youtube": [], "podcasts": []}
                for key in result:
                    for cd in cached.get(key, []):
                        result[key].append(Candidate(**cd))
                return result
            except Exception:
                pass

        async with sem:
            result = await _crawl_one_museum(m, country, session, timeout, crawl_cache_dir)

        if cache_file:
            cache_data = {}
            for key in result:
                cache_data[key] = [
                    {"url": c.url, "category": c.category, "title": c.title,
                     "genre": c.genre, "source_page": c.source_page,
                     "national": c.national, "national_reason": c.national_reason}
                    for c in result[key]
                ]
            cache_file.write_text(json.dumps(cache_data, indent=2, ensure_ascii=False), encoding="utf-8")

        return result

    total = len(museums_with_sites)
    print(f"  [museums] Crawling {total} museums for {country.name}...",
          file=__import__('sys').stderr)

    all_results = await asyncio.gather(*(_crawl_cached(m) for m in museums_with_sites))

    candidates: list[Candidate] = []
    feeds_count = yt_count = pod_count = 0
    for r in all_results:
        candidates.extend(r["feeds"])
        candidates.extend(r["youtube"])
        candidates.extend(r["podcasts"])
        feeds_count += len(r["feeds"])
        yt_count += len(r["youtube"])
        pod_count += len(r["podcasts"])

    print(f"  [museums] {country.name}: {feeds_count} RSS, "
          f"{yt_count} YouTube, {pod_count} podcasts from {total} museums",
          file=__import__('sys').stderr)

    return candidates


# ── SourceProtocol implementation (for pluggable pipeline) ─────────────
from ..profiles._schema import CountryProfile as _CountryProfile
from ..profiles._schema import SourceConfig as _SourceConfig
from ._base import ProbeResult as _ProbeResult


class MuseumSource:
    """Museum website crawler as a SourceProtocol implementation."""

    name = "museums"

    async def search(
        self,
        query: str,
        profile: _CountryProfile,
        config: _SourceConfig,
        session: aiohttp.ClientSession,
    ) -> list[Candidate]:
        return []

    async def probe(
        self,
        profile: _CountryProfile,
        config: _SourceConfig,
        session: aiohttp.ClientSession,
    ) -> _ProbeResult:
        import time as _time
        t0 = _time.monotonic()

        museum_data_dir = Path(__file__).resolve().parent.parent / "data/museums/by_country"
        museum_file = museum_data_dir / f"{profile.country}.json"

        if not museum_file.exists():
            elapsed = (_time.monotonic() - t0) * 1000
            return _ProbeResult(
                source_name="museums",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=f"No museum data for {profile.country}",
            )

        museums = json.loads(museum_file.read_text(encoding="utf-8"))
        with_sites = [m for m in museums if m.get("website", "").strip()]
        elapsed = (_time.monotonic() - t0) * 1000

        return _ProbeResult(
            source_name="museums",
            success=len(with_sites) > 0,
            result_count=len(with_sites),
            latency_ms=elapsed,
        )
