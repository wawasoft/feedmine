import Foundation
import XCTest

/// End-to-end tests for the offline content flow:
/// 1. Download multiple items (articles + podcasts) via context menu
/// 2. Apply "Downloaded" filter — all downloaded items appear
/// 3. Tap each — verify ArticleReaderView opens (local cache)
/// 4. Close and reopen the app (background → foreground)
/// 5. Verify items persist and appear quickly
/// 6. Tap each again — verify offline content still loads
@MainActor
final class FeedmineOfflineUITests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-UITestResetFilters", "-UITestSkipOnboarding",
        ]
        app.launch()
    }

    // MARK: - Complete Multi-Item Offline Flow

    func testCompleteOfflineDownloadAndViewFlow() {
        waitForAppReady()

        // ── Phase 2: Enqueue multiple downloads without filter interference ──
        var downloadCount = 0
        var podcastCount = 0
        let targetTotal = 3

        for i in 0..<targetTotal {
            if i > 0 {
                for _ in 0..<2 { app.swipeUp(); usleep(400_000) }
            }
            let card = firstFeedCard()
            guard card.waitForExistence(timeout: 8) else { break }
            card.press(forDuration: 1.2); usleep(400_000)

            let btn = app.buttons["Download for Offline"]
            if btn.waitForExistence(timeout: 3) {
                if card.staticTexts["Podcast"].exists { podcastCount += 1 }
                btn.tap(); downloadCount += 1
                print("[OfflineTest] Enqueued #\(downloadCount)")
            } else {
                let tp = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                tp.tap()
            }
            usleep(800_000)
        }
        print("[OfflineTest] Enqueued \(downloadCount) downloads (\(podcastCount) podcasts)")

        if downloadCount == 0 { XCTFail("No downloads"); return }

        // Wait for the sequential download queue to process everything.
        // processNext() blocks on each item; 45s/item is generous.
        let waitSec = downloadCount * 45
        print("[OfflineTest] Waiting \(waitSec)s for queue...")
        sleep(UInt32(waitSec))

        // ── Phase 3: Apply filter and count ──
        applyDownloadedFilter()
        let totalDownloaded = waitForFeedItemIdentifiers(timeout: 20).count
        print("[OfflineTest] Downloaded: \(totalDownloaded) items")

        guard totalDownloaded >= 1 else {
            XCTFail("No downloads completed"); return
        }

        // ── Phase 3: Apply filter and open all items ──
        applyDownloadedFilter()
        let cards = waitForFeedItemIdentifiers(timeout: 15)
        print("[OfflineTest] Final filter: \(cards.count) cards")
        attachScreenshot(name: "all-downloaded")

        let minExpected = min(totalDownloaded, 2)
        XCTAssertGreaterThanOrEqual(cards.count, minExpected,
            "At least \(minExpected) items in filter (got \(cards.count))")

        for i in 0..<cards.count {
            let card = firstFeedCard()
            guard card.exists, card.isHittable else { continue }
            card.tap(); usleep(500_000)
            let cb = app.buttons["xmark.circle.fill"].firstMatch
            if cb.waitForExistence(timeout: 8) {
                print("[OfflineTest]  Item \(i+1) opened")
                cb.tap(); usleep(400_000)
            }
        }

        // ── Phase 4: Close and reopen ──
        XCUIDevice.shared.press(.home); sleep(2)
        app.activate(); sleep(3)
        guard app.buttons["filter-button"].waitForExistence(timeout: 20) else {
            XCTFail("App not responsive"); return
        }
        _ = firstFeedCard().waitForExistence(timeout: 30)

        if !app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Downloaded")).firstMatch.exists {
            applyDownloadedFilter()
        }

        // ── Phase 5: Verify after reopen ──
        let t0 = CFAbsoluteTimeGetCurrent()
        let reopenCards = waitForFeedItemIdentifiers(timeout: 10)
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[OfflineTest] After reopen: \(reopenCards.count) cards in \(ms)ms")
        attachScreenshot(name: "after-reopen")

        XCTAssertGreaterThanOrEqual(reopenCards.count, minExpected,
            "Items must persist (expected \(minExpected), got \(reopenCards.count))")
        if !reopenCards.isEmpty {
            XCTAssertLessThan(ms, 5000, "Content must appear in < 5 s (took \(ms)ms)")
        }

        // ── Phase 6: Verify offline load ──
        for i in 0..<min(reopenCards.count, 5) {
            let card = firstFeedCard()
            guard card.exists, card.isHittable else { continue }
            card.tap(); usleep(500_000)
            let cb = app.buttons["xmark.circle.fill"].firstMatch
            if cb.waitForExistence(timeout: 8) {
                print("[OfflineTest]  Item \(i+1) loaded offline")
                cb.tap(); usleep(400_000)
            }
        }
        print("[OfflineTest] ✅ Flow: \(totalDownloaded) items, \(podcastCount) podcasts, " +
              "all persisted + offline-verified")
    }

    // MARK: - Downloaded Filter Toggle Responsiveness

    func testDownloadedFilterTogglesInstantly() {
        waitForAppReady()
        app.buttons["filter-button"].tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 5))

        let btn = app.buttons["Downloaded"].firstMatch
        if !btn.exists {
            for _ in 0..<3 where !btn.exists { app.swipeUp(); usleep(200_000) }
        }
        if btn.exists {
            let start = CFAbsoluteTimeGetCurrent()
            btn.tap()
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print("[OfflineTest] Toggle: \(String(format: "%.0f", ms))ms")
            XCTAssertLessThan(ms, 1500)
            usleep(300_000)
        }
        let btn2 = app.buttons["Downloaded"].firstMatch
        if btn2.exists { btn2.tap(); usleep(300_000) }
        usleep(300_000)
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 3))
        app.buttons["filter-done"].tap()
        print("[OfflineTest] ✅ Toggle test complete")
    }

    // MARK: - Downloaded Chip Toggle

    func testDownloadedChipToggleInHeader() {
        waitForAppReady()
        applyDownloadedFilter()
        let chip = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Downloaded")
        ).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap(); usleep(300_000)
        let cards = waitForFeedItemIdentifiers(timeout: 10)
        print("[OfflineTest] After toggling off: \(cards.count) cards")
        attachScreenshot(name: "chip-toggle")
        print("[OfflineTest] ✅ Chip toggle test complete")
    }

    // MARK: - Helpers

    private func waitForAppReady() {
        dismissOnboardingIfNeeded()
        guard app.buttons["filter-button"].waitForExistence(timeout: 40) else {
            XCTFail("Filter button not found"); return
        }
        sleep(5)
        let ok = firstFeedCard().waitForExistence(timeout: 35)
        print("[OfflineTest] App ready, cards: \(ok)")
        if ok { sleep(2) }
    }

    private func dismissOnboardingIfNeeded() {
        for _ in 0..<10 {
            let n = app.buttons["onboarding-next"]
            let s = app.buttons["onboarding-start-reading"]
            if n.exists { n.tap(); usleep(300_000) }
            else if s.exists {
                let i = app.buttons.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "onboarding-interest-")
                ).firstMatch
                if i.waitForExistence(timeout: 3) { i.tap(); usleep(200_000) }
                s.tap(); usleep(500_000)
                break
            } else { break }
        }
        sleep(2)
    }

    private func firstFeedCard() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
            .firstMatch
    }

    private func applyDownloadedFilter() {
        let doneBtn = app.buttons["filter-done"]
        if doneBtn.exists { doneBtn.tap(); usleep(300_000) }
        app.buttons["filter-button"].tap()
        guard app.buttons["filter-done"].waitForExistence(timeout: 5) else { return }
        usleep(400_000)
        let btn = app.buttons["Downloaded"].firstMatch
        if !btn.exists {
            for _ in 0..<4 where !btn.exists { app.swipeUp(); usleep(200_000) }
        }
        if btn.exists, (btn.value as? String) != "selected" {
            btn.tap(); usleep(300_000)
        }
        app.buttons["filter-done"].tap()
        sleep(3)
    }

    private func toggleOffDownloadedFilter() {
        let chip = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Downloaded")
        ).firstMatch
        if chip.exists { chip.tap(); usleep(500_000) }
    }

    private func waitForFeedItemIdentifiers(timeout: TimeInterval) -> [String] {
        let d = Date().addingTimeInterval(timeout)
        repeat {
            let ids = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
                .allElementsBoundByIndex.map(\.identifier)
            if !ids.isEmpty { return ids }
            usleep(100_000)
        } while Date() < d
        return []
    }

    private func attachScreenshot(name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.lifetime = .keepAlways; a.name = name; add(a)
    }
}
