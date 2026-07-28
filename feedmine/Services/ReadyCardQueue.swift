import Foundation

/// `@MainActor` publication gate that ensures cards only enter the visible
/// feed after their media is fully resolved.
///
/// Items are enqueued in reservoir order, fanned out to
/// `CardPreparationPipeline` for parallel resolution, and reassembled in
/// the original order. The feed never sees a `.loading` state — cards are
/// either ready (`.image` / `.placeholder` / `.none`) or not yet published.
///
/// Usage:
/// ```swift
/// queue.enqueue(items)
/// await queue.waitForReady(count: 20)  // blocks until 20 cards ready or timeout
/// let ready = queue.presentations        // consume the resolved presentations
/// ```
@MainActor
final class ReadyCardQueue {

    /// Resolved presentations, in insertion order. Only populated after
    /// `enqueue` + `waitForReady`.
    private(set) var presentations: [FeedCardPresentation] = []

    /// Items awaiting or currently in preparation, keyed by item ID for
    /// O(1) lookup during order-preserving insertion.
    private var pendingIDs: Set<String> = []

    /// Pipeline that does the actual work (actor, runs off MainActor).
    private let pipeline = CardPreparationPipeline()

    /// How long to wait before publishing whatever is ready (seconds).
    /// A stuck/broken image URL must not stall the entire feed.
    private let timeout: Duration = .seconds(3)

    // MARK: - Public API

    /// Enqueue a batch of items for preparation. Items are resolved in
    /// parallel and inserted into `presentations` maintaining input order.
    /// Call `waitForReady(count:)` to await completion.
    func enqueue(_ items: [FeedItem]) {
        let fresh = items.filter { !pendingIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        pendingIDs.formUnion(fresh.map(\.id))

        Task { [pipeline, weak self] in
            let newPresentations = await pipeline.prepare(fresh)
            guard let self else { return }
            // Merge into presentations, preserving input order.
            // Items resolve in parallel so they arrive out of order; we
            // slot each one at the correct position by scanning for the
            // first gap where the ID hasn't been filled yet.
            var merged = self.presentations
            var newByID = Dictionary(uniqueKeysWithValues: newPresentations.map { ($0.id, $0) })

            // Walk the pending IDs in order; replace any placeholder slot
            // with the resolved presentation.
            for (i, existing) in merged.enumerated() {
                if let replacement = newByID[existing.id] {
                    merged[i] = replacement
                    newByID.removeValue(forKey: existing.id)
                }
            }
            // Append any remaining new presentations at the end
            for item in items {
                if let pres = newByID[item.id] {
                    merged.append(pres)
                }
            }
            self.presentations = merged
            self.pendingIDs.subtract(newPresentations.map(\.id))
        }
    }

    /// Wait until at least `minCount` presentations are ready, or the
    /// timeout expires (whichever comes first). After this returns,
    /// `presentations` contains at least `min(minCount, totalEnqueued)`
    /// resolved cards.
    func waitForReady(count minCount: Int) async {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout.components.seconds))
        while presentations.count < minCount {
            guard Date() < deadline else { break }
            guard !pendingIDs.isEmpty else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Remove presentations whose items are no longer in the given ID set.
    /// Used when filters change — the pipeline discards cards for items
    /// that are no longer visible.
    func retainOnly(ids: Set<String>) {
        presentations.removeAll { !ids.contains($0.id) }
    }

    /// Clear all state (filter change, refresh).
    func reset() {
        presentations = []
        pendingIDs = []
    }
}
