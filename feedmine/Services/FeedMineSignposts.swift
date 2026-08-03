import Foundation
import OSLog

/// Centralized performance signpost logger for FeedMine.
///
/// Wraps `OSSignposter` to provide stable, semantic interval names
/// for XCTest performance measurement via `XCTOSSignpostMetric`.
///
/// Usage:
/// ```swift
/// let state = FeedMineSignposts.begin(.catalogOpen)
/// defer { FeedMineSignposts.end(.catalogOpen, state: state) }
/// // ... measured work ...
/// ```
///
/// - Important: begin/end must be balanced, including in cancellation and error paths.
/// - Important: Do not log content, URLs, or user text in signpost metadata.
/// - Important: Wrap the actual operation, not just a call that schedules async work.
enum FeedMineSignposts {
    // MARK: - Logger

    private static let logger = Logger(
        subsystem: "com.feedmine.performance",
        category: "Performance"
    )

    private static let signposter = OSSignposter(logger: logger)

    // MARK: - Interval Names

    enum Interval: CaseIterable {
        // Launch & startup
        case appLaunchToInteractive

        // Catalog
        case catalogOpen
        case catalogIndexBuild
        case catalogSearch

        // Parsing
        case opmlParse
        case feedParse
        case feedNormalize
        case feedDeduplicate

        // Timeline
        case timelineQuery
        case timelineMerge
        case timelineFirstPage
        case firstCardRender

        // Images
        case imageLoad
        case imageDecode

        // Persistence
        case persistenceWrite
        case persistenceRead
        case migration
        case offlineRestore

        // User actions
        case sourceFollow
        case mediaStart
        case translationStart
        case backgroundRefresh

        /// The `StaticString` identifier used for OSSignposter calls.
        var name: StaticString {
            switch self {
            case .appLaunchToInteractive: return "AppLaunchToInteractive"
            case .catalogOpen: return "CatalogOpen"
            case .catalogIndexBuild: return "CatalogIndexBuild"
            case .catalogSearch: return "CatalogSearch"
            case .opmlParse: return "OPMLParse"
            case .feedParse: return "FeedParse"
            case .feedNormalize: return "FeedNormalize"
            case .feedDeduplicate: return "FeedDeduplicate"
            case .timelineQuery: return "TimelineQuery"
            case .timelineMerge: return "TimelineMerge"
            case .timelineFirstPage: return "TimelineFirstPage"
            case .firstCardRender: return "FirstCardRender"
            case .imageLoad: return "ImageLoad"
            case .imageDecode: return "ImageDecode"
            case .persistenceWrite: return "PersistenceWrite"
            case .persistenceRead: return "PersistenceRead"
            case .migration: return "Migration"
            case .offlineRestore: return "OfflineRestore"
            case .sourceFollow: return "SourceFollow"
            case .mediaStart: return "MediaStart"
            case .translationStart: return "TranslationStart"
            case .backgroundRefresh: return "BackgroundRefresh"
            }
        }
    }

    // MARK: - Public API

    /// Begin a measured interval. Returns state that must be passed to `end`.
    @inline(__always)
    static func begin(_ interval: Interval) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        return signposter.beginInterval(interval.name, id: id)
    }

    /// End a measured interval.
    @inline(__always)
    static func end(_ interval: Interval, state: OSSignpostIntervalState) {
        signposter.endInterval(interval.name, state)
    }

    /// Emit a point event (not an interval).
    @inline(__always)
    static func event(_ interval: Interval) {
        signposter.emitEvent(interval.name)
    }

    // MARK: - Scoped helpers

    /// Measure the execution of `body` under the given signpost interval.
    static func measure<T>(_ interval: Interval, body: () throws -> T) rethrows -> T {
        let state = begin(interval)
        defer { end(interval, state: state) }
        return try body()
    }

    /// Measure the async execution of `body` under the given signpost interval.
    static func measure<T: Sendable>(_ interval: Interval, body: @Sendable () async throws -> T) async rethrows -> T {
        let state = begin(interval)
        defer { end(interval, state: state) }
        return try await body()
    }
}
