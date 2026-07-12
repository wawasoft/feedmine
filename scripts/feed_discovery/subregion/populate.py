# scripts/feed_discovery/subregion/populate.py

from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path

import aiohttp

from ..models import SubRegion
from ..opml import normalize_url
from ..pipeline import Config
from .discover_subregion import discover_subregion
from .enrich_countries import POPULATION, enrich
from .opml_writer import read_existing_feeds, write_subregion_opml

PROGRESS_FILE = Path(__file__).parent / "progress.json"


def load_progress() -> dict:
    """Load progress tracking, returning empty dict if no progress file exists."""
    if PROGRESS_FILE.exists():
        return json.loads(PROGRESS_FILE.read_text(encoding="utf-8"))
    return {}


def save_progress(progress: dict) -> None:
    """Atomically write progress to disk."""
    tmp = PROGRESS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(progress, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(PROGRESS_FILE)


async def populate_country(
    country_slug: str,
    enriched: dict,
    cfg: Config,
    session: aiohttp.ClientSession,
) -> dict:
    """Populate all sub-region OPMLs for one country.

    Args:
        country_slug: e.g. "nigeria"
        enriched: Full enriched countries dict.
        cfg: Discovery config.
        session: Shared aiohttp session.

    Returns:
        Summary dict: {country_slug, total_subregions, populated, failed, total_feeds}
    """
    country_data = enriched.get(country_slug)
    if not country_data:
        return {"country": country_slug, "error": "not in enriched data"}

    sub_data = country_data.get("subregions", [])
    if not sub_data:
        return {"country": country_slug, "total_subregions": 0, "populated": 0, "failed": 0, "total_feeds": 0}

    country_name = country_data["name"]
    native_name = country_data.get("native_name", country_name)

    # Collect all existing URLs across all sub-regions to feed dedup
    all_existing: set[str] = set()
    for sd in sub_data:
        opml_path = Path(sd["opml_path"])
        if opml_path.exists():
            all_existing |= read_existing_feeds(opml_path)

    sem = asyncio.Semaphore(cfg.concurrency)

    async def _process_one(sd: dict) -> tuple[str, int]:
        sub = SubRegion(
            slug=sd["slug"], name=sd["name"],
            parent_country=sd["parent_country"],
            iso2=sd["iso2"], iso3=sd["iso3"],
            ddg_region=sd["ddg_region"],
            opml_path=sd["opml_path"],
        )
        async with sem:
            try:
                cands = await discover_subregion(
                    sub, country_name, native_name, all_existing, session, cfg
                )
            except Exception:
                return (sd["slug"], -1)

        opml_path = Path(sd["opml_path"])
        if cands:
            written = write_subregion_opml(opml_path, cands)
            return (sd["slug"], written)
        return (sd["slug"], 0)

    results = await asyncio.gather(*(_process_one(sd) for sd in sub_data))

    summary = {
        "country": country_slug,
        "total_subregions": len(sub_data),
        "populated": 0,
        "failed": 0,
        "total_feeds": 0,
    }
    for slug, count in results:
        if count < 0:
            summary["failed"] += 1
        elif count > 0:
            summary["populated"] += 1
        summary["total_feeds"] += max(0, count)

    return summary


async def populate_all(
    enriched_path: Path,
    opml_base: Path,
    cfg: Config | None = None,
) -> None:
    """Run the full sub-region population pipeline for all countries.

    Processes countries in descending population order. Progress is saved
    after each country to `progress.json` so the pipeline can be resumed.

    Args:
        enriched_path: Path to countries_enriched.json.
        opml_base: Path to feedmine/Resources/Feeds/countries/.
        cfg: Optional Config override.
    """
    if cfg is None:
        cfg = Config()

    enriched = json.loads(Path(enriched_path).read_text(encoding="utf-8"))
    progress = load_progress()

    # Sort countries by population descending
    sorted_countries = sorted(
        enriched.keys(),
        key=lambda s: enriched[s].get("population", 0),
        reverse=True,
    )

    connector = aiohttp.TCPConnector(limit=cfg.concurrency)
    async with aiohttp.ClientSession(connector=connector) as session:
        for country_slug in sorted_countries:
            # Skip if already done
            if country_slug in progress and all(
                v in ("done", "failed") for v in progress[country_slug].values()
            ):
                print(f"[SKIP] {country_slug} — already complete")
                continue

            print(f"\n{'='*60}")
            print(f"[{country_slug}] Starting {enriched[country_slug].get('name', country_slug)} "
                  f"(pop: {enriched[country_slug].get('population', 0):,})")
            print(f"{'='*60}")

            t0 = time.monotonic()
            summary = await populate_country(country_slug, enriched, cfg, session)
            elapsed = time.monotonic() - t0

            # Update progress
            country_progress = {}
            for sd in enriched[country_slug].get("subregions", []):
                country_progress[sd["slug"]] = "done"
            progress[country_slug] = country_progress
            save_progress(progress)

            print(f"[{country_slug}] Done in {elapsed:.0f}s — "
                  f"{summary['populated']}/{summary['total_subregions']} populated, "
                  f"{summary['total_feeds']} feeds, "
                  f"{summary['failed']} failed")


if __name__ == "__main__":
    import sys

    REPO_ROOT = Path(__file__).resolve().parents[3]
    OPML_BASE = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "countries"
    COUNTRIES_JSON = Path(__file__).resolve().parents[1] / "data" / "countries.json"
    ENRICHED_PATH = Path(__file__).resolve().parents[1] / "data" / "countries_enriched.json"

    if not ENRICHED_PATH.exists():
        print("Generating countries_enriched.json ...")
        enrich(OPML_BASE, COUNTRIES_JSON, ENRICHED_PATH)
        print(f"  -> wrote {ENRICHED_PATH}")

    fresh = "--fresh" in sys.argv
    commit = "--commit" in sys.argv
    cfg = Config(fresh=fresh, concurrency=50)

    asyncio.run(populate_all(ENRICHED_PATH, OPML_BASE, cfg))

    if commit:
        import subprocess
        subprocess.run(["git", "-C", str(REPO_ROOT), "add", str(OPML_BASE)])
        subprocess.run(["git", "-C", str(REPO_ROOT), "commit", "-m",
                        f"data: sub-region OPML population run"])
