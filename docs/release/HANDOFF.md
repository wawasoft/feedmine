# FeedMine 1.0 — handoff (start here in a fresh session)

Repo: `/Users/wagnermontes/Documents/GitHub/feedmine`
Branch: `fix/release-1.0-final-hardening`. The hardening tree was measured all session uncommitted; it is now committed as a
single baseline (see §Baseline) — **every green below carries the commit it belongs to**.
Dev remote `origin` = `wsmontes/feedmine-dev`; prod `upstream` = `wawasoft/feedmine`.
Full session log with every measurement, instrument and retraction: `docs/release/1.0-checklist.md` (long — read the last
~60 entries, not the whole file).

## ⚠️ `project.yml` appears modified in the working tree — do NOT run xcodegen

The file's own header forbids it: *"REFERENCE ONLY — do NOT regenerate the .xcodeproj from it with xcodegen. The committed
.xcodeproj is the single source of truth and contains manual additions (GRDB linkage, build phases, signing config) that
this reference does not reproduce."* Regeneration would destroy exactly those.

Sanctioned path for any project-file change: a **purely additive hand-patch** to `feedmine.xcodeproj/project.pbxproj` —
verified shape: **48 lines added, 0 removed, 0 changed**, 12 entries each in `PBXBuildFile`, `PBXFileReference`, group
children and the Sources phase, no build-setting/scheme/workspace edits, no UUID churn. Prototype: `/tmp/apply_surgical.py`
(output `/tmp/pbxproj.surgical`). The committed project file already contains invented-looking UUIDs from prior hand-edits
(`A1C1D1E1F1A1B1C1D1E1F1A1`, `B2C2…`, `AA11BB22…`); new entries must not collide with them.

## Baseline

- Branch `fix/release-1.0-final-hardening` @ `395eced3` **plus the hardening tree committed as one baseline commit**:
  **`17a0051a` "chore(release): baseline the 1.0 hardening tree (build 16)"**, 155 paths (153 modified + 2 added), working
  tree clean, no push. `catalog.sqlite` goes through **Git LFS** (`*.sqlite` in `.gitattributes`), so its 118 MB never
  enters the pack.
- Restore point: **the commit `17a0051a` is the restore point** — the tree is committed, so nothing depends on a patch file any
  more. `/tmp/wip-1789618800.patch` is a **partial, stale 21:20 snapshot of the uncommitted tree**: it predates the reopen
  step's later revisions, the 150 s readiness gate, the reader-content helper, the classification probe and these docs, so it
  restores the morning's tree, not this one. Use it only to recover that earlier state; use `git` for anything after 00:33.
- App Store Connect: **1.0 (16) uploaded and `VALID`** (uploaded 2026-09-17T13:43:53-07:00, verified through the App Store
  Connect API — `GET /v1/builds?filter[app]=6793279758&sort=-version`), sitting beside 15/14/13… (all `VALID`). The **archive**
  is at `.build/feedmine.xcarchive` (archived app reports `1.0 (16)`), and `git diff --name-only 17a0051a..HEAD -- feedmine/`
  is empty: every commit after the archive touches only docs and `feedmineUITests`, so the uploaded binary is exactly the code
  the bar certified.
- **Upload credentials (the working recipe).** Xcode's Apple ID account path fails on this machine
  (`error: exportArchive Failed to Use Accounts`), so use the App Store Connect API key:
  ```
  xcodebuild -exportArchive -archivePath .build/feedmine.xcarchive \
    -exportOptionsPlist .build/ExportOptions.plist -exportPath .build/tf-export \
    -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_H3U55Z9WZ7.p8 \
    -authenticationKeyID H3U55Z9WZ7 -authenticationKeyIssuerID 0e1bd229-1284-4916-91d2-7bf989859bcc
  ```
  (team `955573A4YH`; the issuer is required — omitting it errors with `The flag -authenticationKeyIssuerID is required`, and a
  wrong one with `No Accounts with App Store Connect Access`.) `/tmp/testflight.sh` wraps archive + export/upload.

## What is PROVEN (evidence exists; do not re-derive)

|Deliverable|Evidence|
|---|---|
|User journey|`testCaptureAllScreens`: **17/17 required surfaces, 0 absent** (basename set `01-main-feed` … `17-reopen`), with the **reader pair visually verified** — 08:08 run: `READER presented=1 presented_ms=97 signal=webview:1`, `READER content_ms=5437 ink=0.961`, and both captures show the reader sheet (title `Dude Perfect`, X + Safari buttons) over a rendered YouTube article; `04` is the screenful **after the swipe** and, on a video page, is not by itself proof of a scroll offset. The reader step gates on **presentation** (`ensureReaderPresented()`: a `.sheet` with `NavigationStack`/`WKWebView`; the feed screen has neither) and then on **content** (`waitForReaderContent()` must return true) — a blank reader leaves `03`/`04` absent with `90-reader-blank.png` as the diagnostic, because a pixel-only gate once passed on the feed's own pixels and filed two feed screenshots as `03`/`04` (08:01 run). Treat the 08:08 run as the verified one; 00:15/00:27 reported 17/17 but their reader pairs were never read.|
|Doctrine item 9 — "close and reopen … feed appears immediately, no loading screen"|**Both halves measured from the app's own log.** Warm relaunch (`terminate()` + `launch()`, same install): `surface[initial-loading] appear` 00:28:31.483 → `publishCards firstPaint: items=20 cards=20` 00:28:31.664 → `page[restore] items=20 withMedia=13` 00:28:31.675 → `surface[initial-loading] disappear` 00:28:31.717 = **234 ms of loading surface**, page restored from disk, no refetch. Cold first install in the same run: the same surface appears at 00:26:33.394 and disappears at 00:27:01.893 = **28.5 s** (all 20 cards off the network, empty SQLite). Test side agrees: `loading_observed=0` at every sample from 2.4 s, `ttff_card_ms=2400`, `launch_returned_ms=2243`.|
|Unit gate|**460 tests, 0 failures × 3 consecutive runs** (107.6 / 108.5 / 110.5 s) under the clean-container protocol below. Labeled: *green under 30 s deadline tolerance; finding 10 (injected clock / suspension points) still open*.|
|Filter-change classification (Latency)|**Case A (target filter already has ready content)**: `setFilter gen=1` → `reloadFromSQLite loaded=1188 filtered=898` (rows, not ready cards) → `done visibleItems=9` after **7.80 s**; probe `clear_ms=0 first_card_ms=8188 page_kept=0 ids_unchanged=0`; **no network line** — local-first in source, but 8.19 s with nothing ready on screen. **Case B (nothing local)**: `localOfType=0`, no card after 30 s — correctly radical, lever is background-fill priority, not query tuning.|
|Catalogue|`http`→`https` rewrite (3 666 URLs / 117 OPML files); shipped `catalog.sqlite` regenerated: `request_url` http **843 → 68**, same 77 443 sources, 0 duplicates/invalid.|
|Production surfaces|Settings shows the **bundle** version (`1.0 (16)`); network identity `FeedminePrototype/1.0` → `Feedmine/1.0` (3 files); `ITSAppUsesNonExemptEncryption = false` declared.|
|Attribution of the 3 identity failures|**CLOSED — probe artifact.** All three carried `NSCocoaErrorDomain Code=260 … /tmp/feedmine-probe/scripts/data/catalog_identity_vectors.json`: the probe built a *copy* of the repo and `vectors()` resolves the fixture through `#filePath`. The real tree has the file (tracked, clean) and all 19 cases passed in every certified gate run.|

## What is OPEN, with its blocker

1. **TestFlight** — build 16; archive done, **upload blocked on credentials**: `-exportArchive` failed with
   `error: exportArchive Failed to Use Accounts` (Xcode's stored Apple ID session from the 13:19 upload of build 15 is no
   longer usable from this shell), and the local ASC API key `~/.appstoreconnect/private_keys/AuthKey_H3U55Z9WZ7.p8` needs
   the **issuer ID**, which nothing on this machine stores:
   ```
   xcodebuild -exportArchive -archivePath .build/feedmine.xcarchive \
     -exportOptionsPlist .build/ExportOptions.plist -exportPath .build/tf-export \
     -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_H3U55Z9WZ7.p8 \
     -authenticationKeyID H3U55Z9WZ7 -authenticationKeyIssuerID <issuer>
   ```
   `/tmp/testflight.sh` does archive + export/upload with the lane lock and prints the archived version, the export exit
   code and the `Upload succeeded` line. Needs the issuer ID (App Store Connect → Users and Access → Integrations) or a
   re-authenticated Xcode account.
2. **Latency, case A** — stop clearing the page on a *prepared* change. Concretely: `setFilter` currently sets
   `display.setLoadingState(.refreshing)` + `display.setFeedDisplayPhase(.preparing(contextID:reason:.filterChange))` and then
   reaches `setVisibleItems([], settlesPhase: false)` (`FeedStore.swift:3151`) whenever the language-buffer branch does not
   hit — the clear is what costs the measured 8.19 s blank. The prepared path is to call
   `immediatelyCullVisibleItemsForActiveFilter()` (`FeedStore.swift:3180`, already used elsewhere and already
   filter-correct) **before** that clear, and when it leaves the page non-empty treat the change like the language-buffer
   branch does: publish the culled cards, `setLoadingState(.idle)`, `setFeedDisplayPhase(.ready(contextID:))`, and let the
   debounced reload replace/expand the composition behind it. Clear + `.preparing` stays the fallback for the genuinely
   empty cull — which is also what keeps the two retracted concerns closed (see the comment at `:3140-3151`: the "filter
   lies" mismatch cannot happen when the kept cards are culled *by the new predicate*, and the dead-end cannot happen while
   `.preparing` is still entered when nothing is ready).
   Acceptance: re-run `/tmp/filter-classify.sh` and require case A to report `page_kept=1`, `clear_ms=-1` and a
   `languages_after` equal to the selected language (the probe already prints both, plus `ids_unchanged` so a stale page
   cannot be mistaken for an update), then the full bar. Then the 7.8 s local composition the same run exposed
   (`reloadFromSQLite … done visibleItems=9`, i.e. the cost sits *after* the query, which finished in 0.45 s). Case B is
   coverage work, not query tuning.
3. **The debounced reload can be dropped** — `scheduleFilterReload` (`FeedStore.swift:3296`) returns silently when
   `generation != filterGeneration`; in the leftover-container state this left a test waiting 37 s for a reload that never
   ran (measured 4×, gone once each gate starts from a clean container). The product-side question — a user whose filter
   change never gets its reload sees the same blank page as case A — belongs with item 2.
4. **Binary decision on the surgical patch** — the user's call was **leave it unlanded**. It adds
   `Services/TestConfiguration.swift` + `Services/FeedMineSignposts.swift` to the shipped app target, and the nine suites it
   enables fail on their own terms (`CatalogPerformanceTests.testBulkInsert_2K` burned four 60 s `measure` timeouts;
   every `measure { … wait(for:) }` case times out because the `Task` inherits `@MainActor` while `wait(for:)` blocks the
   main thread). A landable patch needs that test-side fix first.
5. **9 suites outside the target** — `feedmineTests/Performance/*` + `Support/TestHelpers.swift`, so 460/0 is **29 suites,
   not full coverage**.

## Operational rules that cost or saved time here

- **Certify a journey by its required basename set, never by a file count** — and let that set *decide the exit status*: the
  reader step `XCTFail`s when the reader never presented or its body never rendered (leaving `03`/`04` absent and a
  `90-reader-blank.png` diagnostic), and both acceptance scripts exit 1 on any missing required surface, on
  `** TEST EXECUTE FAILED **` or on a failed gate. Both failure branches have been exercised end to end
  (`superficies-obrigatorias=15/17 ausentes=[03-article-reader 04-article-scrolled]` ⇒ script exit 1). A printed
  `ausentes=[…]` that still exits 0 is not a gate.
- **Clean the app container between test runs.** The unit tests execute *inside the app's process* and write the app's
  UserDefaults and page caches; a run that inherits the previous run's container failed `FeedLoaderCacheTests
  .testFilteredDateSectionsPreserveProviderOrderAcrossDates` with a 36.9–37.1 s page-publication wait that normally takes
  0.318 s, and it also gave the journey a 1-item page slot to restore. `xcrun simctl uninstall <device> com.feedmine.app`
  between gates and before the journey; the gates also lost 60–100 s of wall clock when this was added.
- **A readiness gate that expires before the app is ready fabricates surfaces.** Cold first paint measured 26–81 s against a
  30 s card budget; the budget is now 150 s and prints `READY card_after_ms=…`. `01-main-feed` used to photograph the
  loading screen while the run still counted 16 surfaces.
- **A fixed `sleep` in front of a capture samples the network, not the app** — and **a web view's accessibility tree is not
  a polling primitive**: `app.webViews.staticTexts` (enumerated *or* predicate-limited) timed out the UI query and killed
  the journey at 2/17 twice. The reader gate now measures rendered pixels (screenshot → 60×60 grid → ink fraction ≥ 0.06
  outside a 12% border); screenshots are what `capture()` already uses.
- **Absolute wall-clock budgets in the unit suite are contentions, not contracts.** Three were recalibrated from
  measurements taken with only those cases in flight (interleave-1000 325.81 ms → budget 1 200 ms; interleave-5000
  1.76–1.86 s isolated vs 2.22 s in-suite → 6 000 ms; 5 000 inserts 3.8–5.1 s isolated vs 17.0 s in-suite → 30 000 ms).
  They remain catastrophic-regression guards; the real perf suites live outside the target.
- **Serialize with a real lock** (`mkdir /tmp/feedmine-lane.lock`), covering **`simctl`** as well as `xcodebuild`, and
  **release it by removing `holder` before `rmdir`** — bare `rmdir` cannot remove a non-empty directory, which is how every
  earlier run leaked the lock. Both scripts use `release_lane()` plus a guarded `rm -rf` reclaim.
- **Never trust `test-without-building` without a freshness check** (no source newer than the build product), and abort on
  any build `error:`.
- Scripts: **`scripts/release-acceptance.sh`** (the bar: gates ×3 + journey + basename validation + `REOPEN` lines,
  lock-guarded, **exit 1** on any failed gate or missing surface) and **`scripts/release-journey.sh`** (the journey half
  alone, same gate semantics) are **checked in** — the exit-status propagation that makes them gates rather than reports is
  part of the repository, not of a `/tmp` file. Both derive the repo root from their own path, take `FEEDMINE_SIM_UDID`
  (default: first available iPhone, discovered — no host-specific UDID baked in) and `FEEDMINE_DESTINATION`
  (default `platform=iOS Simulator,id=$UDID`), **assert** the clean-container premise (`get_app_container` must fail after
  `uninstall`, else the run aborts) and capture `xcodebuild`'s exit status for the build as well as the test. Their `/tmp`
  predecessors (`/tmp/acceptance-final.sh`, `/tmp/reopen-measure.sh`) and the probe helpers (`/tmp/filter-classify.sh`,
  `/tmp/perf-baseline.sh`) are ephemeral working copies; treat anything that matters as living in the repo. Logs land in
  `/tmp/feedmine-*.log`, screenshots in `/tmp/feedmine-persona-screenshots` (hardcoded by the UI test, so not configurable).
  **Pin `FEEDMINE_SIM_UDID` when comparing against the numbers in this file**: they were all measured on the iPhone 16
  `2F70B5E4-DF56-428C-A7B9-0A769B6CAC3D`, while the scripts otherwise discover their device (booted iPhone first).
- **Do not "fix" the flaky filter test in product code.** `FeedStore`/`applyFiltersOffMain` were correct; the flakes were
  test-side (fixed `Task.sleep(200ms)` sampling, a process-wide `taxonomy_cache.json`, and now the shared filter state —
  see `normalizeSharedFilterStateForTests()`).

## First actions in the new session, in order

1. **Upload build 16** (archive + export, `destination: upload`) and confirm `Upload succeeded` + `VALID` on App Store
   Connect.
2. Then Latency case A (item 2 above) — classification is done; the page-clear semantics are the target, not the query.
3. Empty the backlog: the reload-drop question (item 3), then the nine suites (item 4/5) if the patch is to land at all.
