import XCTest
import Foundation
@testable import feedmine

final class FeedDiscoveryServiceTests: XCTestCase {

    func testIsDirectFeedURL_recognizesRSSExtension() {
        let url = URL(string: "https://example.com/feed.xml")!
        XCTAssertTrue(FeedDiscoveryService.isDirectFeedURL(url))
    }

    func testIsDirectFeedURL_recognizesYouTube() {
        let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=abc")!
        XCTAssertTrue(FeedDiscoveryService.isDirectFeedURL(url))
    }

    func testIsDirectFeedURL_rejectsRegularWebsite() {
        let url = URL(string: "https://example.com/blog")!
        XCTAssertFalse(FeedDiscoveryService.isDirectFeedURL(url))
    }
}
