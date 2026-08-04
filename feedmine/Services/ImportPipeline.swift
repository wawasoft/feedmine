import Foundation

// MARK: - Import Models

/// Outcome of a single feed URL import attempt.
enum ImportItemStatus: Sendable {
    case imported            // New, validated, added
    case duplicate           // Already exists in registry
    case invalid(String)     // URL malformed or not a feed (reason)
    case unreachable         // Network timeout or non-2xx
}

/// Per-item result returned by the pipeline.
struct ImportItemResult: Sendable {
    let url: String
    let title: String?
    let status: ImportItemStatus
}

/// Aggregate result of an import operation.
struct ImportResult: Sendable {
    let items: [ImportItemResult]
    var importedCount: Int { items.filter { if case .imported = $0.status { return true }; return false }.count }
    var duplicateCount: Int { items.filter { if case .duplicate = $0.status { return true }; return false }.count }
    var invalidCount: Int { items.filter { if case .invalid = $0.status { return true }; return false }.count }
    var unreachableCount: Int { items.filter { if case .unreachable = $0.status { return true }; return false }.count }
}

// MARK: - Import Pipeline

/// Unified ingestion pipeline for feed sources.
/// Every import path (OPML file, pasted URL, remote URL, share sheet) feeds
/// through this single service, ensuring consistent dedup, validation,
/// classification, persistence, and feed reload.
///
/// Usage:
/// ```
/// let result = await pipeline.ingest(urls: ["https://example.com/feed.xml"])
/// let result = await pipeline.ingest(opmlData: data, fileName: "my_feeds")
/// let result = await pipeline.ingest(opmlURL: remoteURL)
/// ```
actor ImportPipeline {
    private let session: URLSession
    /// Injectable probe for testing. When set, bypasses real network requests.
    private let injectedProbe: (@Sendable (String) async -> ProbeResult)?

    init(probe: (@Sendable (String) async -> ProbeResult)? = nil) {
        self.injectedProbe = probe
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "FeedminePrototype/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/json, text/xml, */*"
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Import from raw feed URLs (pasted, share sheet, etc.)
    func ingest(
        urls: [String],
        category: String = "Imported",
        existingURLs: Set<String>
    ) async -> (result: ImportResult, sources: [FeedSource]) {
        var results: [ImportItemResult] = []
        var newSources: [FeedSource] = []

        // P0-01: Track both identity (for dedup) and request URL (for fetching).
        // Identity is the canonical normalized form; requestURL preserves auth
        // parameters, scheme, and www prefix needed for successful HTTP requests.
        var seenIdentities = existingURLs

        // Separate dedup/invalid URLs (no network needed) from probe candidates
        var toProbe: [(identity: String, requestURL: String, rawURL: String)] = []
        for rawURL in urls {
            let identity = OPMLParser.normalizeURL(rawURL)
            let request = OPMLParser.requestURL(rawURL)

            // Dedup check against both existing sources AND this batch
            if seenIdentities.contains(identity) {
                results.append(ImportItemResult(url: rawURL, title: nil, status: .duplicate))
                continue
            }
            seenIdentities.insert(identity)

            // Validate URL format on the request URL (what we'll actually fetch)
            guard URL(string: request) != nil else {
                results.append(ImportItemResult(url: rawURL, title: nil, status: .invalid("Malformed URL")))
                continue
            }

            toProbe.append((identity, request, rawURL))
        }

        // Probe feeds concurrently (max 5 at a time)
        let probeResults: [(rawURL: String, requestURL: String, probe: ProbeResult)] = await withTaskGroup(of: (String, String, ProbeResult).self) { group in
            var collected: [(String, String, ProbeResult)] = []
            var running = 0

            for item in toProbe {
                if running >= 5 {
                    if let result = await group.next() {
                        collected.append(result)
                        running -= 1
                    }
                }
                let request = item.requestURL
                let rawURL = item.rawURL
                group.addTask {
                    let probe = await self.probeFeed(url: request)
                    return (rawURL, request, probe)
                }
                running += 1
            }

            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (rawURL, requestURL, probe) in probeResults {
            switch probe {
            case .success(let title):
                let kind = Self.detectMediaKind(url: requestURL, title: title)
                let source = FeedSource(
                    title: title ?? Self.titleFromURL(requestURL),
                    url: requestURL,  // P0-01: store the fetchable URL
                    category: category,
                    region: "imported",
                    mediaKind: kind
                )
                newSources.append(source)
                results.append(ImportItemResult(url: rawURL, title: title, status: .imported))

            case .invalid(let reason):
                results.append(ImportItemResult(url: rawURL, title: nil, status: .invalid(reason)))

            case .unreachable:
                results.append(ImportItemResult(url: rawURL, title: nil, status: .unreachable))
            }
        }

        return (ImportResult(items: results), newSources)
    }

    /// Import from OPML file data (local file picker, AirDrop, etc.)
    func ingest(
        opmlData: Data,
        fileName: String,
        existingURLs: Set<String>,
        validate: Bool = true
    ) async -> (result: ImportResult, sources: [FeedSource]) {
        // Parse OPML
        let parser = XMLParser(data: opmlData)
        let delegate = OPMLImportDelegate(fallbackCategory: fileName.capitalized)
        parser.delegate = delegate
        // P2-13: Require successful parse. A partial parse (valid outlines
        // followed by malformed XML) would silently return partial sources.
        guard parser.parse(), parser.parserError == nil else {
            let error = parser.parserError?.localizedDescription ?? "malformed OPML"
            return (ImportResult(items: [
                ImportItemResult(url: fileName, title: nil, status: .invalid("OPML parse error: \(error)"))
            ]), [])
        }

        let parsedSources = delegate.sources

        if !validate {
            // Fast path: skip network probes, but still enforce basic syntax
            // validation (URL format, scheme, host, non-empty). Without these
            // checks a malformed OPML can inject garbage URLs into the registry.
            var results: [ImportItemResult] = []
            var newSources: [FeedSource] = []
            var seen = existingURLs
            for source in parsedSources {
                // P0-01: identity for dedup uses normalizeURL; storage uses
                // requestURL to preserve any authorization/signed parameters.
                let identity = OPMLParser.normalizeURL(source.url)
                let fetchURL = OPMLParser.requestURL(source.url)
                // Basic syntax checks on the fetch URL
                guard !fetchURL.isEmpty,
                      let parsed = URL(string: fetchURL),
                      let scheme = parsed.scheme?.lowercased(),
                      ["http", "https"].contains(scheme),
                      parsed.host != nil else {
                    results.append(ImportItemResult(url: source.url, title: source.title,
                                                    status: .invalid("Invalid or unsupported URL")))
                    continue
                }
                if seen.contains(identity) {
                    Log.import_.info("Dropped duplicate URL in OPML: \(identity)")
                    results.append(ImportItemResult(url: source.url, title: source.title, status: .duplicate))
                } else {
                    seen.insert(identity)
                    let kind = Self.detectMediaKind(url: fetchURL, title: source.title)
                    let corrected = FeedSource(
                        title: source.title,
                        url: fetchURL,  // P0-01: store the fetchable URL
                        category: source.category,
                        region: "imported",
                        mediaKind: kind
                    )
                    newSources.append(corrected)
                    results.append(ImportItemResult(url: source.url, title: source.title, status: .imported))
                }
            }
            return (ImportResult(items: results), newSources)
        }

        // With validation: probe each feed
        // P0-01: Deduplicate by identity (normalizeURL), preserve original
        // OPML metadata keyed by identity for title/category restoration.
        var dedupedRequestURLs: [String] = []
        var results: [ImportItemResult] = []
        var seenIdentities = existingURLs
        var metadataByIdentity: [String: (title: String, category: String)] = [:]
        for source in parsedSources {
            let identity = OPMLParser.normalizeURL(source.url)
            guard seenIdentities.insert(identity).inserted else {
                results.append(ImportItemResult(url: source.url, title: source.title, status: .duplicate))
                continue
            }
            let request = OPMLParser.requestURL(source.url)
            dedupedRequestURLs.append(request)
            // Keep first occurrence's metadata when duplicates exist
            if metadataByIdentity[identity] == nil {
                metadataByIdentity[identity] = (source.title, source.category)
            }
        }
        let (probeResult, sources) = await ingest(
            urls: dedupedRequestURLs,
            category: fileName.capitalized,
            existingURLs: existingURLs
        )
        // Merge duplicate results from local dedup with probe results
        let mergedItems = results + probeResult.items
        // Restore original OPML titles/categories where available, keyed by identity
        let corrected = sources.map { source -> FeedSource in
            let identity = OPMLParser.normalizeURL(source.url)
            guard let original = metadataByIdentity[identity] else { return source }
            return FeedSource(
                title: original.title.isEmpty ? source.title : original.title,
                url: source.url,
                category: original.category.isEmpty ? source.category : original.category,
                region: "imported",
                mediaKind: source.mediaKind
            )
        }
        return (ImportResult(items: mergedItems), corrected)
    }

    /// Import from a remote OPML URL (fetch then parse)
    func ingest(
        opmlURL: URL,
        existingURLs: Set<String>,
        validate: Bool = true
    ) async -> (result: ImportResult, sources: [FeedSource])? {
        do {
            let (data, response) = try await session.data(from: opmlURL)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return (ImportResult(items: [
                    ImportItemResult(url: opmlURL.absoluteString, title: nil, status: .unreachable)
                ]), [])
            }
            // P1-12: Reject oversized remote OPML before parsing.
            guard data.count <= Self.opmlImportMaxBytes else {
                return (ImportResult(items: [
                    ImportItemResult(url: opmlURL.absoluteString, title: nil,
                        status: .invalid("OPML too large (\(data.count) bytes)"))
                ]), [])
            }
            let fileName = opmlURL.deletingPathExtension().lastPathComponent
            return await ingest(opmlData: data, fileName: fileName, existingURLs: existingURLs, validate: validate)
        } catch {
            return (ImportResult(items: [
                ImportItemResult(url: opmlURL.absoluteString, title: nil, status: .unreachable)
            ]), [])
        }
    }

    // MARK: - Media Kind Detection

    /// Detect media kind from URL patterns and title hints.
    static func detectMediaKind(url: String, title: String?) -> MediaKind {
        let lower = url.lowercased()

        // YouTube feeds
        if lower.contains("youtube.com/feeds") || lower.contains("youtube.com/channel") {
            return .video
        }

        // Podcast indicators in URL
        let podcastPatterns = ["/podcast", "/episodes", "/audio", "anchor.fm", "feeds.buzzsprout",
                               "feeds.simplecast", "feeds.megaphone", "rss.art19", "feeds.transistor",
                               "feeds.acast", "feeds.libsyn", "pinecast.com", "omny.fm",
                               "podcasts.apple.com", "podbean.com/feed"]
        if podcastPatterns.contains(where: { lower.contains($0) }) {
            return .audio
        }

        // Title-based hints
        if let t = title?.lowercased() {
            if t.contains("podcast") || t.contains("episode") { return .audio }
            if t.contains("youtube") || t.contains("video") { return .video }
        }

        return .text
    }

    /// Derive a display title from a feed URL when no title is available.
    static func titleFromURL(_ url: String) -> String {
        guard let parsed = URL(string: url),
              let host = parsed.host else { return url }
        // Strip www. and common TLDs for readability
        var name = host
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "feeds.", with: "")
            .replacingOccurrences(of: "rss.", with: "")
        // Capitalize first letter
        if let first = name.first {
            name = String(first).uppercased() + name.dropFirst()
        }
        return name
    }

    // MARK: - Feed Probe

    enum ProbeResult: Sendable {
        case success(title: String?)
        case invalid(String)
        case unreachable
    }

    /// P1-12: Per-resource byte ceilings for user-controlled downloads.
    private static let feedProbeMaxBytes = 64_000       // feed validation probe
    private static let opmlImportMaxBytes = 10_000_000  // remote OPML import

    /// Fetch a URL and verify it contains a parseable RSS/Atom/JSON feed.
    /// Returns the feed title if found.
    private func probeFeed(url: String) async -> ProbeResult {
        if let injected = injectedProbe { return await injected(url) }
        guard let feedURL = URL(string: url) else { return .invalid("Malformed URL") }

        do {
            let (data, response) = try await session.data(from: feedURL)
            guard let http = response as? HTTPURLResponse else { return .unreachable }

            guard (200...299).contains(http.statusCode) else {
                return .unreachable
            }

            // P1-12: Reject responses larger than the probe ceiling before
            // inspecting content — prevents memory spikes from oversized
            // responses to user-supplied URLs.
            guard data.count <= Self.feedProbeMaxBytes else {
                return .invalid("Feed response too large (\(data.count) bytes)")
            }

            guard data.looksLikeFeedData else {
                // Check content-type header
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.contains("html") {
                    return .invalid("HTML page, not a feed")
                }
                return .invalid("Unrecognized format")
            }

            // Extract title from feed
            let isJSON = data.first == 0x7B  // '{'
            let title = Self.extractTitle(from: data, isJSON: isJSON)
            return .success(title: title)
        } catch {
            return .unreachable
        }
    }

    /// Quick title extraction without full feed parse.
    private static func extractTitle(from data: Data, isJSON: Bool) -> String? {
        if isJSON {
            // JSON Feed: {"title": "..."}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = json["title"] as? String {
                return title
            }
            return nil
        }
        // XML: <title>...</title> — grab the first one
        let str = String(data: data.prefix(2000), encoding: .utf8) ?? ""
        if let range = str.range(of: "<title>"),
           let end = str[range.upperBound...].range(of: "</title>") {
            let title = String(str[range.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip CDATA wrapper
            if title.hasPrefix("<![CDATA[") && title.hasSuffix("]]>") {
                return String(title.dropFirst(9).dropLast(3))
            }
            return title.isEmpty ? nil : title
        }
        return nil
    }
}

// MARK: - Minimal OPML Parser for Import (actor-safe)

private final class OPMLImportDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    let fallbackCategory: String
    var sources: [FeedSource] = []
    private var categoryStack: [String] = []
    private var outlinePushStack: [Bool] = []

    init(fallbackCategory: String) {
        self.fallbackCategory = fallbackCategory
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        guard element == "outline" else { return }
        if let xmlUrl = attributes["xmlUrl"] ?? attributes["xmlurl"] {
            // Leaf node (feed): use current category from stack, don't push
            let title = attributes["title"] ?? attributes["text"] ?? ""
            let category = categoryStack.last ?? fallbackCategory
            sources.append(FeedSource(title: title, url: xmlUrl, category: category, region: "imported"))
            outlinePushStack.append(false)
        } else {
            // Group node: push category onto stack
            let groupName = attributes["text"] ?? attributes["title"] ?? fallbackCategory
            categoryStack.append(groupName)
            outlinePushStack.append(true)
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard element == "outline" else { return }
        let didPushCategory = outlinePushStack.popLast() ?? false
        if didPushCategory, !categoryStack.isEmpty {
            categoryStack.removeLast()
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        categoryStack.removeAll()
        outlinePushStack.removeAll()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // P2-13: Clear everything — no partial sources from a broken parse.
        sources.removeAll()
        categoryStack.removeAll()
        outlinePushStack.removeAll()
    }
}

// MARK: - Shared Feed Detection

extension Data {
    /// True if the first 500 bytes look like an RSS, Atom, RDF, or JSON Feed.
    /// Shared by ``ImportPipeline`` and ``URLResolver`` to avoid duplicate
    /// feed-detection heuristics.
    var looksLikeFeedData: Bool {
        let prefix = String(prefix(500).compactMap { $0 < 128 ? Character(UnicodeScalar($0)) : nil })
        return prefix.contains("<rss") || prefix.contains("<feed") || prefix.contains("<RDF")
            || prefix.trimmingCharacters(in: .whitespaces).hasPrefix("{")
    }
}
