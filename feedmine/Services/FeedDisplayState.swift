import Foundation

/// Manages the visible feed state — what the UI renders right now.
/// Extracted from FeedStore (P0-01 audit R1).
///
/// FeedStore delegates display state mutations here so the 7,204-line
/// monolith shrinks by ~200 lines and the display phase lifecycle has
/// a single, focused owner.
@MainActor
final class FeedDisplayState: @unchecked Sendable {
    /// Items currently rendered in the feed.
    private(set) var visibleItems: [FeedItem] = []

    /// Pre-resolved card presentations for the visible page.
    private(set) var visibleCards: [FeedCardPresentation] = []

    /// Monotonic counter incremented on every visibleItems change.
    private(set) var visibleItemsGeneration: UInt64 = 0

    /// Loading indicator state exposed to the UI.
    private(set) var loadingState: FeedLoadingState = .idle

    /// Current lifecycle phase of the feed (startup, ready, refreshing).
    private(set) var feedDisplayPhase: FeedDisplayPhase = .preparing(contextID: 0, reason: .startup)

    /// True while the cold-start runway is still being built.
    private(set) var isPreparingInitialRunway = false

    /// Monotonic epoch incremented on every filter/preset change.
    private(set) var presentationEpoch: UInt64 = 0

    /// Context snapshot captured at filter/preset boundaries.
    private(set) var activePresentationContext = FeedPresentationContext(
        epoch: 0, mode: .main,
        filterGeneration: 0, presetGeneration: 0
    )

    // MARK: - Mutations

    func setVisibleItems(_ items: [FeedItem], isAppend: Bool = false) {
        if isAppend {
            let existingIDs = Set(visibleItems.map(\.id))
            let newItems = items.filter { !existingIDs.contains($0.id) }
            visibleItems.append(contentsOf: newItems)
        } else {
            visibleItems = items
        }
        visibleItemsGeneration &+= 1
    }

    func setLoadingState(_ state: FeedLoadingState) {
        loadingState = state
    }

    func setFeedDisplayPhase(_ phase: FeedDisplayPhase) {
        feedDisplayPhase = phase
    }

    func setIsPreparingInitialRunway(_ value: Bool) {
        isPreparingInitialRunway = value
    }

    func incrementEpoch() -> UInt64 {
        presentationEpoch &+= 1
        return presentationEpoch
    }

    func updatePresentationContext(mode: FeedPresentationMode, filterGeneration: Int64, presetGeneration: Int64) {
        activePresentationContext = FeedPresentationContext(
            epoch: presentationEpoch, mode: mode,
            filterGeneration: filterGeneration, presetGeneration: presetGeneration
        )
    }

    func clear() {
        visibleItems = []
        visibleCards = []
        loadingState = .idle
        feedDisplayPhase = .preparing(contextID: 0, reason: .startup)
        isPreparingInitialRunway = false
        presentationEpoch = 0
        visibleItemsGeneration = 0
    }
}
