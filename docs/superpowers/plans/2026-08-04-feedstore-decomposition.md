# FeedStore Decomposition — Implementation Plan

> **Goal:** Extract 5 focused components from the 7,204-line FeedStore monolith, following the audit's recommended decomposition path.

**Architecture:** Each extracted component owns one responsibility domain. FeedStore remains as coordinator holding database ownership and dependency injection. Components communicate through FeedStore's public interface.

**Tech Stack:** Swift 5, GRDB, @MainActor + actor concurrency

## Extraction Order (incremental, each independently testable)

### Phase 1: FeedDisplayState — Display state management
**Files:** Create `feedmine/Services/FeedDisplayState.swift` (~150 lines)
**Extract from FeedStore:**
- `visibleItems`, `visibleCards`, `visibleItemsGeneration`
- `feedDisplayPhase`, `presentationEpoch`
- `loadingState`, `isPreparingInitialRunway`
- `setVisibleItems(_:)`, `presentationEpoch` management

### Phase 2: FilterEngine — Bidirectional filter state
**Files:** Create `feedmine/Services/FilterEngine.swift` (~400 lines)
**Extract from FeedStore:**
- `activeRegion`, `activeNodeIDs`, `activeContentType`, `activeMood`, `activeLanguages`
- `applyFilters(_:)`, `immediatelyCullVisibleItemsForActiveFilter`
- `filterGeneration`, `cachedTaxonomyFeedURLs`
- `setFilter(...)`, `scheduleFilterReload(...)`

### Phase 3: FeedRunwayOrchestrator — Startup + pipeline coordination
**Files:** Create `feedmine/Services/FeedRunwayOrchestrator.swift` (~300 lines)
**Extract from FeedStore:**
- `reservoir`, `reservoirCount`
- `cardQueue`, `preparationCoordinator`, `runwayController`
- `prefetchImagesIfEnabled`, `promotePreparedCards`
- `throttledReservoirAppend`, `flushPendingReservoir`

### Phase 4: SearchAdapter — FTS5 search
**Files:** Create `feedmine/Services/SearchAdapter.swift` (~200 lines)
**Extract from FeedStore:**
- `isSearching`, `searchQuery`, `searchResults`
- `performSearch(_:)`, `clearSearch()`
- FTS5 query construction

### Phase 5: UserContentAdapters — Bookmarks, Collections, Smart Feeds, Curated
**Files:** Modify existing `UserStateStore.swift` extensions
**Extract from FeedStore:**
- Bookmark CRUD → UserStateStore extension
- Collection CRUD → already in SourceCollectionStore
- Smart feed matching → UserStateStore extension
- Curated feed logic → UserStateStore extension

## Testing Strategy
- Each extracted component tested independently with in-memory GRDB
- FeedStore integration tests verify cross-component coordination
- Existing test suite must pass at each phase boundary

## Exit Gates
- FeedStore < 3,000 lines (from 7,204)
- All existing tests pass
- No feature regression
- Each component has dedicated unit tests
