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
}
