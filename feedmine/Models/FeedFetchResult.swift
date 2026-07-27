import Foundation

/// Backward-compatible status for code that only needs a simple pass/fail signal.
enum FeedFetchStatus: Sendable, Equatable, CaseIterable {
    case success
    case empty
    case failed
}

struct FeedFetchResult: Sendable {
    let source: FeedSource
    let items: [FeedItem]
    let outcome: FeedFetchOutcome

    /// Convenience status for backward compatibility during migration.
    var status: FeedFetchStatus {
        switch outcome {
        case .modifiedWithNewItems: return .success
        case .modifiedWithoutNewItems: return .empty
        case .notModified: return .success  // not a failure
        case .failed: return .failed
        case .throttled: return .failed     // temporary block → treat as failed
        }
    }
}
