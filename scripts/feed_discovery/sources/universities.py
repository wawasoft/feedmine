"""University feed discovery — crawl university websites for RSS/Atom feeds,
YouTube channels, and podcast feeds.

Uses Wikidata as the seed list (built by scripts/build_university_list.py),
then crawls each university's official website for:
1. RSS/Atom autodiscovery <link> tags
2. Common feed paths (/feed/, /rss.xml, /atom.xml, etc.)
3. YouTube channel links embedded in the page
4. Apple Podcast / Spotify links
5. Direct podcast RSS feeds

All results are returned as Candidate objects compatible with the pipeline.

Strategy per university:
  Phase 1 — Homepage crawl: fetch root + /news or /blog, extract feeds + YT links
  Phase 2 — Common paths: if nothing found, probe /feed/, /rss/, etc.
  Phase 3 — Deep search: one level of link following for /news, /blog, /research pages
"""

from __future__ import annotations

import asyncio
import html as html_mod
import json
import re
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

import aiohttp

from .. import discover as _discover
from ..models import Candidate, Country

USER_AGENT = "FeedmineUniversityBot/1.0 (university-feed-discovery)"
BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

# Browser-like headers to avoid being served JS-only stubs
_BROWSER_HEADERS = {
    "User-Agent": BROWSER_UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9,pt;q=0.8,es;q=0.7",
}

# Common university sub-paths that often contain news/blogs with feeds
UNIVERSITY_SUB_PATHS = [
    "/news", "/blog", "/blogs", "/research", "/research-news",
    "/articles", "/press", "/media", "/events", "/podcast",
    "/podcasts", "/publications", "/newsroom", "/noticias",
    "/noticias/", "/actualites", "/nachrichten", "/novosti",
    "/novidades", "/novedades", "/news-events", "/latest-news",
    "/category/news", "/category/blog",
]

# Common feed paths to probe when HTML doesn't advertise feeds
FEED_PROBE_PATHS = [
    "/feed/", "/rss/", "/rss.xml", "/feed.xml", "/atom.xml", "/index.xml",
    "/news/feed/", "/news/rss.xml", "/news/feed.xml", "/news/atom.xml",
    "/blog/feed/", "/blog/rss.xml", "/blog/feed.xml", "/blog/atom.xml",
    "/feed", "/rss", "/atom",
    "/noticias/rss", "/noticias/feed", "/noticias/rss.xml",
    "/category/news/feed/", "/category/all/feed/",
]

# YouTube patterns
_YT_CHANNEL_RE = re.compile(
    r"youtube\.com/(?:channel/UC[0-9A-Za-z_-]{22}|@[A-Za-z0-9._%-]+|c/[A-Za-z0-9._%-]+|user/[A-Za-z0-9._%-]+)",
    re.I,
)
_YT_HANDLE_RE = re.compile(r"youtube\.com/@([A-Za-z0-9._%-]+)", re.I)

# Apple Podcast patterns
_APPLE_PODCAST_RE = re.compile(
    r"podcasts\.apple\.com/[^\"'\s<>]+/podcast/[^\"'\s<>]+/id(\d+)",
    re.I,
)
_APPLE_PODCAST_SHORT_RE = re.compile(
    r"apple\.co/[A-Za-z0-9]+",
    re.I,
)

# Spotify podcast patterns
_SPOTIFY_PODCAST_RE = re.compile(
    r"open\.spotify\.com/show/[A-Za-z0-9]+",
    re.I,
)

# Direct podcast RSS links
_PODCAST_RSS_RE = re.compile(
    r'<link[^>]*type="application/rss\+xml"[^>]*title="[^"]*(?:podcast|Podcast|PODCAST)[^"]*"[^>]*>',
    re.I,
)
_PODCAST_ATOM_RE = re.compile(
    r'<link[^>]*type="application/atom\+xml"[^>]*title="[^"]*(?:podcast|Podcast|PODCAST)[^"]*"[^>]*>',
    re.I,
)

# Anchor.fm / Spotify for Podcasters
_ANCHOR_FM_RE = re.compile(r"anchor\.fm/[A-Za-z0-9_-]+", re.I)

# Podcast page keywords in href text/label
_PODCAST_KEYWORDS = ["podcast", "podcasts", "podcastrss", "audio", "episodes"]

# <a href> links that look like they point to RSS/Atom feeds
_A_HREF_FEED_RE = re.compile(
    r'<a\b[^>]*href\s*=\s*["\']([^"\']*(?:rss|feed|atom|podcast)[^"\']*)["\']',
    re.I,
)
# Title attributes / link text suggesting a feed
_A_FEED_TEXT = re.compile(r'(?:rss|atom|feed|syndication|subscribe)', re.I)

# Known feed hubs on university sites
_FEED_HUB_PATHS = [
    "/rss", "/feeds", "/feeds/", "/subscribe", "/news/rss", "/news/feeds",
    "/news/rss/", "/about/rss", "/rss-feeds", "/news/subscribe",
    "/media/rss", "/podcasts", "/podcast",
]

_MAX_HTML_BYTES = 512 * 1024  # University homepages are often 180KB+ (MIT: 178KB)
_CONCURRENT_CRAWL = 5  # per-country internal concurrency


def _find_feeds_from_a_hrefs(html_text: str, base_url: str) -> list[str]:
    """Find RSS/Atom feed URLs from regular <a href> links (not just <link> tags).

    Many university sites don't use <link alternate> autodiscovery but have
    footer links or sidebar links like <a href="/rss">RSS</a>.
    """
    feeds: list[str] = []
    seen: set[str] = set()
    for m in _A_HREF_FEED_RE.finditer(html_text):
        href = m.group(1)
        # Join with base URL
        full_url = urljoin(base_url, href)
        # Check that the URL looks like a feed
        parsed = urlparse(full_url)
        path = parsed.path.lower()
        if any(indicator in path for indicator in [
            "/rss", "/feed", "/atom", ".xml", ".rss",
        ]):
            norm = _normalize_url(full_url)
            if norm not in seen:
                seen.add(norm)
                feeds.append(full_url)
    return feeds


def _find_feed_hub_urls(html_text: str, base_url: str) -> list[str]:
    """Find pages that aggregate/organize feeds (like /rss, /feeds)."""
    hubs: list[str] = []
    seen: set[str] = set()
    for m in _A_HREF_FEED_RE.finditer(html_text):
        href = m.group(1)
        full_url = urljoin(base_url, href)
        parsed = urlparse(full_url)
        path = parsed.path.lower().rstrip("/")
        if any(path.endswith(hub.rstrip("/")) for hub in _FEED_HUB_PATHS):
            norm = _normalize_url(full_url)
            if norm not in seen:
                seen.add(norm)
                hubs.append(full_url)
    return hubs


def _root_of(url: str) -> str:
    parsed = urlparse(url)
    return f"{parsed.scheme}://{parsed.netloc}"


def _host_of(url: str) -> str:
    return urlparse(url).hostname or ""


def _is_valid_domain(url: str) -> bool:
    """Check if URL has a DNS-resolvable hostname (no IDNA issues)."""
    host = urlparse(url).hostname
    if not host:
        return False
    # Reject hostnames that IDNA can't encode (starts with digit, too long, etc.)
    try:
        host.encode("idna")
        return True
    except UnicodeError:
        return False


def _normalize_url(url: str) -> str:
    """Normalize URLs for dedup: strip trailing slash, lowercase scheme+host."""
    parsed = urlparse(url)
    path = parsed.path.rstrip("/") or "/"
    return f"{parsed.scheme}://{parsed.netloc.lower()}{path}"


async def _fetch_html(
    session: aiohttp.ClientSession,
    url: str,
    timeout: int = 12,
    use_browser_ua: bool = False,
    retries: int = 1,
) -> str:
    """Fetch HTML text from a URL, returns empty string on any error.

    Retries on failure or suspiciously short responses (< 2000 bytes)
    which often indicate a JS-only stub from CDN A/B serving.
    """
    if use_browser_ua:
        headers = dict(_BROWSER_HEADERS)
    else:
        headers = {"User-Agent": USER_AGENT}

    last_result = ""
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
                # If response is suspiciously small (JS-only stub), retry
                if len(text) < 2000 and attempt < retries:
                    await asyncio.sleep(1.5 * (attempt + 1))
                    last_result = text
                    continue
                return text
        except (aiohttp.ClientError, UnicodeError, TimeoutError, asyncio.TimeoutError):
            if attempt < retries:
                await asyncio.sleep(1.0 * (attempt + 1))
                continue
            return ""
    return last_result


def _extract_youtube_channels(html_text: str, base_url: str) -> list[str]:
    """Extract YouTube channel URLs from HTML."""
    channels: list[str] = []
    seen: set[str] = set()
    for m in _YT_CHANNEL_RE.finditer(html_text):
        url = m.group(0)
        # Ensure proper scheme
        if not url.startswith("http"):
            url = "https://" + url
        url = url.strip()
        if url not in seen:
            seen.add(url)
            channels.append(url)
    return channels


def _extract_podcast_links(html_text: str, base_url: str) -> list[dict]:
    """Extract podcast links from HTML.

    Returns list of {url, type} where type is 'apple', 'spotify', 'anchor', 'rss'.
    """
    results: list[dict] = []
    seen: set[str] = set()

    # Apple Podcasts
    for m in _APPLE_PODCAST_RE.finditer(html_text):
        url = m.group(0)
        if not url.startswith("http"):
            url = "https://" + url
        if url not in seen:
            seen.add(url)
            results.append({"url": url, "type": "apple_podcast"})

    # Spotify
    for m in _SPOTIFY_PODCAST_RE.finditer(html_text):
        url = m.group(0)
        if not url.startswith("http"):
            url = "https://" + url
        if url not in seen:
            seen.add(url)
            results.append({"url": url, "type": "spotify"})

    # Anchor.fm
    for m in _ANCHOR_FM_RE.finditer(html_text):
        url = m.group(0)
        if not url.startswith("http"):
            url = "https://" + url
        if url not in seen:
            seen.add(url)
            results.append({"url": url, "type": "anchor"})

    return results


def _is_podcast_link(tag_html: str, href: str) -> bool:
    """Check if a link tag looks like it's advertising a podcast feed."""
    combined = (tag_html + " " + href).lower()
    return any(kw in combined for kw in _PODCAST_KEYWORDS)


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
    paths: list[str] | None = None,
) -> list[str]:
    """Probe candidate feed paths concurrently, return only live feed URLs."""
    paths_to_try = paths or FEED_PROBE_PATHS
    urls = [urljoin(root_url.rstrip("/") + "/", p.lstrip("/")) for p in paths_to_try]

    sem = asyncio.Semaphore(8)

    async def _check(url: str) -> str | None:
        async with sem:
            live = await _is_live_feed(session, url, timeout)
            return url if live else None

    results = await asyncio.gather(*(_check(u) for u in urls))
    return [r for r in results if r is not None]


async def _crawl_one_university(
    uni: dict,
    country: Country,
    session: aiohttp.ClientSession,
    timeout: int,
    cache_dir: Path | None = None,
) -> dict:
    """Crawl a single university website for all feed types.

    Args:
        uni: University dict from Wikidata (name, website, youtube, etc.)
        country: Country model for the university
        session: aiohttp session
        timeout: per-request timeout
        cache_dir: optional cache directory

    Returns:
        {feeds: [Candidate], youtube: [Candidate], podcasts: [Candidate]}
    """
    website = (uni.get("website") or "").strip()
    name = uni.get("name", "Unknown University")

    if not website:
        return {"feeds": [], "youtube": [], "podcasts": []}

    root = website.rstrip("/")
    if not root.startswith("http"):
        root = "https://" + root

    # Skip URLs with unresolvable hostnames (IDNA encoding errors)
    if not _is_valid_domain(root):
        return {"feeds": [], "youtube": [], "podcasts": []}

    result: dict = {"feeds": [], "youtube": [], "podcasts": []}
    feed_urls: list[str] = []
    seen_feeds: set[str] = set()
    hub_urls: list[str] = []

    # --- Phase 1: Fetch homepage + find autodiscovery feeds ---
    homepage_html = await _fetch_html(session, root, timeout, use_browser_ua=True)

    if homepage_html:
        # 1a. Standard <link alternate> autodiscovery
        autodiscovered = _discover.find_feeds_in_html(homepage_html, root)
        for url in autodiscovered:
            norm = _normalize_url(url)
            if norm not in seen_feeds:
                seen_feeds.add(norm)
                feed_urls.append(url)

        # 1b. <a href> links pointing to feed URLs (footer/sidebar links)
        a_href_feeds = _find_feeds_from_a_hrefs(homepage_html, root)
        for url in a_href_feeds:
            norm = _normalize_url(url)
            if norm not in seen_feeds:
                seen_feeds.add(norm)
                feed_urls.append(url)

        # 1c. Feed hub pages (pages that list multiple feeds)
        hub_urls = _find_feed_hub_urls(homepage_html, root)

    # --- Phase 2: Crawl sub-pages (news, blog, etc.) for more feeds ---
    sub_htmls: dict[str, str] = {}

    async def _crawl_sub(path: str):
        url = urljoin(root + "/", path.lstrip("/"))
        html_text = await _fetch_html(session, url, timeout, use_browser_ua=True)
        if html_text:
            sub_htmls[path] = html_text
            # Check for autodiscovery
            for feed_url in _discover.find_feeds_in_html(html_text, url):
                norm = _normalize_url(feed_url)
                if norm not in seen_feeds and not _discover._is_junk_feed(feed_url):
                    seen_feeds.add(norm)
                    feed_urls.append(feed_url)
            # Check for <a href> feed links
            for feed_url in _find_feeds_from_a_hrefs(html_text, url):
                norm = _normalize_url(feed_url)
                if norm not in seen_feeds:
                    seen_feeds.add(norm)
                    feed_urls.append(feed_url)

    # Crawl most relevant sub-paths concurrently (limit to priority only for speed)
    priority_paths = ["/news", "/blog", "/podcast", "/podcasts", "/noticias"]
    await asyncio.gather(*(_crawl_sub(p) for p in priority_paths))

    # --- Phase 2b: Also crawl feed hub pages found in Phase 1c ---
    async def _crawl_hub(url: str):
        html_text = await _fetch_html(session, url, timeout, use_browser_ua=True)
        if html_text:
            # Feed hubs often link to individual feeds
            for feed_url in _find_feeds_from_a_hrefs(html_text, url):
                norm = _normalize_url(feed_url)
                if norm not in seen_feeds:
                    seen_feeds.add(norm)
                    feed_urls.append(feed_url)
            # Also try autodiscovery on hub pages
            for feed_url in _discover.find_feeds_in_html(html_text, url):
                norm = _normalize_url(feed_url)
                if norm not in seen_feeds and not _discover._is_junk_feed(feed_url):
                    seen_feeds.add(norm)
                    feed_urls.append(feed_url)

    if hub_urls:
        await asyncio.gather(*(_crawl_hub(u) for u in hub_urls[:3]))

    # --- Phase 2c: Also probe well-known feed hub paths directly ---
    # Many universities have /rss, /feeds, etc. even when the homepage
    # doesn't link to them (or the page is served from a CDN pod that omits them).
    async def _probe_hub_path(path: str):
        url = urljoin(root + "/", path.lstrip("/"))
        html_text = await _fetch_html(session, url, timeout, use_browser_ua=True)
        if html_text and len(html_text) > 2000:  # Real page, not JS stub
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

    # Always probe the most common feed hubs
    default_hubs = ["/rss", "/feeds", "/podcasts", "/podcast"]
    hubs_to_try = [h for h in default_hubs if urljoin(root + "/", h.lstrip("/")) not in hub_urls]
    if hubs_to_try:
        await asyncio.gather(*(_probe_hub_path(h) for h in hubs_to_try))

    # --- Phase 3: Extract YouTube channels from all HTML ---
    all_html_texts = [homepage_html] + list(sub_htmls.values())
    yt_channels: set[str] = set()

    # Start with Wikidata YouTube channel if present
    wd_youtube = (uni.get("youtube") or "").strip()
    if wd_youtube:
        # If it's just a channel ID (UC...), convert to full URL
        if re.match(r"^UC[0-9A-Za-z_-]{22}$", wd_youtube):
            yt_channels.add(f"https://www.youtube.com/channel/{wd_youtube}")
        elif wd_youtube.startswith("@"):
            yt_channels.add(f"https://www.youtube.com/{wd_youtube}")
        elif "youtube.com" in wd_youtube or "youtu.be" in wd_youtube:
            yt_channels.add(wd_youtube)
        else:
            # Try as handle
            yt_channels.add(f"https://www.youtube.com/@{wd_youtube}")
            yt_channels.add(f"https://www.youtube.com/channel/{wd_youtube}")

    # Extract from pages
    for html_text in all_html_texts:
        if html_text:
            yt_channels.update(_extract_youtube_channels(html_text, root))

    for yt_url in yt_channels:
        rss_url = ""  # Will be resolved to RSS by the pipeline
        # Convert YouTube URL to RSS feed URL if possible
        channel_match = _YT_CHANNEL_RE.search(yt_url)
        if channel_match:
            # YouTube RSS feeds
            if "/channel/UC" in yt_url:
                cid = yt_url.split("/channel/")[1].split("?")[0].split("#")[0].split("/")[0]
                rss_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}"
            elif "/@" in yt_url:
                handle = yt_url.split("/@")[1].split("?")[0].split("#")[0].split("/")[0]
                rss_url = f"https://www.youtube.com/feeds/videos.xml?user={handle}"

        result["youtube"].append(Candidate(
            url=rss_url or yt_url,
            category="YouTube",
            title=f"{name} — YouTube",
            genre="Education",
            source_page=website,
            national=True,
            national_reason=f"university-youtube:{name}",
        ))

    # --- Phase 4: Extract podcast links ---
    podcast_links: list[dict] = []
    for html_text in all_html_texts:
        if html_text:
            podcast_links.extend(_extract_podcast_links(html_text, root))

    # Also check for direct podcast RSS in link tags (with podcast-y titles)
    if homepage_html:
        from ..discover import _LINK_RE, _HREF_RE
        for tag in _LINK_RE.findall(homepage_html):
            low = tag.lower()
            if "application/rss+xml" in low or "application/atom+xml" in low:
                m = _HREF_RE.search(tag)
                if m and _is_podcast_link(tag, m.group(1)):
                    rss_url = urljoin(root, html_mod.unescape(m.group(1)))
                    podcast_links.append({"url": rss_url, "type": "podcast_rss"})

    for pl in podcast_links:
        result["podcasts"].append(Candidate(
            url=pl["url"],
            category="Podcasts",
            title=f"{name} — Podcast",
            genre="Education",
            source_page=website,
            national=True,
            national_reason=f"university-podcast:{name}",
        ))

    # --- Phase 5: If no feeds found, probe common paths ---
    if not feed_urls:
        probed = await _probe_feed_paths(session, root, timeout)
        for url in probed:
            norm = _normalize_url(url)
            if norm not in seen_feeds:
                seen_feeds.add(norm)
                feed_urls.append(url)

    # --- Phase 6: Validate all feed URLs ---
    live_feeds: list[str] = []
    if feed_urls:
        checks = await asyncio.gather(*(
            _is_live_feed(session, u, timeout) for u in feed_urls
        ))
        live_feeds = [u for u, ok in zip(feed_urls, checks) if ok]

    for feed_url in live_feeds:
        result["feeds"].append(Candidate(
            url=feed_url,
            category="Education",
            title=f"{name} — Feed",
            genre="University",
            source_page=website,
            national=True,
            national_reason=f"university-feed:{name}",
        ))

    return result


async def discover(
    country: Country,
    session: aiohttp.ClientSession,
    cfg,  # pipeline Config
) -> list[Candidate]:
    """Discover feeds, YouTube channels, and podcasts for all universities in a country.

    This is the main entry point called by the pipeline. It loads the
    Wikidata-generated university list, crawls each university website,
    and returns Candidate objects ready for verification and OPML export.

    Args:
        country: Country model with slug, name, etc.
        session: Shared aiohttp session.
        cfg: Pipeline Config (with timeout, cache_dir, concurrency, etc.).

    Returns:
        List of Candidate objects for feeds, YouTube channels, and podcasts.
    """
    # Load university list for this country
    uni_data_dir = Path(__file__).resolve().parent.parent / "data/universities/by_country"
    uni_file = uni_data_dir / f"{country.slug}.json"

    if not uni_file.exists():
        # Try building it on the fly
        print(f"  [universities] No data for {country.name}, skipping. "
              f"Run: python3 scripts/build_university_list.py --country {country.slug}",
              file=__import__('sys').stderr)
        return []

    universities = json.loads(uni_file.read_text(encoding="utf-8"))

    # Filter to universities with websites
    unis_with_sites = [u for u in universities if u.get("website", "").strip()]
    if not unis_with_sites:
        return []

    timeout = getattr(cfg, "timeout", 15)
    cache_dir = getattr(cfg, "cache_dir", None)

    # Cache for crawl results
    crawl_cache_dir = None
    if cache_dir:
        crawl_cache_dir = Path(cache_dir) / "universities" / country.slug
        crawl_cache_dir.mkdir(parents=True, exist_ok=True)

    # Crawl each university concurrently, bounded by semaphore
    sem = asyncio.Semaphore(_CONCURRENT_CRAWL)

    async def _crawl_cached(uni: dict) -> dict:
        name_slug = "".join(ch if ch.isalnum() else "_" for ch in uni.get("name", "unknown"))
        cache_file = crawl_cache_dir / f"{name_slug}.json" if crawl_cache_dir else None

        if cache_file and cache_file.exists() and not getattr(cfg, "fresh", False):
            try:
                cached = json.loads(cache_file.read_text(encoding="utf-8"))
                # Reconstruct Candidates from cached dicts
                result = {"feeds": [], "youtube": [], "podcasts": []}
                for key in result:
                    for cd in cached.get(key, []):
                        result[key].append(Candidate(**cd))
                return result
            except Exception:
                pass

        async with sem:
            result = await _crawl_one_university(uni, country, session, timeout, crawl_cache_dir)

        if cache_file:
            # Serialize Candidates to plain dicts for caching
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

    # Process all universities
    total = len(unis_with_sites)
    print(f"  [universities] Crawling {total} universities for {country.name}...",
          file=__import__('sys').stderr)

    all_results = await asyncio.gather(*(_crawl_cached(u) for u in unis_with_sites))

    # Collect all candidates
    candidates: list[Candidate] = []
    feeds_count = yt_count = pod_count = 0
    for r in all_results:
        candidates.extend(r["feeds"])
        candidates.extend(r["youtube"])
        candidates.extend(r["podcasts"])
        feeds_count += len(r["feeds"])
        yt_count += len(r["youtube"])
        pod_count += len(r["podcasts"])

    print(f"  [universities] {country.name}: {feeds_count} feeds, "
          f"{yt_count} YouTube, {pod_count} podcasts from {total} universities",
          file=__import__('sys').stderr)

    return candidates


# ---------------------------------------------------------------------------
# UniversitySource — SourceProtocol implementation for pluggable pipeline
# ---------------------------------------------------------------------------

from ..profiles._schema import CountryProfile as _CountryProfile
from ..profiles._schema import SourceConfig as _SourceConfig
from ._base import ProbeResult as _ProbeResult


class UniversitySource:
    """University website crawler as a SourceProtocol implementation.

    Crawls university websites for RSS/Atom feeds, YouTube channels,
    and podcast links. Uses Wikidata as the seed list.
    """
    name = "universities"

    async def search(
        self,
        query: str,
        profile: _CountryProfile,
        config: _SourceConfig,
        session: aiohttp.ClientSession,
    ) -> list[Candidate]:
        """Not used directly — the discover() function above is the main entry.
        This is a stub for the probe interface.
        """
        # Build a minimal Country from profile
        country = Country(
            slug=profile.country,
            name=profile.country,
            cctld=profile.country[:2],
            use_cctld=False,
            lang=profile.languages[0] if profile.languages else "en",
            ddg_region=f"{profile.country[:2]}-{profile.languages[0] if profile.languages else 'en'}",
            cities=[query],
        )

        # We can't easily pass cfg through the protocol, so just return []
        return []

    async def probe(
        self,
        profile: _CountryProfile,
        config: _SourceConfig,
        session: aiohttp.ClientSession,
    ) -> _ProbeResult:
        """Probe: check if we have university data for this country."""
        import time as _time
        t0 = _time.monotonic()

        uni_data_dir = Path(__file__).resolve().parent.parent / "data/universities/by_country"
        uni_file = uni_data_dir / f"{profile.country}.json"

        if not uni_file.exists():
            elapsed = (_time.monotonic() - t0) * 1000
            return _ProbeResult(
                source_name="universities",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=f"No university data for {profile.country}",
            )

        universities = json.loads(uni_file.read_text(encoding="utf-8"))
        with_sites = [u for u in universities if u.get("website", "").strip()]
        elapsed = (_time.monotonic() - t0) * 1000

        return _ProbeResult(
            source_name="universities",
            success=len(with_sites) > 0,
            result_count=len(with_sites),
            latency_ms=elapsed,
        )
