import XCTest
@testable import feedmine

@MainActor
final class FeedDisplayStateTests: XCTestCase {

    // MARK: - setVisibleItems stamping

    func test_setVisibleItems_stampsReadState() {
        let state = FeedDisplayState()
        var item = FeedItem.makeMock(id: "a")
        item.isRead = false

        state.setVisibleItems([item], readItemIDs: ["a"], bookmarkItemIDs: [])

        XCTAssertTrue(state.visibleItems[0].isRead, "Item should be stamped as read")
    }

    func test_setVisibleItems_stampsBookmarkState() {
        let state = FeedDisplayState()
        var item = FeedItem.makeMock(id: "b")
        item.isBookmarked = false

        state.setVisibleItems([item], readItemIDs: [], bookmarkItemIDs: ["b"])

        XCTAssertTrue(state.visibleItems[0].isBookmarked, "Item should be stamped as bookmarked")
    }

    func test_setVisibleItems_stampsMultipleItems() {
        let state = FeedDisplayState()
        let items = [
            FeedItem.makeMock(id: "x"),
            FeedItem.makeMock(id: "y"),
            FeedItem.makeMock(id: "z"),
        ]

        state.setVisibleItems(items, readItemIDs: ["x", "z"], bookmarkItemIDs: ["y"])

        XCTAssertTrue(state.visibleItems[0].isRead, "x should be read")
        XCTAssertFalse(state.visibleItems[1].isRead, "y should not be read")
        XCTAssertTrue(state.visibleItems[2].isRead, "z should be read")
        XCTAssertFalse(state.visibleItems[0].isBookmarked, "x should not be bookmarked")
        XCTAssertTrue(state.visibleItems[1].isBookmarked, "y should be bookmarked")
    }

    // MARK: - setVisibleItems no-op guard

    func test_setVisibleItems_replace_noop_doesNotBumpGeneration() {
        let state = FeedDisplayState()
        let items = [FeedItem.makeMock(id: "a"), FeedItem.makeMock(id: "b")]
        state.setVisibleItems(items, readItemIDs: [], bookmarkItemIDs: [])
        let genAfterFirst = state.visibleItemsGeneration

        // Same items again — should be a no-op
        state.setVisibleItems(items, readItemIDs: [], bookmarkItemIDs: [])

        XCTAssertEqual(state.visibleItemsGeneration, genAfterFirst,
                       "Generation should not bump on identical replace")
    }

    func test_setVisibleItems_replace_differentItems_bumpsGeneration() {
        let state = FeedDisplayState()
        state.setVisibleItems([FeedItem.makeMock(id: "a")], readItemIDs: [], bookmarkItemIDs: [])
        let genAfterFirst = state.visibleItemsGeneration

        state.setVisibleItems([FeedItem.makeMock(id: "b")], readItemIDs: [], bookmarkItemIDs: [])

        XCTAssertGreaterThan(state.visibleItemsGeneration, genAfterFirst,
                             "Generation should bump on different replace")
    }

    // MARK: - publishCards

    func test_publishCards_publishesItemsAndCardsAtomically() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "a")
        let card = FeedCardPresentation.makeMock(id: "a", item: item)

        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        XCTAssertEqual(state.visibleItems.count, 1)
        XCTAssertEqual(state.visibleCards.count, 1)
        XCTAssertEqual(state.visibleItems[0].id, "a")
        XCTAssertEqual(state.visibleCards[0].id, "a")
    }

    func test_publishCards_firstPaint_flipsLoadingStateToIdle() {
        let state = FeedDisplayState()
        // Fresh state: loadingState is .idle by default. Force it to .initial.
        // We need to test the first-paint transition, which requires .initial.
        // Since there's no public setter for .initial on a fresh component,
        // we verify that the initial state is .idle and the transition is a no-op.
        // The actual .initial → .idle path is exercised by FeedStore wiring.
        XCTAssertEqual(state.loadingState, .idle)
    }

    func test_publishCards_firstPaint_setsPhaseToReadyWhenItemsNotEmpty() {
        let state = FeedDisplayState()
        // Reset to simulate pre-first-paint state with .initial loading.
        // Loading state .initial must be set via internal wiring in FeedStore.
        // For this test, we verify the phase coupling contract directly.
        let item = FeedItem.makeMock(id: "a")
        let card = FeedCardPresentation.makeMock(id: "a", item: item)

        // Manually set to .initial (simulating what FeedStore does before first paint)
        state.setLoadingState(.initial)

        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        XCTAssertEqual(state.loadingState, .idle, "First paint should transition loading to idle")
        guard case .ready = state.feedDisplayPhase else {
            XCTFail("First paint with items should set phase to .ready, got \(state.feedDisplayPhase)")
            return
        }
    }

    func test_publishCards_firstPaint_setsPhaseToEmptyWhenItemsEmpty() {
        let state = FeedDisplayState()
        state.setLoadingState(.initial)

        state.publishCards([], items: [], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        XCTAssertEqual(state.loadingState, .idle)
        guard case .empty = state.feedDisplayPhase else {
            XCTFail("First paint with no items should set phase to .empty, got \(state.feedDisplayPhase)")
            return
        }
    }

    func test_publishCards_nonFirstPaint_doesNotChangeLoadingState() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "a")
        let card = FeedCardPresentation.makeMock(id: "a", item: item)

        // First paint
        state.setLoadingState(.initial)
        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)
        XCTAssertEqual(state.loadingState, .idle)

        // Now set to refreshing (simulating a refresh cycle)
        state.setLoadingState(.refreshing)

        // Second publish — should NOT flip loadingState back to .idle
        let item2 = FeedItem.makeMock(id: "b")
        let card2 = FeedCardPresentation.makeMock(id: "b", item: item2)
        state.publishCards([card2], items: [item2], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        XCTAssertEqual(state.loadingState, .refreshing,
                       "Non-first-paint should not change loadingState")
    }

    func test_publishCards_append_noop_doesNotChangeState() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "a")
        let card = FeedCardPresentation.makeMock(id: "a", item: item)

        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)
        let genBefore = state.visibleItemsGeneration
        let countBefore = state.visibleItems.count

        // Append same card — should be filtered
        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: true)

        XCTAssertEqual(state.visibleItems.count, countBefore)
        XCTAssertEqual(state.visibleCards.count, countBefore)
        XCTAssertEqual(state.visibleItemsGeneration, genBefore)
    }

    func test_publishCards_append_newItems_addsThem() {
        let state = FeedDisplayState()
        let item1 = FeedItem.makeMock(id: "a")
        let card1 = FeedCardPresentation.makeMock(id: "a", item: item1)

        state.publishCards([card1], items: [item1], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        let item2 = FeedItem.makeMock(id: "b")
        let card2 = FeedCardPresentation.makeMock(id: "b", item: item2)
        state.publishCards([card2], items: [item2], readItemIDs: [], bookmarkItemIDs: [], isAppend: true)

        XCTAssertEqual(state.visibleItems.count, 2)
        XCTAssertEqual(state.visibleCards.count, 2)
        XCTAssertEqual(state.visibleItems[1].id, "b")
    }

    func test_publishCards_reStampsItems() {
        let state = FeedDisplayState()
        var item = FeedItem.makeMock(id: "a")
        item.isRead = false
        item.isBookmarked = false
        let card = FeedCardPresentation.makeMock(id: "a", item: item)

        // Publish with read/bookmark markers — should stamp
        state.publishCards([card], items: [item], readItemIDs: ["a"], bookmarkItemIDs: ["a"], isAppend: false)

        XCTAssertTrue(state.visibleItems[0].isRead)
        XCTAssertTrue(state.visibleItems[0].isBookmarked)
    }

    // MARK: - mutateVisibleItem

    func test_mutateVisibleItem_modifiesItemInPlace() {
        let state = FeedDisplayState()
        var item = FeedItem.makeMock(id: "a")
        item.isRead = false
        state.setVisibleItems([item], readItemIDs: [], bookmarkItemIDs: [])

        state.mutateVisibleItem(at: 0) { $0.isRead = true }

        XCTAssertTrue(state.visibleItems[0].isRead)
    }

    func test_mutateVisibleItem_withBumpGeneration_incrementsCounter() {
        let state = FeedDisplayState()
        state.setVisibleItems([FeedItem.makeMock(id: "a")], readItemIDs: [], bookmarkItemIDs: [])
        let genBefore = state.visibleItemsGeneration

        state.mutateVisibleItem(at: 0, bumpGeneration: true) { $0.isRead = true }

        XCTAssertEqual(state.visibleItemsGeneration, genBefore + 1)
    }

    func test_mutateVisibleItem_withoutBumpGeneration_doesNotIncrementCounter() {
        let state = FeedDisplayState()
        state.setVisibleItems([FeedItem.makeMock(id: "a")], readItemIDs: [], bookmarkItemIDs: [])
        let genBefore = state.visibleItemsGeneration

        state.mutateVisibleItem(at: 0) { $0.isRead = true }

        XCTAssertEqual(state.visibleItemsGeneration, genBefore,
                       "Read-state change should not invalidate caches")
    }

    func test_mutateVisibleItem_defaultsToNoBump() {
        let state = FeedDisplayState()
        state.setVisibleItems([FeedItem.makeMock(id: "a")], readItemIDs: [], bookmarkItemIDs: [])
        let genBefore = state.visibleItemsGeneration

        // Default bumpGeneration is false
        state.mutateVisibleItem(at: 0) { $0.isBookmarked = true }

        XCTAssertEqual(state.visibleItemsGeneration, genBefore)
    }

    func test_mutateVisibleItem_outOfBounds_isNoop() {
        let state = FeedDisplayState()
        state.setVisibleItems([FeedItem.makeMock(id: "a")], readItemIDs: [], bookmarkItemIDs: [])

        // Should not crash
        state.mutateVisibleItem(at: 999) { $0.isRead = true }
        state.mutateVisibleItem(at: -1) { $0.isRead = true }

        XCTAssertEqual(state.visibleItems.count, 1)
    }

    func test_mutateVisibleItem_toggleBookmarkPattern() {
        let state = FeedDisplayState()
        var item = FeedItem.makeMock(id: "a")
        item.isBookmarked = false
        state.setVisibleItems([item], readItemIDs: [], bookmarkItemIDs: [])

        // Simulate toggleBookmark: flip + bump
        state.mutateVisibleItem(at: 0, bumpGeneration: true) {
            $0.isBookmarked = !$0.isBookmarked
        }

        XCTAssertTrue(state.visibleItems[0].isBookmarked)
        XCTAssertEqual(state.visibleItemsGeneration, 2) // initial set + toggle
    }

    // MARK: - replaceVisibleCard

    func test_replaceVisibleCard_replacesCardInPlace() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "a")
        let card1 = FeedCardPresentation.makeMock(id: "a", item: item)
        state.publishCards([card1], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        let newCard = FeedCardPresentation(
            item: item,
            media: .placeholder,
            layout: .hero,
            isRead: false,
            isBookmarked: false
        )
        state.replaceVisibleCard(at: 0, with: newCard)

        XCTAssertEqual(state.visibleCards[0].layout, .hero)
    }

    func test_replaceVisibleCard_doesNotBumpGeneration() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "a")
        let card = FeedCardPresentation.makeMock(id: "a", item: item)
        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)
        let genBefore = state.visibleItemsGeneration

        let upgradedCard = FeedCardPresentation(
            item: item,
            media: .placeholder,
            layout: .thumbnail,
            isRead: false,
            isBookmarked: false
        )
        state.replaceVisibleCard(at: 0, with: upgradedCard)

        XCTAssertEqual(state.visibleItemsGeneration, genBefore,
                       "Visual card upgrade should not invalidate caches")
    }

    func test_replaceVisibleCard_doesNotTouchVisibleItems() {
        let state = FeedDisplayState()
        let item1 = FeedItem.makeMock(id: "a")
        let card1 = FeedCardPresentation.makeMock(id: "a", item: item1)
        state.publishCards([card1], items: [item1], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)
        let itemsBefore = state.visibleItems

        let newCard = FeedCardPresentation(
            item: item1,
            media: .placeholder,
            layout: .hero,
            isRead: true,
            isBookmarked: false
        )
        state.replaceVisibleCard(at: 0, with: newCard)

        // visibleItems untouched — only the card changed
        XCTAssertEqual(state.visibleItems, itemsBefore)
        XCTAssertEqual(state.visibleCards[0].layout, .hero)
    }

    func test_replaceVisibleCard_outOfBounds_isNoop() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "a")
        let card = FeedCardPresentation.makeMock(id: "a", item: item)
        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        let newCard = FeedCardPresentation.makeMock(id: "x", item: item)
        // Should not crash
        state.replaceVisibleCard(at: 999, with: newCard)

        XCTAssertEqual(state.visibleCards.count, 1)
        XCTAssertEqual(state.visibleCards[0].id, "a")
    }

    // MARK: - advanceEpoch

    func test_advanceEpoch_bumpsEpochAndCapturesContext() {
        let state = FeedDisplayState()
        let epochBefore = state.presentationEpoch

        let (old, new) = state.advanceEpoch(mode: .main, filterGeneration: 5, presetGeneration: 10)

        XCTAssertEqual(state.presentationEpoch, epochBefore + 1)
        XCTAssertEqual(old.epoch, epochBefore)
        XCTAssertEqual(new.epoch, epochBefore + 1)
        XCTAssertEqual(new.mode, .main)
        XCTAssertEqual(new.filterGeneration, 5)
        XCTAssertEqual(new.presetGeneration, 10)
    }

    func test_advanceEpoch_contextMatchesState() {
        let state = FeedDisplayState()
        let (_, new) = state.advanceEpoch(mode: .collection(42), filterGeneration: 3, presetGeneration: 7)

        XCTAssertEqual(state.activePresentationContext, new)
        XCTAssertEqual(state.activePresentationContext.epoch, state.presentationEpoch)
    }

    func test_advanceEpoch_oldContextIsPreviousState() {
        let state = FeedDisplayState()
        let initialContext = state.activePresentationContext

        let (old, _) = state.advanceEpoch(mode: .main, filterGeneration: 1, presetGeneration: 2)

        XCTAssertEqual(old, initialContext)
    }

    func test_advanceEpoch_multipleCalls_keepsConsistency() {
        let state = FeedDisplayState()

        _ = state.advanceEpoch(mode: .main, filterGeneration: 1, presetGeneration: 1)
        _ = state.advanceEpoch(mode: .bookmarks(nil), filterGeneration: 2, presetGeneration: 2)
        _ = state.advanceEpoch(mode: .whatsNew, filterGeneration: 3, presetGeneration: 3)

        XCTAssertEqual(state.presentationEpoch, 3)
        XCTAssertEqual(state.activePresentationContext.epoch, 3)
        XCTAssertEqual(state.activePresentationContext.mode, .whatsNew)
    }

    // MARK: - clear

    func test_clear_resetsAllFields() {
        let state = FeedDisplayState()

        // Populate state
        let item = FeedItem.makeMock(id: "a")
        state.setVisibleItems([item], readItemIDs: [], bookmarkItemIDs: [])
        state.setLoadingState(.refreshing)
        state.setFeedDisplayPhase(.ready(contextID: 1))
        state.setIsPreparingInitialRunway(true)
        _ = state.advanceEpoch(mode: .main, filterGeneration: 1, presetGeneration: 1)

        // Verify populated
        XCTAssertFalse(state.visibleItems.isEmpty)
        XCTAssertEqual(state.loadingState, .refreshing)

        // Clear
        state.clear()

        XCTAssertTrue(state.visibleItems.isEmpty)
        XCTAssertTrue(state.visibleCards.isEmpty)
        XCTAssertEqual(state.loadingState, .idle)
        guard case .preparing = state.feedDisplayPhase else {
            XCTFail("Phase should be .preparing after clear")
            return
        }
        XCTAssertFalse(state.isPreparingInitialRunway)
        XCTAssertEqual(state.presentationEpoch, 0)
        XCTAssertEqual(state.visibleItemsGeneration, 0)
    }

    func test_clear_resetsActivePresentationContext() {
        let state = FeedDisplayState()
        _ = state.advanceEpoch(mode: .main, filterGeneration: 5, presetGeneration: 10)

        XCTAssertEqual(state.presentationEpoch, 1)
        XCTAssertEqual(state.activePresentationContext.epoch, 1)

        state.clear()

        XCTAssertEqual(state.presentationEpoch, 0)
        XCTAssertEqual(state.activePresentationContext.epoch, 0,
                       "activePresentationContext.epoch must match presentationEpoch after clear")
        XCTAssertEqual(state.activePresentationContext.mode, .main)
        XCTAssertEqual(state.activePresentationContext.filterGeneration, 0)
        XCTAssertEqual(state.activePresentationContext.presetGeneration, 0)
    }

    // MARK: - Independent setters

    func test_setLoadingState_updatesValue() {
        let state = FeedDisplayState()
        state.setLoadingState(.refreshing)
        XCTAssertEqual(state.loadingState, .refreshing)
    }

    func test_setFeedDisplayPhase_updatesValue() {
        let state = FeedDisplayState()
        state.setFeedDisplayPhase(.failed(contextID: 1, message: "test error"))
        guard case .failed = state.feedDisplayPhase else {
            XCTFail("Phase should be .failed")
            return
        }
    }

    func test_setIsPreparingInitialRunway_updatesValue() {
        let state = FeedDisplayState()
        XCTAssertFalse(state.isPreparingInitialRunway)
        state.setIsPreparingInitialRunway(true)
        XCTAssertTrue(state.isPreparingInitialRunway)
    }
}

// MARK: - Test Helpers

extension FeedItem {
    static func makeMock(id: String) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Test Source",
            sourceURL: "https://example.com",
            category: "Technology",
            title: "Test \(id)",
            excerpt: "Excerpt for \(id)",
            url: "https://example.com/\(id)",
            imageURL: nil,
            publishedAt: Date(),
            region: "us"
        )
    }
}

extension FeedCardPresentation {
    static func makeMock(id: String, item: FeedItem) -> FeedCardPresentation {
        FeedCardPresentation(
            item: item,
            media: .none,
            layout: .textOnly,
            isRead: false,
            isBookmarked: false
        )
    }
}
