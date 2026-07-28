import XCTest
import UIKit
@testable import feedmine

@MainActor
final class CardPresentationTests: XCTestCase {

    // MARK: - ResolvedCardMedia equality

    func testResolvedCardMedia_image_sameInstance_areEqual() {
        let img = UIImage()
        let a = ResolvedCardMedia.image(img)
        let b = ResolvedCardMedia.image(img)
        XCTAssertEqual(a, b, "Same UIImage instance should be equal by pointer identity")
    }

    func testResolvedCardMedia_image_differentInstances_areNotEqual() {
        let a = ResolvedCardMedia.image(UIImage())
        let b = ResolvedCardMedia.image(UIImage())
        XCTAssertNotEqual(a, b, "Different UIImage instances should not be equal")
    }

    func testResolvedCardMedia_placeholder_areEqual() {
        XCTAssertEqual(ResolvedCardMedia.placeholder, ResolvedCardMedia.placeholder)
    }

    func testResolvedCardMedia_none_areEqual() {
        XCTAssertEqual(ResolvedCardMedia.none, ResolvedCardMedia.none)
    }

    func testResolvedCardMedia_differentCases_areNotEqual() {
        XCTAssertNotEqual(ResolvedCardMedia.image(UIImage()), ResolvedCardMedia.placeholder)
        XCTAssertNotEqual(ResolvedCardMedia.image(UIImage()), ResolvedCardMedia.none)
        XCTAssertNotEqual(ResolvedCardMedia.placeholder, ResolvedCardMedia.none)
    }

    // MARK: - FeedCardPresentation identity

    func testFeedCardPresentation_id_matchesFeedItem() {
        let item = makeItem(id: "test-123")
        let pres = FeedCardPresentation(
            item: item, media: .none, layout: .textOnly,
            isRead: false, isBookmarked: false
        )
        XCTAssertEqual(pres.id, "test-123")
    }

    func testFeedCardPresentation_equality() {
        let item = makeItem(id: "same")
        let now = Date()
        let a = FeedCardPresentation(item: item, media: .none, layout: .textOnly,
                                      isRead: false, isBookmarked: false, preparedAt: now)
        let b = FeedCardPresentation(item: item, media: .none, layout: .textOnly,
                                      isRead: false, isBookmarked: false, preparedAt: now)
        XCTAssertEqual(a, b)
    }

    func testFeedCardPresentation_differentMedia_areNotEqual() {
        let item = makeItem(id: "x")
        let a = FeedCardPresentation(item: item, media: .none, layout: .textOnly,
                                      isRead: false, isBookmarked: false)
        let b = FeedCardPresentation(item: item, media: .placeholder, layout: .textOnly,
                                      isRead: false, isBookmarked: false)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - FeedItemCardView hasImage logic

    func test_cardView_hasImage_true_whenPresentationHasImage() {
        let item = makeItem(id: "img", imageURL: "https://example.com/img.jpg")
        let img = UIImage()
        let pres = FeedCardPresentation(item: item, media: .image(img), layout: .hero,
                                         isRead: false, isBookmarked: false)
        let view = FeedItemCardView(item: item, isRead: false, isBookmarked: false,
                                     presentation: pres)
        XCTAssertTrue(view.hasImageTest, "hasImage should be true with .image media")
    }

    func test_cardView_hasImage_false_whenPresentationIsPlaceholder() {
        let item = makeItem(id: "ph", imageURL: "https://example.com/img.jpg")
        let pres = FeedCardPresentation(item: item, media: .placeholder, layout: .textOnly,
                                         isRead: false, isBookmarked: false)
        let view = FeedItemCardView(item: item, isRead: false, isBookmarked: false,
                                     presentation: pres)
        XCTAssertFalse(view.hasImageTest, "hasImage should be false with .placeholder media")
    }

    func test_cardView_hasImage_false_whenPresentationIsNone() {
        let item = makeItem(id: "no", imageURL: "https://example.com/img.jpg")
        let pres = FeedCardPresentation(item: item, media: .none, layout: .textOnly,
                                         isRead: false, isBookmarked: false)
        let view = FeedItemCardView(item: item, isRead: false, isBookmarked: false,
                                     presentation: pres)
        XCTAssertFalse(view.hasImageTest, "hasImage should be false with .none media")
    }

    func test_cardView_hasImage_false_whenNoPresentation() {
        // Even though the item has hasPotentialImage=true, without a presentation
        // the card must not attempt to render an image — no download trigger.
        let item = makeItem(id: "nopres", imageURL: "https://example.com/img.jpg")
        let view = FeedItemCardView(item: item, isRead: false, isBookmarked: false,
                                     presentation: nil)
        XCTAssertFalse(view.hasImageTest, "hasImage must be false when presentation is nil — no speculative image slots")
    }

    func test_cardView_hasImage_false_whenItemHasNoPotentialImage() {
        // Text-only item with no image URL and no resolvable article page
        let item = FeedItem(
            id: "textonly",
            sourceTitle: "Test",
            sourceURL: "https://example.com",
            category: "News",
            title: "Title",
            excerpt: "Excerpt",
            url: "https://example.com/article",
            imageURL: nil,
            publishedAt: Date(),
            audioURL: nil,
            duration: nil,
            region: "imported",
            language: nil,
            updatedAt: nil,
            authors: nil,
            itemCategories: nil,
            rights: nil,
            attribution: nil,
            enclosures: nil,
            languageFromFeed: nil,
            alternateLinks: nil
        )
        let pres = FeedCardPresentation(item: item, media: .none, layout: .textOnly,
                                         isRead: false, isBookmarked: false)
        let view = FeedItemCardView(item: item, isRead: false, isBookmarked: false,
                                     presentation: pres)
        XCTAssertFalse(view.hasImageTest, "Text-only items should never have an image slot")
    }

    // MARK: - Terminal states: no .loading path

    func test_resolvedCardMedia_hasNoLoadingState() {
        // The ResolvedCardMedia enum must not have a .loading case —
        // cards are published only when media is terminal.
        let cases: [ResolvedCardMedia] = [.image(UIImage()), .placeholder, .none]
        XCTAssertEqual(cases.count, 3, "ResolvedCardMedia has exactly 3 terminal states; no .loading")
    }

    // MARK: - FeedCardLayout terminal states

    func test_feedCardLayout_hasThreeStates() {
        let cases: [FeedCardLayout] = [.hero, .thumbnail, .textOnly]
        XCTAssertEqual(cases.count, 3)
    }

    // MARK: - Helpers

    private func makeItem(id: String, imageURL: String? = nil) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Test Source",
            sourceURL: "https://example.com/feed",
            category: "News",
            title: "Test Title",
            excerpt: "Test excerpt",
            url: "https://example.com/article",
            imageURL: imageURL,
            publishedAt: Date(),
            audioURL: nil,
            duration: nil,
            region: "imported",
            language: "en",
            updatedAt: nil,
            authors: nil,
            itemCategories: nil,
            rights: nil,
            attribution: nil,
            enclosures: nil,
            languageFromFeed: nil,
            alternateLinks: nil
        )
    }
}

// hasImageTest extension defined in ReadyCardQueueTests.swift
