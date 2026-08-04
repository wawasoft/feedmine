# Feed catalog curation

This directory is the audit trail for the production catalog. Crawl evidence
is reconciled before it can reach OPML, SQLite, or the public feed repository.

## Current release: 2026-08-03

The source corpus contained 99,576 rows and 90,326 declared runtime
identities. Reconciliation produced:

- 77,443 publishable canonical sources with an editorial membership;
- 77,443 production placements across 118 OPML files;
- zero duplicate placements, invalid outlines, placeholder titles, `nan`
  languages, escaped query entities, or source-ID mismatches;
- 158,547 canonical membership records retained as provenance;
- 86,712 accepted alias rows mapped to the canonical identity contract;
- 12,864 quarantined corpus rows;
- 54 successful sources held outside production because no membership exists.

The quarantine contains 10,188 failed rows, 2,267 empty rows, 402 URLs whose
HTML entities were corrected and therefore require a fresh crawl, and seven
semantic redirect mismatches. A failed or empty alias can resolve to a
published source only when another variant of the same final identity has a
successful crawl. A corrected URL is never allowed to inherit the result of
the incorrectly escaped request.

The derived SQLite catalog contains 77,443 source, placement, and FTS rows.
It preserves 77,188 `latest_item_at` values and 76,741 site URLs. `PRAGMA
quick_check` passes.

## Identity and publication contract

`scripts/catalog_identity.py` is the Python identity implementation. The
Swift runtime delegates catalog identity to `OPMLParser.normalizeURL`, which
uses the same rules:

1. Decode HTML entities before parsing.
2. Normalize the identity scheme to HTTPS.
3. Lowercase the host and remove a leading `www.`.
4. Remove fragments, one trailing slash, and known tracking parameters.
5. Preserve all other path and query information.
6. Compute `feedmineSourceId` as SHA-256 of that canonical identity.

The request URL is stored separately from the identity so redirect evidence
can be audited without changing the identity formula.

Production eligibility is explicit:

- at least one non-quarantined variant must have `status=done`;
- corrected escaped URLs require a new fetch;
- high-confidence title/domain redirect mismatches are quarantined;
- the canonical source must have at least one editorial membership;
- publication fails when a source ID does not match the canonical URL.

## Artifacts

- `reconciliation-summary.json`: source, alias, membership, and quarantine
  counts for the current corpus.
- `source-aliases.csv.gz`: old source IDs and URLs mapped to canonical source
  IDs and publication URLs.
- `reconciliation-quarantine.csv.gz`: every source row withheld from the clean
  corpus, with a deterministic reason.
- `unmatched-memberships.csv.gz`: OPML occurrences that could not resolve to a
  publishable canonical source.
- `publishable-without-membership.csv`: successful canonical sources awaiting
  an editorial home.
- `source-placement-decisions.csv.gz`: the single production residence chosen
  for each source.
- `source-disposition-ledger.csv.gz`: production and remaining editorial
  discovery identities after reconciliation.
- `staging/discovery-candidates.opml`: non-production editorial candidates.
- `policy-exclusions.csv`: manually reviewed exclusions.
- `source-experience.md`: catalog UX and single-home policy.

## Rebuild

The original Parquet is immutable. Run reconciliation into `build/`, then
curate and compile only from the derived canonical Parquets:

```bash
python scripts/reconcile_feed_corpus.py \
  --sources feeds_corpus_sources.parquet \
  --feeds-root feedmine/Resources/Feeds

python scripts/curate_opml_catalog.py \
  --sources build/catalog-reconciliation/feeds_corpus_sources.parquet \
  --memberships build/catalog-reconciliation/feeds_corpus_source_memberships.parquet \
  --output build/catalog-curated/Feeds \
  --report-dir build/catalog-curated \
  --now 2026-08-03T00:00:00Z

python scripts/build_catalog.py \
  --feeds-root build/catalog-curated/Feeds \
  --output build/catalog-curated/catalog.sqlite \
  --manifest-output build/catalog-curated/catalog-manifest.json
```

`curate_opml_catalog.py` writes only to its explicit output. Promotion to the
bundled resources and public repository remains a separate reviewable step.
`publish_catalog_update.py` revalidates canonical source IDs, URL entities,
source/file counts, and the complete OPML inventory before writing a snapshot.
