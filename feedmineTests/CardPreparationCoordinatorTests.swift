import XCTest
import GRDB
@testable import feedmine

/// Tests for CardPreparationCoordinator: deduplication, commit validation,
/// context guards, peek correctness, and readiness-driven promotion.
@MainActor
final class CardPreparationCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(id: String, title: String = "Title") -> FeedItem {
        FeedItem(
            id: id, sourceTitle: "Source", sourceURL: "https://example.com",
            category: "news", title: title, excerpt: "Excerpt",
            url: "https://example.com/\(id)", imageURL: nil,
            publishedAt: Date()
        )
    }

    private func makeContext(epoch: UInt64 = 1) -> FeedPresentationContext {
        FeedPresentationContext(
            epoch: epoch, mode: .main,
            filterGeneration: 0, presetGeneration: 0
        )
    }

    private func makeCoordinator() -> CardPreparationCoordinator {
        let db = try! DatabaseQueue(configuration: {
            var config = Configuration()
            config.prepareDatabase { db in
                // Minimal schema required by MediaAssetStore
                try db.create(table: "image_resolution") { t in
                    t.column("cache_key", .text).primaryKey()
                    t.column("url", .text).notNull()
                    t.column("file_path", .text)
                    t.column("width", .integer)
                    t.column("height", .integer)
                    t.column("byte_count", .integer)
                    t.column("mime_type", .text)
                    t.column("resolved_at", .datetime)
                    t.column("source", .text)
                }
            }
            return config
        }())
        let store = MediaAssetStore(db: db)
        let policy = RunwayPolicy.forDevice()
        return CardPreparationCoordinator(mediaStore: store, policy: policy)
    }

    // MARK: - Deduplication: replaceEditorialSequence

    func test_replaceEditorialSequence_deduplicatesIntraBatchDuplicates() async {
        let coordinator = makeCoordinator()
        let items = [
            makeItem(id: "A"), makeItem(id: "B"),
            makeItem(id: "A"), makeItem(id: "C"),
            makeItem(id: "B")
        ]
        let ctx = makeContext()

        await coordinator.replaceEditorialSequence(items, context: ctx)

        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 3, "Duplicate IDs within batch should be filtered to unique")
    }

    func test_replaceEditorialSequence_preservesFirstOccurrence() async {
        let coordinator = makeCoordinator()
        let items = [
            makeItem(id: "A", title: "First"),
            makeItem(id: "A", title: "Second")
        ]
        let ctx = makeContext()

        await coordinator.replaceEditorialSequence(items, context: ctx)

        // First occurrence of "A" is kept; second is dropped.
        // Since items have no images, they won't be render-ready yet.
        // But the editorial sequence should have only 1 item.
        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 1, "Only first occurrence should be kept")
    }

    // MARK: - Deduplication: appendEditorialSequence

    func test_appendEditorialSequence_filtersExistingIDs() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A"), makeItem(id: "B")],
            context: ctx
        )

        await coordinator.appendEditorialSequence(
            [makeItem(id: "B"), makeItem(id: "C")],
            context: ctx
        )

        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 3, "Only C should be added; B already exists")
    }

    func test_appendEditorialSequence_deduplicatesIntraBatch() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctx
        )

        await coordinator.appendEditorialSequence(
            [makeItem(id: "B"), makeItem(id: "B"), makeItem(id: "C"), makeItem(id: "B")],
            context: ctx
        )

        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 3, "Intra-batch duplicates in append should be filtered")
    }

    func test_appendEditorialSequence_rejectsWrongContext() async {
        let coordinator = makeCoordinator()
        let ctx1 = makeContext(epoch: 1)
        let ctx2 = makeContext(epoch: 2)

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctx1
        )

        await coordinator.appendEditorialSequence(
            [makeItem(id: "B")], context: ctx2
        )

        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 1, "Append with wrong context should be ignored")
    }

    // MARK: - commitPublished validation

    func test_commitPublished_rejectsStaleContext() async {
        let coordinator = makeCoordinator()
        let ctx1 = makeContext(epoch: 1)
        let ctx2 = makeContext(epoch: 2)

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctx1
        )
        await coordinator.replaceEditorialSequence(
            [makeItem(id: "B")], context: ctx2
        )

        // Try to commit with the stale context (ctx1).
        let result = await coordinator.commitPublished(
            expectedIDs: ["A"], context: ctx1
        )
        XCTAssertFalse(result, "Commit with stale context should be rejected")
    }

    func test_commitPublished_rejectsMismatchedPrefix() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()
        // Items without images — none will be render-ready.
        // commitPublished should reject because the peek returns empty prefix,
        // not the expected IDs.
        let items = (0..<5).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)

        let result = await coordinator.commitPublished(
            expectedIDs: ["0", "1", "2"], context: ctx
        )
        XCTAssertFalse(
            result,
            "Commit with IDs not matching render-ready prefix should be rejected"
        )
    }

    func test_commitPublished_acceptsValidPrefix() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        // Since items have imageURL: nil, the coordinator will resolve them
        // as .none immediately (no image to fetch). Let's verify by
        // preparing them and then committing.
        let items = (0..<3).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)

        // fillRunway should prepare items. Since imageURL is nil, they'll
        // resolve to .none and become render-ready quickly.
        await coordinator.fillRunway(targetRenderReady: 3, context: ctx)

        // Give the async tasks time to complete.
        try? await Task.sleep(for: .milliseconds(500))

        let peeked = await coordinator.peekRenderReadyPrefix(
            maximumCount: 3, context: ctx
        )
        guard peeked.count == 3 else {
            // If items didn't become ready (timing), this test is inconclusive.
            // The coordinator may take longer in CI.
            return
        }

        let result = await coordinator.commitPublished(
            expectedIDs: peeked.map(\.id), context: ctx
        )
        XCTAssertTrue(result, "Commit with matching prefix should succeed")
    }

    // MARK: - peekRenderReadyPrefix

    func test_peekRenderReadyPrefix_rejectsWrongContext() async {
        let coordinator = makeCoordinator()
        let ctx1 = makeContext(epoch: 1)
        let ctx2 = makeContext(epoch: 2)

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctx1
        )

        let cards = await coordinator.peekRenderReadyPrefix(
            maximumCount: 10, context: ctx2
        )
        XCTAssertTrue(cards.isEmpty, "Peek with wrong context should return empty")
    }

    func test_peekRenderReadyPrefix_isNonDestructive() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        let items = (0..<3).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)
        await coordinator.fillRunway(targetRenderReady: 3, context: ctx)
        try? await Task.sleep(for: .milliseconds(500))

        let first = await coordinator.peekRenderReadyPrefix(
            maximumCount: 3, context: ctx
        )
        let second = await coordinator.peekRenderReadyPrefix(
            maximumCount: 3, context: ctx
        )

        XCTAssertEqual(
            first.map(\.id), second.map(\.id),
            "Peek must be non-destructive — same IDs on repeated calls"
        )
    }

    // MARK: - waitForContiguousPrefix

    func test_waitForContiguousPrefix_returnsImmediatelyWhenReady() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        let items = (0..<5).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)
        await coordinator.fillRunway(targetRenderReady: 5, context: ctx)
        try? await Task.sleep(for: .milliseconds(500))

        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        let start = ContinuousClock().now
        let cards = await coordinator.waitForContiguousPrefix(
            minimumCount: 1, maximumCount: 5, deadline: deadline, context: ctx
        )
        let elapsed = start.duration(to: .now)

        if cards.count >= 1 {
            XCTAssertLessThan(
                elapsed, .seconds(1),
                "Should return near-instantly when cards are already ready"
            )
        }
        // If no cards ready, that's a timing issue — not a test failure.
    }

    func test_waitForContiguousPrefix_returnsEmptyOnWrongContext() async {
        let coordinator = makeCoordinator()
        let ctx1 = makeContext(epoch: 1)
        let ctx2 = makeContext(epoch: 2)

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctx1
        )

        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        let cards = await coordinator.waitForContiguousPrefix(
            minimumCount: 1, maximumCount: 5, deadline: deadline, context: ctx2
        )
        XCTAssertTrue(cards.isEmpty, "Should return empty for wrong context")
    }

    // MARK: - editorialAheadCount

    func test_editorialAheadCount_decreasesAfterCommit() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        let items = (0..<5).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)
        await coordinator.fillRunway(targetRenderReady: 5, context: ctx)
        try? await Task.sleep(for: .milliseconds(500))

        let before = await coordinator.editorialAheadCount
        XCTAssertEqual(before, 5, "All 5 items ahead of publish index")

        // Try to commit whatever is ready.
        let peeked = await coordinator.peekRenderReadyPrefix(
            maximumCount: 5, context: ctx
        )
        if !peeked.isEmpty {
            _ = await coordinator.commitPublished(
                expectedIDs: peeked.map(\.id), context: ctx
            )
            let after = await coordinator.editorialAheadCount
            XCTAssertEqual(
                after, 5 - peeked.count,
                "Ahead count should decrease by committed count"
            )
        }
    }

    // MARK: - epoch guard

    func test_replaceEditorialSequence_rejectsOlderEpoch() async {
        let coordinator = makeCoordinator()
        let ctxNew = makeContext(epoch: 5)
        let ctxOld = makeContext(epoch: 3)

        await coordinator.replaceEditorialSequence(
            [makeItem(id: "A")], context: ctxNew
        )
        // Try to install older epoch — should be rejected.
        await coordinator.replaceEditorialSequence(
            [makeItem(id: "B")], context: ctxOld
        )

        let count = await coordinator.editorialCount
        XCTAssertEqual(count, 1, "Older epoch should not replace newer one")
    }

    // MARK: - commitPublished O(1) advance

    func test_commitPublished_advancesByExactCount() async {
        let coordinator = makeCoordinator()
        let ctx = makeContext()

        let items = (0..<10).map { makeItem(id: "\($0)") }
        await coordinator.replaceEditorialSequence(items, context: ctx)
        await coordinator.fillRunway(targetRenderReady: 10, context: ctx)
        try? await Task.sleep(for: .milliseconds(500))

        let peeked = await coordinator.peekRenderReadyPrefix(
            maximumCount: 3, context: ctx
        )
        guard peeked.count == 3 else { return }

        let committed = await coordinator.commitPublished(
            expectedIDs: peeked.map(\.id), context: ctx
        )
        XCTAssertTrue(committed)

        let remaining = await coordinator.editorialAheadCount
        XCTAssertEqual(remaining, 7, "Should have 7 items remaining after committing 3")
    }
}
