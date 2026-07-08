from __future__ import annotations

from scripts.feed_discovery.models import Country
from scripts.feed_discovery.sources import podcasts

BO = Country("bolivia", "Bolivia", "bo", True, "es", "bo-es", [], "Bolivia",
             ["La Paz", "Santa Cruz"], iso2="bo", iso3="BOL")

PAYLOAD = {"results": [
    {"collectionName": "Historia Bolivia", "feedUrl": "https://feeds.x/h",
     "country": "BOL", "primaryGenreName": "Historia"},
    {"collectionName": "Dup", "feedUrl": "https://feeds.x/h",
     "country": "BOL", "primaryGenreName": "Historia"},          # dup feedUrl
    {"collectionName": "US Pod", "feedUrl": "https://feeds.x/us",
     "country": "USA", "primaryGenreName": "News"},              # wrong country
    {"collectionName": "No Feed", "country": "BOL"},             # no feedUrl
]}


def test_seed_terms_are_name_native_and_cities_deduped():
    assert podcasts.podcast_seed_terms(BO) == ["Bolivia", "La Paz", "Santa Cruz"]


def test_itunes_url_has_storefront_entity_and_limit():
    url = podcasts.itunes_search_url("Bolivia", "bo", 50)
    assert url.startswith("https://itunes.apple.com/search?")
    assert "term=Bolivia" in url and "country=bo" in url
    assert "entity=podcast" in url and "limit=50" in url


def test_strict_country_filter_and_dedup():
    cands = podcasts.podcasts_from_itunes_json(PAYLOAD, "BOL")
    assert [c.url for c in cands] == ["https://feeds.x/h"]
    c = cands[0]
    assert c.category == "Podcasts"
    assert c.title == "Historia Bolivia"
    assert c.genre == "Historia"
    assert c.national is True
