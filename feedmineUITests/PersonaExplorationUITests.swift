import Foundation
import UIKit
import XCTest

/// Captures screenshots of every major screen/state in Feedmine for persona agents to analyze.
/// This test does NOT assert — it navigates broadly and saves evidence.
@MainActor
final class PersonaExplorationUITests: XCTestCase {

    let app = XCUIApplication()
    var screenshotDir: String = "/tmp/feedmine-persona-screenshots"

    override func setUp() {
        continueAfterFailure = true
        // Ensure clean state — no onboarding, fresh filters
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-UITestResetFilters", "-UITestSkipOnboarding",
        ]
        app.launch()
        try? FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true, attributes: nil)
    }

    // MARK: - Main Screenshot Harness

    func testCaptureAllScreens() {
        waitForAppReady()

        // 1. Main Feed (default view)
        capture("01-main-feed")

        // 2. Scroll feed to see more cards
        app.swipeUp()
        sleep(1)
        app.swipeUp()
        sleep(1)
        capture("02-main-feed-scrolled")

        // 3. Tap first article to open reader
        if let firstCard = firstHittableCard() {
            firstCard.tap()
            // Presentation first, content second. The pixel gate below cannot tell the reader from the *feed*: both are
            // ink-rich, so applying it straight after the tap returned true in 116 ms on the feed's own pixels and the
            // run captured the feed twice under the names `03-article-reader` / `04-article-scrolled` (found by reading
            // the PNGs, not by the gate). `ArticleReaderView` is a `.sheet` containing a `NavigationStack` and a
            // `WKWebView` (`FeedScreen.swift:260`), and the feed screen has no navigation bar and no web view, so either
            // signal — cheap, single-element queries — means the reader is up.
            let presented = ensureReaderPresented()
            if presented {
                waitForReaderContent()
                sleep(1)
                capture("03-article-reader")
                // Swipe article content
                app.swipeUp()
                sleep(1)
                capture("04-article-scrolled")
            } else {
                // No presentation, no surface: capturing the feed under a reader's name is the fabrication this harness
                // exists to avoid, and the basename validator reports the pair as absent instead.
                print("READER reader_not_presented=1 — 03-article-reader and 04-article-scrolled not captured (the reader surface was not exercised)")
            }
            // Go back
            dismissSheet(preferring: "back")
            sleep(2)
        }

        // 4. Filter Sheet
        let filterButton = app.buttons["filter-button"]
        if filterButton.exists {
            filterButton.tap()
            sleep(2)
            capture("05-filter-sheet")
            app.swipeUp()
            sleep(1)
            capture("06-filter-sheet-scrolled")
            app.buttons["filter-done"].tap()
            sleep(1)
        }

        // 5. Search
        let searchButton = app.buttons["search-button"]
        if searchButton.exists {
            searchButton.tap()
            sleep(2)
            capture("07-search-screen")
            let field = app.textFields["unified-search-field"]
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText("science")
                sleep(2)
                capture("08-search-results")
            }
            // Dismiss search
            dismissSheet(preferring: "Cancel")
            sleep(1)
        }

        // 6. More menu
        let moreMenu = app.buttons["more-menu"]
        if moreMenu.exists {
            moreMenu.tap()
            sleep(2)
            capture("09-more-menu")
            app.swipeUp()
            sleep(1)
            capture("10-more-menu-scrolled")
            // Dismiss
            let doneBtn = app.buttons["done-button"]
            if doneBtn.exists { doneBtn.tap() }
            else { moreMenu.tap() }
            sleep(1)
        }

        // 7. Settings. Look first, open only if needed. `more-menu` is a lazy query — a captured element is
        // never stale — what varies is whether step 6 left the menu open: its dismissal is
        // `if done-button { tap } else { tap more-menu }`, and that fallback *toggles*, so a blind tap here
        // closes an open menu and the following swipeUp then scrolls the feed instead of the sheet.
        let settingsLabel = NSPredicate(format: "label CONTAINS[c] %@", "Settings")
        var settingsBtn = app.buttons.element(matching: settingsLabel)
        if !settingsBtn.exists, app.buttons["more-menu"].waitForExistence(timeout: 5) {
            app.buttons["more-menu"].tap()
            sleep(1)
        }
        if !settingsBtn.exists {
            for _ in 0..<6 {
                app.swipeUp()
                usleep(400_000)
                if app.buttons.element(matching: settingsLabel).exists {
                    settingsBtn = app.buttons.element(matching: settingsLabel); break
                }
                if app.staticTexts.element(matching: settingsLabel).exists {
                    settingsBtn = app.staticTexts.element(matching: settingsLabel); break
                }
            }
        }
        if settingsBtn.exists {
                settingsBtn.tap()
                sleep(2)
                capture("11-settings")
                app.swipeUp()
                sleep(1)
                capture("12-settings-scrolled")
                // The sheet now ships its own exit control; tap it, and only fall back to the grabber drag.
                dismissSheetByDrag()
                if !waitForFeed() { capture("98-settings-exit-failed") }
            } else {
                // Dismiss more menu
                dismissSheet(preferring: "Close")
            }

        // 8. Add Feed — same look-first shape as Settings: never tap the menu blind, because the previous
        // dismissal toggles it and a blind tap then closes an open menu.
        if let addFeedBtn = ensureMenuRow("Add Feed") {
            addFeedBtn.tap()
            sleep(2)
            capture("13-add-feed")
            dismissSheet(preferring: "Cancel")
            sleep(1)
        }

        // 9. Browse Topics via filter
        if filterButton.exists {
            filterButton.tap()
            sleep(1)
            let browsePred = NSPredicate(format: "label CONTAINS[c] %@", "Browse Topics")
            for _ in 0..<6 {
                let btn = app.buttons.element(matching: browsePred)
                let text = app.staticTexts.element(matching: browsePred)
                if btn.exists { btn.tap(); break }
                else if text.exists { text.tap(); break }
                app.swipeUp()
                usleep(300_000)
            }
            sleep(2)
            capture("14-browse-topics")
            app.swipeUp()
            sleep(1)
            capture("15-topics-scrolled")
            // Dismiss
            dismissSheet(preferring: "filter-done")
            sleep(1)
            // Dismiss filter sheet too
            let doneFilter = app.buttons["filter-done"]
            if doneFilter.exists { doneFilter.tap() }
            else { dismissSheet(preferring: "filter-done") }
            sleep(1)
        }

        // 10. Long press context menu on a card
        if let cardForMenu = firstHittableCard() {
            cardForMenu.press(forDuration: 1.0)
            sleep(1)
            capture("16-context-menu")
            app.tap() // dismiss
            sleep(1)
        }

        // 11. Reopen — the headline acceptance criterion: close and reopen the app and the feed is already
        // there, from the page the previous interaction persisted, with no loading screen in between. The 16
        // surfaces above never relaunch, so this had never been measured.
        let reopenCardPredicate = NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-")
        let pageVisibleBeforeTerminate = app.descendants(matching: .any).matching(reopenCardPredicate)
            .firstMatch.exists

        // Guard 1 — a reopen can only be warm if the page actually reached disk. A page that was never
        // flushed would make everything below a cold start wearing a warm label, so prove it *before*
        // terminating. Unreadable container = unverified (reported, not fatal); container read and holding no
        // usable page = a real invalidation, which guard 2 fails on.
        let persistedBefore = reopenPersistedPageEvidence()
        print("REOPEN guard1 persisted_on_disk=\(persistedBefore.usable ? 1 : 0) page_visible_before_terminate=\(pageVisibleBeforeTerminate ? 1 : 0) \(persistedBefore.evidence)")

        app.terminate()

        // Guard 2 — the warm precondition, decided **before** the launch and applied to the verdict after it. Two
        // different failures, two different answers:
        //   * container unreadable → the warm state is **unverified**. The relaunch still happens (so the surface set
        //     stays complete and its captures stay comparable) but nothing below may be read as a warm-start result:
        //     the run prints `verdict=inconclusive` with that reason and no warm ttff conclusion.
        //   * container readable, no usable page → a real invalidation, which fails the run.
        let warmVerified = persistedBefore.containerFound && persistedBefore.usable
        if !persistedBefore.containerFound {
            print("REOPEN guard2 warm_precondition=unverified reason=container-unreadable (the runner could not read the app container, so a warm start cannot be proven)")
        } else if !persistedBefore.usable {
            print("REOPEN guard2 warm_precondition=invalid reason=page-absent \(persistedBefore.evidence)")
            XCTFail("reopen precondition: container readable but holding no usable page — measurement invalid")
        } else {
            print("REOPEN guard2 warm_precondition=verified \(persistedBefore.evidence)")
        }

        // Guard 3 — poll **both** signals at one cadence from the instant of launch, never post-hoc: the positive
        // one (first ready card) and the negative one (any loading/progress surface). A post-hoc check can only
        // see the end state, so a loading screen that appeared and vanished would go unrecorded; sampling the
        // negative signal from the first poll is what makes "no loading screen" a measurement instead of a guess.
        //
        // Both surfaces carry an identifier, which is what makes the negative half assertable at all:
        // `initial-feed-loading` on `InitialFeedLoadingView` (FeedScreen.swift:1709 — the view phase `.preparing`
        // renders) and `feed-empty-state` / `feed-empty-title` on `FeedEmptyStateView` (what a ready-but-empty feed
        // renders, whose title reads "Loading your feed..." while `loadingState == .initial`). Ids are what travel;
        // the matched element's **label** is read once and reported, so the two are never confused.
        //
        // `app.launch()` returns when the app goes idle, so how long it blocks is itself part of the wait a user
        // would sit through: stamp before the call and keep both numbers.
        let launchStart = Date()
        app.launch()
        let launchReturnedMS = Int(Date().timeIntervalSince(launchStart) * 1000)
        let stateAfterLaunch = app.state.rawValue

        // The first observation is a **query**, not a screenshot. `app.screenshot()` costs ~0.5 s and the previous
        // shape charged that to the measurement — the poll that "found" the card ran at the same millisecond as the
        // shot, so the number was the shot's latency, not the app's. Query first, then take the look-frame picture.
        let firstCard = app.descendants(matching: .any).matching(reopenCardPredicate).firstMatch
        let loadingPredicate = NSPredicate(format: "identifier IN %@", ["initial-feed-loading", "feed-empty-state"])
        let loadingAny = app.descendants(matching: .any).matching(loadingPredicate).firstMatch
        let cardAtLaunchReturn = firstCard.exists
        let firstObservationMS = Int(Date().timeIntervalSince(launchStart) * 1000)

        // The look-frame picture: what the screen held at the first moment the harness could look. Written straight to
        // disk under its own name; it is positive evidence in its own right (it is the frame the user would have seen),
        // which is separate from the question the harness cannot answer — whether a loading surface was composited
        // *before* `launch()` returned.
        let firstLookShot = app.screenshot()
        try? firstLookShot.pngRepresentation.write(to: URL(fileURLWithPath: "\(screenshotDir)/17-reopen-at-launch-return.png"))
        let firstLookMS = Int(Date().timeIntervalSince(launchStart) * 1000)

        var firstCardMS = cardAtLaunchReturn ? firstObservationMS : -1
        var firstPollMS = firstObservationMS
        var polls = 0
        var loadingSeen = false
        var loadingFirstMS = -1
        var loadingLastMS = -1
        var loadingSurfaceID = ""
        var loadingTitle = ""
        let reopenDeadline = Date().addingTimeInterval(30)
        while firstCardMS < 0, Date() < reopenDeadline {
            polls += 1
            let elapsed = Int(Date().timeIntervalSince(launchStart) * 1000)
            if loadingAny.exists {
                if !loadingSeen {
                    loadingSeen = true
                    loadingFirstMS = elapsed
                    loadingSurfaceID = loadingAny.identifier
                    loadingTitle = loadingAny.label
                }
                loadingLastMS = elapsed
            }
            if firstCard.exists {
                firstCardMS = elapsed
                break
            }
            usleep(25_000)
        }
        capture("17-reopen")

        sleep(1)
        let settledCards = app.descendants(matching: .any).matching(reopenCardPredicate).allElementsBoundByIndex
        let persistedAfter = reopenPersistedPageEvidence()

        // One poll of resolution: `loading_last_ms` is the last sample that still saw the surface, so the window
        // is a lower bound and `loading_ms` is reported as the span between first and last sighting.
        let loadingMS = loadingSeen ? max(0, loadingLastMS - loadingFirstMS) : -1
        // `launch()` blocks until the app is idle, so nothing before `launch_returned_ms` is observable from here and
        // every ttff below is an **upper bound** — the card may have been on screen for seconds by then.
        print("REOPEN ttff_card_ms=\(firstCardMS < 0 ? "timeout" : String(firstCardMS)) ttff_bound=upper_bound_from_launch_return card_at_launch_return=\(cardAtLaunchReturn ? 1 : 0) first_observation_ms=\(firstObservationMS) query_cost_ms=\(firstLookMS - firstObservationMS) loading_observed=\(loadingSeen ? 1 : 0) loading_ms=\(loadingMS < 0 ? "n/a" : String(loadingMS)) loading_first_ms=\(loadingFirstMS) loading_last_ms=\(loadingLastMS) loading_surface=\(loadingSurfaceID.isEmpty ? "none-observed" : loadingSurfaceID) loading_title=\(loadingTitle.isEmpty ? "n/a" : loadingTitle) cards=\(settledCards.count) hittable=\(settledCards.filter { $0.isHittable }.count) polls=\(polls) first_poll_ms=\(firstPollMS) launch_returned_ms=\(launchReturnedMS) first_look_shot_ms=\(firstLookMS) app_state_after_launch=\(stateAfterLaunch)")
        if !warmVerified {
            print("REOPEN verdict=inconclusive reason=warm-precondition-unverified — the relaunch above happened, but with no proof that the previous run's state reached disk, so `ttff_card_ms`, `loading_*` and `cards` describe an unlabelled start and must not be read as a warm-start result")
        }
        if !loadingSeen {
            print("REOPEN loading_surfaces=neither-observed window_sampled_ms=from_launch_return_to_\(firstCardMS < 0 ? "timeout" : String(firstCardMS)) — no sample from the first observation onward found `initial-feed-loading` or `feed-empty-state`; this says nothing about the window before `launch()` returned")
        }
        print("REOPEN persisted_before \(persistedBefore.evidence)")
        print("REOPEN persisted_after \(persistedAfter.evidence)")
        if firstCardMS < 0 {
            // Guard 4 — name the layer, or say plainly that it cannot be named: an absent persisted row is a
            // save-path miss, a signature mismatch a restore-ordering one — and the signature itself
            // (`FeedStore.pageCacheSignature`) is not reachable from the UI-test target, so the stored keys
            // are reported and the signature is declared unavailable rather than guessed.
            print("REOPEN miss=no-card-within-30s layer=indeterminate stored_keys=\(persistedBefore.pageKeys.joined(separator: ",")) computed_signature=unavailable-in-test-target (pageCacheSignature lives in the app target)")
        }

        print("✅ All exploration screenshots saved to: \(screenshotDir)")
    }



    /// The first card that can actually take the press, scrolling back to the top if none is on
    /// screen. Existence is not hittability: the journey swipes the feed repeatedly, and a matched card
    /// with a negative y (`{{0.0, -686.3}, …}`) fails with "Not hittable" — the same class of bug as the
    /// blind first-match tap.
    private func firstHittableCard() -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-")
        for _ in 0..<5 {
            let cards = app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
            if let card = cards.first(where: { $0.isHittable }) { return card }
            app.swipeDown()
            usleep(300_000)
        }
        return nil
    }

    /// Wait until `ArticleReaderView` is actually presented, before anything is said about its content.
    ///
    /// The reader is a `.sheet` wrapping a `NavigationStack` + `WKWebView` (`FeedScreen.swift:260`), and the feed screen
    /// has neither a navigation bar nor a web view — so `app.webViews` and `app.navigationBars` are precise, cheap,
    /// single-element readers of "the reader is up". Without this gate the pixel check below is a false positive in one
    /// step: the feed is ink-rich, so `bodyInkFraction()` passes on the feed's own pixels the instant after the tap, and
    /// the run then files two feed screenshots as `03-article-reader` / `04-article-scrolled`.
    @discardableResult
    private func ensureReaderPresented(timeout: TimeInterval = 20) -> Bool {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        var sawWebView = false
        var sawNavigationBar = false
        while Date() < deadline {
            sawWebView = app.webViews.firstMatch.exists
            if sawWebView { break }
            sawNavigationBar = app.navigationBars.firstMatch.exists
            if sawNavigationBar { break }
            usleep(250_000)
        }
        let presented = sawWebView || sawNavigationBar
        print("READER presented=\(presented ? 1 : 0) presented_ms=\(Int(Date().timeIntervalSince(started) * 1000)) signal=webview:\(sawWebView ? 1 : 0) navigationbar:\(sawNavigationBar ? 1 : 0)")
        return presented
    }

    /// Wait until the reader is showing an article, judged from **pixels** rather than the accessibility tree.
    ///
    /// History, because both earlier versions were the failure rather than the fix:
    /// 1. `sleep(3)` sampled the network: both reader captures came back showing the chrome (source title, close button,
    ///    blue progress bar still filling) over a **blank white body**, and the surface still counted as covered.
    /// 2. Polling `app.webViews.staticTexts` — first `allElementsBoundByIndex`, then a predicate-limited `firstMatch` —
    ///    asked XCUITest to resolve a UI query inside a live web page every 250 ms. On a large article that timed out and
    ///    killed the whole journey at **2 of 17 surfaces** with `Failed to resolve query: Timed out while evaluating UI
    ///    query`. A web view's accessibility snapshot is not a polling primitive.
    /// 3. The first pixel version, applied straight after the tap, passed on the **feed's** pixels — the false positive
    ///    `ensureReaderPresented()` now prevents. A pixel fraction says "this screen is not blank"; only the presentation
    ///    signal says *which* screen it is.
    ///
    /// The signal is a screenshot's non-background ("ink") fraction over the central region, sampled only after the sheet
    /// is up and twice in a row 400 ms apart, so the presentation animation's mixed frame cannot be mistaken for content.
    @discardableResult
    private func waitForReaderContent(timeout: TimeInterval = 20) -> Bool {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        var fraction = 0.0
        var passes = 0
        if app.webViews.firstMatch.exists { usleep(400_000) }  // let the sheet animation settle under the reader's own frame
        while Date() < deadline {
            fraction = bodyInkFraction()
            passes = fraction >= 0.06 ? passes + 1 : 0
            if passes >= 2 {
                print("READER content_ms=\(Int(Date().timeIntervalSince(started) * 1000)) ink=\(String(format: "%.3f", fraction))")
                return true
            }
            usleep(400_000)
        }
        print("READER content_timeout timeout_s=\(Int(timeout)) ink=\(String(format: "%.3f", fraction))")
        return false
    }

    /// Non-background pixel fraction of the current screen, central region only.
    ///
    /// One screenshot is downsampled into a 60×60 RGB grid; the outer 12% border (status bar, `ArticleReaderView`'s
    /// header, its in-web-view progress bar) is ignored. A pixel counts as ink when it is not near-white.
    private func bodyInkFraction() -> Double {
        guard let cgImage = app.screenshot().image.cgImage else { return 0 }
        let side = 60
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        let margin = Int(Double(side) * 0.12)
        var counted = 0
        var inked = 0
        for row in margin..<(side - margin) {
            for column in margin..<(side - margin) {
                let index = (row * side + column) * 4
                let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
                counted += 1
                if red < 240 || green < 240 || blue < 240 { inked += 1 }
            }
        }
        return counted == 0 ? 0 : Double(inked) / Double(counted)
    }

    /// Dismiss a presented sheet by its own control, never by "the first hittable button": on a sheet
    /// that can be a filter chip, which toggles state and leaves the sheet up, and the next captures
    /// would then photograph the sheet while the run reports the surface as verified.
    private func dismissSheet(preferring identifier: String) {
        if app.buttons[identifier].exists, app.buttons[identifier].isHittable {
            app.buttons[identifier].tap()
            return
        }
        if app.navigationBars.buttons.allElementsBoundByIndex.first(where: { $0.isHittable }) != nil {
            app.navigationBars.buttons.allElementsBoundByIndex.first(where: { $0.isHittable })?.tap()
            return
        }
        // A .presentationDetents sheet has no top-level close control, and `app.swipeDown()` is synthesized at the
        // app's centre — inside the sheet's scroll list — so it scrolls the sheet instead of dismissing it. The
        // failure dump names the affordance the sheet actually exposes: an element labelled "Sheet Grabber".
        let grabber = app.buttons["Sheet Grabber"].exists ? app.buttons["Sheet Grabber"] : app.staticTexts["Sheet Grabber"]
        if grabber.exists {
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            return
        }
        app.swipeDown()
    }

    /// Drives the one flow that reaches the breadth branch: a **manual refresh** (`forceFetch`). The filter
    /// combos do not reach it — with a full page and `needsFilteredBreadth` false for `.all`, `wantsFetch` is
    /// false and no fetch happens at all, which is why no `branch=` line ever appeared for them.
    func testRefreshReachesBreadthFetch() {
        waitForAppReady()
        XCTAssertNotNil(firstHittableCard(), "need a page before refreshing")
        for _ in 0..<3 {
            app.swipeDown()
            usleep(400_000)
        }
        sleep(20)
        XCTAssertNotNil(firstHittableCard(), "the page must survive a refresh")
    }

    /// Evidence-only probe for the latency doctrine's item 8, run **before** any optimising:
    ///
    /// > Given enough time, a filter change updates *only from what is already there* — ready cards, all pretty — and
    /// > the background then starts adjusting to the new reality.
    ///
    /// So the case has to be classified first: at the instant of the change, does the store already hold render-ready
    /// content for the filter being switched to? Two changes are measured — the language filter set to the language the
    /// page is already showing, and the content type set to one the store may hold nothing of. No assertions: every
    /// signal is printed with a wall-clock stamp so it can be joined with the app's own log (`[TaxonomyTrace] setFilter`,
    /// `reloadFromSQLite … loaded/filtered`, `flush gen=… local page published`, `[Latency] flush … localOfType=`), which
    /// is where the *counts* come from — the unit-suite wall clock is not an instrument for this.
    ///
    /// What this probe can and cannot say, both measured:
    /// - `cards()` counts **rendered descendants**, not the store's page (a lazily built list showed 4–8 of the 9
    ///   published items), so it measures the user-visible window, never page size. Page size comes from the app log.
    /// - The page-clear → first-card interval is the window in which the user is not looking at ready content. Which
    ///   surface filled it is available since 2026-09-17 (`initial-feed-loading` on `InitialFeedLoadingView`,
    ///   `feed-empty-state` on `FeedEmptyStateView` — the latter is what a `ready`-but-empty feed shows), so a follow-up
    ///   can name it; this probe deliberately measures only the window, to keep its two changes comparable.
    /// - A change target is not "prepared" or "radical" by construction: the label is only allowed to be attached once
    ///   the app log reports the matching row count (`reloadFromSQLite … filtered=N`, `localOfType=N`) for that
    ///   generation. The probe supplies the timing; the log supplies the classification.
    func testFilterChangeClassification() {
        waitForAppReady()
        guard firstHittableCard() != nil else {
            XCTFail("classification needs a prepared page first")
            return
        }
        let cardPredicate = NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-")
        func cards() -> [XCUIElement] { app.descendants(matching: .any).matching(cardPredicate).allElementsBoundByIndex }
        func languages() -> [String] {
            Set(cards().compactMap { element -> String? in
                let parts = element.identifier.split(separator: "-")
                guard parts.count >= 3, parts[0] == "feed", parts[1] == "item" else { return nil }
                let code = String(parts[2])
                return code == "und" ? nil : code
            }).sorted()
        }
        let openingIDs = cards().map(\.identifier)
        print("FILTERCHANGE before at=\(ISO8601DateFormatter().string(from: Date())) cards=\(openingIDs.count) languages=\(languages()) first_ids=\(openingIDs.prefix(3).joined(separator: ","))")

        // The sheet must never be toggled blind: every tap on `filter-button` while it is open **closes** it, which is
        // how the first version of this probe measured nothing (`skipped=chip-unavailable` on both cases while the app
        // was on the feed). Look first, exactly as `ensureMenuRow` does for the more-menu.
        func sheetIsOpen() -> Bool { app.buttons["filter-done"].exists }
        func openSheet() {
            if sheetIsOpen() { return }
            let button = app.buttons["filter-button"]
            if button.waitForExistence(timeout: 10) {
                button.tap()
                sleep(2)
            }
        }
        func findChip(_ identifier: String, swipes: Int = 8) -> XCUIElement? {
            openSheet()
            guard sheetIsOpen() else {
                print("FILTERCHANGE sheet_unavailable looking=\(identifier)")
                return nil
            }
            // `exists` is visibility-independent, so it can answer true for a chip scrolled out of the sheet — and
            // synthesizing a tap or a swipe on that element aborts with "Not hittable". Require hittability, and scroll
            // the sheet (not the feed) until the chip can actually take the event.
            for _ in 0..<swipes {
                let chip = app.buttons[identifier]
                if chip.exists, chip.isHittable { return chip }
                app.swipeUp()
                usleep(300_000)
            }
            let chip = app.buttons[identifier]
            return chip.exists && chip.isHittable ? chip : nil
        }

        /// Tap a chip, dismiss the sheet (the reload is deferred to dismissal — `isEditingFilters`), then sample.
        func measure(_ label: String, chip: XCUIElement?) {
            guard let chip, chip.exists else {
                let dump = app.buttons.allElementsBoundByIndex.map(\.identifier).filter { !$0.isEmpty }
                print("FILTERCHANGE \(label) skipped=chip-unavailable sheet_open=\(sheetIsOpen() ? 1 : 0) button_ids=\(dump.prefix(30))")
                return
            }
            // Baseline is taken here, immediately before this change's tap, so `ids_unchanged` compares the settled page
            // to the page the user was looking at *for this change* — a single baseline captured before case A would make
            // case B's comparison meaningless.
            let idsBefore = cards().map(\.identifier)
            if !chip.isHittable { chip.swipeUp() }
            chip.tap()
            let chipAt = Date()
            // Scrolling the sheet to reach a chip can push `filter-done` out of reach: scroll back before tapping,
            // otherwise the sheet stays open and the reload is never scheduled.
            let done = app.buttons["filter-done"]
            if done.exists, !done.isHittable {
                for _ in 0..<6 where !done.isHittable {
                    app.swipeDown()
                    usleep(200_000)
                }
            }
            if done.exists { done.tap() } else { dismissSheet(preferring: "filter-done") }
            let t0 = Date()
            var clearedAt = -1
            var firstCardAt = -1
            var polls = 0
            while Date().timeIntervalSince(t0) < 30 {
                polls += 1
                let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
                let count = cards().count
                if count == 0, clearedAt < 0 { clearedAt = elapsed }
                if count > 0, clearedAt >= 0 { firstCardAt = elapsed; break }
                if count > 0, clearedAt < 0, elapsed > 3000 { break }  // never cleared: kept, not re-rendered
                usleep(250_000)
            }
            let settledIDs = cards().map(\.identifier)
            // `ids_unchanged` is *not* a correctness signal: `cards()` samples only what the lazy list has built, so
            // scrolling or republishing changes the sample without proving anything about page identity. The correctness
            // signal is `languages_after` (does the page match the filter that was just applied?); `ids_unchanged` is
            // reported only to show whether the sampled rows moved at all.
            print("FILTERCHANGE \(label) chip_tap_at=\(ISO8601DateFormatter().string(from: chipAt)) clear_ms=\(clearedAt) first_card_ms=\(firstCardAt) polls=\(polls) cards_before=\(idsBefore.count) cards_after=\(settledIDs.count) languages_after=\(languages()) page_kept=\(clearedAt < 0 ? 1 : 0) ids_sampled_same=\(settledIDs == idsBefore ? 1 : 0)")
        }

        // Case A — the target filter is the language the page is already showing. `languages()` gives the target; the
        // classification is still made from the app log (`reloadFromSQLite … filtered=`, `flush … localOfType=`), because
        // the probe can only see rendered rows.
        let pageLanguage = languages().first
        print("FILTERCHANGE case_A_target_language=\(pageLanguage ?? "none")")
        measure("A-language", chip: pageLanguage.flatMap { findChip("language-\($0)") })
        capture("18-filterchange-after-language")

        // Case B — a different content type. **Not** assumed to be radical: whether the store holds any render-ready
        // content of that type is what the app log decides for this generation (`[Latency] flush … localOfType=`), and
        // the run's report is labelled from that number, not from the choice of chip.
        measure("B-type-podcasts", chip: findChip("content-type-podcasts"))
        capture("19-filterchange-after-type")
        print("FILTERCHANGE done")
    }

    /// Dismiss the Settings sheet the way the sheet itself expects: a drag from its grabber.
    ///
    /// `SettingsSheetView` uses `.presentationDetents([.medium, .large])` and has no top-level close button, so
    /// `dismissSheet(preferring: "back")` falls through to `app.swipeDown()` — which, mid-sheet, **scrolls the
    /// sheet** (the failure capture shows it parked on Storage/Share/About/Feedback) instead of closing it. Step 8
    /// then ran inside Settings, where the menu is unreachable.
    private func dismissSheetByDrag() {
        // A .presentationDetents sheet has no top-level close control. `app.otherElements.firstMatch` used to be the
        // fallback and dragged from the very top of the window — a system pull-down that cannot close the sheet while
        // looking like a successful gesture. The sheet names its own affordance (the failure dump showed it).
        let grabber = app.buttons["Sheet Grabber"].exists ? app.buttons["Sheet Grabber"] : app.staticTexts["Sheet Grabber"]
        guard grabber.exists else {
            capture("97-no-sheet-grabber")
            XCTFail("dismissSheetByDrag found no element labelled \"Sheet Grabber\" — the sheet may not be presented")
            return
        }
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
    }

    /// Wait (without swiping — swipes on the feed change what later steps see) until the feed is back.
    @discardableResult
    private func waitForFeed(timeout: TimeInterval = 8) -> Bool {
        let anchor = app.buttons["filter-button"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if anchor.exists, anchor.isHittable { return true }
            usleep(300_000)
        }
        return anchor.exists && anchor.isHittable
    }

    /// Bring a more-menu row into view **without toggling the menu shut**.
    ///
    /// Every step here used `if moreMenu.exists { moreMenu.tap() … }`, which assumes the menu is closed — but the
    /// previous step's dismissal falls back to tapping `more-menu`, which *toggles*. Fixing one step then moved
    /// the loss to the next (settings unlocked, add-feed lost). Look first; open only when the row is absent.
    private func ensureMenuRow(_ label: String) -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", label)
        func row() -> XCUIElement? {
            if app.buttons.element(matching: predicate).exists { return app.buttons.element(matching: predicate) }
            if app.staticTexts.element(matching: predicate).exists { return app.staticTexts.element(matching: predicate) }
            return nil
        }
        if let found = row() { return found }
        // "Look first" is not enough: a row that only exists *after* the menu opens cannot be seen while it is
        // closed, so this tapped `more-menu` and *closed* an open menu — the dump proved it (it showed the feed
        // list: Search/Bookmark/Filter/More). Decide open vs. closed with a canary row that is always in the menu.
        // "Settings" is the sheet's own title too, so it is a false canary (it read true while the app was still
        // inside the sheet). "Export" exists only in this menu.
        let canary = app.buttons["Export"].exists || app.staticTexts["Export"].exists
        if !canary {
            let menu = app.buttons["more-menu"]
            if menu.waitForExistence(timeout: 5) {
                menu.tap()
                sleep(1)
                // Measure immediately after the tap, before any swipe. `exists` is visibility-independent, so an
                // absent row here means the menu never opened; the swipes cannot make an absent row appear, and a
                // dump taken after them only describes the end state.
                let labels = app.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
                print("MENU-AFTER-TAP looking=\(label) addFeed=\(app.buttons["Add Feed"].exists) exportRow=\(app.buttons["Export"].exists) appState=\(app.state.rawValue) labels=\(labels.prefix(14))")
            }
        }
        for _ in 0..<6 {
            if let found = row() { return found }
            app.swipeUp()
            usleep(400_000)
        }
        if row() == nil {
            capture("99-menu-fail-\(label.replacingOccurrences(of: " ", with: "-"))")
            print("MENU-DUMP-STATE looking=\(label) menu-open=\(app.buttons["Export"].exists || app.staticTexts["Export"].exists)")
            // Stop guessing labels: print what the menu actually contains when the row is missing.
            let labels = (app.buttons.allElementsBoundByIndex.map(\.label) + app.staticTexts.allElementsBoundByIndex.map(\.label))
                .filter { !$0.isEmpty }
            print("MENU-DUMP looking=\(label) labels=\(labels.prefix(40))")
        }
        return row()
    }

    /// Tap the first button that can actually receive the event. `app.buttons.firstMatch` picks the
    /// first button in the tree, which on the feed screen is a card that is not hittable — the run then
    /// aborts with "Failed to synthesize event: Not hittable" and every surface after it goes
    /// unexercised (measured: 12 of the 16 steps ever captured).
    private func tapFirstHittableButton() {
        if let button = app.buttons.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            button.tap()
        }
    }

    private func capture(_ name: String) {
        // The lane can leave the app backgrounded or dead: a failure capture showed the simulator's home screen, which
        // silently corrupts every later step and made per-step failures look like UI problems. Bring it forward and
        // record the mismatch loudly instead of measuring it.
        if app.state != .runningForeground {
            // Never activate() here: it relaunches a dead app, which would turn a mid-journey kill into a silent cold
            // start whose later screenshots look verified. Fail loudly instead, and keep the evidence.
            let diag = XCTAttachment(screenshot: app.screenshot())
            diag.name = "00-not-foreground-\(name)"
            diag.lifetime = .keepAlways
            add(diag)
            XCTFail("app not in foreground at capture \(name) (state=\(app.state.rawValue)) — run invalid")
        }
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Also save directly to disk. On iOS `pngRepresentation` is non-optional Data (the
        // optional form is macOS), which is why this file never compiled while unlisted in the
        // project — that is how it ended up outside the target.
        let png = screenshot.pngRepresentation
        let path = "\(screenshotDir)/\(name).png"
        try? png.write(to: URL(fileURLWithPath: path))
        print("📸 Captured: \(name)")
    }

    private func waitForAppReady() {
        guard app.buttons["filter-button"].waitForExistence(timeout: 45) else {
            // Fail loudly instead of "continuing anyway": without the app there is nothing to capture,
            // and continuing spends ~2.5 minutes producing zero evidence (measured: a hung launch showed
            // 60 s waiting for the app to idle, then 45 s here, then "cannot request screenshot data
            // because it does not exist" and 0 captures). Restart/reinstall the simulator and re-run.
            XCTFail("App never became ready: no filter button within 45 s — nothing to capture")
            return
        }
        // Chrome is not content. `filter-button` exists before anything is on screen, and the first page
        // on a **fresh install** is not the ~11 s this comment used to claim: measured on the frozen
        // tree from the app's own log (`DisplayState: publishCards firstPaint`) the cold first paint
        // landed 81.4 s after the process started (OPML parse + taxonomy build + empty SQLite, so all 20
        // cards come off the network). With the old 30 s budget the wait gave up while the app was still
        // on `InitialFeedLoadingView`, `01-main-feed` photographed the loading screen, and step 3's
        // `firstHittableCard()` returned nil — the run then reported "16 surfaces" while silently
        // holding 14, the reader pair `03`/`04` missing. A readiness gate that expires before the app is
        // ready does not skip a step, it fabricates a surface.
        let cardPredicate = NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-")
        let card = app.descendants(matching: .any).matching(cardPredicate).firstMatch
        let cardWaitStart = Date()
        let cardArrived = card.waitForExistence(timeout: 150)
        print("READY card_after_ms=\(Int(Date().timeIntervalSince(cardWaitStart) * 1000)) arrived=\(cardArrived ? 1 : 0)")
        if !cardArrived {
            print("⚠️ No feed card within 150s — content-dependent steps will skip")
        }
        sleep(8)
    }

    // MARK: - Reopen measurement helpers

    /// What the app container holds for the persisted first page, read from the test runner.
    private struct ReopenPersistedPage {
        /// False when the container could not be located/read at all — unverified, not proven absent.
        var containerFound: Bool
        var evidence: String
        /// The stored keys: the `visible-page-cache*` file names that key the persisted page.
        var pageKeys: [String]
        var usable: Bool
    }

    /// Guard 1's evidence. The app's container is found without hardcoding a device UDID: this runner's
    /// `NSHomeDirectory()` is `<device>/data/Containers/Data/Application/<runner-uuid>`, so four
    /// `deleteLastPathComponent()` calls land on `<device>/data`, whose `Containers/Data/Application`
    /// holds the app's container — the sibling whose metadata plist names `com.feedmine.app`. The persisted
    /// first page is `Library/Caches/visible-page-cache*.json` (`FeedDisplayState.pageCacheURL`).
    private func reopenPersistedPageEvidence() -> ReopenPersistedPage {
        var deviceData = URL(fileURLWithPath: NSHomeDirectory())
        for _ in 0..<4 { deviceData.deleteLastPathComponent() }
        let applications = deviceData.appendingPathComponent("Containers/Data/Application")
        let candidates = (try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)) ?? []
        var container: URL?
        for candidate in candidates {
            let metadata = candidate.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: metadata),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let fields = plist as? [String: Any],
                  (fields["MCMMetadataIdentifier"] as? String) == "com.feedmine.app" else { continue }
            container = candidate
            break
        }
        guard let appContainer = container else {
            return ReopenPersistedPage(
                containerFound: false,
                evidence: "container=unreadable searched=\(applications.path) candidates=\(candidates.count)",
                pageKeys: [],
                usable: false
            )
        }
        let caches = appContainer.appendingPathComponent("Library/Caches")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: caches,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        let pages = entries.filter { $0.lastPathComponent.hasPrefix("visible-page-cache") && $0.pathExtension == "json" }
        var keys: [String] = []
        var described: [String] = []
        var usable = false
        for page in pages.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? page.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let items = Self.reopenPageItemCount(at: page)
            usable = usable || items > 0
            keys.append(page.lastPathComponent)
            described.append("\(page.lastPathComponent){bytes=\(values?.fileSize ?? -1) items=\(items) mtime=\(Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))}")
        }
        return ReopenPersistedPage(
            containerFound: true,
            evidence: "container=found pages=\(pages.count) " + described.joined(separator: " "),
            pageKeys: keys,
            usable: usable
        )
    }

    /// Item count of a persisted page, straight from the JSON — the page's own content, not a file size.
    private static func reopenPageItemCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let items = fields["items"] as? [Any] else { return -1 }
        return items.count
    }
}
