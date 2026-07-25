import Foundation

enum ContentSanitizer {
    enum Error: Swift.Error {
        case timeout
        case paywalled
        case notHTML
        case tooLarge
    }

    struct SanitizedContent {
        let html: String
        let imageURLs: [URL]
        let title: String?
        let textPreview: String
    }

    /// Download a web page and produce clean, readable HTML for offline storage.
    static func fetchAndSanitize(
        url: URL,
        maxBytes: Int = 2_000_000
    ) async throws -> SanitizedContent {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("text/html,application/xhtml+xml,*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.notHTML
        }

        // Check status code
        if httpResponse.statusCode == 403 || httpResponse.statusCode == 401 {
            throw Error.paywalled
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw Error.notHTML
        }

        // Check Content-Type
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("application/pdf") || contentType.contains("audio/") {
            throw Error.notHTML
        }

        let rawHTML = String(data: data.prefix(maxBytes), encoding: .utf8)
            ?? String(data: data.prefix(maxBytes), encoding: .isoLatin1)
            ?? ""

        // Extract title
        let title = extractTitle(from: rawHTML)

        // Extract visible text preview
        let preview = extractTextPreview(from: rawHTML)

        // Collect image URLs
        let imageURLs = extractImageURLs(from: rawHTML, baseURL: url)

        // Sanitize
        let cleanHTML = sanitize(rawHTML, baseURL: url)

        return SanitizedContent(
            html: cleanHTML,
            imageURLs: imageURLs,
            title: title,
            textPreview: preview
        )
    }

    // MARK: - Private helpers

    private static func extractTitle(from html: String) -> String? {
        let pattern = #"<title[^>]*>([^<]+)</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractTextPreview(from html: String) -> String {
        // Strip tags, collapse whitespace, take first 500 chars
        var text = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#[0-9]+;", with: " ", options: .regularExpression)
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return words.prefix(100).joined(separator: " ")
    }

    private static func extractImageURLs(from html: String, baseURL: URL) -> [URL] {
        let pattern = #"<img[^>]+src\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        return matches.compactMap { match -> URL? in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            var src = String(html[range])
            // Resolve relative URLs
            if src.hasPrefix("//") {
                src = "https:" + src
            } else if src.hasPrefix("/") {
                guard let scheme = baseURL.scheme, let host = baseURL.host else { return nil }
                src = scheme + "://" + host + src
            } else if !src.hasPrefix("http") {
                src = baseURL.deletingLastPathComponent().absoluteString + "/" + src
            }
            return URL(string: src)
        }
    }

    private static func sanitize(_ html: String, baseURL: URL) -> String {
        var clean = html

        // Remove unwanted elements
        let removals = [
            ("<script[^>]*>[\\s\\S]*?</script>", ""),          // scripts
            ("<style[^>]*>[\\s\\S]*?</style>", ""),            // styles
            ("<iframe[^>]*>[\\s\\S]*?</iframe>", ""),          // iframes
            ("<nav[^>]*>[\\s\\S]*?</nav>", ""),                // nav
            ("<footer[^>]*>[\\s\\S]*?</footer>", ""),          // footer
            ("<form[^>]*>[\\s\\S]*?</form>", ""),              // forms
            ("<!--[\\s\\S]*?-->", ""),                          // comments
            (" on\\w+\\s*=\\s*[\"'][^\"']*[\"']", ""),          // JS event handlers
        ]
        for (pattern, replacement) in removals {
            clean = clean.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        // Wrap in minimal readable CSS
        let wrapper = """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body { font-family: -apple-system, sans-serif; font-size: 17px; line-height: 1.6; max-width: 680px; margin: 0 auto; padding: 16px; color: #1a1a1a; }
          img { max-width: 100%; height: auto; }
          a { color: #007AFF; }
          blockquote { border-left: 3px solid #ddd; margin-left: 0; padding-left: 16px; color: #555; }
        </style>
        </head><body>
        \(clean)
        </body></html>
        """
        return wrapper
    }
}
