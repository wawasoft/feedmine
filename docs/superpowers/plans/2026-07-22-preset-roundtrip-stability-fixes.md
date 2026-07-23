# Plan: Collection Preset Roundtrip Stability Fixes

**Date:** 2026-07-22
**Branch:** `fix/collection-preset-roundtrip` (base baedcba4)
**Review:** max-effort code review → 10 findings → 4 root causes

## Global Constraints

- **No big changes.** Each fix is surgical — 5-20 lines per file.
- **No new public API.** Only internal implementation changes.
- **All existing tests must pass.** Run `xcodebuild test` after each task.
- **Use `&+= 1` for generation increments, `Int64` for generation types.**
- **Follow existing code patterns:** `guard !Task.isCancelled`, `[weak self]`, `Log.feed.error`.
- **presetSourceFilter is authoritative for collections** — member URLs define the allowlist, bypassing `isItemEnabled` by design.

## Root Cause → Task Mapping

| Task | Root Cause | Fix |
|------|-----------|-----|
| 1 | B — scheduleSourceEnablementRefresh lacks preset awareness | Add collection-preset guard to `scheduleSourceEnablementRefresh` so category/region toggles don't flush collection content |
| 2 | A — expectedGeneration == 0 sentinel | Split `loadCollectionPresetFeed` into validated and unvalidated variants; make `start()`, `refreshNow()`, `refreshIfStale()` use the validated path |
| 3 | C — filter changes re-fetch all members | Add staleness gate to network-refetch in `scheduleFilterReload` collection path; only re-filter from cache on overlay-only filter changes |
| 4 | D — missing 16:9 + untracked assets | Restore 16:9 aspect ratio in `heroBase` else branch; stage placeholder assets to git |

## Task Details

### Task 1: Make scheduleSourceEnablementRefresh collection-aware

**File:** `feedmine/Services/FeedStore.swift`

**Problem:** `setCategoryEnabled` (line 1936), `setTopicRegionsEnabled` (line 2107), `setAllCountriesEnabled` call `scheduleSourceEnablementRefresh()` with default `generation=0`, bypassing the generation guard. The 300ms-delayed `applyUpdate(.flush())` clears content and calls `reloadFromSQLite` which filters `is_read == 0`, excluding read items from collection external sources.

**Fix:** In `scheduleSourceEnablementRefresh`, add a guard before `applyUpdate(.flush())`: if a collection preset is active (`presetSourceFilter != nil`), route through `hydrateCollectionPresetFromCache` + `loadCollectionPresetFeed` instead. This mirrors what `setPreset` already does for its editorial → collection transition.

**Exact changes:**
1. At the top of `scheduleSourceEnablementRefresh` task body (after the generation guard), check: `if self.presetSourceFilter != nil, case .collection(let cid, _) = self.activePreset { /* collection-aware path */ return }`
2. In the collection-aware branch: do NOT call `applyUpdate(.flush())`. Instead, call `hydrateCollectionPresetFromCache(collectionID: cid)` (already exists), then if `usesPersistentStorage`, spawn a Task to `loadCollectionPresetFeed(collectionID: cid, expectedPreset: expectedPreset, expectedGeneration: generation)`.

**No test changes needed** — existing round-trip tests exercise category-reset already.

---

### Task 2: Eliminate expectedGeneration == 0 sentinel

**File:** `feedmine/Services/FeedStore.swift`

**Problem:** `loadCollectionPresetFeed(expectedGeneration: Int64 = 0)` uses zero as "skip all validation." Callers from `start()` (line 1196), `refreshNow()` (line 1460), `refreshIfStale()` (line 1508) pass nothing and get no generation protection. Their stale tasks mutate `loadingState` and publish to the reservoir.

**Fix:** Split into two methods with distinct signatures:
1. `loadCollectionPresetFeed(collectionID:)` — fire-and-forget (no validation). Used only when caller has already validated externally or doesn't need validation.
2. `loadCollectionPresetFeed(collectionID:expectedPreset:expectedGeneration:)` — always validates. Used by `setPreset` and `scheduleFilterReload`.

Make the current callers (`start`, `refreshNow`, `refreshIfStale`) use the validated variant by capturing `activePreset` and `presetGeneration` at their call sites.

**Exact changes:**
1. Rename the current 3-param method to `loadCollectionPresetFeed(collectionID:expectedPreset:expectedGeneration:)` — NO default values.
2. Add a thin 1-param wrapper `loadCollectionPresetFeed(collectionID:)` for callers that truly don't need validation (none currently — dead code, but kept for future use).
3. Update callers:
   - `start()` line 1196: capture `let capturedPreset = activePreset; let capturedGen = presetGeneration` before the Task, pass them.
   - `refreshNow()` line 1460: capture and pass.
   - `refreshIfStale()` line 1508: capture and pass.
   - `setPreset` line 1972: already passes captured values — update param names.
   - `scheduleFilterReload` line 1720: already passes captured values — update param names.
4. Remove all `expectedGeneration == 0` short-circuit checks from the method body (guard at 2006, defer at 1997, guard at 2019) — they're no longer needed since generation is always provided.
5. Move `loadingState = .refreshing` (line 1992) to AFTER the first generation guard, so stale tasks never mutate shared state.

---

### Task 3: Add staleness gate to filter-change network refetch

**File:** `feedmine/Services/FeedStore.swift`

**Problem:** `scheduleFilterReload` collection path (line 1716-1726) unconditionally calls `loadCollectionPresetFeed` from network on every filter change. Language toggle, mood change, content-type switch — all fire N HTTP requests for an N-member collection.

**Fix:** Check if the last network fetch is recent enough to skip. If `lastRefreshDate` is within the staleness threshold (900s, matching `refreshIfStale`), skip the network phase — the cache hydration alone is sufficient.

**Exact changes:**
1. In `scheduleFilterReload` collection path (line 1716), before launching the network Task, compute: `let shouldNetworkRefresh = lastRefreshDate.map { Date().timeIntervalSince($0) > 900 } ?? true`.
2. If `!shouldNetworkRefresh`, return after cache hydration without spawning the network Task.
3. The Task that IS spawned must set `lastRefreshDate = .now` — add this to `loadCollectionPresetFeed`'s defer block (only when network fetch actually ran, not when it returned early).

---

### Task 4: Restore 16:9 aspect ratio + stage placeholder assets

**Files:** `feedmine/Views/FeedItemCardView.swift`, 4 asset catalogs

**Problem A:** `heroBase` else branch (line 70-72) uses `.aspectRatio(contentMode: .fill)` without a ratio parameter. The old code had `.aspectRatio(16/9, contentMode: .fit)`. Layout depends on asset intrinsic dimensions.

**Problem B:** `git status` shows 4 placeholder image sets as untracked (`??`). If not staged/committed, `Image("Placeholder-Article")` etc. produce nil images at runtime.

**Fix A:** Add `.aspectRatio(16/9, contentMode: .fill)` as a frame modifier on the `heroBase` itself (after the `@ViewBuilder` branches), so both podcast and non-podcast branches get the 16:9 constraint. The podcast branch already has its own `.aspectRatio(16/9, contentMode: .fit)` — remove it from the branch and rely on the common modifier.

**Fix B:** Stage the 4 asset catalogs: `git add feedmine/Assets.xcassets/Placeholder-*`. Verify they are valid image sets with Contents.json and at least one image file.

**No code changes needed to `contentTypePlaceholderImage`** — the strings are correct; only the assets need to be in the project.

---
**Expected total diff:** 30-50 lines across 1-2 Swift files + 4 asset catalogs staged.
