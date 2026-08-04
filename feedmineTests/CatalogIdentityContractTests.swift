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

    // MARK: - P0-01: Import pipeline preserves request URL

    /// Signed query fields survive paste import via ImportPipeline.
    func testSignedQueryFieldsSurvivePasteImport() async throws {
        let pipeline = ImportPipeline(probe: { _ in .success(title: "Test Feed") })
        let signedURL = "https://private.example/feed.xml?temp_url_sig=abc123&temp_url_expires=1999999999"
        let (result, sources) = await pipeline.ingest(
            urls: [signedURL], existingURLs: []
        )
        XCTAssertEqual(result.importedCount, 1, "Should import with stubbed probe")
        let source = try XCTUnwrap(sources.first)
        XCTAssertTrue(source.url.contains("temp_url_sig=abc123"),
                      "Signed param stripped: \(source.url)")
        XCTAssertTrue(source.url.contains("temp_url_expires=1999999999"),
                      "Expires param stripped: \(source.url)")
        let identity = OPMLParser.normalizeURL(source.url)
        XCTAssertFalse(identity.contains("temp_url_sig"),
                       "Signed param leaked into identity: \(identity)")
    }

    /// AWS-style signed URLs survive import.
    func testAWSstyleSignedURLSurvivesImport() async throws {
        let pipeline = ImportPipeline(probe: { _ in .success(title: "AWS Feed") })
        let signedURL = "https://bucket.example/feed.xml?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=abcd"
        let (result, sources) = await pipeline.ingest(urls: [signedURL], existingURLs: [])
        XCTAssertEqual(result.importedCount, 1)
        let source = try XCTUnwrap(sources.first)
        XCTAssertTrue(source.url.contains("X-Amz-Signature=abcd"),
                      "AWS signature stripped: \(source.url)")
        let identity = OPMLParser.normalizeURL(source.url)
        XCTAssertFalse(identity.contains("X-Amz"),
                       "AWS params leaked into identity: \(identity)")
    }

    /// Two signed aliases in the same batch dedup by identity.
    func testTwoSignedAliasesInSameBatchDedup() async throws {
        let pipeline = ImportPipeline(probe: { _ in .success(title: "CDN Feed") })
        let first = "https://cdn.example.com/feed?x-amz-signature=one&episode=7"
        let second = "https://cdn.example.com/feed?x-amz-signature=two&episode=7"
        let (result, sources) = await pipeline.ingest(
            urls: [first, second], existingURLs: []
        )
        XCTAssertEqual(result.importedCount, 1, "Batch dedup failed: both aliases imported")
        XCTAssertEqual(result.duplicateCount, 1, "Second alias not reported as duplicate")
        XCTAssertEqual(sources.count, 1)
        let source = try XCTUnwrap(sources.first)
        XCTAssertTrue(source.url.contains("x-amz-signature="),
                      "No signature preserved: \(source.url)")
    }

    /// requestURL round-trips correctly through normalizeURL.
    func testRequestURLRoundTripsThroughNormalizeURL() {
        let urls = [
            "https://example.com/feed?temp_url_sig=abc&id=42",
            "https://example.com/feed?X-Amz-Signature=xyz&episode=7",
            "https://cdn.example.com/path/?token=secret&ref=home",
            "http://www.example.com/feed/",
        ]
        for raw in urls {
            let request = OPMLParser.requestURL(raw)
            let identity = OPMLParser.normalizeURL(request)
            let directIdentity = OPMLParser.normalizeURL(raw)
            XCTAssertEqual(identity, directIdentity,
                           "normalizeURL(requestURL(x)) != normalizeURL(x) for: \(raw)")
        }
    }

    /// OPML non-validate import preserves request URL with auth params.
    func testOPMLImportPreservesRequestURL() async throws {
        let pipeline = ImportPipeline()
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline text="Signed" xmlUrl="https://private.example/feed.xml?temp_url_sig=abc123&amp;expires=99" />
          </body>
        </opml>
        """
        let data = Data(opml.utf8)
        let (result, sources) = await pipeline.ingest(
            opmlData: data, fileName: "test", existingURLs: [], validate: false
        )
        XCTAssertEqual(result.importedCount, 1)
        let source = try XCTUnwrap(sources.first)
        XCTAssertTrue(source.url.contains("temp_url_sig=abc123"),
                      "OPML import stripped signed params: \(source.url)")
        let identity = OPMLParser.normalizeURL(source.url)
        XCTAssertFalse(identity.contains("temp_url_sig"),
                       "Signed param leaked into OPML identity: \(identity)")
    }

    /// Duplicate URLs within the same OPML batch dedup.
    func testOPMLBatchDedupDuplicateURLs() async {
        let pipeline = ImportPipeline()
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline text="A" xmlUrl="https://example.com/feed.xml?temp_url_sig=one" />
            <outline text="B" xmlUrl="https://example.com/feed.xml?temp_url_sig=two" />
          </body>
        </opml>
        """
        let data = Data(opml.utf8)
        let (result, sources) = await pipeline.ingest(
            opmlData: data, fileName: "test", existingURLs: [], validate: false
        )
        XCTAssertEqual(result.importedCount, 1, "Both URLs imported instead of dedup")
        XCTAssertEqual(result.duplicateCount, 1, "Second URL not reported as duplicate")
        XCTAssertEqual(sources.count, 1)
    }

    /// skipValidation path in FeedLoader preserves request URL.
    @MainActor
    func testSkipValidationPreservesRequestURL() async throws {
        let store = try FeedStore(inMemory: true)
        let loader = FeedLoader(store: store)
        let signedURL = "https://private.example/feed.xml?temp_url_sig=abc123&expires=999"
        let result = await loader.importFeeds(
            urls: [signedURL], category: "Test", skipValidation: true
        )
        XCTAssertEqual(result.importedCount, 1)
        let imported = store.registry.sources.filter { $0.region == "imported" }
        XCTAssertEqual(imported.count, 1)
        let source = try XCTUnwrap(imported.first)
        XCTAssertTrue(source.url.contains("temp_url_sig=abc123"),
                      "skipValidation stripped signed params: \(source.url)")
    }

    /// skipValidation dedups against existing sources by identity.
    @MainActor
    func testSkipValidationDedupAgainstExisting() async throws {
        let store = try FeedStore(inMemory: true)
        let loader = FeedLoader(store: store)
        // First import with a tracking param
        let url1 = "https://example.com/feed.xml?temp_url_sig=secret123"
        let r1 = await loader.importFeeds(urls: [url1], skipValidation: true)
        XCTAssertEqual(r1.importedCount, 1)
        // Second import with different tracking param — same identity
        let url2 = "https://example.com/feed.xml?temp_url_sig=different456"
        let r2 = await loader.importFeeds(urls: [url2], skipValidation: true)
        XCTAssertEqual(r2.duplicateCount, 1, "Same-identity URL not deduped")
        XCTAssertEqual(r2.importedCount, 0)
    }

    /// OPML validate: true path preserves titles/URLs through probes.
    func testOPMLValidatePathPreservesMetadata() async throws {
        let pipeline = ImportPipeline(probe: { _ in .success(title: "Probed Title") })
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline text="Original Title" xmlUrl="https://example.com/feed.xml?temp_url_sig=abc" />
          </body>
        </opml>
        """
        let data = Data(opml.utf8)
        let (result, sources) = await pipeline.ingest(
            opmlData: data, fileName: "test", existingURLs: [], validate: true
        )
        XCTAssertEqual(result.importedCount, 1)
        let source = try XCTUnwrap(sources.first)
        // Title from OPML should be preserved (not overwritten by probe)
        XCTAssertEqual(source.title, "Original Title")
        // URL should preserve auth params
        XCTAssertTrue(source.url.contains("temp_url_sig=abc"))
    }

    /// validate: true OPML reports duplicates from within the OPML.
    func testOPMLValidatePathReportsInternalDuplicates() async throws {
        let pipeline = ImportPipeline(probe: { _ in .success(title: "Feed") })
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline text="First" xmlUrl="https://example.com/feed.xml?temp_url_sig=one" />
            <outline text="Second" xmlUrl="https://example.com/feed.xml?temp_url_sig=two" />
          </body>
        </opml>
        """
        let data = Data(opml.utf8)
        let (result, sources) = await pipeline.ingest(
            opmlData: data, fileName: "test", existingURLs: [], validate: true
        )
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(sources.count, 1)
    }

    /// Empty imported sources deletes the JSON file.
    @MainActor
    func testEmptyImportedSourcesDeletesJSONFile() async throws {
        let store = try FeedStore(inMemory: true)
        let loader = FeedLoader(store: store)
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imported_sources.json")
        // Clean up from any prior run
        try? FileManager.default.removeItem(at: fileURL)
        // Import then remove all imported sources
        _ = await loader.importFeeds(urls: ["https://example.com/feed.xml?auth=secret"], skipValidation: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "imported_sources.json should exist after import")
        // Remove all imported sources from registry
        let nonImported = store.registry.sources.filter { $0.region != "imported" }
        store.registry.sources = nonImported
        loader.addSources([])  // triggers persistImportedSources
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "imported_sources.json should be deleted when empty")
    }
}
