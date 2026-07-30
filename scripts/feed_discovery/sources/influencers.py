# scripts/feed_discovery/sources/influencers.py

from __future__ import annotations

import json
import time
from pathlib import Path

from ..models import Candidate
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class InfluencersSource:
    """Curated influencer data — YouTube creators, podcasters, and bloggers.

    Reads pre-curated data from data/influencers_curated.json produced by
    scripts/feed_discovery/export_influencers.py.

    Data is hand-curated per country and organized into three tiers:
      - Global: worldwide influencers (shared across all countries)
      - Language: Spanish, Portuguese, French, Arabic regional lists
      - Local: country-specific personalities (10+ per country)

    No runtime API calls needed — purely static data lookup.
    """

    name = "influencers"
    DATA_PATH = (
        Path(__file__).resolve().parents[1]
        / "data"
        / "influencers_curated.json"
    )

    def __init__(self):
        self._entries: list[dict] = []
        self._by_country: dict[str, list[dict]] = {}
        self.enabled = self.DATA_PATH.exists()
        if self.enabled:
            self._load_data()

    def _load_data(self):
        """Load curated influencer data from JSON."""
        try:
            data = json.loads(self.DATA_PATH.read_text(encoding="utf-8"))
            self._entries = data.get("entries", [])
        except Exception:
            self._entries = []

        self._by_country = {}
        for entry in self._entries:
            for slug in entry.get("country_slugs", []):
                if slug not in self._by_country:
                    self._by_country[slug] = []
                self._by_country[slug].append(entry)

    def _slug_to_pipeline(self, slug: str) -> str:
        """Convert feedmine slug (underscores) to profile slug (hyphens)."""
        return slug.replace("_", "-")

    def _profile_to_slug(self, profile: CountryProfile) -> str:
        """Extract country slug from a CountryProfile."""
        return (profile.country or "").lower()

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> list[Candidate]:
        """Return curated influencer channels for this country.

        The query parameter is ignored — entries are matched by country slug
        from the profile. Returns channels sorted by quality score (descending).
        """
        if not self.enabled:
            return []

        country_slug = self._profile_to_slug(profile)
        candidates: list[Candidate] = []
        seen: set[str] = set()

        # Try both underscore and hyphen forms
        entries = (
            self._by_country.get(country_slug, [])
            or self._by_country.get(self._slug_to_pipeline(country_slug), [])
            or self._by_country.get(country_slug.replace("-", "_"), [])
        )

        # Sort by quality (descending)
        entries = sorted(entries, key=lambda e: e.get("quality", 0), reverse=True)

        for entry in entries:
            feed_url = entry.get("feed_url", "")
            if not feed_url or feed_url in seen:
                continue
            seen.add(feed_url)

            candidates.append(Candidate(
                url=feed_url,
                category=entry.get("category", "Influencers"),
                title=entry.get("title", ""),
                genre=entry.get("genre", ""),
                national=True,
                national_reason=f"curated:{entry.get('source','influencers')}",
            ))

        return candidates[:config.max_results]

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> ProbeResult:
        """Check if this source has data for the profile's country."""
        if not self.enabled:
            return ProbeResult(
                source_name="influencers",
                success=False,
                result_count=0,
                latency_ms=0,
                error="disabled: data file not found",
            )

        t0 = time.monotonic()
        try:
            results = await self.search("", profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="influencers",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="influencers",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )
