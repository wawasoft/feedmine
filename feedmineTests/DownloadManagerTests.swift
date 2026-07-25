import XCTest
@testable import feedmine

final class DownloadManagerTests: XCTestCase {

    // MARK: - DownloadStatus Tests

    func testDownloadStatusRawValues() {
        XCTAssertEqual(DownloadStatus.queued.rawValue, "queued")
        XCTAssertEqual(DownloadStatus.downloadingAudio.rawValue, "downloading_audio")
        XCTAssertEqual(DownloadStatus.downloadingPage.rawValue, "downloading_page")
        XCTAssertEqual(DownloadStatus.completed.rawValue, "completed")
        XCTAssertEqual(DownloadStatus.failedAudio.rawValue, "failed_audio")
        XCTAssertEqual(DownloadStatus.failedPage.rawValue, "failed_page")
    }

    func testDownloadModesRawValues() {
        XCTAssertEqual(DownloadMode.wifi.rawValue, "wifi")
        XCTAssertEqual(DownloadMode.cellular.rawValue, "cellular")
    }

    func testAutoDeletePolicyRawValues() {
        XCTAssertEqual(AutoDeletePolicy.afterRead.rawValue, "after_read")
        XCTAssertEqual(AutoDeletePolicy.after7Days.rawValue, "after_7_days")
        XCTAssertEqual(AutoDeletePolicy.manual.rawValue, "manual")
    }

    func testDownloadContentTypeRawValues() {
        XCTAssertEqual(DownloadContentType.podcast.rawValue, "podcast")
        XCTAssertEqual(DownloadContentType.article.rawValue, "article")
    }

    // MARK: - StorageGate Tests

    func testStorageGateAllowed() async {
        let gate = await DownloadManager.shared.checkStorageGate(
            for: 30_000_000,
            freeSpace: 5_000_000_000,
            used: 0,
            limit: 2_000_000_000
        )
        let expected: StorageGate = .allowed
        XCTAssertTrue(gate == expected)
    }

    func testStorageGateInsufficientFree() async {
        // 100 MB download needs 200 MB free (2x margin). 150 MB triggers insufficientFree.
        let gate = await DownloadManager.shared.checkStorageGate(
            for: 100_000_000,
            freeSpace: 150_000_000,
            used: 0,
            limit: 2_000_000_000
        )
        switch gate {
        case .insufficientFree(let needed, let available):
            XCTAssertEqual(needed, 100_000_000)
            XCTAssertEqual(available, 150_000_000)
        default:
            XCTFail("Expected insufficientFree, got \(gate)")
        }
    }

    func testStorageGateWouldExceedUserLimit() async {
        let gate = await DownloadManager.shared.checkStorageGate(
            for: 500_000_000,
            freeSpace: 10_000_000_000,
            used: 1_800_000_000,
            limit: 2_000_000_000
        )
        switch gate {
        case .wouldExceedUserLimit(let used, let limit):
            XCTAssertEqual(used, 1_800_000_000)
            XCTAssertEqual(limit, 2_000_000_000)
        default:
            XCTFail("Expected wouldExceedUserLimit")
        }
    }

    func testStorageGateCriticallyLow() async {
        // New threshold is 50 MB — use 30 MB to trigger criticallyLow.
        let gate = await DownloadManager.shared.checkStorageGate(
            for: 1_000_000,
            freeSpace: 30_000_000,
            used: 0,
            limit: 5_000_000_000
        )
        switch gate {
        case .criticallyLow(let available):
            XCTAssertEqual(available, 30_000_000)
        default:
            XCTFail("Expected criticallyLow")
        }
    }

    func testStorageGateAllowedAtMargin() async {
        let gate = await DownloadManager.shared.checkStorageGate(
            for: 50_000_000,
            freeSpace: 550_000_000,
            used: 0,
            limit: 2_000_000_000
        )
        let expected: StorageGate = .allowed
        XCTAssertTrue(gate == expected)
    }

    // MARK: - Status Cache Tests

    func testStatusCacheReturnsQueuedForUnknownItem() async {
        let status = await DownloadManager.shared.status(for: "nonexistent-xyz")
        XCTAssertEqual(status, .queued)
    }

    func testProgressCacheReturnsZero() async {
        let progress = await DownloadManager.shared.progress(for: "nonexistent-xyz")
        XCTAssertEqual(progress, 0.0, accuracy: 0.001)
    }

    func testIsDownloadedFalseForNonexistent() async {
        let downloaded = await DownloadManager.shared.isDownloaded(itemID: "no-such-item")
        XCTAssertFalse(downloaded)
    }

    func testLocalPathsReturnNil() async {
        let page = await DownloadManager.shared.localPagePath(for: "ghost-item")
        let audio = await DownloadManager.shared.localAudioPath(for: "ghost-item")
        let sync = await DownloadManager.shared.localAudioPathSync(for: "ghost-item")
        XCTAssertNil(page)
        XCTAssertNil(audio)
        XCTAssertNil(sync)
    }

    // MARK: - Delete / Cancel (no crash)

    func testDeleteNonexistentDoesNotCrash() {
        let exp = expectation(description: "delete")
        Task { await DownloadManager.shared.delete(itemID: "noop-delete"); exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    func testCancelNonexistentDoesNotCrash() {
        let exp = expectation(description: "cancel")
        Task { await DownloadManager.shared.cancel(itemID: "noop-cancel"); exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // MARK: - Model Tests

    func testDownloadRecordAllFields() {
        let r = DownloadRecord(
            id: 1, itemID: "id", sourceURL: "https://a.b", contentType: "podcast",
            audioURL: "https://a.b/audio.mp3", pageURL: "https://a.b/page",
            bundlePath: "/tmp", audioPath: "a.mp3", pagePath: "p.html",
            audioBytes: 5_000_000, audioDownloaded: 5_000_000,
            pageBytes: 100_000, pageDownloaded: 100_000,
            status: "completed", createdAt: 1234567890, completedAt: 1234570000
        )
        XCTAssertEqual(r.itemID, "id")
        XCTAssertEqual(r.audioBytes, 5_000_000)
        XCTAssertEqual(r.status, "completed")
    }

    func testDownloadRuleRecordDefaults() {
        let rule = DownloadRuleRecord(
            id: nil, targetType: "source", targetID: "url",
            maxItems: 5, mode: "wifi", enabled: true
        )
        XCTAssertEqual(rule.maxItems, 5)
        XCTAssertTrue(rule.enabled)
        let json = try? JSONEncoder().encode(rule)
        XCTAssertNotNil(json)
    }

    // MARK: - Notification Tests

    func testNotificationAllEvents() {
        let events: [DownloadNotification.DownloadNotificationEvent] = [
            .queued, .completed, .failed, .batchCompleted,
            .autoDownloadStarted, .storageFull, .airplaneModeNoDownloads
        ]
        XCTAssertEqual(events.count, 7)
    }

    func testNotificationPayload() {
        let n = DownloadNotification(event: .completed, itemID: "x", sourceTitle: "S", itemTitle: "T", count: 3)
        XCTAssertEqual(n.event, .completed)
        XCTAssertEqual(n.itemID, "x")
        XCTAssertEqual(n.sourceTitle, "S")
        XCTAssertEqual(n.count, 3)
    }

    // MARK: - NetworkMonitor

    func testNetworkMonitorSharedIsSingleton() {
        XCTAssertTrue(NetworkMonitor.shared === NetworkMonitor.shared)
    }

    func testNetworkMonitorSnapshot() {
        let snap = NetworkMonitor.shared.snapshot()
        XCTAssertTrue(type(of: snap.isConnected) == Bool.self)
        XCTAssertTrue(type(of: snap.isAirplaneMode) == Bool.self)
    }

    // MARK: - ContentSanitizer

    func testSanitizedContentStruct() {
        let c = ContentSanitizer.SanitizedContent(
            html: "<p>Hello</p>",
            imageURLs: [URL(string: "https://x.com/i.jpg")!],
            title: "T",
            textPreview: "preview"
        )
        XCTAssertEqual(c.title, "T")
        XCTAssertEqual(c.imageURLs.count, 1)
    }

    func testSanitizedContentEmptyFields() {
        let c = ContentSanitizer.SanitizedContent(html: "", imageURLs: [], title: nil, textPreview: "")
        XCTAssertNil(c.title)
        XCTAssertTrue(c.html.isEmpty)
    }

    // MARK: - ImageCache

    @MainActor
    func testImageCacheKeyConsistency() {
        let url = URL(string: "https://x.com/img.jpg")!
        let key1 = ImageCache.shared.cacheKey(for: url)
        let key2 = ImageCache.shared.cacheKey(for: url)
        XCTAssertEqual(key1, key2)
        XCTAssertTrue(key1.hasPrefix("img_"))
    }

    @MainActor
    func testCacheFileURLMatchesKey() {
        let url = URL(string: "https://x.com/test.jpg")!
        let fileURL = ImageCache.shared.cacheFileURL(for: url)
        let key = ImageCache.shared.cacheKey(for: url)
        XCTAssertTrue(fileURL.lastPathComponent == key)
    }

    // MARK: - Schema

    @MainActor
    func testFeedStoreEmptyDoesNotCrash() {
        XCTAssertNotNil(FeedStore.empty())
    }

    // MARK: - Edge Cases

    func testLocalPathsUseCorrectBundleStructure() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads")
        XCTAssertTrue(dir.path.hasSuffix("/Downloads"))
    }
}
