# National Feed Discovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Python pipeline that discovers candidate *national* RSS feeds per country/category via DuckDuckGo, filters them with a national heuristic, verifies they are live feeds, and emits reviewable per-country OPML files without touching the app's real feeds.

**Architecture:** A package under `scripts/feed_discovery/` (invoked as `python -m scripts.feed_discovery`, run from repo root). Five stages per country — search → autodiscover → national-filter → liveness-verify → emit. Pure/deterministic units (heuristic, OPML emit, HTML/feed parsing, query builder, report) are TDD'd; network stages (DDG search, HTTP discovery/verify, orchestration) are validated by the `iceland` pilot. Reuses the existing top-level `feedmine_verify` package for OPML parsing (`scanner`) and shared constants.

**Tech Stack:** Python 3.10+, `aiohttp` (already a dep), `ddgs` (DuckDuckGo, no key), `pytest` (new dev dep), stdlib `xml.etree.ElementTree` / `re` / `urllib`.

## Global Constraints

- Python floor: `>=3.10` (matches `pyproject.toml`). Use `from __future__ import annotations` in every module (repo convention in `feedmine_verify`).
- Package is invoked as `python -m scripts.feed_discovery` from the **repo root**; internal imports are **relative** (`from .heuristic import ...`); tests import as `from scripts.feed_discovery.X import Y`.
- Never write to `feedmine/Resources/Feeds/**`. Output goes only to `scripts/feed_discovery/candidates/`.
- Only propose feeds **not already present** in the target country's OPML files (dedup on normalized URL).
- National scope only for now (the 101 `<country>.opml`). Regional support is a future flag, stubbed but not enabled.
- Emitted OPML must match the project format exactly: `<outline text="Category">` groups containing `<outline title="…" xmlUrl="…" type="rss" />`, 2-space indentation, `<?xml version="1.0" encoding="UTF-8"?>` header.
- The 26 categories, fixed order: `News, Sports, Technology, Science, Culture, Movies, Music, Food, Gaming, Travel, Blogs, Design, Environment, DIY, History, Architecture, Programming, Business, Podcasts, Photography, Health, Education, Politics, Humor, Apple, YouTube`.
- HTTP User-Agent: `FeedmineDiscovery/1.0`.
- Reuse `feedmine_verify` (`scanner.scan_directory`, `constants.FEED_ROOT_TAGS/MAX_BODY_BYTES`) rather than reimplementing.

---

### Task 1: Package scaffold, dependencies, pytest config

**Files:**
- Create: `scripts/__init__.py` (empty)
- Create: `scripts/feed_discovery/__init__.py` (empty)
- Create: `scripts/feed_discovery/tests/__init__.py` (empty)
- Create: `scripts/feed_discovery/tests/test_smoke.py`
- Modify: `pyproject.toml` (add deps + pytest config)
- Modify: `.gitignore` (ignore cache/ and candidates/)

**Interfaces:**
- Consumes: nothing.
- Produces: importable package `scripts.feed_discovery`; `pytest` runnable from repo root with `pythonpath = ["."]`.

- [ ] **Step 1: Create the empty package files**

Create `scripts/__init__.py`, `scripts/feed_discovery/__init__.py`, `scripts/feed_discovery/tests/__init__.py` — all empty files.

- [ ] **Step 2: Write the smoke test**

`scripts/feed_discovery/tests/test_smoke.py`:
```python
from __future__ import annotations


def test_package_imports():
    import scripts.feed_discovery as fd
    assert fd is not None


def test_feedmine_verify_reachable():
    # The pipeline reuses feedmine_verify; it must import from repo root.
    from feedmine_verify import scanner
    assert hasattr(scanner, "scan_directory")
```

- [ ] **Step 3: Add dependencies and pytest config to pyproject.toml**

Edit `pyproject.toml`. Change the `dependencies` line and append two new sections:
```toml
dependencies = ["aiohttp>=3.9", "ddgs>=6.0"]

[project.optional-dependencies]
dev = ["pytest>=8"]

[tool.pytest.ini_options]
pythonpath = ["."]
testpaths = ["scripts/feed_discovery/tests"]
```

- [ ] **Step 4: Ignore generated dirs**

Append to `.gitignore`:
```
# feed_discovery generated
scripts/feed_discovery/cache/
scripts/feed_discovery/candidates/
```

- [ ] **Step 5: Install dev deps and run the smoke test**

Run: `python -m pip install -e '.[dev]' && python -m pytest scripts/feed_discovery/tests/test_smoke.py -v`
Expected: 2 passed.

- [ ] **Step 6: Commit**

```bash
git add scripts/__init__.py scripts/feed_discovery/__init__.py scripts/feed_discovery/tests/__init__.py scripts/feed_discovery/tests/test_smoke.py pyproject.toml .gitignore
git commit -m "feat(feed-discovery): package scaffold, deps, pytest config"
```

---

### Task 2: Registry — models and data loaders

**Files:**
- Create: `scripts/feed_discovery/models.py`
- Create: `scripts/feed_discovery/registry.py`
- Create: `scripts/feed_discovery/tests/test_registry.py`
- Create (fixture): `scripts/feed_discovery/tests/fixtures/countries.sample.json`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `models.Country(slug: str, name: str, cctld: str, use_cctld: bool, lang: str, ddg_region: str, allowlist: list[str])`
  - `models.Candidate(url: str, category: str, title: str = "", source_page: str = "", national: bool = False, national_reason: str = "", is_live: bool = False, status_code: int = 0, is_new: bool = True)`
  - `registry.CATEGORIES: list[str]` (26, fixed order)
  - `registry.load_countries(path: Path) -> dict[str, Country]`
  - `registry.load_keywords(path: Path) -> dict[str, dict[str, list[str]]]`
  - `registry.keywords_for(keywords: dict, category: str, lang: str) -> list[str]` (falls back to `"en"`)
  - `registry.load_blocklist(path: Path) -> set[str]`

- [ ] **Step 1: Write the failing test**

`scripts/feed_discovery/tests/test_registry.py`:
```python
from __future__ import annotations

from pathlib import Path

from scripts.feed_discovery import registry
from scripts.feed_discovery.models import Country

FIX = Path(__file__).parent / "fixtures"


def test_categories_are_26_in_fixed_order():
    assert len(registry.CATEGORIES) == 26
    assert registry.CATEGORIES[0] == "News"
    assert registry.CATEGORIES[-1] == "YouTube"


def test_load_countries_parses_entries():
    countries = registry.load_countries(FIX / "countries.sample.json")
    br = countries["brazil"]
    assert isinstance(br, Country)
    assert br.cctld == "br"
    assert br.lang == "pt"
    assert br.use_cctld is True
    assert br.ddg_region == "br-pt"


def test_keywords_for_falls_back_to_english():
    kw = {"News": {"en": ["news"], "pt": ["notícias"]}}
    assert registry.keywords_for(kw, "News", "pt") == ["notícias"]
    assert registry.keywords_for(kw, "News", "xx") == ["news"]  # unknown lang → en
    assert registry.keywords_for(kw, "Unknown", "pt") == []      # unknown category → empty
```

- [ ] **Step 2: Create the fixture**

`scripts/feed_discovery/tests/fixtures/countries.sample.json`:
```json
{
  "brazil": {"name": "Brazil", "cctld": "br", "use_cctld": true, "lang": "pt", "ddg_region": "br-pt", "allowlist": ["globo.com"]},
  "usa": {"name": "USA", "cctld": "us", "use_cctld": false, "lang": "en", "ddg_region": "us-en", "allowlist": ["nytimes.com"]}
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `python -m pytest scripts/feed_discovery/tests/test_registry.py -v`
Expected: FAIL (ModuleNotFoundError: scripts.feed_discovery.registry / models).

- [ ] **Step 4: Write models.py**

`scripts/feed_discovery/models.py`:
```python
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Country:
    slug: str
    name: str
    cctld: str
    use_cctld: bool
    lang: str
    ddg_region: str
    allowlist: list[str] = field(default_factory=list)


@dataclass
class Candidate:
    url: str
    category: str
    title: str = ""
    source_page: str = ""
    national: bool = False
    national_reason: str = ""
    is_live: bool = False
    status_code: int = 0
    is_new: bool = True
```

- [ ] **Step 5: Write registry.py**

`scripts/feed_discovery/registry.py`:
```python
from __future__ import annotations

import json
from pathlib import Path

from .models import Country

CATEGORIES: list[str] = [
    "News", "Sports", "Technology", "Science", "Culture", "Movies", "Music",
    "Food", "Gaming", "Travel", "Blogs", "Design", "Environment", "DIY",
    "History", "Architecture", "Programming", "Business", "Podcasts",
    "Photography", "Health", "Education", "Politics", "Humor", "Apple", "YouTube",
]


def load_countries(path: Path) -> dict[str, Country]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    out: dict[str, Country] = {}
    for slug, meta in data.items():
        out[slug] = Country(
            slug=slug,
            name=meta["name"],
            cctld=meta["cctld"],
            use_cctld=bool(meta["use_cctld"]),
            lang=meta["lang"],
            ddg_region=meta.get("ddg_region", f'{meta["cctld"]}-{meta["lang"]}'),
            allowlist=list(meta.get("allowlist", [])),
        )
    return out


def load_keywords(path: Path) -> dict[str, dict[str, list[str]]]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def keywords_for(keywords: dict, category: str, lang: str) -> list[str]:
    packs = keywords.get(category)
    if not packs:
        return []
    return list(packs.get(lang) or packs.get("en") or [])


def load_blocklist(path: Path) -> set[str]:
    out: set[str] = set()
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip().lower()
        if line and not line.startswith("#"):
            out.add(line)
    return out
```

- [ ] **Step 6: Run test to verify it passes**

Run: `python -m pytest scripts/feed_discovery/tests/test_registry.py -v`
Expected: 3 passed.

- [ ] **Step 7: Commit**

```bash
git add scripts/feed_discovery/models.py scripts/feed_discovery/registry.py scripts/feed_discovery/tests/test_registry.py scripts/feed_discovery/tests/fixtures/countries.sample.json
git commit -m "feat(feed-discovery): registry models and data loaders"
```

---

### Task 3: Generate the config data files (101 countries, keyword packs, blocklist)

**Files:**
- Create: `scripts/feed_discovery/data/country_meta.py` (embedded seed table)
- Create: `scripts/feed_discovery/data/build_countries.py` (one-shot generator)
- Create: `scripts/feed_discovery/data/countries.json` (generated output, committed)
- Create: `scripts/feed_discovery/data/category_keywords.json`
- Create: `scripts/feed_discovery/data/blocklist.txt`
- Create: `scripts/feed_discovery/tests/test_data_coverage.py`

**Interfaces:**
- Consumes: `registry.CATEGORIES`, `registry.load_countries`, `registry.load_keywords`.
- Produces: `data/countries.json` covering every folder under `feedmine/Resources/Feeds/countries/`; `data/category_keywords.json` with an `en` pack for all 26 categories; `data/blocklist.txt`.

- [ ] **Step 1: Write the embedded seed table**

`scripts/feed_discovery/data/country_meta.py` — `(cctld, lang, use_cctld)` per slug. Names are derived from the slug; `usa` is the only `use_cctld=False` seed (refine others by hand later).
```python
from __future__ import annotations

# slug -> (cctld, lang, use_cctld). ddg_region derives as f"{cctld}-{lang}".
# Auto-generated defaults — refine ccTLD/lang/allowlist by hand as needed.
COUNTRY_META: dict[str, tuple[str, str, bool]] = {
    "algeria": ("dz", "ar", True), "angola": ("ao", "pt", True),
    "argentina": ("ar", "es", True), "armenia": ("am", "hy", True),
    "australia": ("au", "en", True), "austria": ("at", "de", True),
    "azerbaijan": ("az", "az", True), "bangladesh": ("bd", "bn", True),
    "belarus": ("by", "be", True), "belgium": ("be", "nl", True),
    "bolivia": ("bo", "es", True), "brazil": ("br", "pt", True),
    "bulgaria": ("bg", "bg", True), "cambodia": ("kh", "km", True),
    "canada": ("ca", "en", True), "chile": ("cl", "es", True),
    "china": ("cn", "zh", True), "colombia": ("co", "es", True),
    "costa-rica": ("cr", "es", True), "croatia": ("hr", "hr", True),
    "cuba": ("cu", "es", True), "cyprus": ("cy", "el", True),
    "czech-republic": ("cz", "cs", True), "denmark": ("dk", "da", True),
    "dominican-republic": ("do", "es", True), "ecuador": ("ec", "es", True),
    "egypt": ("eg", "ar", True), "el-salvador": ("sv", "es", True),
    "estonia": ("ee", "et", True), "ethiopia": ("et", "am", True),
    "finland": ("fi", "fi", True), "france": ("fr", "fr", True),
    "georgia": ("ge", "ka", True), "germany": ("de", "de", True),
    "ghana": ("gh", "en", True), "greece": ("gr", "el", True),
    "guatemala": ("gt", "es", True), "haiti": ("ht", "fr", True),
    "honduras": ("hn", "es", True), "hungary": ("hu", "hu", True),
    "iceland": ("is", "is", True), "india": ("in", "en", True),
    "indonesia": ("id", "id", True), "iran": ("ir", "fa", True),
    "iraq": ("iq", "ar", True), "ireland": ("ie", "en", True),
    "israel": ("il", "he", True), "italy": ("it", "it", True),
    "ivory-coast": ("ci", "fr", True), "jamaica": ("jm", "en", True),
    "japan": ("jp", "ja", True), "kazakhstan": ("kz", "kk", True),
    "kenya": ("ke", "en", True), "latvia": ("lv", "lv", True),
    "lithuania": ("lt", "lt", True), "luxembourg": ("lu", "fr", True),
    "malaysia": ("my", "ms", True), "malta": ("mt", "en", True),
    "mexico": ("mx", "es", True), "morocco": ("ma", "ar", True),
    "myanmar": ("mm", "my", True), "nepal": ("np", "ne", True),
    "netherlands": ("nl", "nl", True), "new-zealand": ("nz", "en", True),
    "nicaragua": ("ni", "es", True), "nigeria": ("ng", "en", True),
    "norway": ("no", "no", True), "pakistan": ("pk", "ur", True),
    "panama": ("pa", "es", True), "paraguay": ("py", "es", True),
    "peru": ("pe", "es", True), "philippines": ("ph", "en", True),
    "poland": ("pl", "pl", True), "portugal": ("pt", "pt", True),
    "puerto-rico": ("pr", "es", True), "qatar": ("qa", "ar", True),
    "romania": ("ro", "ro", True), "russia": ("ru", "ru", True),
    "saudi-arabia": ("sa", "ar", True), "serbia": ("rs", "sr", True),
    "singapore": ("sg", "en", True), "slovakia": ("sk", "sk", True),
    "slovenia": ("si", "sl", True), "south-africa": ("za", "en", True),
    "south-korea": ("kr", "ko", True), "spain": ("es", "es", True),
    "sri-lanka": ("lk", "si", True), "sudan": ("sd", "ar", True),
    "sweden": ("se", "sv", True), "switzerland": ("ch", "de", True),
    "taiwan": ("tw", "zh", True), "thailand": ("th", "th", True),
    "tunisia": ("tn", "ar", True), "turkey": ("tr", "tr", True),
    "uae": ("ae", "ar", True), "ukraine": ("ua", "uk", True),
    "united-kingdom": ("uk", "en", True), "uruguay": ("uy", "es", True),
    "usa": ("us", "en", False), "venezuela": ("ve", "es", True),
    "vietnam": ("vn", "vi", True),
}

# Slugs whose title-case needs a manual override.
NAME_OVERRIDES: dict[str, str] = {
    "usa": "USA", "uae": "UAE", "uk": "UK",
    "united-kingdom": "United Kingdom", "el-salvador": "El Salvador",
    "costa-rica": "Costa Rica", "czech-republic": "Czech Republic",
    "dominican-republic": "Dominican Republic", "new-zealand": "New Zealand",
    "south-africa": "South Africa", "south-korea": "South Korea",
    "sri-lanka": "Sri Lanka", "puerto-rico": "Puerto Rico",
    "ivory-coast": "Ivory Coast", "saudi-arabia": "Saudi Arabia",
}


def display_name(slug: str) -> str:
    if slug in NAME_OVERRIDES:
        return NAME_OVERRIDES[slug]
    return " ".join(w.capitalize() for w in slug.split("-"))
```

- [ ] **Step 2: Write the generator**

`scripts/feed_discovery/data/build_countries.py`:
```python
from __future__ import annotations

import json
from pathlib import Path

from .country_meta import COUNTRY_META, display_name

REPO_ROOT = Path(__file__).resolve().parents[3]
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "countries"
OUT = Path(__file__).parent / "countries.json"


def build() -> dict:
    folders = sorted(p.name for p in COUNTRIES_DIR.iterdir() if p.is_dir())
    result: dict[str, dict] = {}
    missing: list[str] = []
    for slug in folders:
        meta = COUNTRY_META.get(slug)
        if meta is None:
            missing.append(slug)
            continue
        cctld, lang, use_cctld = meta
        result[slug] = {
            "name": display_name(slug),
            "cctld": cctld,
            "use_cctld": use_cctld,
            "lang": lang,
            "ddg_region": f"{cctld}-{lang}",
            "allowlist": [],
        }
    if missing:
        raise SystemExit(f"COUNTRY_META missing entries for: {missing}")
    return result


if __name__ == "__main__":
    OUT.write_text(json.dumps(build(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {OUT} with {len(build())} countries")
```

- [ ] **Step 3: Run the generator**

Run: `python -m scripts.feed_discovery.data.build_countries`
Expected: `Wrote .../countries.json with 101 countries` (no "missing entries" error).

- [ ] **Step 4: Write category_keywords.json**

`scripts/feed_discovery/data/category_keywords.json` — `en` is mandatory for all 26 (fallback); `pt`, `es`, `fr`, `de` provided for the largest language groups. Add more packs later.
```json
{
  "News": {"en": ["news"], "pt": ["notícias"], "es": ["noticias"], "fr": ["actualités"], "de": ["nachrichten"]},
  "Sports": {"en": ["sports"], "pt": ["esportes"], "es": ["deportes"], "fr": ["sport"], "de": ["sport"]},
  "Technology": {"en": ["technology"], "pt": ["tecnologia"], "es": ["tecnología"], "fr": ["technologie"], "de": ["technik"]},
  "Science": {"en": ["science"], "pt": ["ciência"], "es": ["ciencia"], "fr": ["science"], "de": ["wissenschaft"]},
  "Culture": {"en": ["culture"], "pt": ["cultura"], "es": ["cultura"], "fr": ["culture"], "de": ["kultur"]},
  "Movies": {"en": ["movies cinema"], "pt": ["cinema"], "es": ["cine"], "fr": ["cinéma"], "de": ["kino filme"]},
  "Music": {"en": ["music"], "pt": ["música"], "es": ["música"], "fr": ["musique"], "de": ["musik"]},
  "Food": {"en": ["food recipes"], "pt": ["comida receitas"], "es": ["comida recetas"], "fr": ["cuisine recettes"], "de": ["essen rezepte"]},
  "Gaming": {"en": ["gaming games"], "pt": ["games jogos"], "es": ["videojuegos"], "fr": ["jeux vidéo"], "de": ["videospiele"]},
  "Travel": {"en": ["travel"], "pt": ["viagem"], "es": ["viajes"], "fr": ["voyage"], "de": ["reisen"]},
  "Blogs": {"en": ["blog"], "pt": ["blog"], "es": ["blog"], "fr": ["blog"], "de": ["blog"]},
  "Design": {"en": ["design"], "pt": ["design"], "es": ["diseño"], "fr": ["design"], "de": ["design"]},
  "Environment": {"en": ["environment"], "pt": ["meio ambiente"], "es": ["medio ambiente"], "fr": ["environnement"], "de": ["umwelt"]},
  "DIY": {"en": ["diy crafts"], "pt": ["artesanato faça você mesmo"], "es": ["manualidades"], "fr": ["bricolage"], "de": ["heimwerken basteln"]},
  "History": {"en": ["history"], "pt": ["história"], "es": ["historia"], "fr": ["histoire"], "de": ["geschichte"]},
  "Architecture": {"en": ["architecture"], "pt": ["arquitetura"], "es": ["arquitectura"], "fr": ["architecture"], "de": ["architektur"]},
  "Programming": {"en": ["programming developer"], "pt": ["programação desenvolvedor"], "es": ["programación"], "fr": ["programmation"], "de": ["programmierung"]},
  "Business": {"en": ["business economy"], "pt": ["negócios economia"], "es": ["negocios economía"], "fr": ["économie"], "de": ["wirtschaft"]},
  "Podcasts": {"en": ["podcast"], "pt": ["podcast"], "es": ["podcast"], "fr": ["podcast"], "de": ["podcast"]},
  "Photography": {"en": ["photography"], "pt": ["fotografia"], "es": ["fotografía"], "fr": ["photographie"], "de": ["fotografie"]},
  "Health": {"en": ["health"], "pt": ["saúde"], "es": ["salud"], "fr": ["santé"], "de": ["gesundheit"]},
  "Education": {"en": ["education"], "pt": ["educação"], "es": ["educación"], "fr": ["éducation"], "de": ["bildung"]},
  "Politics": {"en": ["politics"], "pt": ["política"], "es": ["política"], "fr": ["politique"], "de": ["politik"]},
  "Humor": {"en": ["humor comedy"], "pt": ["humor"], "es": ["humor"], "fr": ["humour"], "de": ["humor"]},
  "Apple": {"en": ["apple mac iphone"], "pt": ["apple mac iphone"], "es": ["apple mac iphone"], "fr": ["apple mac iphone"], "de": ["apple mac iphone"]},
  "YouTube": {"en": ["youtube channel"], "pt": ["canal youtube"], "es": ["canal youtube"], "fr": ["chaîne youtube"], "de": ["youtube kanal"]}
}
```

- [ ] **Step 5: Write blocklist.txt**

`scripts/feed_discovery/data/blocklist.txt`:
```
# Global international outlets — always rejected as non-national.
# A national edition on a country ccTLD still passes (ccTLD wins).
bbc.co.uk
bbc.com
cnn.com
nytimes.com
theguardian.com
reuters.com
apnews.com
aljazeera.com
dw.com
techcrunch.com
theverge.com
wired.com
engadget.com
arstechnica.com
dezeen.com
designboom.com
archdaily.com
smashingmagazine.com
rollingstone.com
billboard.com
pitchfork.com
variety.com
imdb.com
ign.com
kotaku.com
gamespot.com
eurogamer.net
reddit.com
medium.com
wikipedia.org
nationalgeographic.com
```

- [ ] **Step 6: Write the coverage test**

`scripts/feed_discovery/tests/test_data_coverage.py`:
```python
from __future__ import annotations

from pathlib import Path

from scripts.feed_discovery import registry

DATA = Path(__file__).resolve().parents[1] / "data"
COUNTRIES_DIR = Path(__file__).resolve().parents[4] / "feedmine" / "Resources" / "Feeds" / "countries"


def test_every_country_folder_has_metadata():
    countries = registry.load_countries(DATA / "countries.json")
    folders = {p.name for p in COUNTRIES_DIR.iterdir() if p.is_dir()}
    assert folders <= set(countries), f"missing: {folders - set(countries)}"


def test_every_country_has_two_letter_cctld_and_lang():
    countries = registry.load_countries(DATA / "countries.json")
    for slug, c in countries.items():
        assert len(c.cctld) >= 2, slug
        assert c.lang, slug
        assert c.ddg_region == f"{c.cctld}-{c.lang}", slug


def test_every_category_has_english_pack():
    kw = registry.load_keywords(DATA / "category_keywords.json")
    for cat in registry.CATEGORIES:
        assert kw.get(cat, {}).get("en"), f"no en keywords for {cat}"


def test_blocklist_loads_nonempty():
    assert len(registry.load_blocklist(DATA / "blocklist.txt")) > 5
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `python -m pytest scripts/feed_discovery/tests/test_data_coverage.py -v`
Expected: 4 passed.

- [ ] **Step 8: Commit**

```bash
git add scripts/feed_discovery/data scripts/feed_discovery/tests/test_data_coverage.py
git commit -m "feat(feed-discovery): country metadata, keyword packs, blocklist"
```

---

### Task 4: National heuristic (pure filter)

**Files:**
- Create: `scripts/feed_discovery/heuristic.py`
- Create: `scripts/feed_discovery/tests/test_heuristic.py`

**Interfaces:**
- Consumes: `models.Country`.
- Produces:
  - `heuristic.host_of(url: str) -> str` (lowercased, `www.` stripped)
  - `heuristic.is_national(url: str, country: Country, blocklist: set[str]) -> tuple[bool, str]` where reason ∈ `{"allowlist", "cctld", "blocked", "foreign"}`

- [ ] **Step 1: Write the failing test**

`scripts/feed_discovery/tests/test_heuristic.py`:
```python
from __future__ import annotations

from scripts.feed_discovery.heuristic import host_of, is_national
from scripts.feed_discovery.models import Country

BR = Country("brazil", "Brazil", "br", True, "pt", "br-pt", ["globo.com"])
US = Country("usa", "USA", "us", False, "en", "us-en", ["nytimes.com"])
BLOCK = {"bbc.com", "techcrunch.com"}


def test_host_of_strips_www_and_lowercases():
    assert host_of("https://WWW.G1.Globo.com/rss/") == "g1.globo.com"


def test_cctld_domain_is_national():
    assert is_national("https://www.uol.com.br/feed/", BR, BLOCK) == (True, "cctld")


def test_allowlisted_dotcom_is_national():
    assert is_national("https://globo.com/rss/", BR, BLOCK) == (True, "allowlist")


def test_blocklisted_is_rejected():
    assert is_national("https://techcrunch.com/feed/", BR, BLOCK) == (False, "blocked")


def test_foreign_is_rejected():
    assert is_national("https://example.fr/feed/", BR, BLOCK) == (False, "foreign")


def test_no_cctld_country_only_allowlist_passes():
    # USA: use_cctld=False, so only allowlist passes.
    assert is_national("https://nytimes.com/feed/", US, BLOCK) == (True, "allowlist")
    assert is_national("https://randomsite.com/feed/", US, BLOCK) == (False, "foreign")


def test_national_edition_on_intl_brand_passes_via_cctld():
    assert is_national("https://cnnbrasil.com.br/feed/", BR, BLOCK) == (True, "cctld")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest scripts/feed_discovery/tests/test_heuristic.py -v`
Expected: FAIL (ModuleNotFoundError: heuristic).

- [ ] **Step 3: Write heuristic.py**

`scripts/feed_discovery/heuristic.py`:
```python
from __future__ import annotations

from urllib.parse import urlparse

from .models import Country


def host_of(url: str) -> str:
    host = (urlparse(url).hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    return host


def _matches(host: str, domains) -> bool:
    for d in domains:
        d = d.lower()
        if host == d or host.endswith("." + d):
            return True
    return False


def _cctld_match(host: str, cctld: str) -> bool:
    cctld = cctld.lower()
    return host == cctld or host.endswith("." + cctld)


def is_national(url: str, country: Country, blocklist: set[str]) -> tuple[bool, str]:
    host = host_of(url)
    if not host:
        return False, "foreign"
    if _matches(host, country.allowlist):
        return True, "allowlist"
    if country.use_cctld and _cctld_match(host, country.cctld):
        return True, "cctld"
    if _matches(host, blocklist):
        return False, "blocked"
    return False, "foreign"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest scripts/feed_discovery/tests/test_heuristic.py -v`
Expected: 7 passed.

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/heuristic.py scripts/feed_discovery/tests/test_heuristic.py
git commit -m "feat(feed-discovery): national heuristic filter"
```

---

### Task 5: OPML dedup + emitter

**Files:**
- Create: `scripts/feed_discovery/opml.py`
- Create: `scripts/feed_discovery/tests/test_opml.py`
- Create (fixture): `scripts/feed_discovery/tests/fixtures/sample_country/sample.opml`

**Interfaces:**
- Consumes: `feedmine_verify.scanner.scan_directory`, `registry.CATEGORIES`.
- Produces:
  - `opml.normalize_url(url: str) -> str`
  - `opml.existing_feed_urls(country_dir: Path) -> set[str]` (normalized)
  - `opml.emit_opml(country_name: str, feeds_by_category: dict[str, list[tuple[str, str]]], categories_order: list[str]) -> str`

- [ ] **Step 1: Create the fixture**

`scripts/feed_discovery/tests/fixtures/sample_country/sample.opml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <head><title>Sample</title></head>
  <body>
    <outline text="News">
      <outline title="Existing" xmlUrl="https://existing.com.br/feed/" type="rss" />
    </outline>
  </body>
</opml>
```

- [ ] **Step 2: Write the failing test**

`scripts/feed_discovery/tests/test_opml.py`:
```python
from __future__ import annotations

from pathlib import Path

from scripts.feed_discovery import opml

FIX = Path(__file__).parent / "fixtures" / "sample_country"


def test_normalize_url_canonicalizes():
    assert opml.normalize_url("HTTP://Example.com/Feed/") == "https://example.com/feed"
    assert opml.normalize_url("https://example.com/feed") == "https://example.com/feed"


def test_existing_feed_urls_reads_opml_normalized():
    urls = opml.existing_feed_urls(FIX)
    assert "https://existing.com.br/feed" in urls


def test_emit_opml_matches_project_format():
    xml = opml.emit_opml(
        "Iceland",
        {"News": [("RÚV", "https://www.ruv.is/rss/frettir")]},
        ["News", "Sports"],
    )
    assert xml.startswith('<?xml version="1.0" encoding="UTF-8"?>')
    assert "<title>Iceland Feeds (candidates)</title>" in xml
    assert '    <outline text="News">' in xml
    assert '      <outline title="RÚV" xmlUrl="https://www.ruv.is/rss/frettir" type="rss" />' in xml
    assert "Sports" not in xml  # empty categories are omitted


def test_emit_opml_escapes_special_chars():
    xml = opml.emit_opml("X", {"News": [("A & B", "https://a.br/feed?x=1&y=2")]}, ["News"])
    assert "&amp;" in xml
```

- [ ] **Step 3: Run test to verify it fails**

Run: `python -m pytest scripts/feed_discovery/tests/test_opml.py -v`
Expected: FAIL (ModuleNotFoundError: opml).

- [ ] **Step 4: Write opml.py**

`scripts/feed_discovery/opml.py`:
```python
from __future__ import annotations

from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

from feedmine_verify.scanner import scan_directory


def normalize_url(url: str) -> str:
    u = url.strip().lower().split("#")[0]
    if u.startswith("http://"):
        u = "https://" + u[len("http://"):]
    return u.rstrip("/")


def existing_feed_urls(country_dir: Path) -> set[str]:
    feeds, _errors = scan_directory(Path(country_dir), recursive=True)
    return {normalize_url(f.url) for f in feeds}


def emit_opml(
    country_name: str,
    feeds_by_category: dict[str, list[tuple[str, str]]],
    categories_order: list[str],
) -> str:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<opml version="1.0">',
        "  <head>",
        f"    <title>{escape(country_name)} Feeds (candidates)</title>",
        "  </head>",
        "  <body>",
    ]
    for cat in categories_order:
        feeds = feeds_by_category.get(cat) or []
        if not feeds:
            continue
        lines.append(f"    <outline text={quoteattr(cat)}>")
        for title, url in feeds:
            lines.append(
                f"      <outline title={quoteattr(title)} xmlUrl={quoteattr(url)} type=\"rss\" />"
            )
        lines.append("    </outline>")
    lines.append("  </body>")
    lines.append("</opml>")
    lines.append("")
    return "\n".join(lines)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `python -m pytest scripts/feed_discovery/tests/test_opml.py -v`
Expected: 4 passed.

- [ ] **Step 6: Commit**

```bash
git add scripts/feed_discovery/opml.py scripts/feed_discovery/tests/test_opml.py scripts/feed_discovery/tests/fixtures/sample_country/sample.opml
git commit -m "feat(feed-discovery): OPML dedup and candidate emitter"
```

---

### Task 6: Search stage — query builder (pure) + DDG wrapper with cache

**Files:**
- Create: `scripts/feed_discovery/search.py`
- Create: `scripts/feed_discovery/tests/test_search.py`

**Interfaces:**
- Consumes: `ddgs.DDGS`.
- Produces:
  - `search.build_query(terms: list[str]) -> str`
  - `search.search(query: str, region: str, max_results: int, cache_path: Path, delay: float = 2.0, fresh: bool = False) -> list[str]` (returns result page URLs; reads/writes JSON cache; on region error falls back to region `"wt-wt"`)

- [ ] **Step 1: Write the failing test (pure query builder + cache read path)**

`scripts/feed_discovery/tests/test_search.py`:
```python
from __future__ import annotations

import json
from pathlib import Path

from scripts.feed_discovery import search


def test_build_query_uses_first_term_and_rss():
    assert search.build_query(["notícias"]) == "notícias RSS feed"
    assert search.build_query([]) == "news RSS feed"


def test_search_returns_cached_without_network(tmp_path: Path):
    cache = tmp_path / "News.json"
    cache.write_text(json.dumps(["https://a.br/", "https://b.br/"]), encoding="utf-8")
    # No network: cache hit returns immediately.
    urls = search.search("q", "br-pt", 12, cache, delay=0, fresh=False)
    assert urls == ["https://a.br/", "https://b.br/"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest scripts/feed_discovery/tests/test_search.py -v`
Expected: FAIL (ModuleNotFoundError: search).

- [ ] **Step 3: Write search.py**

`scripts/feed_discovery/search.py`:
```python
from __future__ import annotations

import json
import time
from pathlib import Path


def build_query(terms: list[str]) -> str:
    term = terms[0] if terms else "news"
    return f"{term} RSS feed"


def _extract_url(row: dict) -> str:
    return row.get("href") or row.get("url") or row.get("link") or ""


def _ddg_text(query: str, region: str, max_results: int) -> list[dict]:
    from ddgs import DDGS  # imported lazily so tests don't require the network

    try:
        with DDGS() as ddgs:
            return list(ddgs.text(query, region=region, max_results=max_results))
    except Exception:
        # Invalid region or transient error → retry region-agnostic once.
        with DDGS() as ddgs:
            return list(ddgs.text(query, region="wt-wt", max_results=max_results))


def search(
    query: str,
    region: str,
    max_results: int,
    cache_path: Path,
    delay: float = 2.0,
    fresh: bool = False,
) -> list[str]:
    cache_path = Path(cache_path)
    if not fresh and cache_path.exists():
        return json.loads(cache_path.read_text(encoding="utf-8"))

    rows = _ddg_text(query, region, max_results)
    urls: list[str] = []
    for row in rows:
        u = _extract_url(row)
        if u.startswith(("http://", "https://")):
            urls.append(u)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(urls, ensure_ascii=False, indent=2), encoding="utf-8")
    if delay:
        time.sleep(delay)  # politeness spacing between live queries
    return urls
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest scripts/feed_discovery/tests/test_search.py -v`
Expected: 2 passed.

- [ ] **Step 5: Manual live check (one real query)**

Run: `python -c "from pathlib import Path; from scripts.feed_discovery.search import search, build_query; print(search(build_query(['notícias']), 'br-pt', 5, Path('/tmp/fd_news.json'), delay=0, fresh=True))"`
Expected: prints a list of 1–5 Brazilian result URLs (proves `ddgs` works). If it prints `[]`, note DDG rate-limiting and retry after a minute.

- [ ] **Step 6: Commit**

```bash
git add scripts/feed_discovery/search.py scripts/feed_discovery/tests/test_search.py
git commit -m "feat(feed-discovery): DDG search stage with query builder and cache"
```

---

### Task 7: Discovery stage — HTML feed autodiscovery

**Files:**
- Create: `scripts/feed_discovery/discover.py`
- Create: `scripts/feed_discovery/tests/test_discover.py`

**Interfaces:**
- Consumes: `aiohttp`, `feedmine_verify.constants` (UA is defined locally as `FeedmineDiscovery/1.0`).
- Produces:
  - `discover.find_feeds_in_html(html: str, base_url: str) -> list[str]` (pure; parses `<link rel="alternate" type="application/rss+xml|atom+xml">`)
  - `discover.COMMON_PATHS: list[str]`
  - `async discover.discover_feeds(session, page_url: str, timeout: int) -> list[str]` (fetch HTML → links; if none, probe COMMON_PATHS; if page_url is itself a feed URL, return it)

- [ ] **Step 1: Write the failing test (pure parser)**

`scripts/feed_discovery/tests/test_discover.py`:
```python
from __future__ import annotations

from scripts.feed_discovery.discover import find_feeds_in_html

HTML = """
<html><head>
  <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed/">
  <link rel="alternate" type="application/atom+xml" href="https://x.br/atom.xml">
  <link rel="stylesheet" href="/style.css">
</head></html>
"""


def test_finds_rss_and_atom_links_resolved_to_absolute():
    feeds = find_feeds_in_html(HTML, "https://x.br/blog/")
    assert "https://x.br/feed/" in feeds
    assert "https://x.br/atom.xml" in feeds
    assert all(".css" not in f for f in feeds)


def test_deduplicates_preserving_order():
    html = ('<link rel="alternate" type="application/rss+xml" href="/feed/">'
            '<link rel="alternate" type="application/rss+xml" href="/feed/">')
    assert find_feeds_in_html(html, "https://x.br/") == ["https://x.br/feed/"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest scripts/feed_discovery/tests/test_discover.py -v`
Expected: FAIL (ModuleNotFoundError: discover).

- [ ] **Step 3: Write discover.py**

`scripts/feed_discovery/discover.py`:
```python
from __future__ import annotations

import re
from urllib.parse import urljoin, urlparse

import aiohttp

USER_AGENT = "FeedmineDiscovery/1.0"
COMMON_PATHS = ["/feed/", "/rss/", "/rss.xml", "/feed.xml", "/atom.xml", "/index.xml"]
_LINK_RE = re.compile(r"<link\b[^>]*>", re.I)
_HREF_RE = re.compile(r"href\s*=\s*[\"']([^\"']+)[\"']", re.I)


def find_feeds_in_html(html: str, base_url: str) -> list[str]:
    out: list[str] = []
    for tag in _LINK_RE.findall(html):
        low = tag.lower()
        if "alternate" in low and ("rss+xml" in low or "atom+xml" in low):
            m = _HREF_RE.search(tag)
            if m:
                out.append(urljoin(base_url, m.group(1)))
    seen: set[str] = set()
    result: list[str] = []
    for u in out:
        if u not in seen:
            seen.add(u)
            result.append(u)
    return result


def _looks_like_feed_url(url: str) -> bool:
    path = urlparse(url).path.lower()
    return path.endswith((".xml", "/feed", "/feed/", "/rss", "/rss/")) or "rss" in path or "feed" in path


async def _fetch_text(session: aiohttp.ClientSession, url: str, timeout: int) -> str:
    try:
        async with session.get(
            url,
            headers={"User-Agent": USER_AGENT},
            timeout=aiohttp.ClientTimeout(total=timeout),
            allow_redirects=True,
        ) as resp:
            if resp.status != 200:
                return ""
            data = await resp.content.read(128 * 1024)
            return data.decode("utf-8", errors="ignore")
    except (aiohttp.ClientError, UnicodeError, TimeoutError):
        return ""


async def discover_feeds(session: aiohttp.ClientSession, page_url: str, timeout: int) -> list[str]:
    if _looks_like_feed_url(page_url):
        return [page_url]

    html = await _fetch_text(session, page_url, timeout)
    if html:
        feeds = find_feeds_in_html(html, page_url)
        if feeds:
            return feeds

    # Fallback: probe common feed paths on the site root.
    parsed = urlparse(page_url)
    root = f"{parsed.scheme}://{parsed.netloc}"
    return [urljoin(root, p) for p in COMMON_PATHS]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest scripts/feed_discovery/tests/test_discover.py -v`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/discover.py scripts/feed_discovery/tests/test_discover.py
git commit -m "feat(feed-discovery): HTML feed autodiscovery stage"
```

---

### Task 8: Verify stage — feed parse (pure) + async liveness check

**Files:**
- Create: `scripts/feed_discovery/verify.py`
- Create: `scripts/feed_discovery/tests/test_verify.py`

**Interfaces:**
- Consumes: `aiohttp`, `feedmine_verify.constants.MAX_BODY_BYTES`.
- Produces:
  - `verify.parse_feed(body: bytes) -> tuple[bool, str]` (is_valid_feed, feed_title)
  - `async verify.verify_feed(session, url: str, timeout: int) -> tuple[bool, int, str]` (is_live_valid, status_code, title)

- [ ] **Step 1: Write the failing test (pure feed parser)**

`scripts/feed_discovery/tests/test_verify.py`:
```python
from __future__ import annotations

from scripts.feed_discovery.verify import parse_feed

RSS = b"""<?xml version="1.0"?><rss version="2.0"><channel>
  <title>My Feed</title><item><title>Post</title></item></channel></rss>"""
ATOM = b"""<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Feed</title></feed>"""
NOT_FEED = b"<html><body>hello</body></html>"


def test_parses_rss_title():
    assert parse_feed(RSS) == (True, "My Feed")


def test_parses_atom_title():
    assert parse_feed(ATOM) == (True, "Atom Feed")


def test_rejects_non_feed():
    assert parse_feed(NOT_FEED) == (False, "")


def test_rejects_garbage():
    assert parse_feed(b"\x00\x01 not xml") == (False, "")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest scripts/feed_discovery/tests/test_verify.py -v`
Expected: FAIL (ModuleNotFoundError: verify).

- [ ] **Step 3: Write verify.py**

`scripts/feed_discovery/verify.py`:
```python
from __future__ import annotations

import xml.etree.ElementTree as ET

import aiohttp

from feedmine_verify.constants import MAX_BODY_BYTES

USER_AGENT = "FeedmineDiscovery/1.0"
_FEED_TAGS = {"rss", "feed", "rdf"}


def _localname(tag: str) -> str:
    return tag.lower().rsplit("}", 1)[-1]


def parse_feed(body: bytes) -> tuple[bool, str]:
    try:
        root = ET.fromstring(body)
    except ET.ParseError:
        return False, ""
    if _localname(root.tag) not in _FEED_TAGS:
        return False, ""
    for el in root.iter():
        if _localname(el.tag) == "title" and (el.text or "").strip():
            return True, el.text.strip()
    return True, ""


async def verify_feed(session: aiohttp.ClientSession, url: str, timeout: int) -> tuple[bool, int, str]:
    try:
        async with session.get(
            url,
            headers={"User-Agent": USER_AGENT},
            timeout=aiohttp.ClientTimeout(total=timeout),
            allow_redirects=True,
        ) as resp:
            status = resp.status
            if status != 200:
                return False, status, ""
            body = await resp.content.read(MAX_BODY_BYTES)
    except (aiohttp.ClientError, TimeoutError):
        return False, 0, ""
    is_valid, title = parse_feed(body)
    return is_valid, status, title
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest scripts/feed_discovery/tests/test_verify.py -v`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/verify.py scripts/feed_discovery/tests/test_verify.py
git commit -m "feat(feed-discovery): feed parse and async liveness verify"
```

---

### Task 9: Report aggregation (pure) + writers

**Files:**
- Create: `scripts/feed_discovery/report.py`
- Create: `scripts/feed_discovery/tests/test_report.py`

**Interfaces:**
- Consumes: `models.Candidate`, `registry.CATEGORIES`.
- Produces:
  - `report.summarize(slug: str, candidates: list[Candidate]) -> dict` (counts: total, national, blocked, foreign, live, new, per-category new counts)
  - `report.render_markdown(summaries: list[dict]) -> str`
  - `report.write_reports(out_dir: Path, summaries: list[dict]) -> None` (writes `report.md` + `report.json`)

- [ ] **Step 1: Write the failing test**

`scripts/feed_discovery/tests/test_report.py`:
```python
from __future__ import annotations

from scripts.feed_discovery import report
from scripts.feed_discovery.models import Candidate


def _cand(cat, national, reason, live, new):
    return Candidate(url="https://x.br/f", category=cat, national=national,
                     national_reason=reason, is_live=live, is_new=new)


def test_summarize_counts():
    cands = [
        _cand("News", True, "cctld", True, True),
        _cand("News", True, "cctld", True, False),   # not new (dedup)
        _cand("Sports", False, "blocked", False, True),
        _cand("Sports", False, "foreign", False, True),
    ]
    s = report.summarize("brazil", cands)
    assert s["slug"] == "brazil"
    assert s["total"] == 4
    assert s["national"] == 2
    assert s["blocked"] == 1
    assert s["foreign"] == 1
    assert s["live"] == 2
    assert s["new"] == 1
    assert s["per_category_new"]["News"] == 1


def test_render_markdown_has_country_heading():
    s = report.summarize("brazil", [_cand("News", True, "cctld", True, True)])
    md = report.render_markdown([s])
    assert "brazil" in md
    assert "| News |" in md
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest scripts/feed_discovery/tests/test_report.py -v`
Expected: FAIL (ModuleNotFoundError: report).

- [ ] **Step 3: Write report.py**

`scripts/feed_discovery/report.py`:
```python
from __future__ import annotations

import json
from pathlib import Path

from .models import Candidate
from .registry import CATEGORIES


def summarize(slug: str, candidates: list[Candidate]) -> dict:
    per_cat_new: dict[str, int] = {}
    for c in candidates:
        if c.is_new and c.national and c.is_live:
            per_cat_new[c.category] = per_cat_new.get(c.category, 0) + 1
    return {
        "slug": slug,
        "total": len(candidates),
        "national": sum(1 for c in candidates if c.national),
        "blocked": sum(1 for c in candidates if c.national_reason == "blocked"),
        "foreign": sum(1 for c in candidates if c.national_reason == "foreign"),
        "live": sum(1 for c in candidates if c.is_live),
        "new": sum(1 for c in candidates if c.is_new and c.national and c.is_live),
        "per_category_new": per_cat_new,
    }


def render_markdown(summaries: list[dict]) -> str:
    lines = ["# Feed Discovery Report", ""]
    for s in summaries:
        lines.append(f"## {s['slug']}")
        lines.append(
            f"- total candidates: {s['total']} | national: {s['national']} | "
            f"blocked: {s['blocked']} | foreign: {s['foreign']} | "
            f"live: {s['live']} | **new: {s['new']}**"
        )
        lines.append("")
        lines.append("| Category | New feeds |")
        lines.append("| --- | --- |")
        for cat in CATEGORIES:
            n = s["per_category_new"].get(cat, 0)
            if n:
                lines.append(f"| {cat} | {n} |")
        lines.append("")
    return "\n".join(lines)


def write_reports(out_dir: Path, summaries: list[dict]) -> None:
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "report.md").write_text(render_markdown(summaries), encoding="utf-8")
    (out_dir / "report.json").write_text(
        json.dumps(summaries, ensure_ascii=False, indent=2), encoding="utf-8"
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest scripts/feed_discovery/tests/test_report.py -v`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/report.py scripts/feed_discovery/tests/test_report.py
git commit -m "feat(feed-discovery): run summary report"
```

---

### Task 10: CLI orchestration + `__main__` + pilot

**Files:**
- Create: `scripts/feed_discovery/pipeline.py`
- Create: `scripts/feed_discovery/cli.py`
- Create: `scripts/feed_discovery/__main__.py`
- Create: `scripts/feed_discovery/tests/test_pipeline.py`

**Interfaces:**
- Consumes: everything above (`registry`, `search`, `discover`, `heuristic`, `verify`, `opml`, `report`, `models.Candidate/Country`).
- Produces:
  - `async pipeline.process_country(country, categories, keywords, blocklist, existing_urls, session, cfg) -> list[Candidate]`
  - `pipeline.candidates_to_opml_map(candidates) -> dict[str, list[tuple[str, str]]]` (only new+national+live)
  - `cli.main(argv: list[str] | None = None) -> int`

- [ ] **Step 1: Write the failing test (pure grouping helper)**

`scripts/feed_discovery/tests/test_pipeline.py`:
```python
from __future__ import annotations

from scripts.feed_discovery.models import Candidate
from scripts.feed_discovery.pipeline import candidates_to_opml_map


def test_only_new_national_live_feeds_are_emitted():
    cands = [
        Candidate(url="https://a.br/f", category="News", title="A",
                  national=True, is_live=True, is_new=True),
        Candidate(url="https://b.br/f", category="News", title="B",
                  national=True, is_live=True, is_new=False),   # dropped: not new
        Candidate(url="https://c.com/f", category="News", title="C",
                  national=False, is_live=True, is_new=True),   # dropped: not national
        Candidate(url="https://d.br/f", category="News", title="D",
                  national=True, is_live=False, is_new=True),   # dropped: not live
    ]
    m = candidates_to_opml_map(cands)
    assert m == {"News": [("A", "https://a.br/f")]}


def test_untitled_feed_falls_back_to_host():
    cands = [Candidate(url="https://noticias.br/rss", category="News", title="",
                       national=True, is_live=True, is_new=True)]
    m = candidates_to_opml_map(cands)
    assert m["News"] == [("noticias.br", "https://noticias.br/rss")]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest scripts/feed_discovery/tests/test_pipeline.py -v`
Expected: FAIL (ModuleNotFoundError: pipeline).

- [ ] **Step 3: Write pipeline.py**

`scripts/feed_discovery/pipeline.py`:
```python
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import aiohttp

from . import discover, search, verify
from .heuristic import host_of, is_national
from .models import Candidate, Country
from .opml import normalize_url
from .registry import keywords_for


@dataclass
class Config:
    max_results: int = 12
    timeout: int = 15
    delay: float = 2.0
    fresh: bool = False
    concurrency: int = 50
    cache_dir: Path = Path("scripts/feed_discovery/cache")


def candidates_to_opml_map(candidates: list[Candidate]) -> dict[str, list[tuple[str, str]]]:
    out: dict[str, list[tuple[str, str]]] = {}
    seen: set[str] = set()
    for c in candidates:
        if not (c.is_new and c.national and c.is_live):
            continue
        key = normalize_url(c.url)
        if key in seen:
            continue
        seen.add(key)
        title = c.title or host_of(c.url)
        out.setdefault(c.category, []).append((title, c.url))
    return out


async def process_country(
    country: Country,
    categories: list[str],
    keywords: dict,
    blocklist: set[str],
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    candidates: list[Candidate] = []
    seen_feed_urls: set[str] = set()

    for category in categories:
        terms = keywords_for(keywords, category, country.lang)
        query = search.build_query(terms)
        cache_path = cfg.cache_dir / "search" / country.slug / f"{category}.json"
        page_urls = search.search(
            query, country.ddg_region, cfg.max_results, cache_path, cfg.delay, cfg.fresh
        )

        # Discover feed URLs from each result page.
        feed_urls: list[str] = []
        for page in page_urls:
            found = await discover.discover_feeds(session, page, cfg.timeout)
            feed_urls.extend(found)

        for feed_url in feed_urls:
            norm = normalize_url(feed_url)
            if norm in seen_feed_urls:
                continue
            seen_feed_urls.add(norm)

            national, reason = is_national(feed_url, country, blocklist)
            cand = Candidate(url=feed_url, category=category,
                             national=national, national_reason=reason)
            if not national:
                candidates.append(cand)
                continue

            cand.is_new = norm not in existing_urls
            if not cand.is_new:
                candidates.append(cand)
                continue

            is_live, status, title = await verify.verify_feed(session, feed_url, cfg.timeout)
            cand.is_live, cand.status_code, cand.title = is_live, status, title
            candidates.append(cand)

    return candidates
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest scripts/feed_discovery/tests/test_pipeline.py -v`
Expected: 2 passed.

- [ ] **Step 5: Write cli.py**

`scripts/feed_discovery/cli.py`:
```python
from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

import aiohttp

from . import registry, report
from .opml import emit_opml, existing_feed_urls
from .pipeline import Config, candidates_to_opml_map, process_country

PKG_DIR = Path(__file__).resolve().parent
DATA = PKG_DIR / "data"
REPO_ROOT = PKG_DIR.parents[1]
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "countries"


def _parse_args(argv):
    p = argparse.ArgumentParser(prog="python -m scripts.feed_discovery")
    p.add_argument("--country", action="append", default=[], help="country slug (repeatable)")
    p.add_argument("--all", action="store_true", help="process all countries")
    p.add_argument("--category", action="append", default=[], help="restrict to category (repeatable)")
    p.add_argument("--max-results", type=int, default=12)
    p.add_argument("--concurrency", type=int, default=50)
    p.add_argument("--timeout", type=int, default=15)
    p.add_argument("--delay", type=float, default=2.0)
    p.add_argument("--fresh", action="store_true")
    p.add_argument("--out", type=Path, default=PKG_DIR / "candidates")
    return p.parse_args(argv)


async def _run(args) -> int:
    countries = registry.load_countries(DATA / "countries.json")
    keywords = registry.load_keywords(DATA / "category_keywords.json")
    blocklist = registry.load_blocklist(DATA / "blocklist.txt")
    categories = args.category or registry.CATEGORIES

    if args.all:
        slugs = sorted(countries)
    else:
        slugs = args.country
    if not slugs:
        print("Nothing to do: pass --country SLUG or --all")
        return 1

    cfg = Config(max_results=args.max_results, timeout=args.timeout,
                 delay=args.delay, fresh=args.fresh, concurrency=args.concurrency)
    args.out.mkdir(parents=True, exist_ok=True)
    summaries = []

    connector = aiohttp.TCPConnector(limit=cfg.concurrency, limit_per_host=5)
    async with aiohttp.ClientSession(connector=connector) as session:
        for slug in slugs:
            country = countries.get(slug)
            if country is None:
                print(f"skip unknown country: {slug}")
                continue
            existing = existing_feed_urls(COUNTRIES_DIR / slug)
            print(f"[{slug}] searching {len(categories)} categories…")
            cands = await process_country(
                country, categories, keywords, blocklist, existing, session, cfg
            )
            opml_map = candidates_to_opml_map(cands)
            xml = emit_opml(country.name, opml_map, registry.CATEGORIES)
            (args.out / f"{slug}.opml").write_text(xml, encoding="utf-8")
            summary = report.summarize(slug, cands)
            summaries.append(summary)
            print(f"[{slug}] new national feeds: {summary['new']} → {args.out / (slug + '.opml')}")

    report.write_reports(args.out, summaries)
    print(f"Report: {args.out / 'report.md'}")
    return 0


def main(argv=None) -> int:
    args = _parse_args(argv)
    return asyncio.run(_run(args))
```

- [ ] **Step 6: Write __main__.py**

`scripts/feed_discovery/__main__.py`:
```python
from __future__ import annotations

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 7: Verify the full test suite passes**

Run: `python -m pytest scripts/feed_discovery/tests/ -v`
Expected: all tests pass (smoke, registry, data coverage, heuristic, opml, search, discover, verify, report, pipeline).

- [ ] **Step 8: Run the `iceland` pilot end-to-end**

Run: `python -m scripts.feed_discovery --country iceland --delay 2`
Expected: prints `[iceland] searching 26 categories…` then `[iceland] new national feeds: N → …/candidates/iceland.opml`. Inspect:
```bash
cat scripts/feed_discovery/candidates/iceland.opml
cat scripts/feed_discovery/candidates/report.md
```
Verify the OPML matches project format and the feeds are Icelandic (`.is` domains or allowlisted). If DDG returns empty on some categories (rate limit), re-run — the search cache makes it resume.

- [ ] **Step 9: Commit**

```bash
git add scripts/feed_discovery/pipeline.py scripts/feed_discovery/cli.py scripts/feed_discovery/__main__.py scripts/feed_discovery/tests/test_pipeline.py
git commit -m "feat(feed-discovery): CLI orchestration and pilot runner"
```

---

## Self-Review

**Spec coverage:**
- Discovery via DuckDuckGo → Task 6. Autodiscovery → Task 7. National heuristic (ccTLD + allowlist + blocklist, `use_cctld` fallback) → Task 4. Liveness verify + feed validity → Task 8. Dedup (only new) → Tasks 5 (`existing_feed_urls`) + 10 (`is_new` wiring). Emit OPML in project format → Task 5. Report → Task 9. Config data (countries/keywords/blocklist) → Tasks 2–3. Reuse of `feedmine_verify` → Tasks 1 (import check), 5 (`scanner`), 8 (`constants`). CLI + resumable cache + pilot → Tasks 6 (cache) + 10 (pilot). Future `--include-regions` → deliberately not implemented; scope is national (Global Constraints).
- Note: the emitted OPML title uses the `(candidates)` suffix (Task 5) — reviewer removes it when copying feeds into the real file.

**Placeholder scan:** No TBD/TODO; every code step contains complete code; every test step contains real assertions.

**Type consistency:** `Country`/`Candidate` fields (Task 2) are used consistently in Tasks 4, 9, 10. `is_national` returns `(bool, reason)` (Task 4) and is consumed that way in `pipeline.process_country` (Task 10). `normalize_url` (Task 5) is used for dedup keys in Task 10. `keywords_for(keywords, category, lang)` signature (Task 2) matches its call in Task 10. `candidates_to_opml_map` returns `dict[str, list[tuple[str,str]]]`, exactly what `emit_opml` consumes (Tasks 5, 10).
