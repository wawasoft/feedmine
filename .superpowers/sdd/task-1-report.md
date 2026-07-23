# Task 1 Report: Make scheduleSourceEnablementRefresh collection-aware

## Status: DONE

## Files Changed

- `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Services/FeedStore.swift` — lines 2110-2162 (the `scheduleSourceEnablementRefresh` method body)

## What Changed

Added a collection-aware guard in `scheduleSourceEnablementRefresh` that runs **before** the existing `applyUpdate(.flush())` path. When a collection preset is active (`presetSourceFilter != nil` and `activePreset` is `.collection`), the method now:

1. Sets `loadingState = .refreshing` and calls `refreshWhatsNew(shouldBoost: false)` — same as the flush path.
2. Calls `hydrateCollectionPresetFromCache(collectionID:)` for immediate display from local cache.
3. If `usesPersistentStorage`, spawns a `Task` to call `loadCollectionPresetFeed` for network refresh.
4. Returns early without calling `applyUpdate(.flush())`.

This prevents the flush + `reloadFromSQLite` path from clearing collection content that contains external-source items or read items (which `reloadFromSQLite` filters out with `is_read == 0`).

## Exact Diff

```diff
--- a/feedmine/Services/FeedStore.swift
+++ b/feedmine/Services/FeedStore.swift
@@ -2117,6 +2117,31 @@ class FeedStore: ObservableObject {
                activePreset != expectedPreset || presetGeneration != generation {
                 return
             }
+            // If a collection preset is active, route through the collection-aware
+            // path instead of flushing. A generic flush + reloadFromSQLite would
+            // miss external-source items and read items.
+            if presetSourceFilter != nil,
+               case .collection(let cid, _) = activePreset {
+                loadingState = .refreshing
+                refreshWhatsNew(shouldBoost: false)
+                // Hydrate from cache for immediate display. Network refresh is
+                // optional — only for persistent stores to keep the feed current.
+                do {
+                    try await hydrateCollectionPresetFromCache(collectionID: cid)
+                } catch {
+                    Log.feed.error("collection source-enablement refresh hydrate failed: \(error)")
+                }
+                if usesPersistentStorage {
+                    Task {
+                        await loadCollectionPresetFeed(
+                            collectionID: cid,
+                            expectedPreset: activePreset,
+                            expectedGeneration: presetGeneration
+                        )
+                    }
+                }
+                return
+            }
             self.loadingState = .refreshing
             self.refreshWhatsNew(shouldBoost: false)
             self.applyUpdate(.flush())
```

## Test Results

Test `testCollectionPresetSurvivesEditorialRoundTripSlow` passed in 0.586 seconds with 0 failures.

```
Test Case '-[feedmineTests.FeedStoreTests testCollectionPresetSurvivesEditorialRoundTripSlow]' passed (0.586 seconds).
Test Suite 'FeedStoreTests' passed at 2026-07-22 21:57:24.314.
     Executed 1 test, with 0 failures (0 unexpected) in 0.586 (0.587) seconds
```

## Self-Review

1. **Preserved interfaces:** `scheduleSourceEnablementRefresh(expectedPreset:generation:)` signature is unchanged. Callers passing `generation=0` (default) still work — the collection guard fires **before** the flush in the same task body, so it intercepts all callers including `setCategoryEnabled`, `setTopicRegionsEnabled`, and `setAllCountriesEnabled`.

2. **Guard pattern matches existing code:** The collection check (`if presetSourceFilter != nil, case .collection(let cid, _) = activePreset`) mirrors the existing pattern used in `setPreset` and `refreshWhatsNew`.

3. **Fire-and-forget for network:** The network refresh via `loadCollectionPresetFeed` runs in a separate `Task` so the enablement refresh returns quickly. The function's own generation guards protect against stale execution.

4. **Cache hydrate is awaited:** `hydrateCollectionPresetFromCache` is awaited inline so the UI updates immediately with cached content.

5. **Error handling:** Cache hydrate errors are logged but don't crash — consistent with the existing error handling pattern in `loadCollectionPresetFeed`.

6. **Build verified:** `xcodebuild build` succeeded with no warnings or errors.

## Commit

```
71322af7 - Make scheduleSourceEnablementRefresh collection-aware
```
