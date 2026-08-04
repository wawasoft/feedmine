import XCTest
@testable import feedmine

final class CatalogIdentityContractTests: XCTestCase {
    private struct Vector: Decodable {
        let name: String
        let raw: String
        let canonical: String
        let request: String
        let valid: Bool
    }

    private func vectors() throws -> [Vector] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("scripts/data/catalog_identity_vectors.json")
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }

    func testCanonicalAndRequestURLContractVectors() throws {
        for vector in try vectors() {
            XCTAssertEqual(
                OPMLParser.normalizeURL(vector.raw), vector.canonical,
                "canonical: \(vector.name)"
            )
            XCTAssertEqual(
                OPMLParser.requestURL(vector.raw), vector.request,
                "request: \(vector.name)"
            )
        }
    }

    func testInvalidPortsAreReturnedUnchangedWithoutCrashing() throws {
        for vector in try vectors() where !vector.valid {
            XCTAssertEqual(OPMLParser.normalizeURL(vector.raw), vector.raw, vector.name)
            XCTAssertEqual(OPMLParser.requestURL(vector.raw), vector.raw, vector.name)
        }
    }

    func testSignedParametersNeverEnterIdentityButRemainFetchable() {
        let first = "https://cdn.example.com/feed?x-amz-signature=one&episode=7"
        let second = "https://cdn.example.com/feed?x-amz-signature=two&episode=7"
        XCTAssertEqual(OPMLParser.normalizeURL(first), OPMLParser.normalizeURL(second))
        XCTAssertNotEqual(OPMLParser.requestURL(first), OPMLParser.requestURL(second))
    }

    @MainActor
    func testPersonalCollectionKeepsSignedFetchURLAndOneCompleteCollisionWinner() async throws {
        let userState = try UserStateStore(inMemory: true)
        let store = SourceCollectionStore(db: userState.db)
        let collectionID = try await store.createCollection(name: "Signed feeds")
        let first = SourceReference(
            title: "First endpoint",
            feedURL: "https://cdn.example.com/feed?episode=7&X-Amz-Signature=one"
        )
        let second = SourceReference(
            title: "Replacement endpoint",
            feedURL: "https://cdn.example.com/feed?episode=7&X-Amz-Signature=two"
        )

        try await store.add(first, to: collectionID)
        try await store.add(second, to: collectionID)
        let members = try await store.members(collectionID: collectionID)

        let member = try XCTUnwrap(members.first)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(member.title, "Replacement endpoint")
        XCTAssertTrue(member.sourceURL.contains("X-Amz-Signature=two"))
        XCTAssertEqual(member.id, OPMLParser.normalizeURL(second.feedURL))
    }

    // P1-06: idempotency
    func testNormalizeURLIsIdempotent() throws {
        for vector in try vectors() {
            let once = OPMLParser.normalizeURL(vector.raw)
            let twice = OPMLParser.normalizeURL(once)
            XCTAssertEqual(once, twice,
                "not idempotent: \(vector.name): normalize(\(vector.raw)) = \(once), normalize(\(once)) = \(twice)")
        }
    }

    // P1-06: trailing slash idempotency
    func testMultipleTrailingSlashesAreAllRemoved() {
        XCTAssertEqual(OPMLParser.normalizeURL("https://example.com/feed//"), "https://example.com/feed")
        XCTAssertEqual(OPMLParser.normalizeURL("https://example.com/feed///"), "https://example.com/feed")
    }

    // P1-05: percent-encoded authority delimiters
    func testRejectsPercentEncodedAuthorityDelimiters() {
        // These URLs have percent-encoded delimiters that decode to invalid host chars
        let invalidURLs = [
            "https://foo%2Fbar/feed",
            "https://example%3Acom/feed",
            "https://foo%40bar/feed",
        ]
        for url in invalidURLs {
            // normalizeURL returns the input unchanged for invalid URLs
            XCTAssertEqual(OPMLParser.normalizeURL(url), url,
                "\(url): should return unchanged (invalid)")
            XCTAssertEqual(OPMLParser.requestURL(url), url,
                "\(url): should return unchanged (invalid)")
        }
    }

    // P1-05: valid IPv6 is accepted
    func testValidBracketedIPv6Accepted() {
        let url = "https://[2001:db8::1]/feed"
        XCTAssertEqual(OPMLParser.normalizeURL(url), "https://[2001:db8::1]/feed")
        XCTAssertEqual(OPMLParser.requestURL(url), "https://[2001:db8::1]/feed")
    }
}
