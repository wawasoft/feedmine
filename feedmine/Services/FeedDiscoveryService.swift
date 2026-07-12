import Foundation

/// Discovers RSS/Atom feed URLs from websites.
/// Strategy (in priority order):
/// 1. Known popular domains → instant, no network
/// 2. HTML <link rel="alternate"> meta tags → standards-compliant
/// 3. Anchor tag heuristics → last resort fallback
struct FeedDiscoveryService: Sendable {

    // MARK: - Known feeds (no network required)

    /// Popular domains with known RSS feed URLs. Checked before any network request.
    /// Extensible — add entries as new popular sites are identified.
    static let knownFeeds: [String: [PendingItem.DiscoveredFeed]] = [
        "nytimes.com": [
            PendingItem.DiscoveredFeed(title: "NYT Home", url: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"),
            PendingItem.DiscoveredFeed(title: "NYT Technology", url: "https://rss.nytimes.com/services/xml/rss/nyt/Technology.xml"),
            PendingItem.DiscoveredFeed(title: "NYT Science", url: "https://rss.nytimes.com/services/xml/rss/nyt/Science.xml"),
        ],
        "bbc.com": [
            PendingItem.DiscoveredFeed(title: "BBC News", url: "https://feeds.bbci.co.uk/news/rss.xml"),
        ],
        "wired.com": [
            PendingItem.DiscoveredFeed(title: "Wired", url: "https://www.wired.com/feed/rss"),
        ],
        "theverge.com": [
            PendingItem.DiscoveredFeed(title: "The Verge", url: "https://www.theverge.com/rss/index.xml"),
        ],
        "arstechnica.com": [
            PendingItem.DiscoveredFeed(title: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index"),
        ],
        "techcrunch.com": [
            PendingItem.DiscoveredFeed(title: "TechCrunch", url: "https://techcrunch.com/feed/"),
        ],
        "github.com": [
            PendingItem.DiscoveredFeed(title: "GitHub Blog", url: "https://github.blog/feed/"),
        ],
        "stackoverflow.blog": [
            PendingItem.DiscoveredFeed(title: "Stack Overflow Blog", url: "https://stackoverflow.blog/feed/"),
        ],
    ]

    // MARK: - Direct feed detection

    /// Detect whether a URL is already a direct RSS/Atom/JSON Feed URL.
    /// True → no HTML fetching needed; the URL itself is a feed endpoint.
    static func isDirectFeedURL(_ url: URL) -> Bool {
        let path = url.pathExtension.lowercased()
        if ["xml", "rss", "atom"].contains(path) { return true }
        let absolute = url.absoluteString.lowercased()
        if absolute.contains("youtube.com/feeds") { return true }
        if absolute.hasSuffix("/feed") || absolute.hasSuffix("/rss") { return true }
        // Known podcast hosts that follow RSS patterns
        if absolute.contains("anchor.fm") || absolute.contains("spreaker.com") { return true }
        if absolute.contains("feeds.simplecast.com") || absolute.contains("feeds.transistor.fm") { return true }
        if absolute.contains("feeds.buzzsprout.com") || absolute.contains("media.rss.com") { return true }
        return false
    }

    // MARK: - Discovery

    /// Discover RSS/Atom feeds from a website URL.
    ///
    /// Priority:
    /// 1. Check `knownFeeds` dictionary (instant, no network)
    /// 2. Fetch HTML with 3s timeout
    /// 3. Parse for `<link rel="alternate" type="application/rss+xml|atom+xml" href="...">`
    /// 4. Fallback: regex scan for anchor tags pointing to RSS-like URLs
    /// 5. Resolve relative URLs to absolute
    static func discover(url: URL) async throws -> [PendingItem.DiscoveredFeed] {
        // Step 1: Check known feeds
        if let host = url.host?.lowercased(),
           let known = knownFeeds.first(where: { host == $0.key || host.hasSuffix(".\($0.key)") }) {
            return known.value
        }

        // Step 2: Fetch HTML with tight timeout
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("Feedmine/1.0", forHTTPHeaderField: "User-Agent")
        // Prefer minimal HTML — some sites return full pages that waste bandwidth
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return []
        }
        guard let html = String(data: data, encoding: .utf8) else { return [] }

        // Step 3: Parse <link rel="alternate"> tags
        let linkFeeds = parseLinkTags(html: html, baseURL: url)

        // Step 4: Fallback — scan for anchor tags with RSS-ish URLs
        if linkFeeds.isEmpty {
            return parseAnchorFeeds(html: html, baseURL: url)
        }

        return linkFeeds
    }

    // MARK: - HTML parsing

    /// Parse standard `<link rel="alternate" type="application/rss+xml|atom+xml">` tags.
    private static func parseLinkTags(html: String, baseURL: URL) -> [PendingItem.DiscoveredFeed] {
        var feeds: [PendingItem.DiscoveredFeed] = []

        // Regex to match <link ... rel="alternate" ... type="application/rss+xml|atom+xml" ... href="..." ...>
        let pattern = #/<link\s[^>]*\brel\s*=\s*["']alternate["'][^>]*\btype\s*=\s*["']application\/(?:rss|atom)\+xml["'][^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>/#

        // Simpler approach: extract link tags and check each
        let linkPattern = #/(?i)<link\s+([^>]+)\s*\/?>/#
        let matches = html.matches(of: linkPattern)
        for match in matches {
            let attrs = String(match.1)
            guard attrs.contains("alternate") else { continue }
            guard attrs.contains("rss+xml") || attrs.contains("atom+xml") else { continue }
            if let href = extractAttribute("href", from: attrs),
               let resolved = resolveURL(href, base: baseURL) {
                let title = extractAttribute("title", from: attrs) ?? "Feed"
                feeds.append(PendingItem.DiscoveredFeed(title: title, url: resolved.absoluteString))
            }
        }

        return feeds
    }

    /// Fallback: scan `<a href="...">` for URLs ending in common RSS patterns.
    private static func parseAnchorFeeds(html: String, baseURL: URL) -> [PendingItem.DiscoveredFeed] {
        var feeds: [PendingItem.DiscoveredFeed] = []
        var seen = Set<String>()

        let rssPatterns = ["/rss", "/feed", "/atom.xml", "/rss.xml", ".rss", ".xml", "/feeds/"]
        let anchorPattern = #/(?i)<a\s+[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a>/#

        let matches = html.matches(of: anchorPattern)
        for match in matches {
            let href = String(match.1)
            let text = String(match.2).stripHTML().trimmingCharacters(in: .whitespacesAndNewlines)

            let lower = href.lowercased()
            guard rssPatterns.contains(where: { lower.contains($0) }) else { continue }
            // Skip if text suggests it's not a feed link
            guard !lower.contains("comments") && !lower.contains("reply") else { continue }

            if let resolved = resolveURL(href, base: baseURL),
               !seen.contains(resolved.absoluteString) {
                seen.insert(resolved.absoluteString)
                feeds.append(PendingItem.DiscoveredFeed(
                    title: text.isEmpty ? (resolved.host ?? "Feed") : text,
                    url: resolved.absoluteString
                ))
            }
        }

        return feeds
    }

    // MARK: - Helpers

    /// Extract an attribute value from an HTML attribute string.
    private static func extractAttribute(_ name: String, from attrs: String) -> String? {
        // Match: name="value" or name='value'
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(attrs.startIndex..., in: attrs)
        guard let match = regex.firstMatch(in: attrs, range: range),
              let valueRange = Range(match.range(at: 1), in: attrs) else { return nil }
        return String(attrs[valueRange])
    }

    /// Resolve a potentially relative URL against a base URL.
    private static func resolveURL(_ href: String, base: URL) -> URL? {
        // Already absolute
        if let url = URL(string: href), url.scheme != nil { return url }
        // Relative — resolve against base
        return URL(string: href, relativeTo: base)?.absoluteURL
    }
}

// MARK: - String extension

private extension String {
    func stripHTML() -> String {
        guard let data = data(using: .utf8) else { return self }
        if let plain = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ).string {
            return plain
        }
        return self
    }
}
