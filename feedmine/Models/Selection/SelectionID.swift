import Foundation

/// Single monotonically-increasing identifier for a selection composition.
/// Replaces the parallel generations (filterGeneration, presetGeneration,
/// presentationEpoch, searchGeneration, visibleItemsGeneration) with one
/// authoritative token.
///
/// Every user action that changes what the screen should display creates
/// a new SelectionID. Async operations capture the ID at launch and discard
/// results if a newer ID has been issued in the meantime.
struct SelectionID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Sentinel for "no active selection".
    static let none = SelectionID(rawValue: 0)

    var description: String { "sel-\(rawValue)" }
}

/// Thread-safe monotonic counter for generating SelectionIDs.
/// Safe for concurrent access from any context (not @MainActor bound).
final class SelectionIDGenerator: @unchecked Sendable {
    private let _queue = DispatchQueue(label: "com.feedmine.selection-id-generator")
    private var _next: UInt64 = 1

    func nextID() -> SelectionID {
        _queue.sync {
            let id = SelectionID(rawValue: _next)
            _next += 1
            return id
        }
    }
}
