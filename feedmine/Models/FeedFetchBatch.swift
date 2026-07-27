import Foundation

struct FeedFetchBatch: Sendable {
    let items: [FeedItem]
    let fetchedSourceCount: Int      // sources that produced new items
    let failedSourceCount: Int       // sources that failed (network/parse)
    let emptySourceCount: Int        // sources with zero items but 200 OK
    let notModifiedCount: Int        // sources that returned 304
    let throttledCount: Int          // sources that returned 429/503
    /// Per-source outcome, keyed by source URL.
    let sourceOutcomes: [String: FeedFetchOutcome]
}
