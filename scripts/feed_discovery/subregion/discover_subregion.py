# scripts/feed_discovery/subregion/discover_subregion.py

from __future__ import annotations

import asyncio
import json
import time
from urllib.parse import urlencode, urlparse

import aiohttp

from .. import discover, search, verify
from ..heuristic import is_local
from ..models import Candidate, SubRegion
from ..opml import normalize_url
from ..pipeline import Config
from ..sources.youtube import (
    _BROWSER_UA,
    _CHANNEL_ID,
    _CHANNEL_PATH,
    _COUNTRY,
    _OG_TITLE,
    about_url,
    channel_rss_url,
    extract_channel_refs,
    extract_video_urls,
)

ITUNES_SEARCH = "https://itunes.apple.com/search"


def build_subregion_queries(subregion_name: str, country_name: str, native_name: str) -> list[str]:
    """Build DDG search queries for a sub-region's text/news feeds.

    Returns a list of query strings using city name + country name combinations.
    """
    queries = [
        f"{subregion_name} {country_name} news",
        f"{subregion_name} {country_name} newspaper",
        f"{subregion_name} {country_name} blog",
        f"{subregion_name} {country_name} rss",
    ]
    if native_name and native_name != country_name:
        queries.append(f"{subregion_name} {native_name} notícias")
    return queries


def _root_of(url: str) -> str:
    parsed = urlparse(url)
    return f"{parsed.scheme}://{parsed.netloc}"


async def _discover_text(
    subregion: SubRegion,
    country_name: str,
    native_name: str,
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Discover text/news feeds for a sub-region via DDG search."""
    candidates: list[Candidate] = []
    seen_feed_urls: set[str] = set()
    root_feeds: dict[str, list[str]] = {}

    queries = build_subregion_queries(subregion.name, country_name, native_name)

    # Collect page URLs from DDG
    page_urls: list[str] = []
    seen_pages: set[str] = set()
    for qi, query in enumerate(queries):
        cache_path = cfg.cache_dir / "subregion" / subregion.slug / "search" / f"{qi}.json"
        for url in search.search(
            query, subregion.ddg_region, cfg.max_results, cache_path, cfg.delay, cfg.fresh
        ):
            if url not in seen_pages:
                seen_pages.add(url)
                page_urls.append(url)

    # Discover feeds from page URLs
    roots = list(dict.fromkeys(_root_of(u) for u in page_urls))
    pending = [r for r in roots if r not in root_feeds]
    sem = asyncio.Semaphore(max(1, cfg.concurrency))

    async def _discover_one(root: str) -> tuple[str, list[str]]:
        async with sem:
            feeds = await discover.discover_feeds(session, root, cfg.timeout)
            return root, feeds

    discovered = await asyncio.gather(*(_discover_one(r) for r in pending))
    for root, feeds in discovered:
        root_feeds[root] = feeds

    # Collect all unique feed URLs
    feed_urls: list[str] = []
    for root in roots:
        for feed in root_feeds.get(root, []):
            norm = normalize_url(feed)
            if norm not in seen_feed_urls:
                seen_feed_urls.add(norm)
                feed_urls.append(feed)

    # Classify & verify
    to_verify: list[tuple[str, str]] = []  # (url, title)
    for feed_url in feed_urls:
        norm = normalize_url(feed_url)
        is_loc, reason = is_local(feed_url, subregion.name, None)  # Country not needed
        if not is_loc:
            continue
        is_new = norm not in existing_urls
        if not is_new:
            candidates.append(Candidate(
                url=feed_url, category="News", title="", genre="",
                national=True, national_reason=reason, is_new=False,
            ))
            continue
        to_verify.append((feed_url, reason))

    # Verify liveness concurrently
    sem_v = asyncio.Semaphore(max(1, cfg.concurrency))

    async def _verify_one(url: str, reason: str) -> Candidate | None:
        async with sem_v:
            is_live, status, title = await verify.verify_feed(session, url, cfg.timeout)
            if is_live and discover.is_comment_feed_title(title):
                is_live = False
            if not is_live:
                return None
            # Re-check is_local with feed title now available
            is_loc2, reason2 = is_local(url, subregion.name, None, feed_title=title)
            if not is_loc2:
                return None
            return Candidate(
                url=url, category="News", title=title, genre="",
                national=True, national_reason=reason2, is_live=True, status_code=status,
            )

    results = await asyncio.gather(*(_verify_one(u, r) for u, r in to_verify))
    for c in results:
        if c is not None:
            candidates.append(c)

    return candidates


async def _discover_podcasts(
    subregion: SubRegion,
    country_name: str,
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Discover podcast feeds for a sub-region via iTunes Search API.

    Uses the sub-region name as the primary search term, falling back to
    country name. Filters results to those mentioning the city in title/artist.
    """
    def _itunes_url(term: str) -> str:
        q = urlencode({"term": term, "country": subregion.iso2, "entity": "podcast", "limit": 50})
        return f"{ITUNES_SEARCH}?{q}"

    def _safe(term: str) -> str:
        return "".join(ch if ch.isalnum() else "_" for ch in term)

    candidates: list[Candidate] = []
    seen: set[str] = set()
    city_lower = subregion.name.lower()

    terms = [subregion.name, f"{subregion.name} {country_name}"]
    for term in terms:
        cache_path = cfg.cache_dir / "subregion" / subregion.slug / "itunes" / (_safe(term) + ".json")
        if not cfg.fresh and cache_path.exists():
            payload = json.loads(cache_path.read_text(encoding="utf-8"))
        else:
            payload = {"results": []}
            try:
                async with session.get(
                    _itunes_url(term),
                    timeout=aiohttp.ClientTimeout(total=cfg.timeout),
                ) as resp:
                    if resp.status == 200:
                        payload = await resp.json(content_type=None)
            except (aiohttp.ClientError, TimeoutError):
                payload = {"results": []}
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            if cfg.delay:
                time.sleep(cfg.delay)

        for r in payload.get("results", []):
            feed = r.get("feedUrl")
            if not feed or feed in seen:
                continue
            # Accept if country matches OR city name appears in title/artist
            country_match = (r.get("country") or "").upper() == subregion.iso3.upper()
            title = r.get("collectionName", "")
            artist = r.get("artistName", "")
            city_mention = city_lower in title.lower() or city_lower in artist.lower()
            if not country_match and not city_mention:
                continue
            seen.add(feed)
            norm = normalize_url(feed)
            if norm in existing_urls:
                candidates.append(Candidate(
                    url=feed, category="Podcasts", title=title,
                    genre=r.get("primaryGenreName", ""),
                    national=True, national_reason="itunes_city_match", is_new=False,
                ))
                continue
            candidates.append(Candidate(
                url=feed, category="Podcasts", title=title,
                genre=r.get("primaryGenreName", ""),
                national=True, national_reason="itunes_city_match",
            ))

    return candidates


async def _discover_youtube(
    subregion: SubRegion,
    country_name: str,
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Discover YouTube channels for a sub-region.

    Reuses youtube.py's discovery logic but with city-targeted queries and
    a city-name filter instead of country-name filter.
    """
    # Build city-targeted queries
    queries = [
        f"site:youtube.com {subregion.name} {country_name}",
        f"site:youtube.com {subregion.name}",
    ]
    urls: list[str] = []
    for qi, query in enumerate(queries):
        cache_path = cfg.cache_dir / "subregion" / subregion.slug / "youtube_search" / f"{qi}.json"
        urls.extend(search.search(
            query, subregion.ddg_region, cfg.max_results, cache_path, cfg.delay, cfg.fresh
        ))

    city_lower = subregion.name.lower()
    refs = extract_channel_refs(urls)
    seen_refs: set[str] = set(refs)

    # Resolve video URLs to channels
    for vurl in extract_video_urls(urls):
        vcache = cfg.cache_dir / "subregion" / subregion.slug / "youtube_videos" / (
            "".join(ch if ch.isalnum() else "_" for ch in vurl.split("youtube.com/", 1)[-1]) + ".json"
        )
        if not cfg.fresh and vcache.exists():
            cid = json.loads(vcache.read_text(encoding="utf-8")).get("channel_id", "")
        else:
            cid = ""
            try:
                async with session.get(
                    vurl, headers={"User-Agent": _BROWSER_UA},
                    timeout=aiohttp.ClientTimeout(total=cfg.timeout),
                ) as resp:
                    if resp.status == 200:
                        m = _CHANNEL_ID.search(await resp.text())
                        if m:
                            cid = m.group(1)
            except (aiohttp.ClientError, TimeoutError):
                pass
            vcache.parent.mkdir(parents=True, exist_ok=True)
            vcache.write_text(json.dumps({"channel_id": cid}, ensure_ascii=False), encoding="utf-8")
        if cid:
            ref = f"https://www.youtube.com/channel/{cid}"
            if ref not in seen_refs:
                seen_refs.add(ref)
                refs.append(ref)

    # Resolve channel About pages
    candidates: list[Candidate] = []
    seen_ids: set[str] = set()

    for ref in refs:
        chan_slug = "".join(ch if ch.isalnum() else "_" for ch in ref.rstrip("/").split("youtube.com/", 1)[-1])
        cache_path = cfg.cache_dir / "subregion" / subregion.slug / "youtube_channels" / (chan_slug + ".json")

        if not cfg.fresh and cache_path.exists():
            triple = json.loads(cache_path.read_text(encoding="utf-8"))
        else:
            cid = country_field = title = ""
            try:
                async with session.get(
                    about_url(ref), headers={"User-Agent": _BROWSER_UA},
                    timeout=aiohttp.ClientTimeout(total=cfg.timeout),
                ) as resp:
                    if resp.status == 200:
                        html = await resp.text()
                        m_id = _CHANNEL_ID.search(html)
                        m_co = _COUNTRY.search(html)
                        m_ti = _OG_TITLE.search(html)
                        cid = m_id.group(1) if m_id else ""
                        country_field = m_co.group(1) if m_co else ""
                        title = m_ti.group(1) if m_ti else ""
            except (aiohttp.ClientError, TimeoutError):
                pass
            triple = {"channel_id": cid, "country": country_field, "title": title}
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(triple, ensure_ascii=False), encoding="utf-8")

        cid = triple.get("channel_id", "")
        title = triple.get("title", "")
        if not cid or cid in seen_ids:
            continue

        # City filter: title or country match
        title_lower = title.lower()
        country_field = triple.get("country", "").strip().lower()
        if city_lower not in title_lower and country_field != country_name.lower():
            continue

        seen_ids.add(cid)
        url = channel_rss_url(cid)
        norm = normalize_url(url)
        if norm in existing_urls:
            candidates.append(Candidate(
                url=url, category="YouTube", title=title, genre="",
                national=True, national_reason="youtube_city_match", is_new=False,
            ))
            continue
        candidates.append(Candidate(
            url=url, category="YouTube", title=title, genre="",
            national=True, national_reason="youtube_city_match",
        ))

    return candidates


async def discover_subregion(
    subregion: SubRegion,
    country_name: str,
    native_name: str,
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Discover feeds for a single sub-region using all 3 vias in parallel.

    Args:
        subregion: SubRegion metadata.
        country_name: Parent country's English name (e.g. "Nigeria").
        native_name: Parent country's native name (e.g. "Brasil").
        existing_urls: Set of normalized URLs already in any OPML (for dedup).
        session: Shared aiohttp session.
        cfg: Discovery configuration.

    Returns:
        List of Candidate objects from all 3 vias combined.
    """
    text_cands, podcast_cands, youtube_cands = await asyncio.gather(
        _discover_text(subregion, country_name, native_name, existing_urls, session, cfg),
        _discover_podcasts(subregion, country_name, existing_urls, session, cfg),
        _discover_youtube(subregion, country_name, existing_urls, session, cfg),
    )
    # Deduplicate by normalized URL across vias
    seen: set[str] = set()
    result: list[Candidate] = []
    for c in text_cands + podcast_cands + youtube_cands:
        norm = normalize_url(c.url)
        if norm in seen:
            continue
        seen.add(norm)
        result.append(c)
    return result
