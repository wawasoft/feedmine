# OPML Link Verifier — Design Spec

**Date:** 2026-07-06
**Context:** feedmine iOS app — validate ~10,239 RSS/Atom feed URLs across ~122 OPML files in `feedmine/Resources/Feeds/`.

## Overview

A Python CLI tool that verifies feed URLs in OPML files at three configurable depth levels, with concurrent HTTP checking capable of processing thousands of links in minutes. Includes an in-place cleaning mode to remove dead feeds.

## CLI Interface

```
feedmine-verify [PATH] [OPTIONS]

PATH                  Directory with .opml files (default: feedmine/Resources/Feeds)

--depth LEVEL         Verification depth (default: 3)
                      1 = reachability only (HEAD/GET, check status)
                      2 = reachability + validate body is RSS/Atom XML
                      3 = reachability + validate XML + check freshness (<30d)

--concurrency N       Max simultaneous requests (default: 100)
--timeout SECONDS     Per-request timeout (default: 15)
--clean               Remove dead feeds from OPML files in-place
--output FILE.json    Write JSON report to FILE
--format FORMAT       Terminal output style: full | minimal | summary
--user-agent STRING   Custom User-Agent header
--retries N           Retries per URL on failure (default: 1)
--no-recursive        Skip subdirectories (e.g., countries/)
--help                Full help text with examples
```

### Examples

```bash
feedmine-verify --depth 1 --output report.json
feedmine-verify --depth 3 --concurrency 150 --clean --output report.json
feedmine-verify feeds/tech.opml --depth 2 --format minimal
```

## Architecture

```
feedmine_verify/
├── __init__.py
├── __main__.py          # python -m feedmine_verify
├── cli.py               # argparse setup, --help generation, dispatch
├── scanner.py           # walk directory, parse OPML, extract URLs + metadata
├── checker.py           # async HTTP engine, semaphore, retry, depth dispatch
├── verifiers.py         # depth 1-3 verification functions
├── cleaner.py           # --clean: rewrite OPML files in-place, strip dead feeds
├── reporter.py          # terminal output (rich) + JSON report writing
├── models.py            # dataclasses: Feed, CheckResult, Report
└── constants.py         # timeouts, defaults, user-agent
```

### Data Flow

```
OPML files ──[scanner]──▶ List[Feed] ──[checker]──▶ List[CheckResult]
                                                      │
                                              ┌───────┴───────┐
                                              ▼               ▼
                                        [reporter]       [cleaner]
                                     terminal + JSON    rewrites .opml
```

### Key Decisions

- **Scanner** collects all feeds up front so the progress bar knows total count immediately.
- **Checker** uses `asyncio.Semaphore` for concurrency control + `aiohttp.ClientSession` with connection pooling.
- **Cleaner** parses original OPML XML, removes failing `<outline>` nodes, overwrites with preserved formatting.
- **Models** are plain `@dataclass` types for testability.

## Verification Pipeline

Each depth level runs the previous checks first, stopping on first failure:

### Depth 1 — Reachability
- HEAD request, follow redirects, check 2xx status
- If HEAD rejected, fall back to GET (some servers block HEAD)
- Record: `status_code`, `redirect_chain`, `response_time_ms`

### Depth 2 — Content Validity
- GET first 64KB of body
- Parse as XML, check for `<rss>`, `<feed>`, or `<rdf:RDF>` root element
- Record: `content_type`, `body_size`, `is_valid_feed`

### Depth 3 — Freshness
- Parse the feed, extract most recent `<pubDate>`, `<published>`, or `<updated>`
- Flag as stale if newest post > 30 days old
- Flag as warning if no dates found
- Record: `newest_post_date`, `days_since_last_post`, `freshness_status`

### Result Classification

| Status       | Meaning                                         |
|-------------|-------------------------------------------------|
| `ok`         | All checks passed                               |
| `redirected` | 3xx → 2xx, final URL recorded                   |
| `stale`      | Reachable + valid, but no recent posts (depth 3) |
| `invalid`    | Reachable but not a valid feed                   |
| `timeout`    | No response within timeout window                |
| `dead`       | 4xx/5xx, connection refused, DNS failure         |
| `error`      | Unexpected exception (with traceback)            |

## Error Handling

### Network Errors
- Connection refused, DNS failure, TLS error, reset → classify as `dead`
- Retry once after 1s delay (configurable via `--retries`)

### HTTP Errors
- 429 (rate limit): respect `Retry-After` header, retry once
- 403/401: mark `dead`, do not retry
- 5xx: retry once, then mark `dead`

### Malformed OPML
- Log warning with filename + line, skip broken entry, continue
- Unparseable file → skip entirely, report in JSON errors array

### Edge Cases
- **Duplicate URLs** across files → check once, link result to all source locations
- **Empty OPML file** → skip with note
- **Non-OPML XML** in directory → skip, warn
- **Non-HTTP schemes** in xmlUrl → skip, warn
- **Large responses** → read only first 64KB for content validation
- **Ctrl+C** → save partial JSON report before exiting
- **Mixed quote styles** in OPML → handled by XML parser, not regex

### Concurrency Safety
- Cleaner writes are serialized after all checks complete — no file write races
- Single `aiohttp.ClientSession` shared across all checks
- Semaphore prevents resource exhaustion
- `asyncio.gather(return_exceptions=True)` so one failure doesn't crash the batch

## Report Formats

### Terminal Output (rich)
- Live progress bar with URL count, ETA, current status distribution
- Colored per-status indicators (green = ok, red = dead, yellow = stale/warn)
- Final summary table grouped by OPML file
- Three detail modes: `full` (per-URL), `minimal` (failures only), `summary` (counts only)

### JSON Report
```json
{
  "metadata": {
    "timestamp": "2026-07-06T...",
    "depth": 3,
    "concurrency": 100,
    "timeout": 15,
    "total_feeds": 10239,
    "duration_seconds": 87.3
  },
  "summary": {
    "ok": 8234,
    "redirected": 512,
    "stale": 189,
    "invalid": 67,
    "timeout": 143,
    "dead": 1094
  },
  "results": [
    {
      "url": "https://...",
      "title": "Ars Technica",
      "source_files": ["tech.opml"],
      "status": "ok",
      "status_code": 200,
      "response_time_ms": 342,
      "redirect_chain": [],
      "content_type": "application/rss+xml",
      "body_size": 52831,
      "is_valid_feed": true,
      "newest_post_date": "2026-07-05T...",
      "days_since_last_post": 1,
      "freshness_status": "fresh"
    }
  ],
  "errors": [
    {"file": "broken.opml", "error": "XML parse error at line 5"}
  ]
}
```

## Dependencies

- **Python 3.10+** (match statement, dataclass slots)
- `aiohttp` — async HTTP client with connection pooling
- `rich` — terminal progress bars, tables, colored output
- `lxml` (optional) — faster XML parsing; falls back to stdlib `xml.etree`

## Testing Strategy

- Unit tests for scanner (OPML parsing), verifiers (depth 1-3 logic), models
- Integration tests with a local HTTP server serving known-good and known-bad feeds
- CLI integration tests via `subprocess` on test OPML fixtures
- Performance: ensure 1,000 URLs complete in under 30 seconds at depth 1

## Out of Scope

- Daemon/monitoring mode (one-shot CLI only)
- Email/Slack notifications
- Authentication support for private feeds
- OPML generation (read-only, except `--clean` which strips entries)
