import Foundation
import Observation
import SwiftUI

/// Observes scenePhase changes and surfaces pending Share Extension items.
/// Owns the FeedDiscoverySheet presentation state.
@MainActor
@Observable
final class PendingItemsMonitor {
    let store: FeedStore

    /// Pending items from the Share Extension waiting to be processed.
    private(set) var pendingItems: [PendingItem] = []

    /// Binding to present the discovery sheet on FeedScreen.
    var showDiscoverySheet: Bool = false

    /// IDs already processed this session — prevents re-showing stale items
    /// if scenePhase fires multiple times with unchanged queue contents.
    private var lastProcessedIDs: Set<String> = []

    init(store: FeedStore) {
        self.store = store
    }

    /// Call from `FeedmineApp.onChange(of: scenePhase)`.
    func scenePhaseDidChange(_ phase: ScenePhase) {
        guard phase == .active else { return }

        let allItems = PendingQueue.readAll()
        let newItems = allItems.filter { !lastProcessedIDs.contains($0.id) }
        guard !newItems.isEmpty else { return }

        lastProcessedIDs.formUnion(newItems.map(\.id))
        pendingItems = newItems
        showDiscoverySheet = true
    }

    /// Called by FeedDiscoverySheet when user confirms import.
    func processConfirmed(_ feeds: [FeedSource]) {
        store.registry.sources = OPMLParser.deduplicateSources(
            store.registry.sources + feeds
        )
        PendingQueue.clear()
        pendingItems = []
        showDiscoverySheet = false
    }

    /// Called by FeedDiscoverySheet when user skips/dismisses.
    func processSkipped() {
        // Items stay in queue; will reappear on next foreground.
        // We don't clear to avoid losing data if the user accidentally dismissed.
        pendingItems = []
        showDiscoverySheet = false
    }
}
