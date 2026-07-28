import Foundation

/// Lightweight service for `BGAppRefreshTask` execution.
///
/// Unlike `FeedLoader`, which initializes the full observable stack (stores,
/// catalogs, search engine, taxonomy, image prefetcher, reservoir), this actor
/// only opens the databases and performs the Smart Feed refresh — no UI state,
/// no MainActor coupling, no image pipeline, no catalog loading.
///
/// A `BGAppRefreshTask` gets ~30 seconds of wall-clock time. Creating a full
/// `FeedLoader` inside that window wastes precious seconds on init and risks
/// the system jetissoning the task before any actual work is done.
@globalActor
actor BackgroundRefreshService {
    static let shared = BackgroundRefreshService()

    private let store: FeedStore

    private init() {
        // FeedStore with persistent storage, but BackgroundRefreshService
        // never touches the observable layer (FeedLoader). The init cost
        // is just database open + migrations — no catalog, no taxonomy,
        // no image pipeline.
        self.store = (try? FeedStore(inMemory: false)) ?? FeedStore.empty()
    }

    /// Run a Smart Feed background refresh. Returns true if at least one
    /// Smart Feed was successfully refreshed.
    func refreshSmartFeeds() async -> Bool {
        await store.prepareForBackgroundSmartFeedRefresh()
        return await store.performSmartFeedBackgroundRefresh()
    }
}
