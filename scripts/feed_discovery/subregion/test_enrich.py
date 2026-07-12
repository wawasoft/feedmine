from scripts.feed_discovery.subregion.enrich_countries import humanize_slug, POPULATION


def test_humanize_slug_simple():
    assert humanize_slug("nigeria-lagos") == "Lagos"


def test_humanize_slug_multi_word():
    assert humanize_slug("nigeria-akwa-ibom") == "Akwa Ibom"


def test_humanize_slug_romanian():
    assert humanize_slug("romania-cluj-napoca") == "Cluj-Napoca"


def test_humanize_slug_with_dots():
    assert humanize_slug("usa-district-of-columbia") == "District Of Columbia"


def test_population_has_top_countries():
    assert POPULATION["india"] > 1_000_000_000
    assert POPULATION["china"] > 1_000_000_000
    assert POPULATION["nigeria"] > 200_000_000
    assert POPULATION["brazil"] > 200_000_000


def test_population_has_all_101():
    # All countries in the OPML must have population entries
    assert len(POPULATION) >= 101


from scripts.feed_discovery.subregion.discover_subregion import build_subregion_queries


def test_build_subregion_queries():
    queries = build_subregion_queries("Lagos", "Nigeria", "Nigeria")
    assert any("Lagos" in q for q in queries)
    assert any("Nigeria" in q for q in queries)
    assert any("news" in q.lower() for q in queries)


def test_build_subregion_queries_with_native_name():
    queries = build_subregion_queries("São Paulo", "Brazil", "Brasil")
    assert any("São Paulo" in q for q in queries)
    assert any("Brasil" in q for q in queries)
