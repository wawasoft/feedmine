# FeedMine Test Architecture

**Generated:** 2026-08-01T21:29 PDT
**Commit:** af77069a (main, clean working tree)
**Xcode:** 26.6 (17F113)
**Swift:** 6.3.3 (arm64-apple-macosx26.0)
**macOS:** 26.3.1 (25D2128)
**Architecture:** arm64

---

## 1. Container, Scheme, Targets, and Destinations

| Property | Value |
|---|---|
| Container | `feedmine.xcodeproj` (no .xcworkspace) |
| Scheme | `feedmine` (shared) |
| Targets | feedmine (app), feedmineTests (unit), feedmineUITests (UI) |
| Configurations | Debug, Release |
| Deployment target | iOS 18.0 |
| Device family | iPhone only |
| UI Framework | **SwiftUI** (confirmed via `@main App`, `WindowGroup`, `@Observable`) |
| Persistence | **GRDB 7.4.0** (SQLite + FTS5) |
| Feed parsing | **FeedKit 9.1.2** (RSS/Atom/JSON Feed) |
| Concurrency | Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`) |
| Dependency manager | SPM (packages resolved in .build-dd/.build-device) |
| Supported locales | 40 languages including ar, he, hi, ja, ko, th, zh-Hans, zh-Hant |
| Bundle ID | com.feedmine.app |
| Signing | Automatic (Team: 955573A4YH) |

### Available Destinations

| Type | Name | Identifier |
|---|---|---|
| Simulator | iPhone 14 Plus | D2051E53-70FB-4258-8091-33ED6C671822 |
| Simulator | Wawa App Store 6.9 | 20936611-9BF0-4ADC-B0B0-2B6060C56C0E |
| Device | iPhone 14 Plus | 00008110-00067D861486201E |
| Device | iPhone 15 | 00008120-000260903ED1A01E |

---

## 2. Critical Flow Diagram

```
App Launch (FeedmineApp)
  │
  ├─► FeedScreen (root view)
  │     ├─► FeedLoader (@Observable view model)
  │     │     ├─► FeedStore (GRDB DatabaseQueue)
  │     │     │     ├─► OPMLParser → FeedSource[] (bundled OPML catalog, 34K+ sources)
  │     │     │     ├─► RSSFetcher → FeedItem[] (FeedKit-based fetch)
  │     │     │     ├─► Reservoir (in-memory interleave buffer)
  │     │     │     ├─► SourceScheduler (entropy-based fetch selection)
  │     │     │     ├─► SearchEngine (FTS5 over sources/tags/items)
  │     │     │     ├─► CardPreparationCoordinator → ReadyCardQueue (pre-resolved cards)
  │     │     │     ├─► ImageLoader / ImageCache (DiskImageCache + MemoryImageCache)
  │     │     │     ├─► AudioPlayerManager (AVPlayer-based)
  │     │     │     ├─► BookmarkStore / UserStateStore
  │     │     │     ├─► TaxonomyStore (hierarchical content categories)
  │     │     │     └─► MediaAssetStore
  │     │     └─► visibleItems: [FeedItem], visibleCards: [FeedCardPresentation]
  │     │
  │     ├─► Timeline (List/ScrollView of FeedItemCardView)
  │     ├─► CatalogExploreView → CatalogBrowserViewModel → SQLiteCatalogStore
  │     ├─► Search (SearchEngine via FTS5)
  │     ├─► SourceManagementView (per-source feed history)
  │     ├─► ArticleReaderView (WkWebView-based content reader)
  │     ├─► MiniPlayerBar (audio player mini-controls)
  │     ├─► SettingsSheetView (preferences, filters, export)
  │     ├─► Onboarding (CuratedOnboardingView with Intent/Topics/Language scenes)
  │     └─► FilterSheetView → ContentFilter + TaxonomyChipBar
  │
  ├─► CircadianEngine (time-of-day theme: dawn/morning/afternoon/evening/night)
  ├─► LocaleManager (40-language support)
  ├─► BackgroundRefreshService (BGTaskScheduler)
  └─► NetworkMonitor (offline detection)
```

---

## 3. Key Implementation Points

### App Entry & First Frame
- **File:** `feedmine/feedmineApp.swift:71` — `@main struct FeedmineApp: App`
- **Root view:** `FeedScreen()` in `WindowGroup`
- **First frame signal:** `FeedScreen.body` renders; actual content readiness is gated by `FeedDisplayPhase`

### Timeline Ready Signal
- **File:** `feedmine/Services/FeedLoader.swift:16` — `FeedDisplayPhase` enum
- States: `.preparing`, `.ready`, `.empty`, `.failed`
- `FeedScreen` observes `loader.items` / `loader.cards` / `loader.displayPhase`

### Catalog Loading
- **File:** `feedmine/FeedEngine/SQLiteCatalogStore.swift` — SQLite-backed catalog
- **File:** `feedmine/Services/OPMLParser.swift` — Bundled OPML parse with cache
- Sources loaded from `Resources/Feeds/` bundled OPML files (118 OPML 2.0 files)
- Catalog parsed via `OPMLParser` → `FeedSource[]` → persisted in catalog database

### OPML Parse
- **File:** `feedmine/Services/OPMLParser.swift`
- Uses Foundation `XMLParser`
- Caches parse results with format versioning
- Produces `OPMLParseResult` with sources, country URLs, counts

### RSS/Atom Parse
- **File:** `feedmine/Services/RSSFetcher.swift` — actor-based fetcher
- Uses `FeedKit` library (RSS 2.0, Atom, JSON Feed)
- Custom URLSession configs (starter 5s timeout, regular 15s timeout)
- Audio playability pre-check cache

### Item Normalization
- **File:** `feedmine/Models/FeedItem.swift` — `FeedItem` struct
- ID generated via SHA-256 hash of (url + publishedAt + title)
- `sectionDayOffset` pre-computed for date section grouping
- `isRead`/`isBookmarked` snapshots set at render time

### Deduplication
- Handled in `FeedStore.persistFetchedItems()` via GRDB unique constraints
- `Reservoir` handles in-memory dedup during interleave

### Ordering & Pagination
- **File:** `feedmine/FeedEngine/Pagination.swift`
- `Reservoir` interleaves sources for diversity
- `FeedRunwayController` manages runway length
- Page size configurable, currently derived from runway policy

### Persistence & Migrations
- **File:** `feedmine/Services/FeedStore.swift`
- GRDB `DatabaseQueue` with migrations
- Tables: feedItem, feedSource, bookmark, searchIndex (FTS5), etc.
- `FeedStore(inMemory:)` for testing — uses in-memory DatabaseQueue

### Index & Search
- **File:** `feedmine/Services/SearchEngine.swift` — FTS5 full-text search
- `SearchTerm` with exclusion support (leading `-` prefix)
- `SearchExpression` with required/excluded terms
- Tiered search: sources/tags → saved items → history/cache

### HTTP Client
- **File:** `feedmine/Services/RSSFetcher.swift` — URLSession-based
- **File:** `feedmine/Services/FeedHTTPSync.swift` — HTTP sync utilities
- No custom HTTP client; uses Foundation URLSession

### Image Cache & Pipeline
- **Files:** `Services/ImageCache.swift`, `MemoryImageCache.swift`, `DiskImageCache.swift`
- **File:** `Services/ImageLoader.swift` — async image loading
- **File:** `Services/ImagePrefetcher.swift` — prefetch for scroll performance
- **File:** `Services/ImageResolutionQueue.swift` — resolution ordering
- `CachedAsyncImage` used in views (likely from a package or custom)

### Card Assembly/Rendering
- **File:** `Views/FeedItemCardView.swift` — main card view
- **File:** `Views/PreparedCardImage.swift` — pre-resolved images
- **File:** `Services/CardPreparationCoordinator.swift` — async card prep
- **File:** `Services/CardPreparationPipeline.swift` — pipeline stages
- **File:** `Services/ReadyCardQueue.swift` — prepared card delivery
- `FeedCardPresentation` model with pre-resolved images

### Audio/Video Player
- **File:** `Services/AudioPlayerManager.swift` — AVPlayer-based
- **File:** `Views/MiniPlayerBar.swift` — mini-player UI
- Background audio capability (`UIBackgroundModes: audio`)

### Translation
- Not currently implemented as a feature in the app target
- Would be marked `not applicable` for translation tests per plan

### Background Refresh
- **File:** `feedmineApp.swift:4-68` — `SmartFeedBackgroundScheduler`
- **File:** `Services/BackgroundRefreshService.swift`
- Uses `BGAppRefreshTask` with 15-minute minimum interval

### Offline Handling
- **File:** `Services/NetworkMonitor.swift` — NWPathMonitor-based
- FeedStore persists all fetched content to GRDB
- Image cache persists to disk via DiskImageCache
- App declared offline-first in README

### Themes (Circadian)
- **File:** `Services/CircadianEngine.swift`
- 5 periods: dawn, morning, afternoon, evening, night
- Font weight, letter spacing vary by period
- Palette and typography adjustments

### Logging & Metrics
- **File:** `Services/Log.swift` — structured logging
- **File:** `Services/FeedMetrics.swift` — event and memory metrics
- Uses `OSLog` for subsystem logging

### Dependency Injection
- `@Environment` for SwiftUI environment objects (loader, localeManager, circadianEngine, audioPlayer, contentFilters)
- `FeedStore(inMemory:)` for test injection
- `ProcessInfo.processInfo.arguments` for UI test launch configuration
- No formal DI container; uses singleton pattern (`shared`) and manual injection

---

## 4. Current Testability Assessment

### Existing Test Infrastructure

| Test Target | Files | Type | Coverage |
|---|---|---|---|
| feedmineTests | 19 .swift files | XCTest unit + async | Good coverage of models, services, DB perf, reservoir, scheduler |
| feedmineUITests | 3 .swift files | XCUITest | Basic onboarding flow, filter UI, persona exploration |

### Existing Test Patterns

- `FeedStore(inMemory: true)` for isolated database tests
- `@MainActor` on test classes for UI-thread safety
- `async throws` for async test methods
- `ProcessInfo.processInfo.arguments` for UI test configuration:
  - `-UITestResetFilters` — reset content filters
  - `-UITestShowOnboarding` / `-UITestSkipOnboarding` — onboarding control
  - `-PreparedFeedPipeline` — feature flag toggle
  - `-AppleLanguages` — locale override
- `accessibilityIdentifier` already used in views (e.g., `welcome-start`, `intent-stayInformed`, `filter-button`, `duel-top-card`)

### Testability Gaps

1. **No formal launch configuration type** — arguments are raw strings checked via `ProcessInfo.processInfo.arguments.contains(...)` scattered in `feedmineApp.swift`
2. **No fixture transport system** — tests that need feeds use either the real bundled catalog or in-memory constructed data; no deterministic fixture injection
3. **No network simulation** — `RSSFetcher` always uses real URLSession; no `URLProtocol`-based stub or injectable transport
4. **No clock/seed injection** — `Date()` and `UUID()` used directly; no controllable time/randomness for tests
5. **Incomplete accessibility identifiers** — only onboarding and filter UI have identifiers; timeline cards, catalog, search, player lack them
6. **No signpost instrumentation** — no `OSSignpost` or `XCTOSSignpostMetric` integration for performance measurement
7. **No test plans** — no `.xctestplan` files exist; tests run via `-only-testing:` flags
8. **No physical device performance baseline** — existing `DatabasePerformanceTests` run on simulator using `CFAbsoluteTimeGetCurrent()`, not XCTest performance metrics
9. **UI tests are minimal** — only 3 UI test files covering onboarding and filters; no scroll, launch, offline, or media tests

### Existing Tests That Can Be Reused

- `DatabasePerformanceTests` — already measures insert throughput; can be enhanced with `XCTMetric`
- `FeedStoreTests` — CRUD operations on FeedStore; provides patterns for isolated DB testing
- `ReservoirTests` — interleave and fairness; can be adapted for scale testing
- `FeedmineUITests` — onboarding flow with accessibility identifiers; shows UI test patterns
- `FeedmineFilterUITests` — filter interaction patterns

---

## 5. Proposed Minimal Changes

### Phase 1 — Testability Foundation
1. **`TestConfiguration` struct** — typed wrapper around launch arguments replacing scattered `ProcessInfo` checks
2. **`FixtureTransport` protocol** — injectable URLSession替代 for network simulation
3. **`TestClock` / `TestRandom`** — controllable Date/random for deterministic tests
4. **`accessibilityIdentifier` audit** — add identifiers to timeline, catalog, search, player, card actions
5. **`FeedMinePerformanceSignposts`** — centralized `OSSignposter` for critical intervals
6. **No production code changes** — all additions gated behind `#if DEBUG` or test configuration

### Phase 2 — Fixture Generator (Python script)
7. **`scripts/generate_test_fixtures.py`** — deterministic SQLite generator with seed/manifest

### Phase 3+ — Tests
8. New test files added to existing `feedmineTests` and `feedmineUITests` targets
9. New Test Plans in `TestPlans/` directory
10. New scripts in `Scripts/validation/`

---

## 6. Risks of Modifying Production Code

| Risk | Mitigation |
|---|---|
| Test code leaks into release builds | All test support gated with `#if DEBUG` and test-only launch arguments |
| Schema changes break existing users | Migrations tested against database snapshots |
| Fixture generation touches real catalog | Generator uses seed-based synthetic data only |
| Build settings changes break CI | Test plans use separate configurations; existing Debug/Release preserved |
| GRDB dependency fragile in project file | `project.yml` is reference only; edits go to `.xcodeproj` directly |
| Signpost overhead in production | Signpost logging is compile-time elided in Release unless explicitly enabled for performance tests |

---

## 7. Environment Record

```
ProductName:    macOS
ProductVersion: 26.3.1
BuildVersion:   25D2128
Xcode:          26.6 (17F113)
Swift:          6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target:         arm64-apple-macosx26.0
Xcode Path:     /Applications/Xcode.app/Contents/Developer
Timezone:       America/Vancouver (PDT)
Git Branch:     main
Git Commit:     af77069a
Working Tree:   clean
```
