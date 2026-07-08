from __future__ import annotations

import re

from ..models import Candidate, Country

_CHANNEL_PATH = re.compile(
    r"youtube\.com/(channel/UC[0-9A-Za-z_-]{22}|@[A-Za-z0-9._-]+|c/[^/?#\s\"']+|user/[^/?#\s\"']+)"
)
_CHANNEL_ID = re.compile(r'"channelId":"(UC[0-9A-Za-z_-]{22})"')
_COUNTRY = re.compile(r'"country":"([^"]{1,60})"')
_OG_TITLE = re.compile(r'<meta property="og:title" content="([^"]*)"')


def youtube_seed_queries(country: Country) -> list[str]:
    qs = [f"site:youtube.com {country.name}"]
    if country.native_name and country.native_name != country.name:
        qs.append(f"site:youtube.com {country.native_name}")
    for city in country.cities[:2]:
        qs.append(f"site:youtube.com {city}")
    seen: set[str] = set()
    out: list[str] = []
    for q in qs:
        if q not in seen:
            seen.add(q)
            out.append(q)
    return out


def extract_channel_refs(urls: list[str]) -> list[str]:
    refs: list[str] = []
    seen: set[str] = set()
    for u in urls:
        m = _CHANNEL_PATH.search(u)
        if not m:
            continue
        ref = "https://www.youtube.com/" + m.group(1)
        if ref not in seen:
            seen.add(ref)
            refs.append(ref)
    return refs


def about_url(ref: str) -> str:
    return ref.rstrip("/") + "/about"


def parse_channel_about(html: str) -> tuple[str, str, str]:
    cid = _CHANNEL_ID.search(html)
    country = _COUNTRY.search(html)
    title = _OG_TITLE.search(html)
    return (
        cid.group(1) if cid else "",
        country.group(1) if country else "",
        title.group(1) if title else "",
    )


def channel_rss_url(channel_id: str) -> str:
    return f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"


def channel_candidate_from_html(html: str, country_name: str) -> Candidate | None:
    cid, country, title = parse_channel_about(html)
    if not cid or not country:
        return None
    if country.strip().lower() != country_name.strip().lower():
        return None
    return Candidate(
        url=channel_rss_url(cid), category="YouTube", title=title, genre="",
        national=True, national_reason="youtube about country==name",
    )
