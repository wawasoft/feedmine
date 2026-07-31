# Contact Email Extraction Pipeline

**Date:** 2026-07-31
**Status:** Design approved — awaiting implementation plan

## Overview

Extract and validate contact emails for all 44,965 feed sources in the Feedmine catalog. Goal: build a high-quality contact database for future publisher outreach (newsletters, communications). Emails are extracted from RSS metadata first (fast, zero-cost), then from site scraping as fallback, then validated via SMTP.

## Scope

- **In scope:** Email extraction from RSS `<managingEditor>`, `<webMaster>`, `<itunes:owner>`; site scraping of `/contact`, `/about`, and homepage; SMTP RCPT TO verification; disposable domain filtering; storing results in parquet → OPML → catalog.sqlite → Swift models
- **Out of scope:** Message generation (DeepSeek-powered personalized outreach — separate project); sending actual emails; ongoing/continuous extraction (pipeline is re-runnable but one-shot for now)
- **Scale:** 44,965 sources, ~99% have `site_url`, 26,505 text / 14,484 audio / 3,972 video

## Architecture

```
catalog.sqlite (44,965 sources)
         │
         ▼
 extract_contact_emails.py          ← orchestrator
    ├─ Phase 1: RSS Metadata        ← fast, ~1-2h, 50 parallel workers
    ├─ Phase 2: Site Scraping       ← fallback, ~1-2 days, 20 workers + rate limiting
    └─ Phase 3: Validation          ← regex → DNS MX → disposable filter → SMTP
         │
         ▼
 feeds_corpus_contacts.parquet      ← output (4 new fields per source)
         │
         ▼
 inject_contact_emails.py           ← writes feedmineContact* attributes into OPML
         │
         ▼
 OPML files → catalog.sqlite        ← rebuild via curate_opml_catalog.py
         │
         ▼
 Swift: FeedSource + CatalogModels  ← new optional fields
```

## New Data Fields

| Field | Type | Example | Description |
|-------|------|---------|-------------|
| `contact_email` | `String?` | `"maria.silva@editora.com"` | Validated email address |
| `contact_name` | `String?` | `"Maria Silva"` | Person name (if found near email) |
| `contact_source` | `String?` | `"rss_managing_editor"` | Where the email was found |
| `contact_type` | `String?` | `"personal"` / `"generic"` | Personal vs info@/contact@ |
| `contact_status` | `String` | `"verified"` | Extraction outcome for this source |

### contact_source values
- `rss_managing_editor` — RSS `<managingEditor>` field
- `rss_web_master` — RSS `<webMaster>` field
- `itunes_owner` — iTunes podcast owner email
- `site_contact_page` — found on /contact or equivalent
- `site_about_page` — found on /about or equivalent
- `site_homepage` — found on homepage

### contact_type values
- `personal` — identifiable person (name + email in same context)
- `generic` — role-based address (info@, contact@, redacao@, admin@)

### contact_status values
- `verified` — SMTP RCPT TO confirmed mailbox exists
- `unverified` — MX ok but SMTP failed (timeout, greylisting, catch-all)
- `not_found` — no email found in RSS or site
- `site_blocked` — scraping blocked (403, robots.txt)
- `site_dead` — site offline or HTTP error

## Phase Details

### Phase 1: RSS Metadata Extraction

For each source with a `declared_url` (RSS/Atom feed):

1. HTTP GET with `Range: bytes=0-65536` (first 64KB only)
2. Parse XML, extract: `<managingEditor>`, `<webMaster>`, `<itunes:owner>/<email>`, channel-level `<author>`
3. Regex extract email from each field value (handles `Name <email>` and `email (Name)` formats)
4. If email + name found together → `contact_type = "personal"`
5. If only email → `contact_type = "generic"`

**Performance:** ~30K sources, 1–2 hours with 50 async workers (aiohttp).
**Cost:** Zero.

### Phase 2: Site Scraping (Fallback)

For each source without an email from Phase 1, using `site_url`:

URLs tried per site (in order, stop on first email found):
1. `{site_url}/contact`
2. `{site_url}/about`
3. `{site_url}/contato` (localized variants: /contato, /contacto, /kontakt, /連絡先, /contact-us, /sobre, /nosotros, /chi-siamo, /nous-contacter, /uber-uns)
4. `{site_url}` (homepage)

For each page:
1. `requests.get()` with rotating User-Agent (Chrome, Firefox, Safari)
2. BeautifulSoup extracts visible text
3. Email regex (RFC 5322 simplified)
4. Person heuristic: if a proper name appears on the same line or immediately before the email → `personal`; if email matches info@/contact@/admin@/redacao@/press@ pattern → `generic`

Rate limiting:
- 1–3 second delay between requests to the same domain
- Timeout: 10 seconds per request
- Respects robots.txt (cached per domain, 1h TTL)
- Max 4 URLs per site

**Performance:** ~35K sites, 1–2 days with 20 workers.
**Cost:** Zero.

### Phase 3: Validation

For every email found (Phase 1 + Phase 2), in order:

1. **Regex syntax check** — filter obviously invalid patterns, remove duplicates per source
2. **DNS MX lookup** — extract domain, query MX records; discard domains with no mail server
3. **Disposable domain filter** — static list of ~5000 known disposable domains (Mailinator, 10MinuteMail, GuerrillaMail, etc.)
4. **SMTP RCPT TO verification:**
   - Connect to MX server on port 25
   - `HELO` → `MAIL FROM:<verify@feedmine.com>` → `RCPT TO:<target@domain.com>`
   - Does NOT send `DATA` (no actual email is sent)
   - Response 250 → verified; 550 → invalid; 4xx → greylisting (retry after 5 min, once)
   - Catch-all domains detected by pattern (always returns 250) → mark as `unverified` with catch-all flag

**Performance:** 12–48 hours depending on MX server rate limits and greylisting volume.
**Cost:** Zero.

## Storage Integration

### Parquet (working corpus)
```
feeds_corpus_contacts.parquet
Columns: source_id, contact_email, contact_name, contact_source, contact_type, contact_status, validated_at
```

### OPML (editorial source of truth)
```xml
<outline text="Tape Op Magazine"
         xmlUrl="https://tapeop.com/feed/"
         feedmineContactEmail="john@tapeop.com"
         feedmineContactName="John Baccigaluppi"
         feedmineContactSource="rss_managing_editor"
         feedmineContactType="personal" />
```

### SQLite catalog
```sql
ALTER TABLE catalog_source ADD COLUMN contact_email TEXT;
ALTER TABLE catalog_source ADD COLUMN contact_name TEXT;
ALTER TABLE catalog_source ADD COLUMN contact_source TEXT;
ALTER TABLE catalog_source ADD COLUMN contact_type TEXT;
```

### Swift models
```swift
// FeedSource.swift, SourceReference, SourceSummary, SourceDetails, CatalogSourceOccurrence
let contactEmail: String?
let contactName: String?
let contactSource: String?
let contactType: ContactType?  // enum: personal, generic
```

## Files

### New files
| File | Purpose |
|------|---------|
| `scripts/extract_contact_emails.py` | Orchestrator — reads catalog.sqlite, runs 3 phases, writes parquet |
| `scripts/inject_contact_emails.py` | Reads parquet, injects `feedmineContact*` attributes into OPML files |
| `scripts/data/disposable_domains.txt` | Static list of disposable email domains (updatable) |

### Modified files
| File | Change |
|------|--------|
| `feedmine/Models/FeedSource.swift` | Add 4 optional contact fields |
| `feedmine/FeedEngine/CatalogModels.swift` | Add contact fields to SourceSummary, SourceDetails |
| `feedmine/FeedEngine/CatalogInput.swift` | Add contact fields to CatalogSourceOccurrence |
| `feedmine/FeedEngine/SQLiteCatalogStore.swift` | Add contact columns to catalog_source table |
| `feedmine/Services/OPMLParser.swift` | Parse new `feedmineContact*` attributes; bump cacheFormatVersion |
| `scripts/curate_opml_catalog.py` | Include contact fields in catalog rebuild |

## Error Handling

### By phase
- **Phase 1:** Feed offline/timeout → skip, fall through to Phase 2 with site_url. XML malformed → try regex on raw text. Redirects → follow up to 3. Non-UTF8 encoding → detect (chardet) and convert.
- **Phase 2:** 403/429 → exponential backoff (1s → 2s → 4s → give up). Empty HTML (SPA) → mark `site_blocked`. robots.txt disallows → respect, mark `site_blocked`. Offline/dead → mark `site_dead`.
- **Phase 3:** MX connection refused → 3 retries at 30s intervals. Greylisting (SMTP 4xx) → re-queue for later attempt. Timeout → mark `unverified`, keep email. Catch-all domains → mark `unverified` with flag.

### Checkpoint and resume
- Saves checkpoint every 500 sources processed
- On restart, resumes from last checkpoint
- Per-source log: timestamp, phase, status, error (if any)

## Constraints

### Hard rules
- ❌ Never send DATA during SMTP verification (RCPT TO only — no actual email sent)
- ❌ Never exceed 1 request/second to the same domain
- ❌ Never ignore robots.txt
- ❌ Never store emails that failed syntax validation
- ❌ Never use extracted emails for any purpose other than Feedmine outreach

### Dependencies
- Python 3.11+ with aiohttp, requests, BeautifulSoup4, chardet
- Existing scripts: `feed_discovery/opml.py` (OPML read/write), `curate_opml_catalog.py` (catalog rebuild)
- Existing Swift infrastructure: OPMLParser, SQLiteCatalogCompiler, FeedSource models

## Future Considerations

- **Message generation:** DeepSeek-powered personalized outreach will be built as a separate project, consuming the contact data produced by this pipeline
- **Re-runnable:** Pipeline is designed for re-execution — new sources get processed, expired emails get re-validated
- **Continuous mode:** Can be extended with a cron trigger to process new feeds as they're added to the catalog
