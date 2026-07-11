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
        // Match every <link> tag, then filter to feed-alternate links by testing
        // rel and type INDEPENDENTLY. HTML attribute order is arbitrary, so the
        // previous single regex — which demanded rel="alternate" *before*
        // type="application/rss+xml" — silently missed the very common markup
        // that lists type first (e.g. `<link type="application/rss+xml"
        // rel="alternate" href="...">`).
        guard let linkRegex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = linkRegex.matches(in: html, options: [], range: range)

        return matches.compactMap { match -> FeedLink? in
            guard let matchRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[matchRange])

            // Must be an alternate feed link: rel contains "alternate" AND type is
            // a known feed MIME (rss/atom XML or JSON Feed), in any order.
            let hasAlternate = tag.range(
                of: #"rel=["'][^"']*\balternate\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let hasFeedType = tag.range(
                of: #"type=["']application/(rss\+xml|atom\+xml|feed\+json)["']"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            guard hasAlternate, hasFeedType else { return nil }

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
