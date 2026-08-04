"""Shared editorial collection classification rules."""

from __future__ import annotations

import re
import unicodedata


COUNTRY_COLLECTION_SLUGS = frozenset({
    "countries",
    "90-countries",
    "staging",
    "archived-countries",
})
PRODUCTION_COUNTRY_COLLECTION = "90_countries"


def collection_slug(raw: object) -> str:
    folded = unicodedata.normalize("NFKD", str(raw or ""))
    ascii_value = folded.encode("ascii", "ignore").decode("ascii").casefold()
    return re.sub(r"[^a-z0-9]+", "-", ascii_value).strip("-")


def is_country_collection(raw: object) -> bool:
    return collection_slug(raw) in COUNTRY_COLLECTION_SLUGS


def production_collection(raw: object) -> str:
    """Map every recognized country collection alias to its production root."""
    return PRODUCTION_COUNTRY_COLLECTION if is_country_collection(raw) else str(raw)
