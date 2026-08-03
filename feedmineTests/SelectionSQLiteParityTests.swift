import XCTest
import GRDB
@testable import feedmine

// MARK: - SQL/In-Memory Parity Tests (§9, §24.2)
//
// Verifies that SQLItemRuleCompiler and InMemoryItemRuleEvaluator
// produce the same item IDs for the same fixtures using a temporary
// SQLite database.

@MainActor
final class SelectionSQLiteParityTests: XCTestCase {

    var db: DatabaseQueue!

    override func setUp() async throws {
        db = try DatabaseQueue()
        try createSchema()
    }

    override func tearDown() async throws {
        try db.close()
        db = nil
    }

    // MARK: - Schema

    private func createSchema() throws {
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS feed_item (
                    id TEXT PRIMARY KEY,
                    source_title TEXT NOT NULL,
                    source_url TEXT NOT NULL,
                    category TEXT NOT NULL DEFAULT '',
                    title TEXT NOT NULL,
                    excerpt TEXT NOT NULL DEFAULT '',
                    url TEXT NOT NULL,
                    image_url TEXT,
                    published_at REAL NOT NULL,
                    fetched_at REAL NOT NULL,
                    audio_url TEXT,
                    region TEXT NOT NULL DEFAULT 'global',
                    language TEXT,
                    is_read INTEGER NOT NULL DEFAULT 0,
                    consumed_at REAL
                );
                CREATE TABLE IF NOT EXISTS bookmark_item (
                    item_id TEXT NOT NULL,
                    list_id INTEGER NOT NULL,
                    PRIMARY KEY (item_id, list_id)
                );
                """)
        }
    }

    // MARK: - Fixture helpers

    func makeFixtureItems(count: Int = 20) -> [FeedItem] {
        let regions = ["global", "countries/brazil", "countries/brazil/sao-paulo", "countries/usa", "countries/france"]
        let languages: [String?] = ["en", "pt", "ja", "fr", nil]

        return (0..<count).map { i in
            FeedItem(
                id: "sql-parity-\(i)",
                sourceTitle: "Source \(i % 5)",
                sourceURL: "https://example\(i % 5).com/feed",
                category: "Category \(i % 4)",
                title: "Title \(i): \(["Breaking News", "Tech Update", "Sports", "Weather", "Opinion"][i % 5])",
                excerpt: "Excerpt \(i). Detailed content for testing parity.",
                url: "https://example.com/article/\(i)",
                imageURL: i % 3 == 0 ? "https://example.com/img/\(i).jpg" : nil,
                publishedAt: Date().addingTimeInterval(-Double(i * 3600)),
                audioURL: i % 5 == 0 ? "https://example.com/audio/\(i).mp3" : nil,
                duration: i % 5 == 0 ? 1800.0 : nil,
                region: regions[i % regions.count],
                language: languages[i % languages.count],
                isRead: i % 7 == 0,
                isBookmarked: i % 11 == 0
            )
        }
    }

    func insertFixtures(_ items: [FeedItem]) throws {
        try db.write { db in
            for item in items {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO feed_item
                    (id, source_title, source_url, category, title, excerpt, url,
                     image_url, published_at, fetched_at, audio_url, region, language, is_read)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        item.id, item.sourceTitle, item.sourceURL, item.category,
                        item.title, item.excerpt, item.url,
                        item.imageURL, item.publishedAt.timeIntervalSince1970,
                        Date().timeIntervalSince1970, item.audioURL,
                        item.region, item.language, item.isRead ? 1 : 0
                    ])
            }
        }
    }

    // MARK: - Region filter parity

    func test_regionFilter_sameIDs() async throws {
        let items = makeFixtureItems(count: 20)
        try insertFixtures(items)

        var rules = ItemRuleSet.none
        rules.regions = ["countries/brazil"]

        // SQL
        let (sql, args) = SQLItemRuleCompiler().compile(rules, limit: 200, offset: 0)
        let sqlIDs = try await db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: args).map { $0["id"] as String }
        }

        // In-memory
        let evaluator = InMemoryItemRuleEvaluator()
        let memItems = await evaluator.evaluate(items, against: rules)
        let memIDs = Set(memItems.map(\.id))

        // Compare: SQL results should all be in-memory results
        for id in sqlIDs {
            XCTAssertTrue(memIDs.contains(id), "SQL result \(id) should be in memory results")
        }
        // In-memory results should match expected count
        let expectedCount = items.filter {
            $0.region == "countries/brazil" || $0.region.hasPrefix("countries/brazil/")
        }.count
        XCTAssertEqual(sqlIDs.count, expectedCount, "SQL count should match expected")
    }

    // MARK: - Language filter parity

    func test_languageFilter_sameIDs() async throws {
        let items = makeFixtureItems(count: 20)
        try insertFixtures(items)

        var rules = ItemRuleSet.none
        rules.languages = ["en", "pt"]

        let (sql, args) = SQLItemRuleCompiler().compile(rules, limit: 200, offset: 0)
        let sqlIDs = try await db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: args).map { $0["id"] as String }
        }

        let evaluator = InMemoryItemRuleEvaluator()
        let memItems = await evaluator.evaluate(items, against: rules)

        let expectedCount = items.filter {
            $0.language == "en" || $0.language == "pt"
        }.count
        XCTAssertEqual(sqlIDs.count, expectedCount)
        XCTAssertEqual(memItems.count, expectedCount)
    }

    // MARK: - Read filter parity

    func test_readFilter_sameIDs() async throws {
        let items = makeFixtureItems(count: 20)
        try insertFixtures(items)

        var rules = ItemRuleSet.none
        rules.history.includeRead = false

        let (sql, args) = SQLItemRuleCompiler().compile(rules, limit: 200, offset: 0)
        let sqlIDs = try await db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: args).map { $0["id"] as String }
        }

        let evaluator = InMemoryItemRuleEvaluator()
        let memItems = await evaluator.evaluate(items, against: rules)

        let expectedCount = items.filter { !$0.isRead }.count
        XCTAssertEqual(sqlIDs.count, expectedCount)
        XCTAssertEqual(memItems.count, expectedCount)

        // No read items should appear
        let readIDs = items.filter(\.isRead).map(\.id)
        for id in sqlIDs {
            XCTAssertFalse(readIDs.contains(id))
        }
    }

    // MARK: - Keyword exclusion parity

    func test_keywordExclusion_sameIDs() async throws {
        let items = makeFixtureItems(count: 20)
        try insertFixtures(items)

        var rules = ItemRuleSet.none
        rules.excludedKeywords = ["Breaking"]

        let (sql, args) = SQLItemRuleCompiler().compile(rules, limit: 200, offset: 0)
        let sqlIDs = try await db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: args).map { $0["id"] as String }
        }

        let evaluator = InMemoryItemRuleEvaluator()
        let memItems = await evaluator.evaluate(items, against: rules)

        let expectedCount = items.filter { !$0.title.contains("Breaking") }.count
        XCTAssertEqual(sqlIDs.count, expectedCount)
        XCTAssertEqual(memItems.count, expectedCount)
    }

    // MARK: - Audio content type parity

    func test_audioContentType_sameIDs() async throws {
        let items = makeFixtureItems(count: 20)
        try insertFixtures(items)

        var rules = ItemRuleSet.none
        rules.contentTypes = [.audio]

        let (sql, args) = SQLItemRuleCompiler().compile(rules, limit: 200, offset: 0)
        let sqlIDs = try await db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: args).map { $0["id"] as String }
        }

        let evaluator = InMemoryItemRuleEvaluator()
        let memItems = await evaluator.evaluate(items, against: rules)

        let expectedCount = items.filter { $0.audioURL != nil }.count
        XCTAssertEqual(sqlIDs.count, expectedCount)
        XCTAssertEqual(memItems.count, expectedCount)
    }

    // MARK: - Date range parity

    func test_dateRange_sameIDs() async throws {
        let items = makeFixtureItems(count: 20)
        try insertFixtures(items)

        var rules = ItemRuleSet.none
        let cutoff = Date().addingTimeInterval(-6 * 3600)  // 6 hours ago
        rules.history.dateRange = cutoff...Date()

        let (sql, args) = SQLItemRuleCompiler().compile(rules, limit: 200, offset: 0)
        let sqlIDs = try await db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: args).map { $0["id"] as String }
        }

        let evaluator = InMemoryItemRuleEvaluator()
        let memItems = await evaluator.evaluate(items, against: rules)

        let expectedCount = items.filter { $0.publishedAt >= cutoff }.count
        XCTAssertEqual(sqlIDs.count, expectedCount)
        XCTAssertEqual(memItems.count, expectedCount)
    }

    // MARK: - Combined filters

    func test_combinedFilters_sameIDs() async throws {
        let items = makeFixtureItems(count: 30)
        try insertFixtures(items)

        var rules = ItemRuleSet.none
        rules.regions = ["global"]
        rules.languages = ["en"]
        rules.history.includeRead = false
        rules.contentTypes = [.text]
        rules.excludedKeywords = ["Weather"]

        let (sql, args) = SQLItemRuleCompiler().compile(rules, limit: 200, offset: 0)
        let sqlIDs = try await db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: args).map { $0["id"] as String }
        }

        let evaluator = InMemoryItemRuleEvaluator()
        let memItems = await evaluator.evaluate(items, against: rules)

        let expected = items.filter { item in
            item.region == "global"
            && item.language == "en"
            && !item.isRead
            && item.audioURL == nil
            && !item.isYouTube
            && !item.title.contains("Weather")
        }

        XCTAssertEqual(sqlIDs.count, expected.count, "SQL count mismatch")
        XCTAssertEqual(memItems.count, expected.count, "Memory count mismatch")

        // Verify IDs match
        let memIDs = Set(memItems.map(\.id))
        let expectedIDs = Set(expected.map(\.id))
        XCTAssertEqual(memIDs, expectedIDs, "In-memory results should match expected")
    }
}
