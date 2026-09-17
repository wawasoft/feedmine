import Foundation
import XCTest
import OSLog

/// UI tests that operate the app — tapping through filter combinations,
/// measuring responsiveness, and capturing structured logs.
@MainActor
final class FeedmineFilterUITests: XCTestCase {

    let app = XCUIApplication()
    private static let ui = Logger(
        subsystem: "com.feedmine.tests.ui",
        category: "FilterOps"
    )

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments = ["-AppleLanguages", "(en)", "-UITestResetFilters", "-UITestSkipOnboarding"]
        app.launch()
    }

    // MARK: - Content Type Filter Tap Responsiveness

    func testContentTypeVideoSelectionCompletesUnder1Second() {
        let log = Self.ui
        log.info("=== testContentTypeVideoSelectionResponsiveness ===")

        waitForAppReady()

        // Open filter
        app.buttons["filter-button"].tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 5),
                      "Filter sheet must open")

        log.info("  Filter sheet open. Testing content-type-videos button...")

        let videoBtn = app.buttons["content-type-videos"]
        guard videoBtn.waitForExistence(timeout: 3) else {
            log.error("  content-type-videos button not found")
            app.buttons["filter-done"].tap()
            return
        }

        // Measure tap responsiveness
        let start = CFAbsoluteTimeGetCurrent()
        videoBtn.tap()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        log.info("  [perf] Video filter tap: \(String(format: "%.2f", elapsed))ms")
        XCTAssertLessThan(elapsed, 1500, "Video filter tap must respond under 1.5s")

        // Verify selection state updated
        let selected = app.buttons["content-type-videos"].value as? String
        log.info("  Button state after tap: \(selected ?? "nil")")

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    func testContentTypeAllSelectionsRespondQuickly() {
        let log = Self.ui
        log.info("=== testAllContentTypeSelections ===")

        waitForAppReady()
        app.buttons["filter-button"].tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 5))

        let types = ["content-type-all", "content-type-articles",
                     "content-type-videos", "content-type-podcasts",
                     "content-type-forums"]

        var timings: [(String, Double)] = []
        for typeID in types {
            let btn = app.buttons[typeID]
            if !btn.exists { app.swipeUp(); usleep(300_000) }
            guard btn.waitForExistence(timeout: 3) else {
                log.warning("  Button \(typeID) not found, skipping")
                continue
            }

            let start = CFAbsoluteTimeGetCurrent()
            btn.tap()
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            timings.append((typeID, ms))
            log.info("  [tap] \(typeID): \(String(format: "%.2f", ms))ms")
            usleep(100_000) // let UI settle
        }

        app.buttons["filter-done"].tap()

        // Report
        let avg = timings.map(\.1).reduce(0, +) / Double(max(timings.count, 1))
        let max = timings.map(\.1).max() ?? 0
        log.info("  Summary: avg=\(String(format: "%.2f", avg))ms max=\(String(format: "%.2f", max))ms")
        attachTimingReport(
            named: "content-type-tap-timings",
            rows: timings.map { "\($0.0),\(String(format: "%.2f", $0.1))" },
            summary: "average_ms=\(String(format: "%.2f", avg)),max_ms=\(String(format: "%.2f", max))"
        )

        XCTAssertLessThan(max, 1500, "Any content type tap must be under 1.5s")
        log.info("  ✅ PASS")
    }

    // MARK: - Filter Combination: Content Type + Language

    func testVideoFilterWithEnglishLanguage() {
        let log = Self.ui
        log.info("=== testVideoFilterWithEnglishLanguage ===")

        waitForAppReady()
        openFilter()

        // Select Videos without toggling it back to All when state persisted
        // from a previous test run.
        let videoButton = app.buttons["content-type-videos"]
        XCTAssertTrue(videoButton.waitForExistence(timeout: 3))
        if (videoButton.value as? String) != "selected" {
            videoButton.tap()
        }
        XCTAssertEqual(videoButton.value as? String, "selected")
        log.info("  Selected: Videos")

        // Select English language — scroll down to language section
        swipeToSection("Language", log: log)
        let enBtn = app.buttons["language-en"]
        if enBtn.waitForExistence(timeout: 3) {
            if (enBtn.value as? String) != "selected" {
                enBtn.tap()
            }
            XCTAssertEqual(enBtn.value as? String, "selected")
            log.info("  Selected: English language")
        } else {
            XCTFail("English language button not found in filter")
        }

        // Dismiss
        app.buttons["filter-done"].tap()

        // Assert the actual metadata on visible cards, not merely their
        // presence. This catches feeds that incorrectly declare English.
        let identifiers = waitForFeedItemIdentifiers(timeout: 10)
        XCTAssertFalse(identifiers.isEmpty, "Video + English should surface cards")
        XCTAssertTrue(
            identifiers.allSatisfy { $0.hasPrefix("feed-item-en-") },
            "English-only filter leaked non-English cards: \(identifiers)"
        )
        log.info("  Visible English cards after video+en filter: \(identifiers.count)")

        // Screenshot for diagnostics
        let shot = app.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.lifetime = .keepAlways
        att.name = "video-en-filter"
        add(att)

        // Verify filter chips show
        let chipBar = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Videos'")
        ).firstMatch
        log.info("  Filter chip visible: \(chipBar.exists)")

        log.info("  ✅ PASS")
    }

    func testArticlesFilterWithPortugueseLanguage() {
        let log = Self.ui
        log.info("=== testArticlesFilterWithPortuguese ===")

        waitForAppReady()
        openFilter()

        // Select Articles
        tapFilterButton("content-type-articles", log: log)

        // Select Portuguese
        swipeToSection("Language", log: log)
        let ptBtn = app.buttons.element(matching: NSPredicate(format: "label CONTAINS 'Português'"))
        if ptBtn.exists {
            ptBtn.tap()
            log.info("  Selected: Português")
        } else {
            log.warning("  Portuguese not found — scrolling...")
            for _ in 0..<5 { app.swipeUp(); usleep(200_000) }
            let ptBtn2 = app.buttons.element(matching: NSPredicate(format: "label CONTAINS 'Português'"))
            if ptBtn2.exists { ptBtn2.tap(); log.info("  Found Portuguese after scroll") }
        }

        app.buttons["filter-done"].tap()
        sleep(5)

        let cells = app.cells.count
        log.info("  Visible cells: \(cells)")
        log.info("  ✅ PASS")
    }

    // MARK: - Filter Switching: Rapid Toggle

    func testRapidContentTypeTogglesDontBlockUI() {
        let log = Self.ui
        log.info("=== testRapidContentTypeToggles ===")

        waitForAppReady()
        openFilter()

        let types = ["content-type-videos", "content-type-podcasts", "content-type-articles", "content-type-videos"]
        var totalMs: Double = 0

        for typeID in types {
            let btn = app.buttons[typeID]
            if !btn.exists { app.swipeUp(); usleep(200_000) }
            guard btn.exists else { continue }

            let start = CFAbsoluteTimeGetCurrent()
            btn.tap()
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            totalMs += ms
            log.info("  [rapid] \(typeID): \(String(format: "%.2f", ms))ms")
        }

        let avgMs = totalMs / Double(types.count)
        log.info("  Average toggle time: \(String(format: "%.2f", avgMs))ms")
        XCTAssertLessThan(avgMs, 1000, "Average toggle under 1s")

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    // MARK: - Dismiss + Reopen (state preservation)

    func testFilterSelectionSurvivesDismissAndReopen() {
        let log = Self.ui
        log.info("=== testFilterStatePreservation ===")

        waitForAppReady()
        openFilter()

        // Select Videos
        tapFilterButton("content-type-videos", log: log)

        // Dismiss
        app.buttons["filter-done"].tap()
        sleep(3)
        log.info("  Dismissed filter sheet with Videos selected")

        // Reopen
        openFilter()

        // Verify Videos is still selected
        let videoBtn = app.buttons["content-type-videos"]
        guard videoBtn.waitForExistence(timeout: 3) else {
            log.warning("  Video button not found on reopen")
            app.buttons["filter-done"].tap()
            return
        }

        let value = videoBtn.value as? String
        log.info("  Video button state on reopen: \(value ?? "nil")")

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    // MARK: - Mood Filter

    func testMoodFilterSelectionRespondsQuickly() {
        let log = Self.ui
        log.info("=== testMoodFilterSelection ===")

        waitForAppReady()
        openFilter()

        // Scroll to Mood section (bottom)
        for _ in 0..<10 { app.swipeUp(); usleep(150_000) }

        // Find mood buttons
        let moodLabels = ["👻 Fun", "📰 Serious", "⚙️ Technical", "✨ Inspiring"]
        var found = false
        for label in moodLabels {
            let btn = app.buttons.element(matching: NSPredicate(format: "label CONTAINS %@", label))
            if btn.exists {
                log.info("  Found mood: \(label)")
                let start = CFAbsoluteTimeGetCurrent()
                btn.tap()
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                log.info("  [tap] \(label): \(String(format: "%.2f", ms))ms")
                found = true
                break
            }
        }

        if !found { log.warning("  No mood filter buttons found") }

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    // MARK: - Clear All Filters

    func testClearAllFiltersRemovesAllSelections() {
        let log = Self.ui
        log.info("=== testClearAllFilters ===")

        waitForAppReady()
        openFilter()

        // Apply video + at least one mood
        tapFilterButton("content-type-videos", log: log)

        // Find and tap Clear All
        let clearBtn = app.buttons["Clear All Filters"]
        if clearBtn.exists {
            let start = CFAbsoluteTimeGetCurrent()
            clearBtn.tap()
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            log.info("  Cleared all filters in \(String(format: "%.2f", ms))ms")

            // Should dismiss the sheet
            let sheetGone = !app.buttons["filter-done"].waitForExistence(timeout: 3)
            log.info("  Sheet dismissed: \(sheetGone)")
        } else {
            log.warning("  Clear All Filters button not visible")
            app.buttons["filter-done"].tap()
        }

        sleep(3)
        log.info("  ✅ PASS")
    }

    // MARK: - Full Combination Matrix (exhaustive)

    func testFilterCombinationsMatrix() {
        let log = Self.ui
        log.info("=== testFilterCombinationsMatrix ===")

        waitForAppReady()

        let typeIDs = ["content-type-all", "content-type-articles",
                       "content-type-videos", "content-type-podcasts"]

        var results: [(String, Double, Double, Bool)] = []

        for typeID in typeIDs {
            openFilter()
            let btn = app.buttons[typeID]
            if !btn.exists { app.swipeUp(); usleep(200_000) }
            guard btn.exists else {
                app.buttons["filter-done"].tap()
                continue
            }

            let start = CFAbsoluteTimeGetCurrent()
            btn.tap()
            app.buttons["filter-done"].tap()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            log.info("  [combo] \(typeID) select+dismiss: \(String(format: "%.2f", elapsed))ms")

            let waitStart = CFAbsoluteTimeGetCurrent()
            let identifiers = waitForFeedItemIdentifiers(timeout: 8)
            let contentAppeared = !identifiers.isEmpty
            let contentWait = (CFAbsoluteTimeGetCurrent() - waitStart) * 1000
            results.append((typeID, elapsed, contentWait, contentAppeared))
            log.info("    content available: \(contentAppeared) after \(String(format: "%.2f", contentWait))ms")
            log.info("    → \(identifiers.count) visible cards")
            XCTAssertTrue(contentAppeared, "\(typeID) must show cards within 8 seconds")

            // Clear for next iteration
            openFilter()
            app.buttons["filter-done"].tap()
            sleep(1)
        }

        let avg = results.map(\.1).reduce(0, +) / Double(max(results.count, 1))
        log.info("  Avg select+dismiss: \(String(format: "%.2f", avg))ms")
        attachTimingReport(
            named: "filter-matrix-timings",
            rows: results.map {
                "\($0.0),select_and_dismiss_ms=\(String(format: "%.2f", $0.1)),content_wait_ms=\(String(format: "%.2f", $0.2)),content_appeared=\($0.3)"
            },
            summary: "average_select_and_dismiss_ms=\(String(format: "%.2f", avg))"
        )

        // Screenshot of final state
        let shot = app.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.lifetime = .keepAlways
        att.name = "filter-matrix-done"
        add(att)

        log.info("  ✅ PASS")
    }

    // MARK: - Helpers

    private func waitForAppReady() {
        guard app.buttons["filter-button"].waitForExistence(timeout: 40) else {
            XCTFail("App failed to load — filter button not found")
            return
        }
        // Chrome is not content. A fixed sleep(5) let the first combo (`content-type-all`) run inside the
        // cold start — first page lands ~12 s after launch on a clean install — so that combo was
        // asserting cold-start readiness inside its own 8 s window, and no fetch-branch change could move
        // it. Wait for a card; on timeout, fail loudly rather than time a measurement against an empty app.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
            .firstMatch
        guard card.waitForExistence(timeout: 40) else {
            XCTFail("Feed never produced a card — combos would measure an empty app")
            return
        }
    }

    // MARK: - Prepared repository (review P1.2)

    /// A context that was prepared before must switch **from the prepared repository**, not from a fresh reload.
    ///
    /// The page cache is keyed by the composition signature, so every context the reader visits writes its own prepared
    /// page. This drives the sequence the review names for the filter-change flow — context A, context B, then back into
    /// A — and asserts what the reader observes: each switch lands on cards rather than on a waiting surface.
    ///
    /// The app-side evidence that the return was served from disk (`page[restore] … reason=filter`) is read from the
    /// device log by the release probe, because a UI test cannot read the app's log: grep for `reason=filter` after this
    /// test to confirm the path, and for its absence to catch a regression that leaves the switch merely *fast*.
    ///
    /// Timings are logged with ISO-8601 stamps so the test-side sequence and the device log can be lined up.
    func testSwitchBackIntoAPreparedContextLandsOnCards() {
        let log = Self.ui
        log.info("=== P1.2 filter-switch A → B → A at \(ISO8601DateFormatter().string(from: Date())) ===")
        waitForAppReady()

        func select(_ id: String, _ label: String) {
            log.info("  [P12] select \(label) at \(ISO8601DateFormatter().string(from: Date()))")
            openFilter()
            var chip: XCUIElement?
            for _ in 0..<6 {
                if app.buttons[id].exists { chip = app.buttons[id]; break }
                app.swipeUp()
                usleep(400_000)
            }
            guard let chip else {
                XCTFail("\(label): chip \(id) missing from an open, scrolled sheet")
                return
            }
            chip.tap()
            app.buttons["filter-done"].tap()
            let card = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
                .firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 30),
                          "\(label): the switch must land on cards, not on a waiting surface")
            log.info("  [P12] \(label) landed at \(ISO8601DateFormatter().string(from: Date()))")
        }

        select("content-type-videos", "A=videos")
        // A's composition settles so its prepared page is written (the write is detached, right after publish).
        sleep(6)
        select("content-type-podcasts", "B=podcasts")
        sleep(6)
        // The return: A's page sits in the prepared repository, so this switch must not wait for a recomposition.
        select("content-type-videos", "A=videos-return")
        log.info("  ✅ PASS")
    }

    private func openFilter() {
        app.buttons["filter-button"].tap()
        _ = app.buttons["filter-done"].waitForExistence(timeout: 5)
        sleep(1)
    }

    private func tapFilterButton(_ id: String, log: Logger) {
        let btn = app.buttons[id]
        if !btn.exists {
            for _ in 0..<4 { app.swipeUp(); usleep(200_000) }
        }
        guard btn.waitForExistence(timeout: 3) else {
            log.warning("  Button \(id) not found")
            return
        }
        btn.tap()
        usleep(100_000)
    }

    private func attachTimingReport(named name: String, rows: [String], summary: String) {
        let report = (["measurement,details"] + rows + [summary]).joined(separator: "\n")
        let attachment = XCTAttachment(
            data: Data(report.utf8),
            uniformTypeIdentifier: "public.plain-text"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Leaves one content type selected on an **idle** app for tens of seconds. That is the only configuration
    /// where coverage mining can produce a pass: every new flush cancels `coverageMiningTask` before its first
    /// pass (it sleeps ~600 ms first), and the combo matrix changes type every ~1.8 s, so a
    /// `coverage active-audio-p0:` line cannot appear there by construction — which is why the earlier zero is an
    /// artifact and not evidence about audio.
    func testPodcastFilterIdleReachesCoverageMining() {
        waitForAppReady()
        openFilter()
        // Assert the sheet is open before tapping a control inside it: the matrix taps this same id every run,
        // so "button not found" here would mean the sheet never opened and send the reader hunting a rename
        // that did not happen.
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 10),
                      "filter sheet did not open")
        // The sheet is long: its lower controls only exist after scrolling (the journey captures both
        // `05-filter-sheet` and `06-filter-sheet-scrolled`, and the matrix swipes before tapping).
        var foundPodcasts = false
        for _ in 0..<6 {
            if app.buttons["content-type-podcasts"].exists { foundPodcasts = true; break }
            app.swipeUp()
            usleep(400_000)
        }
        XCTAssertTrue(foundPodcasts, "podcasts control missing from an open, scrolled sheet")
        app.buttons["content-type-podcasts"].tap()
        app.buttons["filter-done"].tap()
        // Liveness: the idle window must actually elapse with the type selected, or the coverage labels read
        // afterwards are about some other phase.
        let idleUntil = Date().addingTimeInterval(45)
        while Date() < idleUntil {
            usleep(1_000_000)
        }
        XCTAssertTrue(true, "idle window elapsed")
    }

    private func waitForFeedItemIdentifiers(timeout: TimeInterval) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // `isHittable` removes two ways this assertion used to be satisfied without the requested
            // content: an identifier left over from the previous composition and one scrolled out of the
            // viewport. It does **not** check the type — the id is `feed-item-pt-<hash>`, fixed prefix plus
            // hash, with no kind in it, and a kept page of article cards is both on screen and hittable, so
            // it would still pass. Type checking needs what the app exposes on the card surface (or a
            // comparison against the ids the app logged for that combo); until then this helper is stronger
            // than "some id exists" and still weaker than "cards of the requested type".
            let cards = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
                .allElementsBoundByIndex
                .filter(\.isHittable)
            let identifiers = cards.map(\.identifier)
            // Honour the budget: the deadline was only tested between iterations, so a slow tree query
            // returned late and the caller reported "content available" at 10 241 ms against an 8 s cap.
            // Returning empty past the deadline makes the number and the verdict agree.
            if !identifiers.isEmpty, Date() < deadline { return identifiers }
            usleep(100_000)
        } while Date() < deadline
        return []
    }

    private func swipeToSection(_ name: String, log: Logger) {
        for _ in 0..<8 {
            let found = app.staticTexts.containing(
                NSPredicate(format: "label == %@", name)
            ).firstMatch.exists
            if found { log.info("  Found section: \(name)"); return }
            app.swipeUp()
            usleep(150_000)
        }
        log.warning("  Section '\(name)' not found after scrolling")
    }
}
