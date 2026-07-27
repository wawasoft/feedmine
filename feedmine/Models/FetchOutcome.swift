import Foundation

// MARK: - HTTP-level outcome (from FeedHTTPSync)

enum HTTPOutcome: Sendable {
    case notModified
    case success(Data)
    case throttled(until: Date)
    case failed(Error)
}

/// Returned by FeedHTTPSync.fetch() — raw HTTP result before parsing.
struct FetchHTTPResult: Sendable {
    let data: Data?
    let outcome: HTTPOutcome
    let updatedValidators: HTTPValidators
    let canonicalURL: String?
}

// MARK: - Feed-level outcome (from RSSFetcher)

enum FeedFetchOutcome: Sendable, Equatable {
    case notModified
    case modifiedWithNewItems([FeedItem], validators: HTTPValidators)
    case modifiedWithoutNewItems(validators: HTTPValidators)
    case failed(Error)
    case throttled(until: Date)

    // Equatable conformance for .failed (Error is not Equatable)
    static func == (lhs: FeedFetchOutcome, rhs: FeedFetchOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.notModified, .notModified): return true
        case (.modifiedWithNewItems(let lItems, _), .modifiedWithNewItems(let rItems, _)):
            return lItems == rItems
        case (.modifiedWithoutNewItems, .modifiedWithoutNewItems): return true
        case (.failed, .failed): return true  // approximate — errors aren't Equatable
        case (.throttled(let lDate), .throttled(let rDate)): return lDate == rDate
        default: return false
        }
    }
}
