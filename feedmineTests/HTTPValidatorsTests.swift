import XCTest
@testable import feedmine

final class HTTPValidatorsTests: XCTestCase {

    // MARK: - Cache-Control parsing

    func testParseMaxAge() {
        let cc = HTTPValidators.ParsedCacheControl.parse("max-age=3600")
        XCTAssertEqual(cc.maxAge, 3600)
        XCTAssertFalse(cc.noCache)
    }

    func testParseNoCache() {
        let cc = HTTPValidators.ParsedCacheControl.parse("no-cache, max-age=0")
        XCTAssertTrue(cc.noCache)
        XCTAssertEqual(cc.maxAge, 0)
    }

    func testParseNoStore() {
        let cc = HTTPValidators.ParsedCacheControl.parse("no-store")
        XCTAssertTrue(cc.noStore)
    }

    func testParseMustRevalidate() {
        let cc = HTTPValidators.ParsedCacheControl.parse("must-revalidate, max-age=86400")
        XCTAssertTrue(cc.mustRevalidate)
        XCTAssertEqual(cc.maxAge, 86400)
    }

    func testParseEmpty() {
        let cc = HTTPValidators.ParsedCacheControl.parse("")
        XCTAssertNil(cc.maxAge)
        XCTAssertFalse(cc.noCache)
    }

    // MARK: - CadenceEstimator

    func testDefaultValues() {
        let e = CadenceEstimator()
        XCTAssertEqual(e.publicationInterval, 3600)
        XCTAssertEqual(e.confidence, 0)
        XCTAssertTrue(e.lastPublication == .distantPast)
    }

    func testFirstPublicationDoesNotChangeInterval() {
        var e = CadenceEstimator()
        let now = Date()
        e.recordPublication(now)
        XCTAssertEqual(e.publicationInterval, 3600) // unchanged on first record
        XCTAssertEqual(e.confidence, 0.1)
    }

    func testEMAConverges() {
        var e = CadenceEstimator()
        let t0 = Date()
        e.recordPublication(t0)                              // first — no interval yet
        let t1 = t0.addingTimeInterval(7200)                 // 2h later
        e.recordPublication(t1)
        // EMA: 3600*0.7 + 7200*0.3 = 2520 + 2160 = 4680
        XCTAssertEqual(e.publicationInterval, 4680, accuracy: 0.01)
        XCTAssertEqual(e.confidence, 0.2, accuracy: 0.0001)
        let t2 = t1.addingTimeInterval(7200)                 // consistent 2h
        e.recordPublication(t2)
        // EMA: 4680*0.7 + 7200*0.3 = 3276 + 2160 = 5436
        XCTAssertEqual(e.publicationInterval, 5436, accuracy: 0.01)
        XCTAssertEqual(e.confidence, 0.3, accuracy: 0.0001)
    }

    func testMinIntervalClamped() {
        var e = CadenceEstimator(publicationInterval: 60, confidence: 1.0, lastPublication: Date())
        XCTAssertEqual(e.minInterval, 300) // clamped to 5 min minimum

        e = CadenceEstimator(publicationInterval: 100_000_000, confidence: 1.0, lastPublication: Date())
        XCTAssertEqual(e.minInterval, 2_592_000) // clamped to 30 day maximum
    }

    func testRecordNoChangeDecreasesConfidence() {
        var e = CadenceEstimator(publicationInterval: 3600, confidence: 0.5, lastPublication: Date())
        e.recordNoChange()
        XCTAssertEqual(e.confidence, 0.48)
        // Can't drop below 0.1
        for _ in 0..<30 { e.recordNoChange() }
        XCTAssertEqual(e.confidence, 0.1)
    }

    // MARK: - Codable round-trip

    func testRoundTripValidators() throws {
        var v = HTTPValidators()
        v.etag = "\"abc123\""
        v.cacheControl = HTTPValidators.ParsedCacheControl(maxAge: 3600)
        v.capabilities = SourceCapabilities(
            websub: SourceCapabilities.WebSubEndpoints(hub: "https://hub.example.com", selfURL: nil)
        )

        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(HTTPValidators.self, from: data)
        XCTAssertEqual(decoded.etag, "\"abc123\"")
        XCTAssertEqual(decoded.cacheControl?.maxAge, 3600)
        XCTAssertEqual(decoded.capabilities?.websub?.hub, "https://hub.example.com")
    }
}
