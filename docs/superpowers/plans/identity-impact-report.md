# Identity Impact Report — Code Review Fixes for 5c27f3f3

**Date:** 2026-08-03
**Corpus size:** 77,443 sources across 118 OPML files

## Identity Impact

| Metric | Count |
|--------|-------|
| Unchanged | 77,443 |
| Changed | 0 |
| Collided | 0 |
| Rejected/invalid | 0 |
| Idempotency failures | 0 |

**Conclusion:** Identity contract changes are fully backward-compatible. No OPML, SQLite, or manifest regeneration required.

## Findings Status

| Finding | Severity | Status | Test |
|---------|----------|--------|------|
| P0-01 | Critical | FIXED | `test_fetch_new_feeds_progress.py` — 26 tests |
| P0-02 | Critical | FIXED | `test_prepare_entity_recrawl.py` — 10 tests |
| P1-03 | High | FIXED | `test_prepare_entity_recrawl.py` (reordered parquet, key mismatch, xml_url mismatch) |
| P1-04 | High | FIXED | Monotonic revision enforcement in `publish_catalog_update.py` |
| P1-05 | High | FIXED | `test_catalog_identity_contract.py` — 8 new vectors + host validation tests |
| P1-06 | High | FIXED | `test_catalog_identity_contract.py` — idempotency + source_id stability + OPML scan |
| P1-07 | High | FIXED | `fetch_all_feeds.py` — source_id-based dedup, DuckDB schema udpated |
| P1-08 | High | FIXED | `.github/workflows/editorial-ci.yml` + `.github/workflows/ios-ci.yml` |
| P2-09 | Medium | FIXED | `UserStateStore.swift` — ORDER BY added_at DESC |
| P2-10 | Medium | FIXED | `curate_itunes_podcasts.py` — canonical_url as dedup key |
| P2-11 | Medium | FIXED | `inject_curated_to_parquet.py` — request_url for xml_url |
| P2-12 | Medium | FIXED | `pyproject.toml` — testpaths → scripts; hash gate broadened |
| P2-13 | Medium | FIXED | `pyproject.toml` — editorial extra; `fetch_all_feeds.py` identity dedup |

## Gate Results

| Gate | Result |
|------|--------|
| `git diff --check` | ✅ PASS |
| `python3 -m compileall -q scripts` | ✅ PASS |
| `python3 -m pytest scripts/` (43 tests) | ✅ 43 passed, 67 subtests |
| `migrate_catalog_identity.py --dry-run` | ✅ 118 files, 0 changes |
| `PRAGMA quick_check` | ✅ ok |
| FTS row count | ✅ 77,443 |
| `catalog_source` row count | ✅ 77,443 |
| Manifest: sources / placements / files / nodes | ✅ 77,443 / 77,443 / 118 / 6,450 |
| Manifest: duplicates / invalid / failed | ✅ 0 / 0 / 0 |
| Identity scan (all OPML source IDs) | ✅ 77,443 unchanged, 0 changed |
| `canonical(canonical(x)) == canonical(x)` | ✅ 0 failures across 77,443 URLs |
| Swift `xcodebuild test CatalogIdentityContractTests` | ✅ 8 tests, 0 failures |
| Catalog rebuild (78,292 sources from parquet) | ✅ 0 identity mismatches |

## Commits

1. `508fd466` — fix: typed progress schema for fetch_new_feeds (P0-01)
2. `17dd41c2` — fix: clear fetch evidence + resolve by old_source_id (P0-02, P1-03)
3. `c3c551b5` — fix: reject percent-encoded authority delimiters + idempotent canonical (P1-05, P1-06)
4. `9ca7d3f8` — fix: persistence, producers, publishing, and CI gates (P1-04,P1-07,P1-08,P2-09,P2-10,P2-11,P2-12,P2-13)
