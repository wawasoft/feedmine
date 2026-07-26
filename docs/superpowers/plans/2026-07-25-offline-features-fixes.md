# Offline Features — Bug Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix Critical and High-severity bugs discovered during the 6-loop systematic review of the `offline-features` branch, stabilizing the app for merge to `main`.

**Architecture:** Work in priority order (P0 → P1) grouped by component. Each component is an independent workstream. Fixes within a component are ordered by dependency. Every task produces independently testable changes verified by the existing 287-unit-test suite.

**Tech Stack:** Swift 6, SwiftUI, GRDB 7.4, iOS 18+, Xcode 26

**Baseline:** 287 tests, 2 pre-existing failures (`testBundledStarterCatalog` — catalog not in test env, unrelated to this branch)

## Global Constraints

- All changes must keep the existing 285 test suite passing
- No new warnings under `SWIFT_STRICT_CONCURRENCY = complete`
- Follow existing code patterns (weak self in Tasks, @MainActor where needed, GRDB patterns)
- One fix per commit, with descriptive message
- Test after each task: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=26.5' -only-testing:feedmineTests`

---

## P0 — Critical (4 issues)

### P0-1: TaxonomyStore — Missing `languages/` region handler

**Severity:** Critical
**File:** `feedmine/Services/TaxonomyStore.swift:222-320`
**Issue:** `derivePath` has no handler for regions starting with `"languages/"`. Feeds with `region = "languages/spanish"` produce zero path segments and attach to root node. `searchRank` (line 437) references `"languages"` scope but the path derivation is missing.

**Task:** Add `"languages/"` branch to `derivePath` mirroring the `"countries/"` pattern.

---

### P0-2: SettingsSheetView — "Reset Everything" button does nothing

**Severity:** Critical
**File:** `feedmine/Views/SettingsSheetView.swift:248-251`
**Issue:** The destructive "Reset Everything" button has an empty action block. Users tap it, the confirmation dialog dismisses, and nothing happens — dead UX.

**Task:** Either wire up actual reset logic (clear read history + bookmarks + source config) or disable/hide the button until implementation is ready.

---

### P0-3: ContentSanitizer — Regex-based HTML sanitization is fundamentally insecure

**Severity:** Critical
**File:** `feedmine/Services/ContentSanitizer.swift:116-132`
**Issue:** The sanitizer uses regex to strip HTML, but HTML is not a regular language. Known bypasses: unquoted event handlers (`onerror=alert(1)`), `<base>` injection, `<meta>` refresh redirect, `javascript:` protocol in links, `<noscript>`/`<embed>`/`<object>` elements.

**Task:** Replace regex sanitization with a proper HTML parser (SwiftSoup) or an allowlist-based approach. At minimum, add the missing element/attribute removals as an interim hardening.

---

### P0-4: CatalogUpdateService — Backup destroyed before replacement verified

**Severity:** Critical
**File:** `feedmine/Services/CatalogUpdateService.swift:378-396`
**Issue:** `activate()` deletes the old backup (`removeItem(at: backupURL)`) BEFORE creating the new one (`moveItem(at: currentURL, to: backupURL)`). If `moveItem` fails, both `backupURL` and `currentURL` are gone — **complete data loss** with no recovery path.

**Task:** Reorder: move current → backup FIRST (overwriting if needed), THEN stage → current. Never delete the backup before the new one is confirmed.

---

## P1 — High (32 issues)

### Workstream A: FeedStore Concurrency & Memory

#### Task A1: Add `[weak self]` to closures passed to whatsNewManager

**File:** `feedmine/Services/FeedStore.swift:2349-2400`
**Issue:** 8 closures passed to `whatsNewManager` use `[self]` (strong capture). These are `@escaping` and stored inside `Task` objects in `WhatsNewManager`, creating retain cycles that keep `FeedStore` alive for the full network fetch duration.

**Fix:** Change `[self]` to `[weak self]` in closures at lines 2349, 2352, 2358, 2364, 2374-2378, 2386-2387, 2399, 2400.

---

#### Task A2: Add `[weak self]` to bookmarkStore closure captures

**File:** `feedmine/Services/FeedStore.swift:3847, 4209`
**Issue:** Two closures passed to `bookmarkStore` use `[self]` strong capture.

**Fix:** Change to `[weak self]` with guard-let at lines 3849 and 4211.

---

#### Task A3: Guard `_sharedDB` IUO in `sharedDB()`

**File:** `feedmine/Services/FeedStore.swift:11-15`
**Issue:** `_sharedDB` is an implicitly unwrapped optional that crashes if accessed before any FeedStore instance exists. The empty `MainActor.run {}` does nothing useful.

**Fix:** Add `guard let db = _sharedDB else { fatalError("FeedStore.sharedDB() called before init") }` or make `sharedDB()` throw.

---

#### Task A4: Add `[weak self]` to `refreshPodcastCounts` Task

**File:** `feedmine/Services/FeedStore.swift:62-73`
**Issue:** Fire-and-forget `Task {}` mutates `@MainActor` properties without `[weak self]`.

**Fix:** Add `[weak self]` and guard-let.

---

#### Task A5: Fix duplicate `imageRepairs` loop in `persistFetchedItems`

**File:** `feedmine/Services/FeedStore.swift:2446-2451, 2511-2516`
**Issue:** Same `for repair in imageRepairs` loop appears twice — once in the early-return guard path and once in the batch `db.write`. DRY violation; changing one copy won't change the other.

**Fix:** Extract into a private helper method.

---

#### Task A6: Add logging on count mismatch discard in `persistFetchedItems`

**File:** `feedmine/Services/FeedStore.swift:2480-2484`
**Issue:** If `actualNew.count`, `regions.count`, and `resolvedLanguages.count` don't match, the entire batch is silently discarded. No retry, no user feedback.

**Fix:** Add `Log.feed.error` with the actual mismatched counts before returning `[]`.

---

### Workstream B: DownloadManager Actor Safety

#### Task B1: Fix actor re-entrancy race between `cancel()` and `processOne()`

**File:** `feedmine/Services/DownloadManager.swift:169-204, 520-692`
**Issue:** `cancel()` and `processOne()` both independently adjust `_storageUsed`. Actor suspension points allow interleaving: `processOne` writes files + adds to `_storageUsed`, `cancel` reads old DB state + subtracts stale values, `processOne` returns — `_storageUsed` is permanently wrong.

**Fix:** Gate `cancel()` with a per-item flag. If `processOne` is active for that `itemID`, defer the storage adjustment. Use `activeTasks[itemID]` presence as the signal.

---

#### Task B2: Replace `try?` with logged errors at 6 critical DB write sites

**File:** `feedmine/Services/DownloadManager.swift:536, 562, 570, 578, 587, 676`
**Issue:** All DB write failures are silently discarded. In-memory caches and DB diverge, surviving process restarts.

**Fix:** Replace `try?` with `do/catch` that logs the error and specific context (which phase, itemID).

---

#### Task B3: Remove fire-and-forget `Task` from `status(for:)`

**File:** `feedmine/Services/DownloadManager.swift:215-220`
**Issue:** Every non-cached `status(for:)` call spawns a new unstructured `Task`. 100 List cells = 100 Tasks competing for the actor.

**Fix:** Remove the Task spawn. Document that callers must use the async path (`loadStatusFromDB`) for uncached lookups. Or add a debounced batch preload.

---

#### Task B4: Add `onTermination` handler to `notificationContinuation`

**File:** `feedmine/Services/DownloadManager.swift:55, 69-71`
**Issue:** When the consumer stops iterating `notifications`, the continuation terminates silently. All future `notify()` calls silently drop events — the notification-driven UI permanently dies with no diagnostics.

**Fix:** Add `onTermination` handler that logs the termination reason.

---

### Workstream C: BookmarkStore

#### Task C1: Remove `@MainActor` from BookmarkStore

**File:** `feedmine/Services/BookmarkStore.swift:4`
**Issue:** `@MainActor` annotation causes synchronous DB reads to block the main thread. `allBookmarkedItemIDs()` is called from `FeedStore.cachedSourceItems()` on the main actor.

**Fix:** Remove `@MainActor`. Callers already use `async/await`.

---

#### Task C2: Make `clearAllBookmarks` async throws

**File:** `feedmine/Services/BookmarkStore.swift:158-171`
**Issue:** Fire-and-forget `Task` returns before deletion completes. Two concurrent calls race. No error propagation. No cross-database transaction.

**Fix:** Make the method `async throws`. Remove the inner `Task`. Use a single `userDB.write` + `contentDB.write` with proper error propagation.

---

#### Task C3: Fix `toggleSearchActive` read-then-write race

**File:** `feedmine/Services/BookmarkStore.swift:143-156`
**Issue:** `wasActive` is read in one transaction, `newState` is written in another. Two concurrent toggles can both read the same value and produce the same output.

**Fix:** Move read and write into a single `userDB.write` block.

---

#### Task C4: Fix `synchronizeRetentionPins` crash-window data loss

**File:** `feedmine/Services/BookmarkStore.swift:178-196`
**Issue:** `DELETE FROM bookmark_item` followed by individual re-inserts. Crash between delete and last insert = permanent data loss.

**Fix:** Batch all inserts into a single statement. Or use a temp table + atomic rename.

---

#### Task C5: Guard force-unwrapped optional IDs

**File:** `feedmine/Services/BookmarkStore.swift:36, 38, 247, 313, 368`
**Issue:** Five `r.id!` force-unwraps crash on corrupt/NULL data.

**Fix:** Replace with `guard let id = r.id else { throw BookmarkError.corruptData }`.

---

#### Task C6: Invalidate `_defaultListID` cache on list deletion

**File:** `feedmine/Services/BookmarkStore.swift:12, 21-28`
**Issue:** Cached default list ID is never invalidated. After deletion, stale cache points to nonexistent list.

**Fix:** Set `_defaultListID = nil` in `deleteBookmarkList` and `createBookmarkList`.

---

### Workstream D: ImageCache

#### Task D1: Fix `cachedImageData` blocking MainActor

**File:** `feedmine/Services/ImageCache.swift:459-464`
**Issue:** `cachedImageData(for:)` is `nonisolated` but performs `Data(contentsOf:)` — blocking I/O that can be called from `@MainActor` via `AudioPlayerManager`.

**Fix:** Make it `async` using `FileHandle` or `Data(contentsOf:options:)` with async/await.

---

#### Task D2: Fix `didWriteToDisk` synchronous I/O on MainActor

**File:** `feedmine/Services/ImageCache.swift:684-709`
**Issue:** `contentsOfDirectory` + `removeItem` run synchronously on MainActor. Evicting hundreds of files can block the main thread.

**Fix:** Move file enumeration and deletion to a `Task.detached(priority: .background)`.

---

#### Task D3: Downsample images in `setImage(_:for:)` before caching

**File:** `feedmine/Services/ImageCache.swift:560-574`
**Issue:** `setImage(_:for:)` stores caller-provided `UIImage` directly in `NSCache` with no downsampling. A 4032×3024 photo consumes ~48MB per entry.

**Fix:** Downsample using `ImageIO` (same as `setImage(data:for:maxDimension:)`) before inserting into `memoryCache`.

---

### Workstream E: ExportEngine & CatalogUpdateService

#### Task E1: Replace `try?` with proper error handling in ExportEngine

**File:** `feedmine/Services/ExportEngine.swift:129, 474`
**Issue:** `try? encoder.encode(backup) ?? Data()` — returns 0-byte corrupt backup on any encode failure. `try? data.write(to:)` — returns file URL pointing to nonexistent file.

**Fix:** Throw errors properly. Let callers decide error presentation.

---

#### Task E2: Make ExportEngine methods async

**File:** `feedmine/Services/ExportEngine.swift` (all methods)
**Issue:** All methods are synchronous static functions called on `@MainActor`, blocking UI during large exports.

**Fix:** Annotate with `nonisolated` or move to `Task.detached`. Use `await` in callers.

---

#### Task E3: Fix CatalogUpdateService `activate()` ordering

**File:** `feedmine/Services/CatalogUpdateService.swift:378-396`
**Issue:** Same as P0-4 — backup deleted before replacement verified. Also: non-atomic `moveItem` can leave `currentURL` inconsistent after crash, orphaned backup is never restored.

**Fix (3-part):** (a) Move current → backup first (overwrite). (b) Use `replaceItemAt` for atomic staging → current. (c) In `activeSnapshot`, check backup when current is missing.

---

### Workstream F: NetworkMonitor & RSSFetcher

#### Task F1: Fix `isAirplaneMode` heuristic

**File:** `feedmine/Services/NetworkMonitor.swift:27`
**Issue:** `availableInterfaces.isEmpty` is not airplane mode. False positives on Macs with Wi-Fi off, false negatives on iOS with Wi-Fi left enabled in airplane mode.

**Fix:** Replace with combination of `path.status == .unsatisfied` AND absence of `.cellular` interface. Document that true airplane mode detection requires `SCNetworkReachability`. For now, improve the heuristic.

---

#### Task F2: Cancel in-flight fetches efficiently in RSSFetcher

**File:** `feedmine/Services/RSSFetcher.swift:182-183, 201-202, 209-210`
**Issue:** `group.cancelAll()` + `break` then `withTaskGroup` exits → implicitly awaits all cancelled tasks. `URLSession.data` tasks don't preempt TCP connections; cancellation can block up to 15s timeout.

**Fix:** Add explicit `Task.checkCancellation()` inside the fetch loop. Replace `URLSession.shared.data(from:)` with cancellable variant.

---

### Workstream G: Views

#### Task G1: Fix `hasAnyDownloads` sync I/O in FeedScreen

**File:** `feedmine/Views/FeedScreen.swift:71-74`
**Issue:** `contentsOfDirectory(atPath:)` is synchronous blocking disk I/O evaluated every body recomputation.

**Fix:** Replace with `DownloadManager.shared.storageUsed() > 0` (cached, O(1)). Make the check a `@State` populated via `.task`.

---

#### Task G2: Fix Equatable `==` omitting `@State` in FeedItemCardView

**File:** `feedmine/Views/FeedItemCardView.swift:7-12`
**Issue:** `.equatable()` uses `==` that omits `imageLoadFailed` and `imageAppeared`. When image loading state changes, `==` returns true → SwiftUI skips body → transition never renders.

**Fix:** Either include the `@State` properties in `==` or remove `.equatable()`.

---

#### Task G3: Add download state visibility to FeedItemCardView

**File:** `feedmine/Views/FeedItemCardView.swift:454-486`
**Issue:** Zero visual indication of download state (queued/downloading/completed/failed). Users can tap "Download for Offline" on already-downloaded items. No badge/progress.

**Fix:** Add context-menu item showing current state. Add a small badge (checkmark/spinner/X) based on `DownloadManager.shared.status(for:)`.

---

#### Task G4: Fix `saveRule`/`loadRule` missing `@MainActor`

**File:** `feedmine/Views/SourceManagementView.swift:348, 366`
**Issue:** Both methods access `@State` after `await` without `@MainActor` annotation. Under Swift 6 strict concurrency, this crashes.

**Fix:** Annotate both `@MainActor`.

---

#### Task G5: Fix silent DB error swallowing in `saveRule`/`loadRule`

**File:** `feedmine/Views/SourceManagementView.swift:361-363, 382-384`
**Issue:** All DB read/write errors silently discarded. UI toggles appear successful but settings revert.

**Fix:** Surface errors via an `@State var ruleError: String?` displayed as inline banner.

---

#### Task G6: Debounce concurrent `saveRule` calls

**File:** `feedmine/Views/SourceManagementView.swift:343-345`
**Issue:** Three `.onChange` modifiers each independently fire `Task { await saveRule() }`. Rapid changes can produce stale writes.

**Fix:** Store a `Task` reference, cancel before starting a new save. Use a single `onChange` on a combined model struct.

---

### Workstream H: SearchEngine & MomentGreeting

#### Task H1: Fix SQL `LIMIT 180` before relevance sort

**File:** `feedmine/Services/SearchEngine.swift:142-157`
**Issue:** SQL fetches 180 items ordered by date, then client re-sorts for relevance. If DB has >180 matches, unread items published earlier are excluded before the client sort runs.

**Fix:** Push the read-status ordering into SQL as a secondary sort (`ORDER BY is_read ASC, published_at DESC`), then apply `LIMIT` after both sorts.

---

#### Task H2: Fix per-chunk `LIMIT 40` dropping saved-item matches

**File:** `feedmine/Services/SearchEngine.swift:110-131`
**Issue:** Each 400-ID chunk has its own `LIMIT 40`. If one chunk has 45 matches, 5 are silently dropped. Final `prefix(40)` only sees survivors.

**Fix:** Remove per-chunk `LIMIT 40`. Keep only the final `prefix(40)`.

---

#### Task H3: Fix duplicate `while` condition in MomentGreeting

**File:** `feedmine/Services/MomentGreeting.swift:519`
**Issue:** `while result.hasSuffix(" ·") || result.hasSuffix(" ·")` — both conditions are identical. Second was meant to be `"· "`.

**Fix:** Change second condition to `result.hasSuffix("· ")`.

---

### Workstream I: Other High-Severity

#### Task I1: Fix AudioPlayerManager `assumeIsolated` crash risk

**File:** `feedmine/Services/AudioPlayerManager.swift:106, 115`
**Issue:** `MainActor.assumeIsolated` crashes if notification arrives off-main-thread.

**Fix:** Replace with `await MainActor.run { ... }`.

---

#### Task I2: Fix AudioPlayerManager `MPNowPlayingInfoCenter` from background

**File:** `feedmine/Services/AudioPlayerManager.swift:195`
**Issue:** `MPNowPlayingInfoCenter.default().nowPlayingInfo = updated` inside `Task.detached` — writes from background thread.

**Fix:** Wrap in `await MainActor.run { ... }`.

---

#### Task I3: Fix ArticleReaderView concurrent `loadContent` race

**File:** `feedmine/Views/ArticleReaderView.swift:89-114`
**Issue:** Two Tasks can run concurrently for the same `WKWebView`. Last writer wins — user sees stale content.

**Fix:** Store in-flight Task in Coordinator. Cancel before spawning new one.

---

### Workstream J: SettingsSheetView

#### Task J1: Fix silent storage limit overwrite on settings open

**File:** `feedmine/Views/SettingsSheetView.swift:331-333`
**Issue:** If `manager.storageLimit` is not in the picker array, `firstIndex` returns nil → fallback index 2 (2 GB) → `.onChange` fires and silently overwrites to 2 GB.

**Fix:** Clamp to nearest limit instead of using index-based picker, or show the actual byte value.

---

#### Task J2: Prevent `.onChange` firing during initial load

**File:** `feedmine/Views/SettingsSheetView.swift:449-465`
**Issue:** `loadSettings()` sets `@State` → triggers `.onChange` → writes back same value to actor.

**Fix:** Add `var isInitialLoad = true` guard in each `onChange` handler.

---

## P2 — Medium (50+ issues)

Summary-level. Detailed task plans available in individual review reports.

| Component | Key Issues | Est. Effort |
|-----------|-----------|-------------|
| FeedStore | `prefetchImagesIfEnabled`/[`prefetchUpcoming` missing weak self, `capSourceItemsBatch` stale dedup, `try!` in `empty()`, synchronous DB read on main actor | 3-4 tasks |
| DownloadManager | `loadCachesFromDB` redundant casts, `enforceStorageLimit` over-eviction by 1, `try?` in image copy loop | 2 tasks |
| BookmarkStore | `deleteBookmarkList` silently no-ops on default, individual INSERTs in loops, N+1 query in `allBookmarkLists`, cross-database `synchronizeRetentionPin` | 3 tasks |
| ExportEngine | Cache `DateFormatter` instances, fix OPML `dateCreated` spec violation, temp file cleanup, string `+=` inefficiency | 3 tasks |
| ImageCache | `try!` on 6 regex patterns, disk cache no eviction on launch, busy-wait polling loop, EXIF orientation ignored | 3 tasks |
| OPMLParser | Blocking `Data(contentsOf:)` in task group, unbounded file read, `extractLanguage` raw-byte scan, cache fingerprint ignores file count, `perFile` array memory | 4 tasks |
| CatalogUpdateService | OOM on large manifest, no retry on transient errors, orphaned staging accumulation, `revisionCollision` terminal, rollback silently refused | 4 tasks |
| NetworkMonitor | Optimistic `isConnected = true`, `stop()` kills monitor permanently, `snapshot()` omits `wasDisconnected`, `isExpensive` never observable | 3 tasks |
| TaxonomyStore | `Dictionary(uniqueKeysWithValues:)` crash on duplicate, `sortedChildrenCache` unbounded growth, `isFeedInSubtree` string prefix, `coverageGroups` `@ObservationIgnored`, `build()` blocking `async` | 3 tasks |
| SourceRegistry | `isSourceEnabled` returns false for unknown URLs (by design, but needs documentation) | 1 task |
| ImportPipeline | `@unchecked Sendable` on delegate, optional return never nil, `extractTitle` XML fragility | 2 tasks |
| UserStateStore | TOCTOU race in migration check, `Date()` in write loops, `source.url` vs `source.feedURL` inconsistency | 2 tasks |
| MomentGreeting | `loadTemplates` sync I/O on MainActor, substring scoring inflates, static mutable state | 2 tasks |
| SearchEngine | Bare `"` FTS syntax error, catalog DB open failure silent | 2 tasks |
| Views | FilterSheetView download toggle bypasses draft pattern, FeedItemCardView landscape card missing fade-in, `UIImpactFeedbackGenerator` per-render | 3 tasks |
| UITests | Card loops always tap first card, 15+ hardcoded sleeps, duplicate Phase 3 block, missing assertions | 5 tasks |

---

## P3 — Low (100+ issues)

Code style, minor optimizations, documentation gaps. Suitable for gradual cleanup. Not blocking merge.

---

## Execution Order

### Sprint 1 (Focused — ~2-3 days)
1. **P0-1** (TaxonomyStore `languages/` handler)
2. **P0-4** + **E3** (CatalogUpdateService atomic replacement)
3. **P0-2** (SettingsSheetView Reset button)
4. **P0-3** (ContentSanitizer HTML parser — may span sprints)

### Sprint 2 (Concurrency — ~3-4 days)
5. **A1-A4** (FeedStore weak self + IUO + imageRepairs)
6. **B1-B2** (DownloadManager re-entrancy + try? logging)
7. **C1-C4** (BookmarkStore @MainActor + async + races + crash-window)

### Sprint 3 (I/O & Thread Safety — ~2-3 days)
8. **D1-D3** (ImageCache async I/O + downsampling)
9. **E1-E2** (ExportEngine throws + async)
10. **F1-F2** (NetworkMonitor heuristic + RSSFetcher cancellation)
11. **G1-G2** (FeedScreen hasAnyDownloads + FeedItemCardView Equatable)

### Sprint 4 (Views & UX — ~2-3 days)
12. **G3-G6** (Download state visibility + SourceManagementView fixes)
13. **H1-H3** (SearchEngine limits + MomentGreeting duplicate while)
14. **I1-I3** (AudioPlayerManager + ArticleReaderView)
15. **J1-J2** (SettingsSheetView picker + onChange)

### Sprint 5+ (P2/P3 — ongoing)
16. P2 issues by component (see table above)
17. P3 cleanup

---

**Total estimated effort:** ~12-16 developer-days for P0+P1, ~10-15 days for P2, ongoing for P3.
