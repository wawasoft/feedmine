# Content Architecture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat string-keyed source toggle system with a hierarchical Library tree, add cross-cutting Channels, build share-sheet FeedDetector, and add multi-format export.

**Architecture:** Three SQLite tables (library_node, library_source, channel + channel_node) replace SourceRegistry's in-memory disabled/enabledOverrides sets. A recursive CTE resolves active sources. Channel references library nodes many-to-many. FeedDetector is a new actor. Three new views (ShareResultView, LibraryBrowser, ExportHub) replace four old ones.

**Tech Stack:** SwiftUI + Observation, GRDB/SQLite + FTS5, FeedKit. Swift 6 strict concurrency. iOS 18.0 target.

## Global Constraints

- iOS 18.0 minimum deployment target
- Swift 6.0 with complete strict concurrency checking
- GRDB 7.4.0+ for SQLite persistence
- FeedKit 9.0+ for RSS/Atom/JSON feed parsing
- Single iPhone-only target (TARGETED_DEVICE_FAMILY: "1")
- CircadianEngine must be used for all accent colors, spacing, typography
- Haptic feedback on all toggle, save, and export actions
- All new strings use `String(localized:)` for future i18n
- No external dependencies beyond FeedKit and GRDB

---

## File Map

**Create:**
- `feedmine/Models/LibraryNode.swift` — LibraryNode struct + GRDB record + recursive CTE query
- `feedmine/Models/Channel.swift` — Channel struct + GRDB record
- `feedmine/Services/FeedDetector.swift` — FeedDetector actor (URL → feed/OPML/webpage detection)
- `feedmine/Views/LibraryTreeView.swift` — Shared tree component (navigation + selection modes)
- `feedmine/Views/ShareResultView.swift` — Share sheet result sheet (loading, result, destination picker)
- `feedmine/Views/LibraryBrowser.swift` — Library tree browser (replaces country drill-down screens)
- `feedmine/Views/ExportHub.swift` — Export options screen (OPML, CSV, JSON, HTML, PDF)

**Modify:**
- `feedmine/Models/FeedSource.swift` — Add `SourceOrigin` enum
- `feedmine/Services/FeedStore.swift` — Migration v6, library seeding, channel filter state
- `feedmine/Services/FeedLoader.swift` — Channel selection API, onOpenURL handler
- `feedmine/Services/SourceRegistry.swift` — Deprecation wrappers reading from library tree
- `feedmine/Services/SourceScheduler.swift` — Accept `[FeedSource]` instead of region/category params
- `feedmine/Services/OPMLParser.swift` — Set `.bundled` / `.imported` origin on created sources
- `feedmine/feedmineApp.swift` — `onOpenURL` for share sheet URL reception
- `feedmine/Views/FeedScreen.swift` — Channel picker button in header
- `feedmine/Views/SettingsSheetView.swift` — Export hub navigation link

**Remove (end of Phase 3):**
- `feedmine/Views/CountriesListScreen.swift`
- `feedmine/Views/CountryDetailScreen.swift`
- `feedmine/Views/RegionDetailScreen.swift`

**Keep but simplify:**
- `feedmine/Views/FilterSheetView.swift` — Remove category/region picker (moved to LibraryBrowser/Channel)
- `feedmine/Views/SourceManagementView.swift` — Keep OPML import/export, rest replaced by LibraryBrowser

---

## Phase 1 — Foundation (Data Layer)

### Task 1: Add SourceOrigin to FeedSource

**Files:**
- Modify: `feedmine/Models/FeedSource.swift`

**Interfaces:**
- Produces: `SourceOrigin` enum with `.bundled`, `.imported`, `.user` cases
- Produces: `FeedSource.origin: SourceOrigin` property (default `.bundled`)

- [ ] Add `SourceOrigin` enum to `FeedSource.swift`

```swift
// Add above FeedSource struct
enum SourceOrigin: String, Codable, Sendable {
    case bundled   // from bundled OPML files
    case imported  // user imported OPML file
    case user      // user added via URL / share sheet
}
```

- [ ] Add `origin` property to `FeedSource` with default

```swift
struct FeedSource: Codable, Identifiable, Sendable {
    var id: String { url }
    let title: String
    let url: String
    let category: String
    let region: String
    let mediaKind: MediaKind
    let origin: SourceOrigin  // new field, default .bundled
}
```

- [ ] Update `FeedSource` initializer in OPMLParser to accept origin (keep existing default)

- [ ] Build and verify: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,id=D3A8E60A-D820-4E29-A7E3-BC32DE7AD990' build`

- [ ] Commit

```bash
git add feedmine/Models/FeedSource.swift
git commit -m "feat: add SourceOrigin enum to FeedSource"
```

### Task 2: Create LibraryNode and Channel models

**Files:**
- Create: `feedmine/Models/LibraryNode.swift`
- Create: `feedmine/Models/Channel.swift`

**Interfaces:**
- Produces: `LibraryNode` struct (id, parentId, name, sortOrder, origin, enabled)
- Produces: `LibraryNodeRecord` GRDB record
- Produces: `LibrarySourceRecord` GRDB record (node_id, source_url)
- Produces: `Channel` struct (id, name, sortOrder)
- Produces: `ChannelRecord` GRDB record
- Produces: `ChannelNodeRecord` GRDB record (channel_id, node_id)

- [ ] Create `feedmine/Models/LibraryNode.swift`

```swift
import Foundation
import GRDB

// MARK: - Domain model

struct LibraryNode: Identifiable, Hashable, Sendable {
    var id: Int64
    var parentId: Int64?
    var name: String
    var sortOrder: Int
    var origin: SourceOrigin
    var enabled: Bool
    var childCount: Int = 0       // populated by query, not stored
    var sourceCount: Int = 0      // populated by query, not stored
}

// MARK: - GRDB Records

struct LibraryNodeRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var parentId: Int64?
    var name: String
    var sortOrder: Int
    var origin: String
    var enabled: Bool

    static let databaseTableName = "library_node"

    enum CodingKeys: String, CodingKey {
        case id
        case parentId = "parent_id"
        case name
        case sortOrder = "sort_order"
        case origin
        case enabled
    }

    func toNode() -> LibraryNode {
        LibraryNode(
            id: id!,
            parentId: parentId,
            name: name,
            sortOrder: sortOrder,
            origin: SourceOrigin(rawValue: origin) ?? .bundled,
            enabled: enabled
        )
    }
}

struct LibrarySourceRecord: Codable, FetchableRecord, PersistableRecord {
    var nodeId: Int64
    var sourceUrl: String

    static let databaseTableName = "library_source"

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case sourceUrl = "source_url"
    }
}

// MARK: - Derived table for source lookup

/// Joins library_node + library_source for fetching FeedSource metadata
/// without loading all sources into memory.
struct LibraryNodeSource: Codable, FetchableRecord {
    var nodeId: Int64
    var sourceUrl: String
    var nodeEnabled: Bool
    var parentEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case sourceUrl = "source_url"
        case nodeEnabled = "node_enabled"
        case parentEnabled = "parent_enabled"
    }
}

// MARK: - Recursive CTE query

extension LibraryNodeRecord {
    /// Returns all source_urls from enabled nodes in the active tree.
    /// Uses recursive CTE — a disabled parent excludes descendants
    /// regardless of their own enabled flag.
    static func activeSourceURLs(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            WITH RECURSIVE active_tree AS (
                SELECT id FROM library_node
                WHERE enabled = 1 AND parent_id IS NULL
                UNION ALL
                SELECT n.id FROM library_node n
                JOIN active_tree a ON n.parent_id = a.id
                WHERE n.enabled = 1
            )
            SELECT DISTINCT ls.source_url FROM library_source ls
            JOIN active_tree at ON ls.node_id = at.id
        """)
    }

    /// Returns flat list of enabled nodes for tree rendering.
    static func allNodes(_ db: Database) throws -> [LibraryNodeRecord] {
        try LibraryNodeRecord
            .order(Column("sort_order"))
            .fetchAll(db)
    }

    /// Returns child nodes for a given parent, ordered by sort_order.
    static func children(of parentId: Int64?, _ db: Database) throws -> [LibraryNodeRecord] {
        if let pid = parentId {
            return try LibraryNodeRecord
                .filter(Column("parent_id") == pid)
                .order(Column("sort_order"))
                .fetchAll(db)
        } else {
            return try LibraryNodeRecord
                .filter(Column("parent_id") == nil)
                .order(Column("sort_order"))
                .fetchAll(db)
        }
    }
}
```

- [ ] Create `feedmine/Models/Channel.swift`

```swift
import Foundation
import GRDB

// MARK: - Domain model

struct Channel: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var sortOrder: Int
}

// MARK: - GRDB Records

struct ChannelRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String
    var sortOrder: Int

    static let databaseTableName = "channel"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
    }

    func toChannel() -> Channel {
        Channel(id: id!, name: name, sortOrder: sortOrder)
    }
}

struct ChannelNodeRecord: Codable, FetchableRecord, PersistableRecord {
    var channelId: Int64
    var nodeId: Int64

    static let databaseTableName = "channel_node"

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case nodeId = "node_id"
    }

    /// Returns all node IDs for a channel
    static func nodeIDs(for channelId: Int64, _ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT node_id FROM channel_node WHERE channel_id = ?
        """, arguments: [channelId])
    }

    /// Returns source URLs for a channel by joining through library_node + library_source
    static func sourceURLs(for channelId: Int64, _ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT ls.source_url FROM library_source ls
            JOIN channel_node cn ON ls.node_id = cn.node_id
            WHERE cn.channel_id = ?
        """, arguments: [channelId])
    }
}
```

- [ ] Build and verify

- [ ] Commit

```bash
git add feedmine/Models/LibraryNode.swift feedmine/Models/Channel.swift
git commit -m "feat: add LibraryNode and Channel models with GRDB records"
```

### Task 3: Add migration v6 to FeedStore

**Files:**
- Modify: `feedmine/Services/FeedStore.swift` (add migration v6)

**Interfaces:**
- Consumes: `LibraryNodeRecord`, `LibrarySourceRecord` tables from Task 2
- Produces: v6 migration registered in `FeedStore.migrate()`

- [ ] Add v6 migration after existing v5 migration in `FeedStore.migrate()`

```swift
migrator.registerMigration("v6_library_tree") { db in
    try db.create(table: "library_node") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("parent_id", .integer).references("library_node", onDelete: .cascade)
        t.column("name", .text).notNull()
        t.column("sort_order", .integer).notNull().defaults(to: 0)
        t.column("origin", .text).notNull().defaults(to: "bundled")
        t.column("enabled", .integer).notNull().defaults(to: 1)
    }

    try db.create(table: "library_source") { t in
        t.column("node_id", .integer).notNull()
            .references("library_node", onDelete: .cascade)
        t.column("source_url", .text).notNull()
        t.primaryKey(["node_id", "source_url"])
    }

    try db.create(index: "idx_library_parent", on: "library_node", columns: ["parent_id"])
    try db.create(index: "idx_library_source_node", on: "library_source", columns: ["node_id"])

    try db.create(table: "channel") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("name", .text).notNull()
        t.column("sort_order", .integer).notNull().defaults(to: 0)
    }

    try db.create(table: "channel_node") { t in
        t.column("channel_id", .integer).notNull()
            .references("channel", onDelete: .cascade)
        t.column("node_id", .integer).notNull()
            .references("library_node", onDelete: .cascade)
        t.primaryKey(["channel_id", "node_id"])
    }

    // Migrate existing source_toggle state
    let toggles = try Row.fetchAll(db, sql: "SELECT key, state FROM source_toggle")
    for row in toggles {
        let key: String = row["key"]
        let state: Int = row["state"]
        // state 0 = disabled. Only migrate disabled entries — enabled is default.
        guard state == 0 else { continue }
        // Find or create node for this toggle key.
        // Region keys: "region:brazil" → node name "brazil"
        // Category keys: "cat:tech" → node name "tech"
        // URL keys: "url:https://..." → find in library_source
        if key.hasPrefix("url:") {
            let url = String(key.dropFirst(4))
            // Disable at source level: find the node containing this URL
            if let nodeId = try Int64.fetchOne(db, sql:
                "SELECT node_id FROM library_source WHERE source_url = ? LIMIT 1",
                arguments: [url]
            ) {
                try db.execute(sql: "UPDATE library_node SET enabled = 0 WHERE id = ?",
                              arguments: [nodeId])
            }
        } else if key.hasPrefix("region:") || key.hasPrefix("cat:") {
            let name = String(key.dropFirst(key.firstIndex(of: ":")!.utf16Offset(in: key) + 1))
            // Disable the node matching this name
            try db.execute(sql: "UPDATE library_node SET enabled = 0 WHERE name = ?",
                          arguments: [name])
        }
    }
}
```

- [ ] Verify migration runs: delete app from simulator, build and run, check SQLite file for new tables

- [ ] Commit

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "feat: add v6 migration for library tree and channels"
```

### Task 4: Seed library tree from OPML

**Files:**
- Modify: `feedmine/Services/FeedStore.swift` (add seeding method)
- Modify: `feedmine/Services/OPMLParser.swift` (set origin on sources)

**Interfaces:**
- Consumes: `OPMLParser.parseAll()` from existing code
- Consumes: `LibraryNodeRecord`, `LibrarySourceRecord` from Task 2
- Produces: `FeedStore.seedLibrary()` method

- [ ] Add `seedLibrary()` method to `FeedStore`

```swift
func seedLibrary() async {
    // Already seeded? Check if root node exists.
    let hasRoot: Bool = (try? await db.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_node WHERE parent_id IS NULL") ?? 0
    } > 0) ?? false
    guard !hasRoot else { return }

    let result = await OPMLParser.parseAll()
    guard !result.sources.isEmpty else { return }

    do {
        try await db.write { db in
            // Create root
            try db.execute(sql: """
                INSERT INTO library_node (id, parent_id, name, sort_order, origin, enabled)
                VALUES (1, NULL, 'Feedmine', 0, 'bundled', 1)
            """)

            var nodeId: Int64 = 2
            var regionNodeIds: [String: Int64] = [:]     // region path → node id
            var categoryNodeIds: [String: Int64] = [:]    // category name → node id

            // Group sources by region
            let byRegion = Dictionary(grouping: result.sources, by: \.region)

            // Sort regions for deterministic ordering
            let sortedRegions = byRegion.keys.sorted()

            for region in sortedRegions {
                guard let sources = byRegion[region] else { continue }

                // Determine parent node based on region path
                let parentId: Int64
                let nodeName: String

                if region == "global" {
                    // Global feeds go under English General
                    if categoryNodeIds["__english_general__"] == nil {
                        try db.execute(sql: """
                            INSERT INTO library_node (id, parent_id, name, sort_order, origin, enabled)
                            VALUES (?, 1, 'English General', 1, 'bundled', 1)
                        """, arguments: [nodeId])
                        categoryNodeIds["__english_general__"] = nodeId
                        nodeId += 1
                    }
                    parentId = categoryNodeIds["__english_general__"]!
                } else if region.hasPrefix("countries/") {
                    let parts = region.split(separator: "/").map(String.init)
                    // parts[0] = "countries", parts[1] = country slug, parts[2...] = optional sub-region

                    // Ensure "International" node exists
                    if categoryNodeIds["__international__"] == nil {
                        try db.execute(sql: """
                            INSERT INTO library_node (id, parent_id, name, sort_order, origin, enabled)
                            VALUES (?, 1, 'International', 2, 'bundled', 1)
                        """, arguments: [nodeId])
                        categoryNodeIds["__international__"] = nodeId
                        nodeId += 1
                    }

                    // Ensure country node exists
                    let country = parts[1]
                    let countryPath = "countries/\(country)"
                    if regionNodeIds[countryPath] == nil {
                        let countryName = CountryStore.countryName(for: country)
                        try db.execute(sql: """
                            INSERT INTO library_node (id, parent_id, name, sort_order, origin, enabled)
                            VALUES (?, ?, ?, ?, 'bundled', 1)
                        """, arguments: [nodeId, categoryNodeIds["__international__"]!, countryName, nodeId])
                        regionNodeIds[countryPath] = nodeId
                        nodeId += 1
                    }

                    if parts.count >= 3 {
                        // Sub-region: create node under country
                        let regionPath = region
                        if regionNodeIds[regionPath] == nil {
                            let regionName = parts[2...].joined(separator: " ").capitalized
                            try db.execute(sql: """
                                INSERT INTO library_node (id, parent_id, name, sort_order, origin, enabled)
                                VALUES (?, ?, ?, ?, 'bundled', 1)
                            """, arguments: [nodeId, regionNodeIds[countryPath]!, regionName, nodeId])
                            regionNodeIds[regionPath] = nodeId
                            nodeId += 1
                        }
                        parentId = regionNodeIds[regionPath]!
                    } else {
                        parentId = regionNodeIds[countryPath]!
                    }
                } else {
                    // Unknown region pattern — put under root
                    parentId = 1
                }

                // Group sources by category and create category nodes
                let byCategory = Dictionary(grouping: sources, by: \.category)
                for (category, categorySources) in byCategory.sorted(by: { $0.key < $1.key }) {
                    let catKey = "\(parentId)_\(category)"
                    if categoryNodeIds[catKey] == nil {
                        try db.execute(sql: """
                            INSERT INTO library_node (id, parent_id, name, sort_order, origin, enabled)
                            VALUES (?, ?, ?, ?, 'bundled', 1)
                        """, arguments: [nodeId, parentId, category, nodeId])
                        categoryNodeIds[catKey] = nodeId
                        nodeId += 1
                    }

                    let catNodeId = categoryNodeIds[catKey]!
                    for source in categorySources {
                        try db.execute(sql: """
                            INSERT OR IGNORE INTO library_source (node_id, source_url)
                            VALUES (?, ?)
                        """, arguments: [catNodeId, source.url])
                    }
                }
            }
        }
    } catch {
        print("[FeedStore] seedLibrary error: \(error)")
    }
}
```

- [ ] Update `OPMLParser.parseAll()` — sources already created without origin. Since `FeedSource.origin` defaults to `.bundled`, no change needed for the parse path. Import path (`parseImportedFile`) needs explicit `.imported`.

```swift
// In OPMLParser.parseImportedFile, update the delegate result assignment:
static func parseImportedFile(url: URL) throws -> [FeedSource] {
    let data = try Data(contentsOf: url)
    let parser = XMLParser(data: data)
    let fileName = url.deletingPathExtension().lastPathComponent
    let delegate = OPMLDelegate(fallbackCategory: fileName.capitalized)
    parser.delegate = delegate
    parser.parse()
    if let error = parser.parserError { throw error }
    // Tag all imported sources
    return delegate.sources.map { source in
        FeedSource(title: source.title, url: source.url, category: source.category,
                   region: "imported", mediaKind: source.mediaKind, origin: .imported)
    }
}
```

- [ ] Call `seedLibrary()` in `FeedStore.start()` after `loadFromOPML()` and before `restoreFilters()`

- [ ] Build, run, verify: check that library_node and library_source tables are populated after first launch

- [ ] Commit

```bash
git add feedmine/Services/FeedStore.swift feedmine/Services/OPMLParser.swift
git commit -m "feat: seed library tree from OPML on first launch"
```

### Task 5: Create FeedDetector actor

**Files:**
- Create: `feedmine/Services/FeedDetector.swift`

**Interfaces:**
- Produces: `FeedDetector` actor with `detect(url:) async -> DetectionResult`
- Produces: `DetectionResult` enum: `.feed(FeedSource)`, `.multipleFeeds([FeedSource])`, `.opml([FeedSource])`, `.noFeedFound`, `.error(String)`

- [ ] Create `feedmine/Services/FeedDetector.swift`

```swift
import Foundation

actor FeedDetector {
    enum DetectionResult {
        case feed(FeedSource)
        case multipleFeeds([FeedSource])
        case opml([FeedSource])
        case noFeedFound
        case error(String)
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "FeedminePrototype/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/json, text/html, text/xml"
        ]
        self.session = URLSession(configuration: config)
    }

    func detect(url: URL) async -> DetectionResult {
        // Step 1: HEAD to check Content-Type
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"

        let headResult: (status: Int, contentType: String?)
        do {
            let (_, response) = try await session.data(for: headRequest)
            let http = response as? HTTPURLResponse
            headResult = (http?.statusCode ?? 0, http?.allHeaderFields["Content-Type"] as? String)
        } catch {
            return .error("Could not reach server")
        }

        let ct = headResult.contentType?.lowercased() ?? ""

        // Direct feed detection
        if ct.contains("application/rss+xml") || ct.contains("application/atom+xml") || ct.contains("application/feed+json") {
            return makeFeedResult(url: url)
        }

        // OPML detection
        if ct.contains("text/x-opml") || url.pathExtension == "opml" {
            return await detectOPML(url: url)
        }

        // HTML — autodiscover
        if ct.contains("text/html") || headResult.status == 200 {
            return await detectFromHTML(url: url)
        }

        // Fallback: try GET and inspect
        return await detectFromHTML(url: url)
    }

    // MARK: - Private

    private func makeFeedResult(url: URL) -> DetectionResult {
        let title = url.host ?? url.absoluteString
        let source = FeedSource(
            title: title, url: url.absoluteString,
            category: "Imported", region: "imported",
            mediaKind: .text, origin: .user
        )
        return .feed(source)
    }

    private func detectOPML(url: URL) async -> DetectionResult {
        do {
            let sources = try OPMLParser.parseImportedFile(url: url)
            guard !sources.isEmpty else { return .noFeedFound }
            return .opml(sources)
        } catch {
            return .error("Could not parse OPML file")
        }
    }

    private func detectFromHTML(url: URL) async -> DetectionResult {
        guard let html = await fetchHTML(url: url) else {
            return .error("Could not load page")
        }

        // Parse <link rel="alternate"> tags
        let feedLinks = parseFeedLinks(from: html, baseURL: url)

        if !feedLinks.isEmpty {
            let sources = feedLinks.map { link in
                FeedSource(
                    title: link.title ?? url.host ?? "Feed",
                    url: link.url.absoluteString,
                    category: "Imported", region: "imported",
                    mediaKind: .text, origin: .user
                )
            }

            if sources.count == 1 {
                return .feed(sources[0])
            } else {
                return .multipleFeeds(sources)
            }
        }

        // Path probes
        let probes = ["/feed/", "/rss/", "/rss.xml", "/feed.xml",
                      "/atom.xml", "/index.xml", "/feeds/posts/default"]
        var foundURLs: [URL] = []

        for path in probes {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            components.path = path
            guard let probeURL = components.url else { continue }
            if await checkURL(probeURL) {
                foundURLs.append(probeURL)
            }
        }

        if foundURLs.isEmpty {
            return .noFeedFound
        }

        let sources = foundURLs.map { feedURL in
            FeedSource(
                title: feedURL.host ?? url.host ?? "Feed",
                url: feedURL.absoluteString,
                category: "Imported", region: "imported",
                mediaKind: .text, origin: .user
            )
        }

        return sources.count == 1 ? .feed(sources[0]) : .multipleFeeds(sources)
    }

    private func fetchHTML(url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, _) = try await session.data(for: request)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func checkURL(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private struct FeedLink {
        let url: URL
        let title: String?
    }

    private func parseFeedLinks(from html: String, baseURL: URL) -> [FeedLink] {
        // Simple regex-based extraction of <link rel="alternate"> tags
        let pattern = #"<link[^>]*rel=["']alternate["'][^>]*type=["']application\/(rss|atom)\+xml["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)

        return matches.compactMap { match in
            guard let matchRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[matchRange])

            // Extract href
            guard let hrefMatch = try? NSRegularExpression(
                pattern: #"href=["']([^"']+)["']"#,
                options: .caseInsensitive
            ).firstMatch(in: tag, options: [], range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
                  let hrefRange = Range(hrefMatch.range(at: 1), in: tag) else {
                return nil
            }

            let href = String(tag[hrefRange])
            guard let resolvedURL = URL(string: href, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }

            // Extract optional title
            let title: String?
            if let titleMatch = try? NSRegularExpression(
                pattern: #"title=["']([^"']+)["']"#,
                options: .caseInsensitive
            ).firstMatch(in: tag, options: [], range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
               let titleRange = Range(titleMatch.range(at: 1), in: tag) {
                title = String(tag[titleRange])
            } else {
                title = nil
            }

            return FeedLink(url: resolvedURL, title: title)
        }
    }
}
```

- [ ] Build and verify

- [ ] Commit

```bash
git add feedmine/Services/FeedDetector.swift
git commit -m "feat: add FeedDetector actor for URL-based feed discovery"
```

### Task 6: Wire FeedDetector into onOpenURL

**Files:**
- Modify: `feedmine/feedmineApp.swift`
- Modify: `feedmine/Services/FeedLoader.swift` (add `handleIncomingURL` method)

**Interfaces:**
- Consumes: `FeedDetector.detect(url:)` from Task 5
- Produces: `FeedLoader.detectedResult: DetectionResult?` published state for sheet

- [ ] Update `feedmineApp.swift` to handle incoming URLs

```swift
import SwiftUI

@main
struct FeedmineApp: App {
    @State private var loader = FeedLoader()
    @State private var localeManager = LocaleManager.shared
    @State private var incomingURL: URL?

    var body: some Scene {
        WindowGroup {
            FeedScreen(incomingURL: $incomingURL)
                .environment(loader)
                .environment(localeManager)
                .onOpenURL { url in
                    incomingURL = url
                }
        }
    }
}
```

- [ ] Update `FeedScreen` to accept incoming URL binding. Add to `FeedScreen` struct:

```swift
@Binding var incomingURL: URL?
@State private var showShareResult = false
```

- [ ] Add `.onChange(of: incomingURL)` handler in `FeedScreen`:

```swift
.onChange(of: incomingURL) { _, url in
    guard let url else { return }
    showShareResult = true
    Task {
        await loader.detectIncomingURL(url)
    }
}
```

- [ ] Add sheet for `ShareResultView`:

```swift
.sheet(isPresented: $showShareResult) {
    ShareResultView()
        .environment(loader)
}
```

- [ ] Add `FeedLoader.detectIncomingURL()`:

```swift
private let detector = FeedDetector()

var detectedResult: FeedDetector.DetectionResult?
var isDetecting = false

func detectIncomingURL(_ url: URL) async {
    isDetecting = true
    detectedResult = nil
    detectedResult = await detector.detect(url: url)
    isDetecting = false
}
```

- [ ] Build and verify

- [ ] Commit

```bash
git add feedmine/feedmineApp.swift feedmine/Views/FeedScreen.swift feedmine/Services/FeedLoader.swift
git commit -m "feat: wire FeedDetector into onOpenURL flow"
```

---

## Phase 2 — Logic Replacement

### Task 7: Replace SourceRegistry toggle with library tree queries

**Files:**
- Modify: `feedmine/Services/SourceRegistry.swift`
- Modify: `feedmine/Services/FeedStore.swift`

- [ ] Add computed property to `SourceRegistry` that reads active source URLs from library CTE instead of in-memory sets:

```swift
// In FeedStore, replace registry.enabledSources with a library-backed version
var enabledSourceURLs: [String] {
    (try? db.read { db in try LibraryNodeRecord.activeSourceURLs(db) }) ?? []
}
```

- [ ] Add `SourceRegistry.isSourceEnabled()` override that checks library_source + library_node.enabled:

```swift
func isSourceEnabled(_ url: String) -> Bool {
    // First check library tree
    if let db = database {
        let enabled: Bool = (try? db.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT ln.enabled FROM library_node ln
                JOIN library_source ls ON ln.id = ls.node_id
                WHERE ls.source_url = ?
                LIMIT 1
            """, arguments: [url]) ?? false
        }) ?? false
        return enabled
    }
    // Fallback to existing logic during transition
    return !disabled.contains(Self.sourceKey(url))
}
```

- [ ] Keep both systems running in parallel during Phase 2. Add assertion/logging to detect discrepancies.

- [ ] Build and verify — existing toggles should work via both systems

- [ ] Commit

### Task 8: Add Channel support to FeedStore

**Files:**
- Modify: `feedmine/Services/FeedStore.swift`
- Modify: `feedmine/Services/FeedLoader.swift`

- [ ] Add `FeedStore.selectedChannelID: Int64?` property

- [ ] Add `FeedStore.channels: [Channel]` array, loaded on start

- [ ] Add `FeedStore.activeChannelSourceURLs: [String]` computed property that either returns all active sources or the channel's subset:

```swift
var activeChannelSourceURLs: [String] {
    if let channelID = selectedChannelID {
        return (try? db.read { db in
            try ChannelNodeRecord.sourceURLs(for: channelID, db)
        }) ?? []
    }
    // "All" — return all enabled source URLs
    return (try? db.read { db in
        try LibraryNodeRecord.activeSourceURLs(db)
    }) ?? []
}
```

- [ ] Load channels on `FeedStore.start()`:

```swift
func loadChannels() async {
    do {
        let records = try await db.read { db in
            try ChannelRecord.order(Column("sort_order")).fetchAll(db)
        }
        channels = records.map { $0.toChannel() }
    } catch {
        channels = []
    }
}
```

- [ ] Expose through `FeedLoader`:

```swift
var channels: [Channel] { store.channels }
var selectedChannelID: Int64? {
    get { store.selectedChannelID }
    set { store.selectedChannelID = newValue }
}

func selectChannel(_ id: Int64?) {
    store.selectedChannelID = id
    store.applyUpdate(.flush())
}
```

- [ ] Build and verify

- [ ] Commit

### Task 9: Update SourceScheduler for flat source list

**Files:**
- Modify: `feedmine/Services/SourceScheduler.swift`

- [ ] Change `nextBatch()` signature to accept `[FeedSource]` instead of region/category params:

```swift
func nextBatch(
    reservoir: [FeedItem],
    enabledSources: [FeedSource],
    activeContentType: String? = nil
) -> [FeedSource] {
    // Use enabledSources directly instead of filtering from sourcesByRegion
    // ...
}
```

- [ ] Simplify scoring: remove region deficits (sources are pre-filtered by caller). Keep category deficits, time factor, contentTypeBoost, and failure backoff.

- [ ] Build and verify

- [ ] Commit

---

## Phase 3 — UI

### Task 10: Create LibraryTreeView shared component

**Files:**
- Create: `feedmine/Views/LibraryTreeView.swift`

- [ ] Create a single `LibraryTreeView` component usable in two modes: `.navigation` (full browser) and `.selection` (destination picker). Use a recursive SwiftUI view with `DisclosureGroup`.

```swift
enum LibraryTreeMode {
    case navigation
    case selection(selectedNodeID: Binding<Int64?>)
}

struct LibraryTreeView: View {
    let mode: LibraryTreeMode
    let nodes: [LibraryNode]
    let childNodes: (Int64) -> [LibraryNode]
    let sourceCount: (Int64) -> Int

    var body: some View {
        ForEach(nodes) { node in
            if hasChildren(node) {
                DisclosureGroup { ... } label: { nodeRow(node) }
            } else {
                nodeRow(node)
            }
        }
    }
}
```

- [ ] Node row: SF Symbol chevron + name + source count + toggle (checkmark.circle.fill). In `.selection` mode, tapping selects the node with circadian accent highlight.

- [ ] Build and verify

- [ ] Commit

### Task 11: Create ShareResultView

**Files:**
- Create: `feedmine/Views/ShareResultView.swift`

- [ ] Five states matching spec: Loading, Single feed, Multiple feeds, OPML pack, No feed found, Error.

- [ ] Loading: URL in SF Mono, thin ProgressView, phase text.

- [ ] Single: card with metadata, Preview button, Add to Library.

- [ ] Multiple: checkbox list, Select all/Deselect all, Add N feeds.

- [ ] OPML: summary card, disclosure groups, Import.

- [ ] Destination picker: recent nodes + Browse all → LibraryTreeView in `.selection` mode.

- [ ] Build and verify

- [ ] Commit

### Task 12: Create LibraryBrowser

**Files:**
- Create: `feedmine/Views/LibraryBrowser.swift`

- [ ] Breadcrumb navigation: top-level shows root nodes, deep levels push to new screen with tappable breadcrumb.

- [ ] Uses `LibraryTreeView(mode: .navigation)` for tree rendering.

- [ ] Search: toolbar button, filters in-memory, remembers expansion state.

- [ ] Edit mode: EditButton, drag reorder, swipe delete, "+" always visible.

- [ ] Build and verify

- [ ] Commit

### Task 13: Create ExportHub

**Files:**
- Create: `feedmine/Views/ExportHub.swift`

- [ ] Two sections: Data formats (OPML, CSV, JSON) and Document formats (HTML, PDF).

- [ ] OPML: segmented control "All / Mine", ShareLink.

- [ ] JSON: Export + Import buttons. Import uses `.fileImporter`.

- [ ] HTML/PDF: generate → preview sheet → ShareLink.

- [ ] Post-export toast using existing toast pattern from FeedScreen.

- [ ] Build and verify

- [ ] Commit

### Task 14: Update FeedScreen header with Channel picker

**Files:**
- Modify: `feedmine/Views/FeedScreen.swift`

- [ ] Add Channel picker button next to existing filter button in `compactHeader`. Shows current channel name or "All". Tapping opens a menu listing user channels.

- [ ] Add link to ExportHub in Settings.

### Task 15: Remove old screens

**Files:**
- Remove: `feedmine/Views/CountriesListScreen.swift`
- Remove: `feedmine/Views/CountryDetailScreen.swift`
- Remove: `feedmine/Views/RegionDetailScreen.swift`
- Simplify: `feedmine/Views/FilterSheetView.swift` (remove category/region sections)
- Simplify: `feedmine/Views/SourceManagementView.swift` (remove category/source toggles, keep OPML import/export)

- [ ] Remove import references in other files that reference removed views

- [ ] Build and verify

- [ ] Commit

---

## Verification Checklist

**After Phase 1:**
- [ ] App launches with v6 migration creating new tables
- [ ] `library_node` populated with Feedmine tree structure
- [ ] `library_source` has entries for all bundled feeds
- [ ] `FeedDetector.detect(url:)` correctly identifies feed URLs, OPML files, and HTML pages
- [ ] `onOpenURL` triggers detection flow

**After Phase 2:**
- [ ] Toggling a library node disables/enables its sources in the feed
- [ ] Disabling a parent hides all descendant sources from the feed
- [ ] Channel selection filters sources correctly
- [ ] SourceScheduler works with flat source list
- [ ] Existing functionality (bookmarks, read state, podcast player) unaffected

**After Phase 3:**
- [ ] Share from Safari → Feedmine opens ShareResultView
- [ ] ShareResultView correctly handles all five result states
- [ ] LibraryBrowser navigates tree, toggles work, search works
- [ ] ExportHub generates and shares all five formats
- [ ] Old screens removed without broken references
- [ ] Full build succeeds
