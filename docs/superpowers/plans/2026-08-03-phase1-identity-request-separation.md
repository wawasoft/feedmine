# Phase 1: Identity/Request URL Separation (P0-01)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development

**Goal:** Fix P0-01 — all import paths must preserve the fetchable request URL (with auth/signed params) while using canonical identity for dedup.

**Architecture:** `FeedSource.url` becomes the fetchable request URL. `FeedSource.id` becomes `normalizeURL(url)`. Import paths use `OPMLParser.requestURL(raw)` for storage and `OPMLParser.normalizeURL(raw)` for identity comparisons. Follows the existing `SourceReference` pattern.

**Tech Stack:** Swift 5, XCTest, xcodebuild simulator

## Global Constraints

- iOS 18.0+, iPhone simulator
- Swift strict concurrency complete
- All existing tests must continue to pass
- Identity comparisons use `OPMLParser.normalizeURL`
- Fetch URLs preserved via `OPMLParser.requestURL`

---

### Task 1: Fix FeedSource.id to use normalized URL

**Files:**
- Modify: `feedmine/Models/FeedSource.swift:12`

**Fix:**
Change `var id: String { url }` to `var id: String { OPMLParser.normalizeURL(url) }`

This makes identity stable: two FeedSources with equivalent URLs (http vs https, www prefix, trailing slash) share the same identity.

---

### Task 2: Fix ImportPipeline.ingest(urls:) to preserve requestURL

**Files:**
- Modify: `feedmine/Services/ImportPipeline.swift:59-137`

**Changes:**
1. Use `OPMLParser.requestURL(rawURL)` for the stored FeedSource.url
2. Use `OPMLParser.normalizeURL(rawURL)` for identity/dedup
3. Add mutable `seenIdentities` set for batch dedup (prevent duplicates within same batch)
4. Probe the requestURL, not the normalized URL

---

### Task 3: Fix ImportPipeline.ingest(opmlData:) to preserve requestURL

**Files:**
- Modify: `feedmine/Services/ImportPipeline.swift:139-227`

**Changes:**
1. Non-validate path: store `OPMLParser.requestURL(source.url)` instead of `OPMLParser.normalizeURL(source.url)`
2. Validate path: pass requestURL through to ingest(urls:)
3. OPMLImportDelegate: store raw xmlUrl (already correct — it preserves the raw URL)

---

### Task 4: Fix FeedLoader.importFeeds skipValidation path

**Files:**
- Modify: `feedmine/Services/FeedLoader.swift:1345-1377`

**Changes:**
1. Use `OPMLParser.requestURL(rawURL)` for FeedSource.url
2. Use `OPMLParser.normalizeURL(rawURL)` for dedup against existingURLs
3. Add batch dedup with mutable seen set

---

### Task 5: Fix persistImportedSources empty-state and atomic write (P0-04 partial)

**Files:**
- Modify: `feedmine/Services/FeedLoader.swift:1456-1467`

**Changes:**
1. Delete JSON file when imported sources are empty (don't leave stale file)
2. Use `.atomic` write option

---

### Task 6: Create identity/request URL contract tests

**Files:**
- Create: `feedmineTests/IdentityContractTests.swift`

**Tests (using xcodebuild + iPhone simulator):**
1. Signed query fields survive paste import via importFeeds
2. Signed query fields survive OPML import via importOPML
3. Two signed aliases deduplicate by identity while retaining valid request URL
4. skipValidation preserves the request URL
5. Removing volatile parameter changes neither identity nor fetch URL
6. Import result ordering and duplicate reporting remain deterministic
7. Batch dedup: same URL twice in batch only imports once
8. Empty imported sources deletes the JSON file
