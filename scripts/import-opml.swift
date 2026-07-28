#!/usr/bin/env swift

import Foundation

// MARK: - Models

enum MediaKind: String, Codable {
    case text, video, audio, forum
}

struct ParsedFeed: Codable {
    let title: String
    let xmlUrl: String
    let htmlUrl: String?
    let category: String
    let language: String?
    let description: String?
    let tags: [String]
    let mediaKind: MediaKind
}

struct ProbeResult: Codable {
    let xmlUrl: String
    let normalizedUrl: String
    let status: String
    let httpStatus: Int?
    let feedTitle: String?
    let error: String?
}

// MARK: - OPML Parser

final class OPMLImportDelegate: NSObject, XMLParserDelegate {
    let fallbackCategory: String
    var feeds: [ParsedFeed] = []
    private var categoryStack: [String] = []
    private var outlinePushStack: [Bool] = []

    init(fallbackCategory: String) {
        self.fallbackCategory = fallbackCategory
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        guard element == "outline" else { return }

        let xmlUrl = (attributes["xmlUrl"] ?? attributes["xmlurl"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (attributes["title"] ?? attributes["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if xmlUrl.isEmpty {
            let groupName = title.isEmpty ? fallbackCategory : title
            categoryStack.append(groupName)
            outlinePushStack.append(true)
        } else {
            outlinePushStack.append(false)
            let category = categoryStack.last ?? fallbackCategory
            let language = attributes["language"]?.trimmingCharacters(in: .whitespaces)
            let description = attributes["description"]?.trimmingCharacters(in: .whitespaces)
            let htmlUrl = attributes["htmlUrl"]?.trimmingCharacters(in: .whitespaces)
            let tags = (attributes["category"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let mediaKind: MediaKind = {
                let lower = xmlUrl.lowercased()
                if lower.contains("youtube.com/feeds") || lower.contains("youtube.com/channel") { return .video }
                let podcastPatterns = ["/podcast", "/episodes", "/audio", "anchor.fm", "feeds.buzzsprout",
                                       "feeds.simplecast", "feeds.megaphone", "rss.art19", "feeds.transistor",
                                       "feeds.acast", "feeds.libsyn", "pinecast.com", "omny.fm",
                                       "podcasts.apple.com", "podbean.com/feed"]
                if podcastPatterns.contains(where: { lower.contains($0) }) { return .audio }
                if lower.contains("reddit.com/r/") { return .forum }
                return .text
            }()

            feeds.append(ParsedFeed(
                title: title.isEmpty ? category : title,
                xmlUrl: xmlUrl,
                htmlUrl: htmlUrl,
                category: category,
                language: language,
                description: description,
                tags: tags,
                mediaKind: mediaKind
            ))
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard element == "outline" else { return }
        let didPush = outlinePushStack.popLast() ?? false
        if didPush, !categoryStack.isEmpty {
            categoryStack.removeLast()
        }
    }
}

// MARK: - URL Normalization

func normalizeURL(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed) else { return trimmed }
    components.scheme = "https"
    if let host = components.host?.lowercased() {
        components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    components.fragment = nil
    if components.path.hasSuffix("/") {
        components.path.removeLast()
    }
    return components.string ?? trimmed
}

// MARK: - Feed Validation

func probeFeed(url: String, timeout: TimeInterval = 8) async -> ProbeResult {
    let normalized = normalizeURL(url)
    guard let feedURL = URL(string: url) ?? URL(string: normalized) else {
        return ProbeResult(xmlUrl: url, normalizedUrl: normalized, status: "invalid",
                           httpStatus: nil, feedTitle: nil, error: "Malformed URL")
    }

    var request = URLRequest(url: feedURL, timeoutInterval: timeout)
    request.setValue("FeedminePrototype/1.0", forHTTPHeaderField: "User-Agent")
    request.setValue("application/rss+xml, application/atom+xml, application/json, text/xml, */*",
                     forHTTPHeaderField: "Accept")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return ProbeResult(xmlUrl: url, normalizedUrl: normalized, status: "unreachable",
                               httpStatus: nil, feedTitle: nil, error: "Not HTTP")
        }
        guard (200...299).contains(http.statusCode) else {
            return ProbeResult(xmlUrl: url, normalizedUrl: normalized, status: "unreachable",
                               httpStatus: http.statusCode, feedTitle: nil,
                               error: "HTTP \(http.statusCode)")
        }
        let prefix = String(data: data.prefix(500), encoding: .utf8) ?? ""
        let isFeed = prefix.contains("<rss") || prefix.contains("<feed")
            || prefix.contains("<RDF")
            || prefix.trimmingCharacters(in: .whitespaces).hasPrefix("{")

        if isFeed {
            var title: String? = nil
            if prefix.hasPrefix("{"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                title = json["title"] as? String
            } else if let range = prefix.range(of: "<title>"),
                      let end = prefix[range.upperBound...].range(of: "</title>") {
                title = String(prefix[range.upperBound..<end.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if title?.hasPrefix("<![CDATA[") == true && title?.hasSuffix("]]>") == true {
                    title = String(title!.dropFirst(9).dropLast(3))
                }
            }
            return ProbeResult(xmlUrl: url, normalizedUrl: normalized, status: "reachable",
                               httpStatus: http.statusCode, feedTitle: title, error: nil)
        } else {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            return ProbeResult(xmlUrl: url, normalizedUrl: normalized, status: "invalid",
                               httpStatus: http.statusCode, feedTitle: nil,
                               error: contentType.contains("html") ? "HTML page, not a feed"
                                       : "Not a feed (content-type: \(contentType))")
        }
    } catch {
        return ProbeResult(xmlUrl: url, normalizedUrl: normalized, status: "unreachable",
                           httpStatus: nil, feedTitle: nil, error: error.localizedDescription)
    }
}

// MARK: - OPML Generator

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

func generateOPML(feeds: [ParsedFeed], outputPath: String) throws {
    let grouped = Dictionary(grouping: feeds, by: \.category)
        .sorted { $0.value.count > $1.value.count }

    var xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Generated by Feedmine Import Pipeline -->
    <opml version="2.0">
      <head>
        <title>Imported Feeds</title>
        <dateCreated>\(ISO8601DateFormatter().string(from: Date()))</dateCreated>
      </head>
      <body>

    """

    for (category, catFeeds) in grouped {
        xml += "    <outline text=\"\(xmlEscape(category))\" title=\"\(xmlEscape(category))\">\n"
        for feed in catFeeds {
            let mediaKindAttr = feed.mediaKind != .text ? "\n        feedmineMediaKind=\"\(feed.mediaKind.rawValue)\"" : ""
            let descAttr = feed.description.map { " description=\"\(xmlEscape($0))\"" } ?? ""
            let langAttr = feed.language.map { " language=\"\($0)\"" } ?? ""
            let htmlUrlAttr = feed.htmlUrl.map { " htmlUrl=\"\(xmlEscape($0))\"" } ?? ""
            xml += """
                      <outline text="\(xmlEscape(feed.title))" title="\(xmlEscape(feed.title))" type="rss"\
                xmlUrl="\(xmlEscape(feed.xmlUrl))"\(descAttr)\(langAttr)\(htmlUrlAttr)\(mediaKindAttr)/>

            """
        }
        xml += "    </outline>\n"
    }

    xml += """
      </body>
    </opml>
    """

    try xml.write(toFile: outputPath, atomically: true, encoding: .utf8)
    fputs("Wrote \(feeds.count) feeds to \(outputPath)\n", stderr)
}

// MARK: - Main Logic

func run(args: [String]) async throws {
    guard args.count >= 2 else {
        print("Usage: import-opml.swift <opml-file> [--validate] [--json] [--limit N] [--output-opml <path>]")
        print("  --validate      Probe each feed URL to check if alive")
        print("  --json          Output results as JSON")
        print("  --limit N       Only probe N feeds (for quick testing)")
        print("  --output-opml <path>  Generate Feedmine-compatible OPML with validated feeds only")
        exit(1)
    }

    let opmlPath = args[1]
    let shouldValidate = args.contains("--validate")
    let shouldOutputJSON = args.contains("--json")
    let outputOPML = args.enumerated()
        .first(where: { $0.element == "--output-opml" })
        .map { args[$0.offset + 1] }
    let limitArg = args.enumerated()
        .first(where: { $0.element == "--limit" })
        .map { Int(args[$0.offset + 1]) ?? 0 } ?? 0

    guard FileManager.default.fileExists(atPath: opmlPath) else {
        fputs("File not found: \(opmlPath)\n", stderr)
        exit(1)
    }

    let opmlURL = URL(fileURLWithPath: opmlPath)

    // Phase 1: Parse
    fputs("Parsing OPML...\n", stderr)
    let data = try Data(contentsOf: opmlURL)
    let parser = XMLParser(data: data)
    let delegate = OPMLImportDelegate(fallbackCategory: opmlURL.deletingPathExtension().lastPathComponent)
    parser.delegate = delegate
    parser.parse()

    if let error = parser.parserError {
        fputs("Parse error: \(error)\n", stderr)
        exit(1)
    }

    let feeds = delegate.feeds
    fputs("Parsed \(feeds.count) feeds in \(Set(feeds.map(\.category)).count) categories\n", stderr)

    // Category summary
    let byCategory = Dictionary(grouping: feeds, by: \.category)
    print("=".padding(toLength: 70, withPad: "=", startingAt: 0))
    print("OPML Import Report: \(opmlURL.lastPathComponent)")
    print("=".padding(toLength: 70, withPad: "=", startingAt: 0))
    print("\nCategories (\(byCategory.count)):\n")
    for (cat, catFeeds) in byCategory.sorted(by: { $0.value.count > $1.value.count }) {
        let kinds = Dictionary(grouping: catFeeds, by: \.mediaKind)
            .map { "\($0.value.count) \($0.key.rawValue)" }
            .joined(separator: ", ")
        print("  \(cat.padding(toLength: 30, withPad: " ", startingAt: 0)) \(catFeeds.count) feeds (\(kinds))")
    }

    // Duplicate check
    var seen = Set<String>()
    var dupes = 0
    for feed in feeds {
        if seen.contains(normalizeURL(feed.xmlUrl)) { dupes += 1 }
        else { seen.insert(normalizeURL(feed.xmlUrl)) }
    }
    print("\n  Total: \(feeds.count) feeds, \(seen.count) unique, \(dupes) duplicates")

    // Phase 2: Validate
    var reachableFeeds: [ParsedFeed] = []
    var probeResults: [ProbeResult] = []

    if shouldValidate {
        let feedsToProbe = limitArg > 0 ? Array(feeds.prefix(limitArg)) : feeds
        let total = feedsToProbe.count
        fputs("Probing \(total) feeds (max 10 concurrent, 8s timeout)...\n", stderr)

        let startTime = Date()

        let results: [ProbeResult] = await withTaskGroup(
            of: (Int, ProbeResult).self,
            returning: [ProbeResult].self
        ) { group in
            var out = [(Int, ProbeResult)]()
            out.reserveCapacity(total)
            let maxConcurrent = 10
            var running = 0
            var submitted = 0

            for (i, feed) in feedsToProbe.enumerated() {
                if running >= maxConcurrent {
                    if let result = await group.next() {
                        out.append(result)
                        running -= 1
                    }
                }
                group.addTask {
                    let r = await probeFeed(url: feed.xmlUrl)
                    return (i, r)
                }
                running += 1
                submitted += 1
            }
            for await result in group {
                out.append(result)
            }
            out.sort { $0.0 < $1.0 }
            return out.map(\.1)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        probeResults = results

        for (i, result) in results.enumerated() {
            if result.status == "reachable", i < feedsToProbe.count {
                reachableFeeds.append(feedsToProbe[i])
            }
        }

        let reachable = results.filter { $0.status == "reachable" }
        let unreachable = results.filter { $0.status == "unreachable" }
        let invalid = results.filter { $0.status == "invalid" }

        print("\n" + "=".padding(toLength: 70, withPad: "=", startingAt: 0))
        print("Validation Results (\(String(format: "%.1f", elapsed))s)")
        print("=".padding(toLength: 70, withPad: "=", startingAt: 0))
        print("  ✅ Reachable:    \(reachable.count)/\(total)")
        print("  ❌ Unreachable:  \(unreachable.count)/\(total)")
        print("  ⚠️  Invalid:      \(invalid.count)/\(total)")

        if !unreachable.isEmpty {
            print("\n❌ Unreachable (\(unreachable.count)):")
            for r in unreachable.sorted(by: { ($0.error ?? "") < ($1.error ?? "") }) {
                let err = r.error.map { " — \($0)" } ?? ""
                let status = r.httpStatus.map { " [\($0)]" } ?? ""
                print("  \(r.xmlUrl)\(status)\(err)")
            }
        }

        if !invalid.isEmpty {
            print("\n⚠️  Invalid / Not a feed (\(invalid.count)):")
            for r in invalid {
                let err = r.error.map { " — \($0)" } ?? ""
                print("  [\(r.httpStatus ?? 0)] \(r.xmlUrl)\(err)")
            }
        }

        if !reachable.isEmpty {
            print("\n✅ Reachable feeds (\(reachable.count)):")
            for r in reachable.prefix(50) {
                let probe = probeResults.first(where: { $0.xmlUrl == r.xmlUrl })
                let titleStr = probe?.feedTitle.map { " → \"\($0)\"" } ?? ""
                let status = probe?.httpStatus
                print("  [\(status ?? 0)] \(r.xmlUrl)\(titleStr)")
            }
            if reachable.count > 50 {
                print("  ... and \(reachable.count - 50) more")
            }
        }
    } else {
        reachableFeeds = feeds
    }

    // Phase 3: Output
    if shouldOutputJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(reachableFeeds)
        print("\n")
        print(String(data: json, encoding: .utf8)!)
    }

    if let outputPath = outputOPML {
        try generateOPML(feeds: reachableFeeds, outputPath: outputPath)
    }

    fputs("Done.\n", stderr)
}

// MARK: - Entry Point

let sema = DispatchSemaphore(value: 0)
Task {
    do {
        try await run(args: CommandLine.arguments)
    } catch {
        fputs("Fatal: \(error)\n", stderr)
        exit(1)
    }
    sema.signal()
}
sema.wait()
