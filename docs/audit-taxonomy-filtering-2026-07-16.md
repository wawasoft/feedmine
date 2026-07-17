# Audit: FeedMine Taxonomy Filtering & Performance

**Date:** 2026-07-16
**Branch:** `main` (commits `fd20db5d` and `8cea7569`)
**Scope:** Debugging session + performance optimization + UI test automation
**Tests:** 82 total (75 unit + 7 UI), all passing

---

## 1. Root Causes Fixed

### 1.1 OPML Parse Cache Fingerprint (CRITICAL)
- **File:** `feedmine/Services/OPMLParser.swift`
- **Before:** Fingerprint was `"5-1.0-1"` — version and build only. OPML files reorganized into subdirectories (`ae17b903`) but cache survived with stale `region=global` data.
- **After:** Fingerprint `"6-1.0-1-fc4534-mt..."` includes file count + newest mtime. `cacheFormatVersion` bumped 5→6.
- **Impact:** Acoustics sources had `region=global` instead of `region=topic/General`. Taxonomy tree was wrong. Node ID was `global/acoustics` instead of `general/acoustics`.

### 1.2 Race Condition: Pipeline vs Urgent Fetch
- **File:** `feedmine/Services/FeedStore.swift`
- **Before:** `applyUpdate(.flush())` runs `reloadFromSQLite` → `reservoir.seed()` which REPLACES visibleItems. Concurrently, `fetchUrgentTaxonomyBatch` adds items to `pendingReservoirItems` → `flushPendingReservoir()`. `flushPendingReservoir` only moves to visible when `visibleItems.isEmpty` — but pipeline already set visible items from SQLite. New items trapped in reservoir buffer.
- **After:** Added `filterGeneration` counter (Int64). Every async operation captures generation at launch. Pipeline (`flush`, `refresh`, `reloadFromSQLite`) checks generation before applying results. After urgent fetch, calls `applyUpdate(.refresh(generation:))` to force-sync items to visible.

### 1.3 SQL Query Missing www. Variants
- **File:** `feedmine/Services/FeedStore.swift` line ~1624
- **Before:** `reloadFromSQLite` taxonomy path generated only `[url, "\(url)/"]` variants. `www.aes.org/rss/` normalizes to `aes.org/rss` but item stored with original `www.aes.org/rss/` in SQLite — no match.
- **After:** Also generates `www.` prefix variants: `[url, "\(url)/", wwwURL, "\(wwwURL)/"]`.

---

## 2. Performance Optimizations Implemented

### 2.1 Quick Wins
| # | Change | File | Expected Impact |
|---|--------|------|-----------------|
| 1 | Remove `.scrollTransition(.animated(.spring(...)))` from FeedItemView | `FeedItemView.swift:38` | Eliminates per-frame GPU compositing during scroll |
| 2 | Pre-compute reverse taxonomy index `nodeToFeedURLs: [String: Set<String>]` | `TaxonomyStore.swift` | `feedURLs(inSubtreesOf:)` goes from O(276K × selectedNodes) to O(selectedNodes) |
| 3 | Pre-normalize sourceURL at persistence via `withNormalizedSourceURL` | `FeedItem.swift`, `FeedStore.swift` | Eliminates `OPMLParser.normalizeURL()` in `applyFilters` hot loop |
| 4 | Replace `localizedStandardContains` with `contains()` on pre-normalized text | `FeedStore.swift:279` | 5-10x faster content filter matching |
| 5 | Snapshot `isRead`/`isBookmarked` per-item via `setVisibleItems` stamping | `FeedItem.swift`, `FeedStore.swift`, `FeedItemView.swift` | Marking one item read no longer invalidates all card views |

### 2.2 Moderate Improvements
| # | Change | File | Expected Impact |
|---|--------|------|-----------------|
| 6 | `ForEach(0..<items.count)` instead of `ForEach(Array(items.enumerated()))` | `FeedScreen.swift:453` | Zero per-render array allocation |
| 7 | `Reservoir.seed()` interleave offloaded to `Task.detached` | `Reservoir.swift:48` | Interleave no longer blocks MainActor |
| 8 | Pre-compute `sectionDayOffset` at persistence time | `FeedItem.swift`, `FeedLoader.swift`, `FeedStore.swift` | Eliminates Calendar operations on every scroll-driven cache miss |

---

## 3. Tests Added

### 3.1 Unit Tests (14 new, 75 total)
| Test | Category | What it validates |
|------|----------|-------------------|
| `testAcousticsResolvesExactlyFourURLs` | Acoustics | Node ID = `general/acoustics`, 4 URLs resolved |
| `testAcousticsURLNormalizationVariants` | URL | www/http/trailing-slash converge to same identity |
| `testAcousticsEligibilityAllFourEnabled` | Eligibility | Category disabled + taxonomy selected → 4 pass |
| `testAcousticsEligibilityWithOneDisabled` | Toggle | 1 individually disabled → 3 pass |
| `testAcousticsSQLiteItemsLoadable` | SQLite | Items in DB loadable via taxonomy selection |
| `testAcousticsEndToEndLocalPipeline` | Pipeline | Full chain: URLs→eligible→visibleItems=4 |
| `testFilterGenerationPreventsStaleOverwrite` | Concurrency | Stale filter results don't overwrite fresh ones |
| `testSingleFeedCategoryResolution` | Single | Greek & Roman Mythology → 1 URL |
| `testManyFeedsCategoryResolution` | Many | Italy Podcasts → 20 URLs |
| `testPodcastCategoryFiltering` | Audio | NPR Wait Wait → isPodcast=true |
| `testVideoCategoryFiltering` | Video | YouTube Cooking → isYouTube=true |
| `testCountryCategoryFiltering` | Country | Algeria News → countries/ hierarchy |
| `testIndividuallyDisabledFeedBlockedUnderTaxonomy` | Toggle | ASA disabled → blocked even under taxonomy |
| `testCategoryWithNoItemsShowsEmptyState` | Empty | No SQLite items → 0 visible, loadingState=.idle |

### 3.2 UI Tests (7 tests)
All using real simulator (iPhone 14 Plus, iOS 26.5):

| Test | Search Term | Feeds | Time |
|------|-------------|-------|------|
| `testAcousticsFilterShowsAcousticsCards` | Acoustics | 4 | ~84s |
| `testSingleFeedCategoryShowsCard` | Greek & Roman Mythology | 1 | ~82s |
| `testPodcastCategoryShowsCards` | Humor & Comedy Websites | 7 | ~84s |
| `testVideoCategoryShowsCards` | YouTube — Cooking Channels | 1 | ~83s |
| `testCountryCategoryShowsCards` | Algeria | varies | ~83s |
| `testManyFeedsCategoryShowsCards` | Photography News & Reviews | 11 | ~86s |
| `testClearFiltersRestoresFullFeed` | Acoustics → Clear | — | ~90s |

Helper: `selectTaxonomyCategory(searchTerm:expectedKeywords:forbiddenSources:screenshotName:)` parameterizes the full flow.

---

## 4. Known Issues (Not Yet Fixed)

### 4.1 CRITICAL: `nodeToFeedURLs` Not Rebuilt on Cache Load
- **File:** `TaxonomyStore.swift` line ~426
- `loadFromCache` restores `flatIndex` and `feedToNodeID` but NOT `nodeToFeedURLs`. On warm start, `feedURLs(inSubtreesOf:)` returns `[]` — taxonomy filtering silently disabled.
- **Fix:** Rebuild reverse index at end of `loadFromCache` from `feedToNodeID`, or serialize it in `CachedTree`.

### 4.2 CRITICAL: `flushPendingReservoir` Race Against `.refresh`
- **File:** `FeedStore.swift` line ~1407
- `fetchUrgentTaxonomyBatch` calls `flushPendingReservoir()` (fires detached task) then `applyUpdate(.refresh)`. The refresh may run before the detached task's MainActor block — newly fetched items never become visible.
- **Fix:** Make `flushPendingReservoir` synchronous or await its completion before calling `.refresh`.

### 4.3 CRITICAL: Bookmark State Always False
- **File:** `FeedStore.swift` line 628
- `setVisibleItems` hardcodes `bookmarkItemIDs: []`. `FeedItemView` uses `item.isBookmarked` which is always false. Bookmark icon never shows filled state.
- **Fix:** Pass real bookmark IDs from `FeedLoader.bookmarkItemIDs` into `setVisibleItems`.

### 4.4 IMPORTANT: `http://` URL Variant Missing from SQL Query
- **File:** `FeedStore.swift` line ~1624
- SQL IN clause generates https variants only. Items stored before `withNormalizedSourceURL` was introduced have `http://` source URLs — silently excluded from taxonomy results.
- **Fix:** Also prepend `http://` variants. Self-heals after 30 days when old items expire.

### 4.5 IMPORTANT: `sectionDayOffset` DST Bug
- **File:** `FeedStore.swift` line 1198
- Uses `Int(diff / 86400)` — assumes 24h days. DST spring-forward has 23h days, causing items at 7-day boundary to show in wrong section. Offsets never decay (yesterday stays "Yesterday" forever).
- **Fix:** Use `Calendar.dateComponents([.day], ...)` for initial computation. Recompute offsets on each dateSections call for items with offset>0.

### 4.6 MODERATE: `.trim` Bypasses Generation Guard
- **File:** `FeedStore.swift` line ~697
- `.trim` case has no generation parameter. Stale trim from old pipeline can corrupt visible items after filter change.
- **Fix:** Add `generation: Int64` parameter to `.trim` and guard.

### 4.7 MODERATE: `loadedIDs` Seeded Before Generation Guard
- **File:** `FeedStore.swift` line 1668
- `reloadFromSQLite` adds IDs to `loadedIDs` BEFORE checking generation. If generation fails, IDs remain permanently, blocking future What's New promotion.
- **Fix:** Move `loadedIDs.insert` after the generation check.

### 4.8 PERFORMANCE: `cacheFingerprint` Walks 4534 Files Every Launch
- **File:** `OPMLParser.swift` line 34
- 50-200ms startup cost. Fingerprint never changes for a given build.
- **Fix:** Cache fingerprint in UserDefaults alongside the parse cache.

### 4.9 PERFORMANCE: `applyFilters` Calls `normalizeURL` on Already-Normalized Items
- **File:** `FeedStore.swift` line 257
- Items from `persistFetchedItems` already have normalized URLs via `withNormalizedSourceURL`. Redundant URLComponents parse per item per filter pass.
- **Fix:** Use `cachedTaxonomyFeedURLs.contains(item.sourceURL)` directly.

### 4.10 PERFORMANCE: `searchableText` Recomputed on Every Access
- **File:** `FeedItem.swift` line 63
- Computed property re-allocates 3 Strings per access. Called from `_contentFilterExcludes` for every item in every `applyFilters` pass.
- **Fix:** Make it a stored `let` computed in `init`.

---

## 5. Architecture Notes

### 5.1 FeedStore God Class (102KB)
- All state, DB writes, language detection, reservoir management, source health, filter persistence on `@MainActor`.
- **Future:** Extract subsystems (persistence, fetching, filtering) into actors or isolated classes.

### 5.2 Taxonomy URL Caching Duplication
- `cachedTaxonomyFeedURLs` in FeedStore (line 69) redundantly stores union of `nodeToFeedURLs` for current selection.
- Coherency maintained only by `filterGeneration` counter.

### 5.3 OPML Parse Cache Scale
- 4,534 OPML files → 39,697 unique sources → 18,197 duplicates
- Parse takes significant time on first launch; cache is critical for warm starts.

---

## 6. Deployment Commands

```bash
# Unit tests
xcodebuild test -project feedmine.xcodeproj -scheme feedmine \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus' \
  -only-testing:feedmineTests

# UI tests
xcodebuild test -project feedmine.xcodeproj -scheme feedmine \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus' \
  -only-testing:feedmineUITests

# Install on physical device
xcodebuild -project feedmine.xcodeproj -scheme feedmine \
  -destination 'platform=iOS,id=BBA4F656-A5EA-5D81-934E-E484ED71B8E2' \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device BBA4F656-A5EA-5D81-934E-E484ED71B8E2 \
  path/to/feedmine.app
```

---

## 7. Real Feed Status (Acoustics)

| Feed | HTTP | Content-Type | Size |
|------|------|-------------|------|
| acousticalsociety.org/rss/ | 403 | text/html | 5KB (blocked) |
| acousticstoday.org/feed/ | 200 | application/rss+xml | 26KB ✅ |
| acoustics.org/feed/ | 200 | application/rss+xml | 14KB ✅ |
| www.aes.org/rss/ | 200→redirect | application/rss+xml | 71KB ✅ |

3 of 4 feeds return valid RSS content.
