import Foundation

struct OPMLParser {
    // MARK: - Parse cache

    /// Bump when the parse LOGIC or FeedSource shape changes (region derivation,
    /// mediaKind classification, dedup/normalize) so caches produced by the old
    /// logic are ignored even within the same app build.
    private static let cacheFormatVersion = 10  // + shared catalog URL identity

    /// Codable envelope persisted to Caches/.
    private struct CachedParse: Codable {
        let fingerprint: String
        let sources: [FeedSource]
        let sharedCountrySourceURLs: [String]
        let fileCount: Int
        let failedFileCount: Int
        let invalidSourceCount: Int
        let duplicateSourceCount: Int
    }

    /// Cache key combining app version with the active local catalog revision.
    /// Managed updates are activated as complete snapshots, so the manifest
    /// revision is a constant-time and exact invalidation key.
    private static func cacheFingerprint(feedsURL: URL?) -> String {
        let info = Bundle.main.infoDictionary
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        // Bundled resources are immutable for an installed build. The mtime
        // remains useful for development builds that do not carry a manifest.
        let executableMtime = Bundle.main.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } ?? nil
        let feedsMtime = feedsURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } ?? nil
        let stamp = max(
            executableMtime?.timeIntervalSince1970 ?? 0,
            feedsMtime?.timeIntervalSince1970 ?? 0
        )
        let revision = CatalogRuntime.activeManifest()?.revision ?? 0
        return "\(cacheFormatVersion)-\(short)-\(build)-r\(revision)-mt\(Int64(stamp * 1000))"
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("opml-parse-cache.plist")
    }

    private static func loadCache(fingerprint: String) -> OPMLParseResult? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let cached = try? PropertyListDecoder().decode(CachedParse.self, from: data),
              cached.fingerprint == fingerprint else { return nil }
        return OPMLParseResult(
            sources: cached.sources,
            sharedCountrySourceURLs: Set(cached.sharedCountrySourceURLs),
            fileCount: cached.fileCount,
            failedFileCount: cached.failedFileCount,
            invalidSourceCount: cached.invalidSourceCount,
            duplicateSourceCount: cached.duplicateSourceCount
        )
    }

    private static func saveCache(_ result: OPMLParseResult, fingerprint: String) {
        guard let url = cacheURL else { return }
        let payload = CachedParse(
            fingerprint: fingerprint,
            sources: result.sources,
            sharedCountrySourceURLs: result.sharedCountrySourceURLs.sorted(),
            fileCount: result.fileCount,
            failedFileCount: result.failedFileCount,
            invalidSourceCount: result.invalidSourceCount,
            duplicateSourceCount: result.duplicateSourceCount
        )
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            // Surface a persistently failing cache write (full disk, bad
            // permissions) instead of silently re-parsing on every launch.
            Log.feed.error("Failed to write parse cache: \(error)")
        }
    }

    /// Scan the active local snapshot for all .opml files. The app bundle is
    /// the bootstrap/fallback snapshot; GitHub is never read by this parser.
    static func parseAll() async -> OPMLParseResult {
        let feedsURL = CatalogRuntime.activeFeedsURL()
        // Cache fast path after a constant-time bundle fingerprint.
        let endFingerprintMetric = FeedMetrics.beginInterval("OPML.fingerprint")
        let fingerprint = cacheFingerprint(feedsURL: feedsURL)
        endFingerprintMetric()

        let endCacheReadMetric = FeedMetrics.beginInterval("OPML.cacheRead")
        let cached = loadCache(fingerprint: fingerprint)
        endCacheReadMetric()
        if let cached {
            FeedMetrics.event("OPML.cacheHit")
            return cached
        }
        FeedMetrics.event("OPML.cacheMiss")

        // Cache miss: enumerate all bundled OPML files. Bundle.urls(...) does not
        // recurse, so we walk Feeds/ manually to reach Feeds/countries/{c}/… feeds.
        let endFullParseMetric = FeedMetrics.beginInterval("OPML.fullParse")
        defer { endFullParseMetric() }
        var opmlFiles: [URL] = []
        if let feedsURL,
           let enumerator = FileManager.default.enumerator(at: feedsURL, includingPropertiesForKeys: nil) {
            while let fileURL = enumerator.nextObject() as? URL {
                if fileURL.pathExtension == "opml" {
                    opmlFiles.append(fileURL)
                }
            }
        }

        // Sort files for a STABLE, deterministic parse order. Dedup keeps the
        // first occurrence of a duplicated feed URL, so ordering decides which
        // region/category owns it — that ownership must not change across
        // launches. (Randomizing fetch order, if wanted, belongs in the
        // scheduler, not here where it corrupts canonical source metadata.)
        opmlFiles.sort { $0.path < $1.path }

        guard !opmlFiles.isEmpty else {
            return OPMLParseResult(
                sources: [],
                sharedCountrySourceURLs: [],
                fileCount: 0,
                failedFileCount: 0,
                invalidSourceCount: 0,
                duplicateSourceCount: 0
            )
        }

        // Parse concurrently but BOUNDED to ~core count in flight. Each parseFile
        // does synchronous blocking I/O (Data(contentsOf:) + XMLParser); spawning
        // one task per file (~1900) would over-subscribe the cooperative thread
        // pool and open ~1900 descriptors at once. A sliding window keeps at most
        // `maxConcurrency` tasks live while still collating results by original
        // index, so dedup ownership stays byte-identical to a serial parse.
        // Honors cancellation: if the parent task is cancelled mid-parse we stop
        // adding work and do NOT cache the partial result.
        var perFile = [(sources: [FeedSource], invalids: Int, failed: Bool)?](
            repeating: nil, count: opmlFiles.count
        )
        let maxConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount)
        var wasCancelled = false
        await withTaskGroup(of: (index: Int, sources: [FeedSource], invalids: Int, failed: Bool).self) { group in
            var submitted = 0
            let seed = min(maxConcurrency, opmlFiles.count)
            while submitted < seed {
                let idx = submitted, url = opmlFiles[idx]
                group.addTask { Self.parseOne(idx, url) }
                submitted += 1
            }
            while let result = await group.next() {
                perFile[result.index] = (result.sources, result.invalids, result.failed)
                if Task.isCancelled {
                    wasCancelled = true
                    group.cancelAll()
                    break
                }
                if submitted < opmlFiles.count {
                    let idx = submitted, url = opmlFiles[idx]
                    group.addTask { Self.parseOne(idx, url) }
                    submitted += 1
                }
            }
        }

        // Flatten in the deterministic file-sorted order.
        var allSources: [FeedSource] = []
        var failedFileCount = 0
        var invalidSourceCount = 0
        for entry in perFile {
            guard let entry else { continue }
            allSources.append(contentsOf: entry.sources)
            invalidSourceCount += entry.invalids
            if entry.failed { failedFileCount += 1 }
        }

        let sharedCountrySourceURLs = sharedCountrySourceURLs(in: allSources)
        let deduped = deduplicateSources(allSources)
        let duplicateSourceCount = allSources.count - deduped.count

        let result = OPMLParseResult(
            sources: deduped,
            sharedCountrySourceURLs: sharedCountrySourceURLs,
            fileCount: opmlFiles.count,
            failedFileCount: failedFileCount,
            invalidSourceCount: invalidSourceCount,
            duplicateSourceCount: duplicateSourceCount
        )
        FeedMetrics.event(
            "OPML.parseCounts",
            "files=\(opmlFiles.count) sources=\(deduped.count) duplicates=\(duplicateSourceCount) invalid=\(invalidSourceCount)"
        )
        // Only cache a COMPLETE parse. A partial result from a transient file
        // failure or a cancellation must never be persisted, or it would be
        // served on every later launch until the app build changes.
        if failedFileCount == 0 && !wasCancelled {
            saveCache(result, fingerprint: fingerprint)
        }
        return result
    }

    /// Parse a single OPML file into sources, tagged with its derived region.
    /// Pure and Sendable — safe to run as a concurrent child task.
    private static func parseOne(_ index: Int, _ fileURL: URL) -> (index: Int, sources: [FeedSource], invalids: Int, failed: Bool) {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let region = region(for: fileURL, fileName: fileName)
        do {
            let kind = mediaKind(for: fileName)
            let (sources, invalids) = try parseFile(
                url: fileURL,
                fallbackCategory: fileName.capitalized,
                region: region,
                mediaKind: kind
            )
            return (index, sources, invalids, false)
        } catch {
            Log.feed.error("Failed to parse \(fileURL.lastPathComponent): \(error)")
            return (index, [], 0, true)
        }
    }

    // MARK: - Private

    /// Encode a file's region from its path/name:
    /// - "global" for root/category feeds (flat, no parent directory)
    /// - "countries/{country}" for a country-level feed (e.g. brazil.opml in brazil/)
    /// - "countries/{country}/{region}" for a sub-region feed (e.g. brazil-acre.opml)
    /// - "topic/{group}" for a feed in a topic subdirectory (e.g. Sports/soccer.opml)
    /// - "topic/{group}/{subgroup}" for nested topic subdirectories
    private static func region(for fileURL: URL, fileName: String) -> String {
        let components = fileURL.pathComponents
        // Check for countries/ first (existing behavior preserved)
        if let countriesIdx = components.lastIndex(where: { orderedPathName($0) == "countries" }),
           countriesIdx + 1 < components.count {
            let countryDir = components[countriesIdx + 1]
            if fileName == countryDir {
                return "countries/\(countryDir)"
            }
            if fileName.hasPrefix("\(countryDir)-") {
                let regionSlug = String(fileName.dropFirst(countryDir.count + 1))
                return "countries/\(countryDir)/\(regionSlug)"
            }
            return "countries/\(countryDir)"
        }
        // Check if file is inside a subdirectory of Feeds/ (excluding languages/)
        if let feedsIdx = components.lastIndex(of: "Feeds"),
           feedsIdx + 2 < components.count {
            let relative = Array(components[(feedsIdx + 1)...])
            // Skip languages/ — those are language variants of global topics
            if relative.first == "languages" { return "global" }
            // Skip countries/ (handled above)
            if relative.first == "countries" { return "global" }
            // Encode the directory path as a topic region
            if relative.count >= 2 {
                let dirPath = relative.dropLast().joined(separator: "/")
                return "topic/\(dirPath)"
            }
        }
        return "global"
    }

    /// Numeric path prefixes express editorial menu order and are not part of
    /// the semantic folder name (`90_countries` is the Countries branch).
    private static func orderedPathName(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"^\d+[ _-]+"#,
            with: "",
            options: .regularExpression
        )
    }

    /// Extract <language> from the OPML <head> section by scanning the raw XML.
    private static func extractLanguage(from data: Data) -> String? {
        // Quick scan — look for <language>en</language> in the first 2KB
        let head = String(data: data.prefix(2048), encoding: .utf8) ?? ""
        guard let range = head.range(of: "<language>"),
              let endRange = head.range(of: "</language>", range: range.upperBound..<head.endIndex) else {
            return nil
        }
        let lang = String(head[range.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lang.isEmpty ? nil : lang
    }

    private static func parseFile(url: URL, fallbackCategory: String, region: String, mediaKind: MediaKind = .text) throws -> (sources: [FeedSource], invalidCount: Int) {
        let data = try Data(contentsOf: url)
        let fileLanguage = extractLanguage(from: data)
        let parser = XMLParser(data: data)
        let delegate = OPMLDelegate(fallbackCategory: fallbackCategory, region: region, mediaKind: mediaKind,
                                    fileLanguage: fileLanguage)
        parser.delegate = delegate
        parser.parse()

        if let error = parser.parserError {
            throw error
        }

        return (delegate.sources, delegate.invalidSourceCount)
    }

    static func deduplicateSources(_ sources: [FeedSource]) -> [FeedSource] {
        var seen: Set<String> = []
        var result: [FeedSource] = []

        for source in sources {
            let key = normalizeURL(source.url)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(source)
        }

        return result
    }

    /// Finds feeds repeated in separate country catalogs before URL
    /// deduplication discards their original locations.
    static func sharedCountrySourceURLs(in sources: [FeedSource]) -> Set<String> {
        let countriesByURL = sources.reduce(into: [String: Set<String>]()) { result, source in
            let parts = source.region.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "countries" else { return }
            result[normalizeURL(source.url), default: []].insert("\(parts[0])/\(parts[1])")
        }
        return Set(countriesByURL.compactMap { url, countries in
            countries.count > 1 ? url : nil
        })
    }

    /// Derive the media kind from an OPML filename, so the scheduler can
    /// differentiate podcast/video/text sources at the collection level.
    static func mediaKind(for fileName: String) -> MediaKind {
        let lower = fileName.lowercased()
        if lower.contains("podcast") { return .audio }
        if lower.contains("youtube") { return .video }
        if lower.contains("reddit") || lower.contains("forum") { return .forum }
        return .text
    }

    /// Lowercase scheme and host only. Trim whitespace. Remove trailing slash. Preserve path/query case.
    /// Parse a single OPML file from any URL (for import)
    static func parseImportedFile(url: URL) throws -> [FeedSource] {
        let data = try Data(contentsOf: url)
        let fileLanguage = extractLanguage(from: data)
        let parser = XMLParser(data: data)
        let fileName = url.deletingPathExtension().lastPathComponent
        let delegate = OPMLDelegate(fallbackCategory: fileName.capitalized, fileLanguage: fileLanguage)
        parser.delegate = delegate
        parser.parse()
        if let error = parser.parserError { throw error }
        return delegate.sources
    }

    /// Export current sources as an OPML string
    static func exportOPML(sources: [FeedSource]) -> String {
        let grouped = Dictionary(grouping: sources, by: \.category)
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0">
          <head><title>Feedmine Export</title></head>
          <body>

        """
        for (category, feeds) in grouped.sorted(by: { $0.key < $1.key }) {
            xml += "    <outline text=\"\(xmlEscape(category))\">\n"
            for feed in feeds {
                xml += "      <outline title=\"\(xmlEscape(feed.title))\" xmlUrl=\"\(xmlEscape(feed.url))\" type=\"rss\"/>\n"
            }
            xml += "    </outline>\n"
        }
        xml += """
          </body>
        </opml>
        """
        return xml
    }

    /// Escape text for safe inclusion in an XML attribute value. `&` must be
    /// replaced first, or the entities produced by the later replacements would
    /// themselves be re-escaped. Without this, titles/URLs containing `"`, `&`,
    /// or `<` produce malformed OPML that fails to re-import.
    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Thread-safe cache for repeated normalization of the same URL strings.
    /// Called 30+ times across the codebase on a small working set of URLs.
    /// NSCache is inherently thread-safe; the annotation silences the Swift 6
    /// warning about the unannotated ObjC type.
    private static nonisolated(unsafe) let normalizedURLCache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 5000
        return c
    }()

    private static let identityQueryParameters = Set([
        "utm_source", "utm_medium", "utm_campaign", "utm_term",
        "utm_content", "ref", "source", "fbclid", "gclid",
        "mc_cid", "mc_eid", "ref_src", "temp_url_sig",
        "temp_url_expires", "expires", "cfid", "cftoken",
        "jsessionid", "phpsessid",
    ])

    /// OPML is XML, so only the five XML named entities plus numeric entities
    /// are portable. This deliberately mirrors scripts/catalog_identity.py
    /// instead of Foundation's broader, platform-dependent HTML decoding.
    private static func decodeURLXMLEntities(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            var decoded = value
                .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
                .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
                .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
                .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
                .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)

            while let range = decoded.range(
                of: #"&#(?:[0-9]+|[xX][0-9A-Fa-f]+);"#,
                options: .regularExpression
            ) {
                let entity = String(decoded[range])
                let payload = entity.dropFirst(2).dropLast()
                let radix: Int
                let digits: Substring
                if payload.first == "x" || payload.first == "X" {
                    radix = 16
                    digits = payload.dropFirst()
                } else {
                    radix = 10
                    digits = payload
                }
                guard let scalarValue = UInt32(digits, radix: radix),
                      scalarValue <= 0x10FFFF,
                      !(0xD800...0xDFFF).contains(scalarValue),
                      let scalar = UnicodeScalar(scalarValue) else {
                    // Leave invalid entities untouched and continue after it.
                    let suffix = decoded[range.upperBound...]
                    guard suffix.range(
                        of: #"&#(?:[0-9]+|[xX][0-9A-Fa-f]+);"#,
                        options: .regularExpression
                    ) != nil else { break }
                    // Invalid entities are exceptionally rare in URLs. Avoid
                    // an unbounded replacement loop by ending this pass.
                    break
                }
                decoded.replaceSubrange(range, with: String(scalar))
            }
            guard decoded != value else { break }
            value = decoded
        }
        return value
    }

    private static func normalizePercentEncoding(_ value: String, safe: CharacterSet) -> String {
        let scalars = Array(value.unicodeScalars)
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        var result = ""
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%", index + 2 < scalars.count,
               hexadecimal.contains(scalars[index + 1]),
               hexadecimal.contains(scalars[index + 2]) {
                result += "%"
                result += String(scalars[index + 1]).uppercased()
                result += String(scalars[index + 2]).uppercased()
                index += 3
                continue
            }
            if scalar.isASCII, safe.contains(scalar) {
                result.append(Character(String(scalar)))
            } else {
                for byte in String(scalar).utf8 {
                    result += String(format: "%%%02X", byte)
                }
            }
            index += 1
        }
        return result
    }

    private static var pathSafeCharacters: CharacterSet {
        CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" +
            "-._~!$&'()*+,;=/:@"
        )
    }

    private static var querySafeCharacters: CharacterSet {
        pathSafeCharacters.union(CharacterSet(charactersIn: "?"))
    }

    private static var userInfoSafeCharacters: CharacterSet {
        CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" +
            "-._~!$&'()*+,;=:"
        )
    }

    private static func hasValidPort(in raw: String) -> Bool {
        guard let schemeEnd = raw.range(of: "://")?.upperBound else { return false }
        let remainder = raw[schemeEnd...]
        let authorityEnd = remainder.firstIndex { "/?#".contains($0) } ?? raw.endIndex
        var authority = String(raw[schemeEnd..<authorityEnd])
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return false }
            let suffix = authority[authority.index(after: close)...]
            guard !suffix.isEmpty else { return true }
            guard suffix.first == ":" else { return false }
            return validPortDigits(suffix.dropFirst())
        }
        let colonCount = authority.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        if colonCount == 0 { return !authority.isEmpty }
        guard colonCount == 1, let colon = authority.lastIndex(of: ":") else { return false }
        return validPortDigits(authority[authority.index(after: colon)...])
    }

    private static func validPortDigits<S: StringProtocol>(_ digits: S) -> Bool {
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let port = Int(digits), (1...65535).contains(port) else { return false }
        return true
    }

    private static func encodedHost(_ rawHost: String, stripWWW: Bool) -> String? {
        var host = rawHost.lowercased()
        if host.contains(":") {
            return "[\(host)]"
        }
        if stripWWW, host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        var hostComponents = URLComponents()
        hostComponents.scheme = "https"
        hostComponents.host = host
        guard let encoded = hostComponents.string,
              encoded.hasPrefix("https://") else { return nil }
        return String(encoded.dropFirst("https://".count))
    }

    private static func filteredIdentityQuery(_ rawQuery: String?) -> String? {
        guard let rawQuery else { return nil }
        let retained = rawQuery.split(separator: "&", omittingEmptySubsequences: true).compactMap {
            segment -> String? in
            let rawName = String(segment.split(separator: "=", maxSplits: 1,
                                               omittingEmptySubsequences: false).first ?? "")
            let name = (rawName.removingPercentEncoding ?? rawName)
                .replacingOccurrences(of: "+", with: " ")
                .lowercased()
            guard !identityQueryParameters.contains(name), !name.hasPrefix("x-amz-") else {
                return nil
            }
            return normalizePercentEncoding(String(segment), safe: querySafeCharacters)
        }
        return retained.isEmpty ? nil : retained.joined(separator: "&")
    }

    private static func transformedURL(_ raw: String, identity: Bool) -> String {
        let decoded = decodeURLXMLEntities(raw)
        guard hasValidPort(in: decoded),
              let components = URLComponents(string: decoded),
              let originalScheme = components.scheme?.lowercased(),
              originalScheme == "http" || originalScheme == "https",
              let rawHost = components.host,
              let host = encodedHost(rawHost, stripWWW: identity) else {
            return decoded
        }
        if let port = components.port, !(1...65535).contains(port) {
            return decoded
        }

        var authority = ""
        if let user = components.percentEncodedUser {
            authority += normalizePercentEncoding(user, safe: userInfoSafeCharacters)
            if let password = components.percentEncodedPassword {
                authority += ":" + normalizePercentEncoding(password, safe: userInfoSafeCharacters)
            }
            authority += "@"
        }
        authority += host
        if let port = components.port { authority += ":\(port)" }

        var path = normalizePercentEncoding(components.percentEncodedPath, safe: pathSafeCharacters)
        if identity, path.hasSuffix("/") { path.removeLast() }
        let query: String?
        if identity {
            query = filteredIdentityQuery(components.percentEncodedQuery)
        } else if let rawQuery = components.percentEncodedQuery {
            query = normalizePercentEncoding(rawQuery, safe: querySafeCharacters)
        } else {
            query = nil
        }
        return "\(identity ? "https" : originalScheme)://\(authority)\(path)" +
            (query.map { "?\($0)" } ?? "")
    }

    static func normalizeURL(_ raw: String) -> String {
        // Fast path: cache hit
        if let cached = normalizedURLCache.object(forKey: raw as NSString) {
            return cached as String
        }
        let result = transformedURL(raw, identity: true)
        normalizedURLCache.setObject(result as NSString, forKey: raw as NSString)
        return result
    }

    /// URL used for HTTP requests. Unlike normalizeURL, this preserves signed
    /// and authorization parameters, the original scheme, www and trailing /
    /// while still repairing XML entities and invalid lone percent signs.
    static func requestURL(_ raw: String) -> String {
        transformedURL(raw, identity: false)
    }
}

// MARK: - XMLParser Delegate

private final class OPMLDelegate: NSObject, XMLParserDelegate {
    let fallbackCategory: String
    let region: String
    let mediaKind: MediaKind
    var sources: [FeedSource] = []
    var invalidSourceCount = 0

    private var categoryStack: [String] = []
    private var outlinePushStack: [Bool] = []  // tracks which opens pushed a category
    private var languageStack: [String?] = []
    private var fileLanguage: String?  // from <head><language>

    init(fallbackCategory: String, region: String = "global", mediaKind: MediaKind = .text,
         fileLanguage: String? = nil) {
        self.fallbackCategory = fallbackCategory
        self.region = region
        self.mediaKind = mediaKind
        self.fileLanguage = fileLanguage
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "outline" else { return }

        let xmlUrl = attributeDict["xmlUrl"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = attributeDict["title"] ?? attributeDict["text"] ?? ""

        let language = attributeDict["language"]

        if xmlUrl.isEmpty {
            // Category container — push onto stack, record that we pushed
            let category = attributeDict["title"] ?? attributeDict["text"]
            if let cat = category, !cat.isEmpty {
                categoryStack.append(cat)
                // Push language: outline attr → parent → file-level (all nil-safe)
                languageStack.append(language ?? languageStack.last ?? fileLanguage)
                outlinePushStack.append(true)
            } else {
                outlinePushStack.append(false)
            }
            return
        }

        // Feed source — did NOT push a category
        outlinePushStack.append(false)

        // Validate URL has scheme and host
        guard let components = URLComponents(string: xmlUrl),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            invalidSourceCount += 1
            return
        }

        let category = categoryStack.last ?? fallbackCategory
        // Per-source mediaKind override: file-level mediaKind is a hint,
        // but the URL is authoritative. YouTube feeds inside country OPMLs
        // were getting mediaKind=.text and losing their video boost.
        let resolvedKind: MediaKind = {
            if xmlUrl.contains("youtube.com/feeds") { return .video }
            if xmlUrl.contains("anchor.fm") || xmlUrl.contains("spreaker.com") || xmlUrl.contains("podcast") { return .audio }
            if xmlUrl.contains("reddit.com/r/") { return .forum }
            return mediaKind
        }()
        let rawLanguage = language ?? languageStack.last ?? fileLanguage
        let resolvedLanguage = rawLanguage == "und" ? nil : rawLanguage
        let tags = (attributeDict["category"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let defaultEnabled = attributeDict["feedmineDefaultEnabled"]?.lowercased() != "false"
        let qualityScore = attributeDict["feedmineQualityScore"].flatMap(Int.init)
        let explicitMediaKind = attributeDict["feedmineMediaKind"].flatMap(MediaKind.init(rawValue:))

        sources.append(
            FeedSource(
                title: title.isEmpty ? category : title,
                url: xmlUrl,
                category: category,
                region: region,
                mediaKind: explicitMediaKind ?? resolvedKind,
                language: resolvedLanguage,
                sourceDescription: attributeDict["description"],
                tags: tags,
                nature: attributeDict["feedmineNature"],
                activity: attributeDict["feedmineActivity"],
                qualityScore: qualityScore,
                defaultEnabled: defaultEnabled,
                contactEmail: attributeDict["feedmineContactEmail"],
                contactName: attributeDict["feedmineContactName"],
                contactSource: attributeDict["feedmineContactSource"],
                contactType: attributeDict["feedmineContactType"]
            )
        )
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "outline" else { return }

        let didPushCategory = outlinePushStack.popLast() ?? false
        if didPushCategory, !categoryStack.isEmpty {
            categoryStack.removeLast()
        }
        if didPushCategory, !languageStack.isEmpty {
            languageStack.removeLast()
        }
    }
}
