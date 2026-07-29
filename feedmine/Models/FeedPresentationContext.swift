import Foundation

/// Identifies a specific feed composition session. Every async preparation
/// task captures this context; results are discarded if the context changes
/// before the task completes.
struct FeedPresentationContext: Hashable, Sendable {
    /// Monotonic counter incremented whenever the published sequence must
    /// be rebuilt (preset change, filter change, collection switch, etc.).
    let epoch: UInt64

    /// Which feed surface this context serves.
    let mode: FeedPresentationMode

    /// Snapshot of filterGeneration at context creation time.
    let filterGeneration: Int64

    /// Snapshot of presetGeneration at context creation time.
    let presetGeneration: Int64
}

enum FeedPresentationMode: Hashable, Sendable {
    case main
    case collection(Int64)
    case smartFeed(Int64)
    case bookmarks(Int64?)
    case lastClicked
    case whatsNew
}
