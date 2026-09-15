import CryptoKit
import Foundation
import Observation

/// Builds and maintains the feed taxonomy tree from `FeedSource` records.
///
/// The tree is derived from the OPML file structure (directories + <outline> nesting).
/// Each feed belongs to exactly one leaf node (single-home). Multi-label semantics
/// are achieved via filter union — selecting multiple nodes shows all feeds in their subtrees.
///
/// Performance:
/// - Build: O(n) single pass, <500ms cold, <50ms warm (disk cache)
/// - Search: O(n) over flatIndex, 300ms debounce in UI layer
/// - Lookup: O(1) via flatIndex dictionary
/// - Memory: ~128 bytes per node → <2MB for 10K nodes
@MainActor
@Observable
final class TaxonomyStore {

    struct CoverageGroup: Sendable {
        let id: String
        let feedURLs: Set<String>
    }

    // MARK: - Shared singleton

    static let shared = TaxonomyStore()

    // MARK: - State

    private(set) var root: TaxonomyNode?
    private(set) var flatIndex: [String: TaxonomyNode] = [:]

    /// O(1) node lookup by ID.
    func node(id: String) -> TaxonomyNode? { flatIndex[id] }
    private var feedToNodeID: [String: String] = [:]  // normalizedURL → leaf node ID

    /// parentID → [childID] index, rebuilt during build(). Makes children(of:) O(1).
    private var childrenIndex: [String: [String]] = [:]
    @ObservationIgnored private var sortedChildrenCache: [String: [TaxonomyNode]] = [:]

    /// Reverse index: nodeID → all feed URLs in that node's subtree.
    /// Built once during build(from:) and used by feedURLs(inSubtreesOf:)
    /// for O(selectedNodes) lookups instead of O(allFeeds × selectedNodes).
    private var nodeToFeedURLs: [String: Set<String>] = [:]
    @ObservationIgnored private(set) var coverageGroups: [CoverageGroup] = []

    var selectedNodeIDs: Set<String> = []

    /// Monotonic counter for interleaved build() calls. Each call captures a
    /// generation at start and only applies its result if no newer build has
    /// begun since — so builds apply in call order, not task-completion order.
    @ObservationIgnored private var buildGeneration: UInt64 = 0

    // MARK: - Persistence

    nonisolated private static let cacheURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("taxonomy_cache.json")
    }()
    nonisolated private static let cacheSchemaVersion = 3

    // MARK: - Tree Building

    /// Snapshot of a finished taxonomy build. Computed entirely off the
    /// main actor by `computeTaxonomy`, then assigned to the singleton in
    /// one main-actor transaction.
    private struct BuiltTaxonomy: Sendable {
        let root: TaxonomyNode
        let flatIndex: [String: TaxonomyNode]
        let feedToNodeID: [String: String]
        let childrenIndex: [String: [String]]
        let nodeToFeedURLs: [String: Set<String>]
        let coverageGroups: [CoverageGroup]
    }

    /// Build the taxonomy tree from all feed sources.
    /// Single pass, O(n). Caches result to disk for warm starts.
    ///
    /// The tree build is a pure function of the source list, so the heavy
    /// computation (500ms–1.5s for ~240 sources / 10K nodes) runs in a
    /// detached task instead of blocking the main actor. Only the final
    /// assignment of the rebuilt indexes touches the shared singleton, and
    /// that happens on the main actor. Cache persistence (JSON-encoding
    /// ~10K nodes) also runs off main.
    func build(
        from sources: [FeedSource],
        sharedCountrySourceURLs: Set<String> = []
    ) async {
        // Capture a generation. build() is main-actor isolated, so this bump
        // is atomic relative to any other build() call — but the await below
        // releases the main actor, letting a newer build start (and finish)
        // first. The generation guard makes the stale build's apply a no-op.
        let gen = buildGeneration + 1
        buildGeneration = gen

        let built = await Task.detached(priority: .userInitiated) {
            Self.computeTaxonomy(
                from: sources,
                sharedCountrySourceURLs: sharedCountrySourceURLs
            )
        }.value

        // Apply on the main actor — only the final assignment of the
        // rebuilt indexes touches shared state.
        guard buildGeneration == gen else { return }

        feedToNodeID = built.feedToNodeID
        childrenIndex = built.childrenIndex
        sortedChildrenCache.removeAll()
        nodeToFeedURLs = built.nodeToFeedURLs
        flatIndex = built.flatIndex
        // A rebuild can finish while a topic is being chosen. Keep the
        // *current* selection (including any made during the build window),
        // dropping only IDs that no longer exist in the refreshed catalogue.
        selectedNodeIDs = selectedNodeIDs.filter { built.flatIndex[$0] != nil }
        root = built.root
        coverageGroups = built.coverageGroups

        // Persist off main — encoding ~10K nodes is expensive too.
        Task.detached(priority: .background) {
            Self.persistCache(
                root: built.root,
                flatIndex: built.flatIndex,
                feedToNodeID: built.feedToNodeID,
                sources: sources,
                sharedCountrySourceURLs: sharedCountrySourceURLs
            )
        }
    }

    /// Pure computation of the taxonomy tree. No shared instance state —
    /// safe to run off the main actor.
    nonisolated private static func computeTaxonomy(
        from sources: [FeedSource],
        sharedCountrySourceURLs: Set<String>
    ) -> BuiltTaxonomy {
        let countryRegionsByURL = sources.reduce(into: [String: Set<String>]()) { result, source in
            let regionParts = source.region.split(separator: "/", omittingEmptySubsequences: true)
            guard regionParts.count >= 2, regionParts[0] == "countries" else { return }
            let countryRegion = "\(regionParts[0])/\(regionParts[1])"
            result[OPMLParser.normalizeURL(source.url), default: []].insert(countryRegion)
        }
        let sharedAcrossCountries = sharedCountrySourceURLs.union(
            Set(countryRegionsByURL.compactMap { url, regions in
            regions.count > 1 ? url : nil
            })
        )

        // Intermediate: path segments → children
        var tree: [String: (node: TaxonomyNode, childIDs: Set<String>)] = [:]
        var rootChildren: Set<String> = []
        var feedToNodeID: [String: String] = [:]
        var nodeToFeedURLs: [String: Set<String>] = [:]

        // Ensure virtual root exists
        let rootNode = TaxonomyNode.root(feedCount: 0, childrenCount: 0)
        tree[rootNode.id] = (rootNode, [])

        for source in sources {
            // A globally syndicated feed can appear in many country OPMLs.
            // It must not be presented as local content for any one country.
            if source.region.hasPrefix("countries/")
                && sharedAcrossCountries.contains(OPMLParser.normalizeURL(source.url)) {
                continue
            }

            // Derive path: region + category → node ID segments
            let segments = derivePath(from: source)
            var parentID = TaxonomyNode.rootID

            for (depth, segment) in segments.enumerated() {
                let nodeID: String
                if parentID == TaxonomyNode.rootID {
                    nodeID = segment.slug
                } else {
                    nodeID = "\(parentID)/\(segment.slug)"
                }

                if tree[nodeID] == nil {
                    let node = TaxonomyNode(
                        id: nodeID,
                        name: segment.name,
                        parentId: parentID,
                        childrenCount: 0,
                        feedCount: 0,
                        language: segment.language,
                        level: depth + 1,
                        kind: segment.kind
                    )
                    tree[nodeID] = (node, [])
                    tree[parentID]?.childIDs.insert(nodeID)
                    if parentID == TaxonomyNode.rootID {
                        rootChildren.insert(nodeID)
                    }
                }

                parentID = nodeID
            }

            // Map feed URL → leaf node
            let normalizedURL = OPMLParser.normalizeURL(source.url)
            feedToNodeID[normalizedURL] = parentID
            // Populate reverse index: leaf node accumulates direct feed URLs
            nodeToFeedURLs[parentID, default: []].insert(normalizedURL)
        }

        // Pre-compute direct feed counts: single O(M) pass over feedToNodeID,
        // then O(N) bottom-up aggregation for subtree totals. True O(N+M).
        var nodeFeedCounts: [String: Int] = [:]
        for (_, nodeID) in feedToNodeID {
            nodeFeedCounts[nodeID, default: 0] += 1
        }

        // Bottom-up feedCount computation — sort by descending level so
        // leaves are processed before parents
        let sortedIDs = tree.keys.sorted {
            (tree[$0]?.node.level ?? 0) > (tree[$1]?.node.level ?? 0)
        }
        for nodeID in sortedIDs {
            guard let entry = tree[nodeID] else { continue }
            // Direct feeds at this node (O(1) dictionary lookup)
            let directFeeds = nodeFeedCounts[nodeID] ?? 0
            // Child feedCounts are already computed (children have higher level)
            let childTotal = entry.childIDs.reduce(0) {
                $0 + (tree[$1]?.node.feedCount ?? 0)
            }
            // Propagate child URLs up to parent: parent's URL set = union of children's sets
            // plus its own direct URLs (already populated in the main loop)
            for childID in entry.childIDs {
                if let childURLs = nodeToFeedURLs[childID] {
                    nodeToFeedURLs[nodeID, default: []].formUnion(childURLs)
                }
            }
            let total = directFeeds + childTotal
            tree[nodeID] = (TaxonomyNode(
                id: entry.node.id, name: entry.node.name, parentId: entry.node.parentId,
                childrenCount: entry.childIDs.count, feedCount: total,
                language: entry.node.language, level: entry.node.level, kind: entry.node.kind
            ), entry.childIDs)
        }

        // Update root
        let totalFeeds = tree[TaxonomyNode.rootID]?.childIDs.reduce(0) {
            tree[$1]?.node.feedCount ?? 0
        } ?? 0
        tree[TaxonomyNode.rootID] = (
            TaxonomyNode.root(feedCount: totalFeeds, childrenCount: rootChildren.count),
            rootChildren
        )

        // Build flat index
        let flatIndex = Dictionary(uniqueKeysWithValues: tree.map { ($0.key, $0.value.node) })

        // Numeric folder prefixes are the editorial menu order.
        let topChildren = rootChildren
            .compactMap { flatIndex[$0] }
            .sorted(by: Self.editorialNodeOrder)
        let rootWithChildren = TaxonomyNode(
            id: rootNode.id, name: rootNode.name, parentId: nil,
            childrenCount: topChildren.count, feedCount: totalFeeds,
            language: nil, level: 0, kind: .topic
        )

        // Build children index for O(1) lookups
        var childrenIndex: [String: [String]] = [:]
        for (nodeID, node) in flatIndex {
            guard let parentID = node.parentId else { continue }
            childrenIndex[parentID, default: []].append(nodeID)
        }

        // Leaf-only coverage groups for the "All feeds in this topic" UI.
        let coverageGroups = flatIndex.values.compactMap { node -> CoverageGroup? in
            guard node.id != TaxonomyNode.rootID,
                  node.childrenCount == 0,
                  node.feedCount > 0,
                  let urls = nodeToFeedURLs[node.id],
                  !urls.isEmpty else { return nil }
            return CoverageGroup(id: node.id, feedURLs: urls)
        }.sorted { $0.id < $1.id }

        return BuiltTaxonomy(
            root: rootWithChildren,
            flatIndex: flatIndex,
            feedToNodeID: feedToNodeID,
            childrenIndex: childrenIndex,
            nodeToFeedURLs: nodeToFeedURLs,
            coverageGroups: coverageGroups
        )
    }

    // MARK: - Path derivation

    private struct PathSegment {
        let slug: String
        let name: String
        let language: String?
        let kind: NodeKind
    }

    nonisolated private static func derivePath(from source: FeedSource) -> [PathSegment] {
        var segments: [PathSegment] = []
        let region = source.region

        if region.hasPrefix("topic/") {
            // Topic subdirectory: encode the folder hierarchy as taxonomy nodes,
            // then append the category as leaf.  "topic/Sports" → Sports → category
            let parts = region.components(separatedBy: "/")
            // parts[0] = "topic", parts[1...] = directory path
            for (idx, part) in parts.enumerated() where idx >= 1 {
                let kind: NodeKind = idx == 1 ? .topic : .subcategory
                let displayName = Self.orderedDisplayName(part)
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
                segments.append(PathSegment(
                    slug: part.lowercased(), name: displayName,
                    language: source.language, kind: kind
                ))
            }
            // Append the category itself as the leaf subcategory, BUT skip
            // when it would duplicate the last directory segment (e.g. a file
            // "acoustics.opml" inside an "Acoustics/" directory would produce
            // "Acoustics → Acoustics" — the directory IS the category).
            let subSlug = source.category
                .lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
            if segments.last?.slug != subSlug {
                segments.append(PathSegment(
                    slug: subSlug, name: source.category,
                    language: source.language, kind: .subcategory
                ))
            }
        } else if region == "global" {
            // Flat global feeds (no parent directory) — add "global" virtual node
            segments.append(PathSegment(
                slug: "global", name: "Global",
                language: nil, kind: .topic
            ))
            let slug = source.category
                .lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
            segments.append(PathSegment(
                slug: slug, name: source.category,
                language: source.language, kind: .subcategory
            ))
        } else if region.hasPrefix("countries/") {
            // Countries path: countries → country → (sub-region?) → subcategory
            // Always starts with "countries" virtual node
            if segments.isEmpty || segments.last?.slug != "countries" {
                segments.append(PathSegment(
                    slug: "countries", name: "Countries",
                    language: nil, kind: .topic
                ))
            }

            let parts = region.components(separatedBy: "/")
            // parts[0] = "countries", parts[1] = country, parts[2+] = sub-region
            for (idx, part) in parts.enumerated() where idx >= 1 {
                let kind: NodeKind = idx == 1 ? .country : .region
                let displayName = part
                    .replacingOccurrences(of: "-", with: " ")
                    .capitalized
                segments.append(PathSegment(
                    slug: part, name: displayName,
                    language: source.language, kind: kind
                ))
            }

            // Append subcategory
            let subSlug = source.category
                .lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
            segments.append(PathSegment(
                slug: subSlug, name: source.category,
                language: source.language, kind: .subcategory
            ))
        } else if region == "imported" {
            segments.append(PathSegment(
                slug: "imported", name: "Imported",
                language: source.language, kind: .topic
            ))
            let subSlug = source.category
                .lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: " ", with: "_")
            segments.append(PathSegment(
                slug: subSlug, name: source.category,
                language: source.language, kind: .subcategory
            ))
        }

        return segments
    }

    // MARK: - Queries

    /// Direct children of a node, sorted by name.
    func children(of nodeID: String) -> [TaxonomyNode] {
        if let cached = sortedChildrenCache[nodeID] { return cached }
        guard let childIDs = childrenIndex[nodeID] else { return [] }
        let children = childIDs
            .compactMap { flatIndex[$0] }
            .sorted(by: Self.editorialNodeOrder)
        sortedChildrenCache[nodeID] = children
        return children
    }

    nonisolated private static func editorialNodeOrder(_ lhs: TaxonomyNode, _ rhs: TaxonomyNode) -> Bool {
        let lhsOrder = ordinal(in: lhs.id.components(separatedBy: "/").last ?? lhs.id)
        let rhsOrder = ordinal(in: rhs.id.components(separatedBy: "/").last ?? rhs.id)
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    nonisolated private static func ordinal(in raw: String) -> Int {
        let prefix = raw.prefix { $0.isNumber }
        guard !prefix.isEmpty, let value = Int(prefix) else { return Int.max }
        return value
    }

    nonisolated private static func orderedDisplayName(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"^\d+[ _-]+"#,
            with: "",
            options: .regularExpression
        )
    }

    func hasChildren(_ nodeID: String) -> Bool {
        !(childrenIndex[nodeID]?.isEmpty ?? true)
    }

    /// All ancestors from root to the given node (inclusive).
    func ancestors(of nodeID: String) -> [TaxonomyNode] {
        var result: [TaxonomyNode] = []
        var current: String? = nodeID
        while let id = current, let node = flatIndex[id] {
            result.append(node)
            current = node.parentId
        }
        return result.reversed()
    }

    /// Leaf node ID for a feed URL.
    func nodeID(for feedURL: String) -> String? {
        feedToNodeID[OPMLParser.normalizeURL(feedURL)]
    }

    /// Whether a feed's leaf node is in the subtree of the given node ID.
    func isFeedInSubtree(feedURL: String, nodeID: String) -> Bool {
        guard let leafID = feedToNodeID[OPMLParser.normalizeURL(feedURL)] else { return false }
        if leafID == nodeID { return true }
        return leafID.hasPrefix(nodeID + "/")
    }

    /// All feed URLs whose leaf node falls within the subtree of any of the given node IDs.
    /// Uses a pre-computed reverse index (nodeID → Set<feedURL>) for O(selectedNodes)
    /// instead of scanning all 276K+ feedToNodeID entries.
    func feedURLs(inSubtreesOf nodeIDs: Set<String>) -> Set<String> {
        guard !nodeIDs.isEmpty else { return [] }
        var result: Set<String> = []
        for nodeID in nodeIDs {
            if let urls = nodeToFeedURLs[nodeID] {
                result.formUnion(urls)
            }
        }
        return result
    }

    private func rebuildCoverageGroups() {
        coverageGroups = flatIndex.values.compactMap { node in
            guard node.id != TaxonomyNode.rootID,
                  node.childrenCount == 0,
                  node.feedCount > 0,
                  let urls = nodeToFeedURLs[node.id],
                  !urls.isEmpty else { return nil }
            return CoverageGroup(id: node.id, feedURLs: urls)
        }.sorted { $0.id < $1.id }
    }

    /// Search flat index by name. Case-insensitive. Returns up to 50 results.
    ///
    /// Names are not unique: a topic such as "Mythology & Folklore" can also
    /// exist below many countries. Rank the global editorial taxonomy first so
    /// choosing the first visible result is deterministic and useful, while
    /// keeping geographic variants available with their breadcrumb in the UI.
    func search(_ query: String) -> [TaxonomyNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return Array(flatIndex.values
            .filter { $0.id != TaxonomyNode.rootID && $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { lhs, rhs in
                let lhsRank = Self.searchRank(lhs, query: q)
                let rhsRank = Self.searchRank(rhs, query: q)
                if lhsRank != rhsRank { return lhsRank.lexicographicallyPrecedes(rhsRank) }

                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
            .prefix(50))
    }

    private static func searchRank(_ node: TaxonomyNode, query: String) -> [Int] {
        let exactMatch = node.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        let topLevelID = node.id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? node.id
        let scope: Int
        switch topLevelID {
        case "countries": scope = 2
        case "languages": scope = 3
        case "imported": scope = 4
        default: scope = 0
        }
        return [exactMatch ? 0 : 1, scope, node.level, -node.feedCount]
    }

    // MARK: - Selection

    func select(_ nodeID: String) {
        selectedNodeIDs.insert(nodeID)
    }

    func deselect(_ nodeID: String) {
        selectedNodeIDs.remove(nodeID)
    }

    func toggle(_ nodeID: String) {
        if selectedNodeIDs.contains(nodeID) {
            deselect(nodeID)
        } else {
            select(nodeID)
        }
    }

    func clearSelection() {
        selectedNodeIDs.removeAll()
    }

    var hasSelection: Bool { !selectedNodeIDs.isEmpty }

    /// Resolved node names for display in chip bar, sorted by depth then name.
    var selectedNodeNames: [String] {
        selectedNodeIDs.compactMap { flatIndex[$0]?.name }.sorted()
    }

    // MARK: - Fingerprint

    /// Stable fingerprint of the source set — all taxonomy-relevant fields,
    /// normalized, sorted, SHA-256. The pre-deduplication cross-country URL
    /// signal is included too, so the cache invalidates on any edit that
    /// affects country membership in the taxonomy tree.
    nonisolated static func sourceFingerprint(
        for sources: [FeedSource],
        sharedCountrySourceURLs: Set<String> = []
    ) -> String {
        let records = sources.map { source in
            [
                OPMLParser.normalizeURL(source.url),
                source.category,
                source.region,
                FeedStore.normalizedLanguageCode(source.language) ?? "",
                source.mediaKind.rawValue
            ].joined(separator: "\u{1F}")  // unit separator — cannot appear in any field
        }
        .sorted()
        .joined(separator: "\n")
        let sharedRecords = sharedCountrySourceURLs.sorted().joined(separator: "\n")

        let digest = SHA256.hash(data: Data("\(records)\n--shared-country-urls--\n\(sharedRecords)".utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cache

    /// Invalidate disk cache — call when OPML manifest changes.
    func invalidateCache() {
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    /// Try to load from disk cache. Returns true if cache was valid.
    /// Validates both sourceCount (fast pre-check) and sourceFingerprint
    /// (guards against equal-count URL swaps). Rejects old caches without
    /// a fingerprint so stale data never survives an upgrade.
    func loadFromCache(
        sources: [FeedSource],
        sharedCountrySourceURLs: Set<String> = []
    ) -> Bool {
        let count = sources.count
        let fingerprint = Self.sourceFingerprint(
            for: sources,
            sharedCountrySourceURLs: sharedCountrySourceURLs
        )
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cached = try? JSONDecoder().decode(CachedTree.self, from: data) else {
            return false
        }
        guard cached.schemaVersion == Self.cacheSchemaVersion else { return false }
        // Fast pre-check — count mismatch is a cheap rejection
        guard cached.sourceCount == count else { return false }
        // Reject old caches that predate fingerprint persistence
        guard let cachedFingerprint = cached.sourceFingerprint else { return false }
        // Content-level validation — same count, different URLs
        guard cachedFingerprint == fingerprint else { return false }

        self.flatIndex = cached.flatIndex
        self.feedToNodeID = cached.feedToNodeID
        // Rebuild children index from restored flatIndex
        self.childrenIndex.removeAll()
        self.sortedChildrenCache.removeAll()
        for (nodeID, node) in self.flatIndex {
            guard let parentID = node.parentId else { continue }
            self.childrenIndex[parentID, default: []].append(nodeID)
        }
        // Rebuild reverse index (nodeToFeedURLs) from restored feedToNodeID.
        // Must replicate the bottom-up propagation from build() so that
        // feedURLs(inSubtreesOf:) works correctly on the warm-cache path.
        self.nodeToFeedURLs.removeAll()
        for (feedURL, nodeID) in self.feedToNodeID {
            self.nodeToFeedURLs[nodeID, default: []].insert(feedURL)
        }
        // Bottom-up: propagate child URLs to parents, sorted by descending level
        let sortedIDs = self.flatIndex.keys.sorted {
            (self.flatIndex[$0]?.level ?? 0) > (self.flatIndex[$1]?.level ?? 0)
        }
        for nodeID in sortedIDs {
            guard let childIDs = self.childrenIndex[nodeID] else { continue }
            for childID in childIDs {
                if let childURLs = self.nodeToFeedURLs[childID] {
                    self.nodeToFeedURLs[nodeID, default: []].formUnion(childURLs)
                }
            }
        }
        rebuildCoverageGroups()
        self.root = cached.root
        return true
    }

    /// Persist a finished build to disk. Pure function of the build
    /// snapshot — runs off the main actor so JSON-encoding ~10K nodes
    /// never blocks first paint.
    nonisolated private static func persistCache(
        root: TaxonomyNode?,
        flatIndex: [String: TaxonomyNode],
        feedToNodeID: [String: String],
        sources: [FeedSource],
        sharedCountrySourceURLs: Set<String>
    ) {
        let fingerprint = Self.sourceFingerprint(
            for: sources,
            sharedCountrySourceURLs: sharedCountrySourceURLs
        )
        let cached = CachedTree(
            schemaVersion: Self.cacheSchemaVersion,
            root: root,
            flatIndex: flatIndex,
            feedToNodeID: feedToNodeID,
            sourceCount: sources.count,
            sourceFingerprint: fingerprint
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}

// MARK: - Cache DTO

private struct CachedTree: Codable {
    let schemaVersion: Int
    let root: TaxonomyNode?
    let flatIndex: [String: TaxonomyNode]
    let feedToNodeID: [String: String]
    let sourceCount: Int
    /// SHA-256 fingerprint of normalized, sorted source URLs.
    /// `nil` for caches written before this field existed — rejected on load.
    let sourceFingerprint: String?
}
