from __future__ import annotations

from urllib.parse import urlencode

from ..models import Candidate, Country

ITUNES_SEARCH = "https://itunes.apple.com/search"


def podcast_seed_terms(country: Country) -> list[str]:
    terms = [country.name]
    if country.native_name and country.native_name != country.name:
        terms.append(country.native_name)
    terms.extend(country.cities)
    seen: set[str] = set()
    out: list[str] = []
    for t in terms:
        if t and t not in seen:
            seen.add(t)
            out.append(t)
    return out


def itunes_search_url(term: str, iso2: str, limit: int = 50) -> str:
    q = urlencode({"term": term, "country": iso2, "entity": "podcast", "limit": limit})
    return f"{ITUNES_SEARCH}?{q}"


def podcasts_from_itunes_json(payload: dict, iso3: str) -> list[Candidate]:
    out: list[Candidate] = []
    seen: set[str] = set()
    for r in payload.get("results", []):
        if (r.get("country") or "").upper() != iso3.upper():
            continue
        feed = r.get("feedUrl")
        if not feed or feed in seen:
            continue
        seen.add(feed)
        out.append(Candidate(
            url=feed, category="Podcasts",
            title=r.get("collectionName", ""),
            genre=r.get("primaryGenreName", ""),
            national=True, national_reason="itunes country==iso3",
        ))
    return out
