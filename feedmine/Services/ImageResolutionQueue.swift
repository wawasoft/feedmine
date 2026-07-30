import Foundation
import GRDB
import UIKit

// MARK: - Image Resolution State

enum ImageResolutionState: String, Sendable {
    case pending     // waiting for retry
    case inProgress  // currently resolving
    case failed      // all retries exhausted
}

// MARK: - Delegate Protocol

/// Callbacks from the retry queue to FeedStore. FeedStore implements these
/// on @MainActor, but the protocol itself is not actor-bound so the ImageResolutionQueue
/// actor can call these methods without sendability warnings. FeedStore's implementation
/// naturally runs on MainActor since FeedStore is @MainActor.
@MainActor
protocol ImageResolutionQueueDelegate: AnyObject, Sendable {
    /// Called when a background retry resolves an image. FeedStore should
    /// update the item's `imageURL` in the reservoir and, if visible,
    /// replace the card's media slot in-place.
    func imageResolutionQueue(didResolveImageFor itemID: String)

    /// Called when all retries are exhausted and the item is permanently
    /// text-only. FeedStore may record this for diagnostics.
    func imageResolutionQueue(didExhaustRetriesFor itemID: String)
}

// MARK: - Image Resolution Queue

/// Persistent retry queue for image resolution.
///
/// Items whose images failed during the initial pipeline (3-second timeout in
/// ``ReadyCardQueue``, transient network errors, truncated RSS feeds needing
/// article-OG resolution) enter this queue. Each item is retried with
/// exponential backoff, and when a retry succeeds the visible card is upgraded
/// in-place — no feed shift, no re-insertion.
///
/// Retry state survives app termination via the `image_retry_queue` SQLite
/// table, keyed by item ID with CASCADE delete.
///
/// ## Backoff schedule
///
/// | Attempt | Delay    |
/// |---------|----------|
/// | 1       | 30 s     |
/// | 2       | 2 min    |
/// | 3       | 10 min   |
/// | 4       | 1 h      |
/// | 5       | 6 h      |
/// | 6+      | failed   |
///
/// ## Concurrency
///
/// The actor processes items sequentially (one at a time) to avoid saturating
/// the network. The polling loop runs every 15 seconds, processing at most
/// 10 items per cycle. Since retry delays are measured in minutes-to-hours,
/// a 15-second poll is negligible.
actor ImageResolutionQueue {

    // MARK: - Configuration

    /// Exponential backoff delays indexed by `retry_count`.
    private static let backoffDelays: [TimeInterval] = [
        30,       // attempt 1 — transient network blip
        120,      // attempt 2 — slow CDN recovery
        600,      // attempt 3 — past ArticleImageResolver 300 s TTL
        3600,     // attempt 4 — 1 hour
        21600,    // attempt 5 — 6 hours
    ]

    /// Maximum number of retries before marking as failed.
    private static var maxRetries: Int { backoffDelays.count }

    /// Interval between poll cycles.
    private static let pollInterval: Duration = .seconds(15)

    /// Maximum items processed per poll cycle.
    private static let batchSize = 10

    // MARK: - State

    private let db: DatabaseQueue
    private weak var delegate: ImageResolutionQueueDelegate?

    private var pollTask: Task<Void, Never>?

    /// In-memory set of item IDs that have been enqueued and not yet resolved
    /// or failed. Used to avoid duplicate SQLite writes for already-pending items.
    private var pendingIDs: Set<String> = []

    // MARK: - Init

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Lifecycle

    /// Wire the delegate and start processing. Call once after FeedStore.init.
    func configure(delegate: ImageResolutionQueueDelegate) {
        self.delegate = delegate
        Task { await loadPendingFromSQLite() }
        startPolling()
    }

    /// Stop the poll loop (e.g., on flush / reset).
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Public API

    /// Enqueue a single item for retry. Idempotent — if the item is already
    /// pending, its `retry_count` is preserved.
    func enqueue(itemID: String) async {
        await enqueueBatch(itemIDs: [itemID])
    }

    /// Enqueue multiple items for retry. More efficient than calling
    /// `enqueue(itemID:)` in a loop because it uses a single SQLite write.
    func enqueueBatch(itemIDs: [String]) async {
        let now = Int(Date().timeIntervalSince1970)
        let newIDs = itemIDs.filter { !pendingIDs.contains($0) }
        guard !newIDs.isEmpty else { return }

        do {
            try await db.write { db in
                for id in newIDs {
                    // Upsert: only insert if not already present; if present,
                    // leave retry_count alone (don't reset backoff progress).
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO image_retry_queue
                            (item_id, state, retry_count, next_retry_at, created_at, updated_at)
                            VALUES (?, 'pending', 0, ?, ?, ?)
                            """,
                        arguments: [id, now, now, now]
                    )
                }
            }
            pendingIDs.formUnion(newIDs)
        } catch {
            Log.feed.error("ImageResolutionQueue enqueueBatch failed: \(error)")
        }

        startPolling()
    }

    /// Remove an item from the retry queue (e.g., a fresh fetch brought a
    /// working image URL, or the item was deleted).
    func dequeue(itemID: String) async {
        pendingIDs.remove(itemID)
        do {
            try await db.write { db in
                try db.execute(
                    sql: "DELETE FROM image_retry_queue WHERE item_id = ?",
                    arguments: [itemID]
                )
            }
        } catch {
            Log.feed.error("ImageResolutionQueue dequeue failed: \(error)")
        }
    }

    // MARK: - Polling

    private func startPolling() {
        // Already polling — don't start a second loop.
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await self.processBatch()

                // If nothing left, stop polling to conserve resources.
                // We'll restart when the next enqueue arrives.
                if await self.countPending() == 0 {
                    await self.clearPollTask()
                    return
                }

                try? await Task.sleep(for: Self.pollInterval)
            }
            await self.clearPollTask()
        }
    }

    private func clearPollTask() {
        pollTask = nil
    }

    // MARK: - Batch Processing

    private func processBatch() async {
        let now = Int(Date().timeIntervalSince1970)
        let batch: [ImageRetryQueueRecord] = (try? await db.read { db in
            try ImageRetryQueueRecord
                .fetchAll(db, sql: """
                    SELECT * FROM image_retry_queue
                    WHERE state = 'pending'
                      AND next_retry_at <= ?
                    ORDER BY next_retry_at ASC
                    LIMIT ?
                    """, arguments: [now, Self.batchSize]
                )
        }) ?? []

        for record in batch {
            guard !Task.isCancelled else { return }

            await resolve(record: record)
        }
    }

    // MARK: - Resolution

    private func resolve(record: ImageRetryQueueRecord) async {
        let itemID = record.itemID

        // 1. Mark in-progress
        let now = Int(Date().timeIntervalSince1970)
        try? await db.write { db in
            try db.execute(
                sql: """
                    UPDATE image_retry_queue
                    SET state = 'in_progress', updated_at = ?
                    WHERE item_id = ?
                    """,
                arguments: [now, itemID]
            )
        }

        // 2. Read the item from SQLite
        guard let itemRecord: FeedItemRecord = try? await db.read({ db in
            try FeedItemRecord.fetchOne(db, key: itemID)
        }) else {
            // Item was deleted — clean up the queue entry
            await dequeue(itemID: itemID)
            return
        }

        let feedItem = itemRecord.toFeedItem()

        // 3. Determine resolution URLs
        let imageURL = feedItem.bestImageURL.flatMap(URL.init(string:))
        let articleURL = feedItem.canResolveArticleImage ? URL(string: feedItem.url) : nil

        guard imageURL != nil || articleURL != nil else {
            // No resolution path available — mark as failed
            await markFailed(itemID: itemID, error: "No resolution URL available")
            return
        }

        // 4. Clear ArticleImageResolver miss cache for this article URL
        if let articleURL {
            await ArticleImageResolver.shared.resetMiss(for: articleURL)
        }

        // 5. Attempt resolution
        let resolvedImage = await ImageLoader.resolveImage(url: imageURL, articleURL: articleURL)

        guard !Task.isCancelled else { return }

        if resolvedImage != nil {
            // SUCCESS: remove from queue, notify delegate
            await onSuccess(itemID: itemID)
        } else {
            // FAILURE: increment retry count or exhaust
            await onFailure(itemID: itemID, record: record, error: "ImageLoader.resolveImage returned nil")
        }
    }

    // MARK: - Outcome Handlers

    private func onSuccess(itemID: String) async {
        pendingIDs.remove(itemID)
        await dequeue(itemID: itemID)

        // Notify FeedStore to update visibleCards in-place
        await delegate?.imageResolutionQueue(didResolveImageFor: itemID)
    }

    private func onFailure(itemID: String, record: ImageRetryQueueRecord, error: String) async {
        let newRetryCount = record.retryCount + 1
        let now = Int(Date().timeIntervalSince1970)

        if newRetryCount >= Self.maxRetries {
            await markFailed(itemID: itemID, error: error)
            await delegate?.imageResolutionQueue(didExhaustRetriesFor: itemID)
        } else {
            let delayIdx = min(newRetryCount - 1, Self.backoffDelays.count - 1)
            let delay = Self.backoffDelays[delayIdx]
            let nextRetryAt = now + Int(delay)

            try? await db.write { db in
                try db.execute(
                    sql: """
                        UPDATE image_retry_queue
                        SET state = 'pending',
                            retry_count = ?,
                            next_retry_at = ?,
                            last_error = ?,
                            updated_at = ?
                        WHERE item_id = ?
                        """,
                    arguments: [newRetryCount, nextRetryAt, error, now, itemID]
                )
            }

            // Keep polling to catch the next retry window
            startPolling()
        }
    }

    private func markFailed(itemID: String, error: String) async {
        pendingIDs.remove(itemID)
        let now = Int(Date().timeIntervalSince1970)
        try? await db.write { db in
            try db.execute(
                sql: """
                    UPDATE image_retry_queue
                    SET state = 'failed', last_error = ?, updated_at = ?
                    WHERE item_id = ?
                    """,
                arguments: [error, now, itemID]
            )
        }
    }

    // MARK: - SQLite Helpers

    private func countPending() async -> Int {
        let now = Int(Date().timeIntervalSince1970)
        return (try? await db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM image_retry_queue
                WHERE state = 'pending' AND next_retry_at <= ?
                """, arguments: [now]
            )
        }) ?? 0
    }

    private func loadPendingFromSQLite() async {
        let now = Int(Date().timeIntervalSince1970)
        let ids: [String] = (try? await db.read { db in
            try String.fetchAll(db, sql: """
                SELECT item_id FROM image_retry_queue
                WHERE state = 'pending' AND next_retry_at <= ?
                ORDER BY next_retry_at ASC
                """, arguments: [now]
            )
        }) ?? []
        pendingIDs.formUnion(ids)
    }
}
