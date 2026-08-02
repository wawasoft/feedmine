import Foundation
import FeedKit

actor RSSFetcher {
    private let session: URLSession
    private let starterSession: URLSession
    private let httpSync: FeedHTTPSync
    private let starterHTTPSync: FeedHTTPSync

    /// Cache of audio-URL → playable? so repeat fetches never re-probe the same
    /// enclosure (podcast episode URLs are stable).
    private var audioPlayability: [String: Bool] = [:]

    private static let playabilityCacheKey = "audio_playability_cache"

    init() {
        // Restore persisted playability cache (#34) so probes survive restart
        if let saved = UserDefaults.standard.dictionary(forKey: Self.playabilityCacheKey) as? [String: Bool] {
            audioPlayability = saved
        }
        let cache = URLCache(
            memoryCapacity: 4_194_304,
            diskCapacity: 20_971_520
        )
        let headers = [
            "User-Agent": "FeedminePrototype/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/json, text/xml"
        ]

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true       // wait for network instead of failing immediately
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 2 // be a good citizen
        config.urlCache = cache
        config.httpAdditionalHeaders = headers
        self.session = URLSession(configuration: config)

        // First-run surfaces need a real wall-clock ceiling. A separate
        // session prevents one unresponsive publisher from stretching a
        // nominal starter deadline to the normal 30-second resource timeout.
        // Both sessions share the same cache, so a fast-lane response is also
        // available to the regular refresh pipeline.
        let starterConfig = URLSessionConfiguration.default
        starterConfig.timeoutIntervalForRequest = 5
        starterConfig.timeoutIntervalForResource = 7
        starterConfig.waitsForConnectivity = false
        starterConfig.allowsCellularAccess = true
        starterConfig.httpMaximumConnectionsPerHost = 2
        starterConfig.urlCache = cache
        starterConfig.httpAdditionalHeaders = headers
        self.starterSession = URLSession(configuration: starterConfig)

        self.httpSync = FeedHTTPSync(session: session)
        self.starterHTTPSync = FeedHTTPSync(session: starterSession)
    }

    /// Fetch and parse a single feed with conditional GET support.
    /// - Parameters:
    ///   - source: The feed source to fetch.
    ///   - validators: Previously-stored HTTP validators for conditional GET.
    ///   - httpSync: HTTP transport to use (defaults to the normal-timout session).
    func fetch(_ source: FeedSource,
               validators: HTTPValidators = HTTPValidators(),
               httpSync: FeedHTTPSync? = nil) async -> FeedFetchResult {
        guard !Task.isCancelled else {
            return FeedFetchResult(source: source, items: [], outcome: .failed(CancellationError()))
        }

        let transport = httpSync ?? self.httpSync
        let httpResult = await transport.fetch(source, validators: validators)

        switch httpResult.outcome {
        case .notModified:
            return FeedFetchResult(
                source: source, items: [],
                outcome: .notModified
            )

        case .throttled(let until):
            return FeedFetchResult(
                source: source, items: [],
                outcome: .throttled(until: until)
            )

        case .failed(let error):
            return FeedFetchResult(
                source: source, items: [],
                outcome: .failed(error)
            )

        case .success(let data):
            let parser = FeedParser(data: data)
            let result = parser.parse()

            switch result {
            case .success(let feed):
                let feedLevelMeta = extractFeedLevelMetadata(from: feed, source: source)
                var updatedValidators = httpResult.updatedValidators
                updatedValidators.ttl = feedLevelMeta.ttl
                updatedValidators.skipHours = feedLevelMeta.skipHours
                updatedValidators.skipDays = feedLevelMeta.skipDays
                updatedValidators.lastBuildDate = feedLevelMeta.lastBuildDate
                updatedValidators.capabilities = feedLevelMeta.capabilities
                if let canonicalURL = httpResult.canonicalURL {
                    updatedValidators.canonicalURL = canonicalURL
                }

                let items = extractItems(from: feed, source: source)
                if items.isEmpty {
                    updatedValidators.lastOutcome = .modifiedWithoutNewItems
                    Log.network.info("Empty feed: \(source.title)")
                    return FeedFetchResult(
                        source: source, items: [],
                        outcome: .modifiedWithoutNewItems(validators: updatedValidators)
                    )
                }
                let validated = await validateAudio(in: items)
                updatedValidators.lastOutcome = .modifiedWithNewItems
                return FeedFetchResult(
                    source: source, items: validated,
                    outcome: .modifiedWithNewItems(validated, validators: updatedValidators)
                )

            case .failure(let error):
                var failedValidators = httpResult.updatedValidators
                failedValidators.lastOutcome = .failed
                Log.network.error("Parse failure for \(source.title): \(error)")
                return FeedFetchResult(
                    source: source, items: [],
                    outcome: .failed(error)
                )
            }
        }
    }

    /// Cold-start fetch that uses the starter HTTP sync with the 5s/7s
    /// timeout session so a slow publisher can't stretch the cold-start
    /// deadline past the ~2.25s per-feed window.
    private func fetchStarterSource(_ source: FeedSource) async -> FeedFetchResult {
        await fetch(source, validators: HTTPValidators(), httpSync: starterHTTPSync)
    }

    /// Fetch multiple feeds concurrently with a real concurrency cap.
    func fetchAll(_ sources: [FeedSource], maxConcurrent: Int = 5) async -> FeedFetchBatch {
        var allItems: [FeedItem] = []
        var fetchedSourceCount = 0
        var failedSourceCount = 0
        var emptySourceCount = 0
        var notModifiedCount = 0
        var throttledCount = 0
        var sourceOutcomes: [String: FeedFetchOutcome] = [:]

        // Sliding-window concurrency: keep up to `maxConcurrent` fetches in
        // flight at all times. As each one finishes we immediately start the
        // next, so a single slow feed can only occupy its own slot — it can't
        // stall the whole batch. (The previous chunked approach blocked every
        // free slot until the slowest feed in the chunk returned, so with
        // maxConcurrent=15 one hung feed idled up to 14 others for the full
        // request timeout.)
        let cap = max(1, maxConcurrent)

        await withTaskGroup(of: FeedFetchResult.self) { group in
            var iterator = sources.makeIterator()

            // Prime the window.
            var started = 0
            while started < cap, let source = iterator.next() {
                group.addTask { await self.fetch(source) }
                started += 1
            }

            // Drain as results arrive, refilling each freed slot.
            while let result = await group.next() {
                sourceOutcomes[result.source.url] = result.outcome
                switch result.outcome {
                case .modifiedWithNewItems:
                    fetchedSourceCount += 1
                    allItems.append(contentsOf: result.items)
                case .modifiedWithoutNewItems:
                    emptySourceCount += 1
                case .notModified:
                    notModifiedCount += 1
                case .failed:
                    failedSourceCount += 1
                case .throttled:
                    throttledCount += 1
                }

                if Task.isCancelled {
                    // Stop starting new work; signal in-flight fetches to bail
                    // early, then keep draining until the window empties.
                    group.cancelAll()
                } else if let source = iterator.next() {
                    group.addTask { await self.fetch(source) }
                }
            }
        }

        return FeedFetchBatch(
            items: allItems,
            fetchedSourceCount: fetchedSourceCount,
            failedSourceCount: failedSourceCount,
            emptySourceCount: emptySourceCount,
            notModifiedCount: notModifiedCount,
            throttledCount: throttledCount,
            sourceOutcomes: sourceOutcomes
        )
    }

    /// Cold-start fetch that stops waiting as soon as there is enough content
    /// for the first page and its runway. Slow feeds are cancelled for this
    /// pass and remain eligible for the progressive background fetch.
    func fetchStarter(
        _ sources: [FeedSource],
        maxConcurrent: Int = 15,
        minimumSuccessfulSources: Int = 4,
        minimumItemCount: Int = 40,
        deadline: Duration = .milliseconds(2_250),
        onProgress: (@MainActor @Sendable (FeedFetchResult) -> Void)? = nil
    ) async -> FeedFetchBatch {
        enum Event: Sendable {
            case result(FeedFetchResult)
            case deadline
            case cancelled
        }

        var allItems: [FeedItem] = []
        var fetchedSourceCount = 0
        var failedSourceCount = 0
        var emptySourceCount = 0
        var notModifiedCount = 0
        var throttledCount = 0
        var sourceOutcomes: [String: FeedFetchOutcome] = [:]
        let cap = max(1, maxConcurrent)

        await withTaskGroup(of: Event.self) { group in
            var iterator = sources.makeIterator()
            var activeFetches = 0

            while activeFetches < cap, let source = iterator.next() {
                group.addTask { .result(await self.fetchStarterSource(source)) }
                activeFetches += 1
            }
            group.addTask {
                do {
                    try await Task.sleep(for: deadline)
                    return .deadline
                } catch {
                    return .cancelled
                }
            }

            eventLoop: while let event = await group.next() {
                switch event {
                case .cancelled:
                    continue
                case .deadline:
                    group.cancelAll()
                    break eventLoop
                case .result(let result):
                    activeFetches -= 1
                    sourceOutcomes[result.source.url] = result.outcome
                    switch result.outcome {
                    case .modifiedWithNewItems:
                        fetchedSourceCount += 1
                        allItems.append(contentsOf: result.items)
                    case .modifiedWithoutNewItems:
                        emptySourceCount += 1
                    case .notModified:
                        notModifiedCount += 1
                    case .failed:
                        failedSourceCount += 1
                    case .throttled:
                        throttledCount += 1
                    }
                    await onProgress?(result)

                    let runwayReady = fetchedSourceCount >= minimumSuccessfulSources
                        && allItems.count >= minimumItemCount
                    if runwayReady {
                        group.cancelAll()
                        break eventLoop
                    }

                    if let source = iterator.next() {
                        group.addTask { .result(await self.fetchStarterSource(source)) }
                        activeFetches += 1
                    } else if activeFetches == 0 {
                        group.cancelAll()
                        break eventLoop
                    }
                }
            }
        }

        return FeedFetchBatch(
            items: allItems,
            fetchedSourceCount: fetchedSourceCount,
            failedSourceCount: failedSourceCount,
            emptySourceCount: emptySourceCount,
            notModifiedCount: notModifiedCount,
            throttledCount: throttledCount,
            sourceOutcomes: sourceOutcomes
        )
    }

    // MARK: - Audio extraction

    private struct AudioEnclosure {
        let url: String
        let duration: TimeInterval?
    }

    private func extractAudio(from item: RSSFeedItem, source: FeedSource) -> AudioEnclosure? {
        // Standard enclosure
        if let enc = item.enclosure?.attributes,
           let url = enc.url,
           Self.isAudioCandidate(url: url, type: enc.type, medium: nil),
           let resolved = resolvedAudioURL(url, source: source) {
            return AudioEnclosure(url: resolved, duration: nil)
        }

        // Media namespace
        let mediaContents = (item.media?.mediaContents ?? []) + (item.media?.mediaGroup?.mediaContents ?? [])
        if !mediaContents.isEmpty {
            for m in mediaContents {
                guard let attr = m.attributes, let url = attr.url else { continue }
                if Self.isAudioCandidate(url: url, type: attr.type, medium: attr.medium),
                   let resolved = resolvedAudioURL(url, source: source) {
                    let duration = attr.duration.map(TimeInterval.init)
                    return AudioEnclosure(url: resolved, duration: duration)
                }
            }
        }

        return nil
    }

    /// True if the URL path ends in a common audio file extension. Uses the URL
    /// path so query strings (e.g. "…/ep.mp3?token=…") don't defeat the match.
    private static func hasAudioFileExtension(_ url: String) -> Bool {
        let path = (URL(string: url)?.path ?? url).lowercased()
        let exts = [".mp3", ".m4a", ".m4b", ".aac", ".ogg", ".oga", ".opus", ".wav", ".flac"]
        return exts.contains { path.hasSuffix($0) }
    }

    private static func isAudioCandidate(url: String, type: String?, medium: String?) -> Bool {
        let mediaType = type?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mediaMedium = medium?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if mediaMedium == "audio" || mediaType.hasPrefix("audio/") { return true }
        if mediaType.hasPrefix("image/") || mediaType.hasPrefix("video/") || mediaType.hasPrefix("text/") {
            return false
        }
        return hasAudioFileExtension(url)
    }

    private func resolvedAudioURL(_ raw: String?, source: FeedSource) -> String? {
        FeedItem.resolvedMediaURL(from: raw, baseURL: source.url)?.absoluteString
    }

    private func extractAtomAudio(from entry: AtomFeedEntry, source: FeedSource) -> String? {
        guard let links = entry.links else { return nil }
        for link in links {
            guard let attr = link.attributes, let href = attr.href else { continue }
            let isEnclosure = attr.rel?.lowercased() == "enclosure"
            if Self.isAudioCandidate(url: href, type: attr.type, medium: nil) || (isEnclosure && Self.hasAudioFileExtension(href)) {
                return resolvedAudioURL(href, source: source)
            }
        }
        return nil
    }

    private func extractJSONAudio(from item: JSONFeedItem, source: FeedSource) -> AudioEnclosure? {
        guard let attachment = item.attachments?.first(where: {
            guard let url = $0.url else { return false }
            return Self.isAudioCandidate(url: url, type: $0.mimeType, medium: nil)
        }),
              let resolved = resolvedAudioURL(attachment.url, source: source) else {
            return nil
        }
        return AudioEnclosure(url: resolved, duration: attachment.durationInSeconds)
    }

    private func extractDuration(from item: RSSFeedItem) -> TimeInterval? {
        let dur = item.iTunes?.iTunesDuration ?? 0
        return dur > 0 ? dur : nil
    }

    // MARK: - Audio playability validation

    /// Probe the audio enclosures of freshly-parsed items and strip `audioURL`
    /// from any that don't actually serve playable audio, so unplayable
    /// "podcasts" never reach the feed. Bounded, cached, and only touches items
    /// that claim audio — text feeds pay nothing.
    private func validateAudio(in items: [FeedItem]) async -> [FeedItem] {
        // Cap probes per feed so a huge episode list can't stall a fetch; the
        // newest items matter most and appear first.
        let audioIndices = items.indices.filter { items[$0].audioURL != nil }
        guard !audioIndices.isEmpty else { return items }
        let toProbe = Array(audioIndices.prefix(12))

        var playable: [String: Bool] = [:]
        let cap = 6
        await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = toProbe.makeIterator()
            var started = 0
            while started < cap, let idx = iterator.next() {
                guard let audio = items[idx].audioURL else { continue }
                group.addTask { (audio, await self.isPlayableAudio(audio)) }
                started += 1
            }
            while let (audio, ok) = await group.next() {
                playable[audio] = ok
                if let idx = iterator.next(), let next = items[idx].audioURL {
                    group.addTask { (next, await self.isPlayableAudio(next)) }
                }
            }
        }

        guard !playable.isEmpty else { return items }
        var result = items
        for idx in toProbe {
            if let audio = result[idx].audioURL, playable[audio] == false {
                result[idx] = result[idx].withoutAudio()
            }
        }
        return result
    }

    private enum AudioProbe { case playable, notAudio, unknown }

    /// Whether `urlString` should be treated as playable audio. Only a
    /// *definitive* negative — a 2xx with a text/image body, or a gone status
    /// (404/410) — is cached as false and strips the item. Transient failures
    /// (timeouts, 5xx, rate limits) return true (keep) and are NOT cached, so a
    /// network blip can't permanently demote a good podcast.
    private func isPlayableAudio(_ urlString: String) async -> Bool {
        if let cached = audioPlayability[urlString] { return cached }
        guard let url = URL(string: urlString) else {
            audioPlayability[urlString] = false
            savePlayabilityCache()
            return false
        }
        switch await probeAudio(url) {
        case .playable:
            audioPlayability[urlString] = true
            trimPlayabilityCache()
            savePlayabilityCache()
            return true
        case .notAudio:
            audioPlayability[urlString] = false
            trimPlayabilityCache()
            savePlayabilityCache()
            return false
        case .unknown:
            return true   // couldn't confirm — keep it, retry on a later fetch
        }
    }

    private func trimPlayabilityCache() {
        guard audioPlayability.count > 500 else { return }
        // Drop arbitrary entries to keep cache bounded
        let keysToRemove = audioPlayability.keys.prefix(audioPlayability.count - 300)
        for key in keysToRemove { audioPlayability.removeValue(forKey: key) }
        savePlayabilityCache()
    }

    private func savePlayabilityCache() {
        UserDefaults.standard.set(audioPlayability, forKey: Self.playabilityCacheKey)
    }

    private func probeAudio(_ url: URL) async -> AudioProbe {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 6
        do {
            let (_, response) = try await session.data(for: head)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            // Some servers reject HEAD — retry with a 1-byte ranged GET.
            if http.statusCode == 405 || http.statusCode == 501 {
                return await probeAudioRanged(url)
            }
            return classify(http)
        } catch {
            return await probeAudioRanged(url)
        }
    }

    private func probeAudioRanged(_ url: URL) async -> AudioProbe {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            return classify(http)
        } catch {
            return .unknown   // network error — can't determine, don't strip
        }
    }

    /// Classify a probe response. Lenient on content-type (many audio CDNs send
    /// octet-stream / video-mp4); only a 2xx with a text/image body or a gone
    /// status (404/410) is a definitive non-audio. Everything else
    /// (3xx/403/429/5xx) is transient/ambiguous → unknown (keep, don't cache).
    private func classify(_ http: HTTPURLResponse) -> AudioProbe {
        let code = http.statusCode
        if (200...299).contains(code) || code == 206 {
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if type.hasPrefix("text/") || type.hasPrefix("image/") { return .notAudio }
            return .playable
        }
        if code == 404 || code == 410 { return .notAudio }
        return .unknown
    }

    // MARK: - Feed-Level Metadata Extraction

    /// Extract feed-level metadata (TTL, skip hours/days, last build date, capabilities)
    /// from a parsed feed for persistence in HTTPValidators.
    private func extractFeedLevelMetadata(from feed: Feed, source: FeedSource) -> (
        ttl: Int?,
        skipHours: [Int]?,
        skipDays: [String]?,
        lastBuildDate: Date?,
        capabilities: SourceCapabilities?
    ) {
        switch feed {
        case .rss(let rss):
            let cloud = rss.cloud.map { cloud in
                SourceCapabilities.RSSCloudEndpoints(
                    domain: cloud.attributes?.domain ?? "",
                    port: cloud.attributes?.port ?? 0,
                    path: cloud.attributes?.path ?? "",
                    registerProcedure: cloud.attributes?.registerProcedure ?? "",
                    protocolVersion: cloud.attributes?.protocolSpecification ?? ""
                )
            }
            let websubFromRSS = discoverWebSubFromRSS(source: source)
            let caps = SourceCapabilities(
                websub: websubFromRSS,
                cloud: cloud,
                hasPagination: false
            )
            return (
                ttl: rss.ttl,
                skipHours: rss.skipHours,
                skipDays: rss.skipDays?.map(\.rawValue),
                lastBuildDate: rss.lastBuildDate,
                capabilities: caps
            )
        case .atom(let atom):
            let websub = atom.links?.first(where: { link in
                link.attributes?.rel?.lowercased() == "hub"
            }).map { hub in
                SourceCapabilities.WebSubEndpoints(
                    hub: hub.attributes?.href ?? "",
                    selfURL: atom.links?.first(where: {
                        $0.attributes?.rel?.lowercased() == "self"
                    })?.attributes?.href
                )
            }
            let hasPagination = atom.links?.contains(where: {
                let rel = $0.attributes?.rel?.lowercased() ?? ""
                return rel == "next" || rel == "previous" || rel == "first" || rel == "last"
            }) ?? false
            return (
                ttl: nil,
                skipHours: nil,
                skipDays: nil,
                lastBuildDate: atom.updated,
                capabilities: websub.map { SourceCapabilities(websub: $0, hasPagination: hasPagination) }
            )
        case .json(let json):
            let websub = json.hubs?.first(where: { $0.type?.lowercased() == "websub" }).map { hub in
                SourceCapabilities.WebSubEndpoints(hub: hub.url ?? "", selfURL: json.feedUrl)
            }
            return (
                ttl: nil,
                skipHours: nil,
                skipDays: nil,
                lastBuildDate: nil,
                capabilities: websub.map { SourceCapabilities(websub: $0, hasPagination: false) }
            )
        }
    }

    /// Discover WebSub endpoints from RSS feed's atom:link elements.
    /// FeedKit doesn't expose these natively, so we parse the raw XML.
    private func discoverWebSubFromRSS(source: FeedSource) -> SourceCapabilities.WebSubEndpoints? {
        // WebSub in RSS is declared via atom:link elements.
        // FeedKit 9.x may expose these via rssFeed.namespaces or similar.
        // For now, return nil — a follow-up can add regex-based extraction
        // from raw XML if FeedKit doesn't expose these links.
        // The Atom and JSON Feed paths are already covered.
        return nil
    }

    // MARK: - Item Metadata Extraction

    private func extractRSSAuthors(from item: RSSFeedItem) -> [FeedItemAuthor]? {
        var authors: [FeedItemAuthor] = []
        if let author = item.author, !author.isEmpty {
            // RSS author is often just a string — parse name if it looks like "Name <email>"
            if let emailStart = author.firstIndex(of: "<"),
               let emailEnd = author.firstIndex(of: ">"),
               emailStart < emailEnd {
                let name = String(author[..<emailStart]).trimmingCharacters(in: .whitespaces)
                let email = String(author[author.index(after: emailStart)..<emailEnd])
                authors.append(FeedItemAuthor(name: name.isEmpty ? nil : name, email: email, uri: nil))
            } else {
                authors.append(FeedItemAuthor(name: author, email: nil, uri: nil))
            }
        }
        if let itunesAuthor = item.iTunes?.iTunesAuthor, !itunesAuthor.isEmpty {
            // Avoid duplicates
            if !authors.contains(where: { $0.name == itunesAuthor }) {
                authors.append(FeedItemAuthor(name: itunesAuthor, email: nil, uri: nil))
            }
        }
        return authors.isEmpty ? nil : authors
    }

    private func extractRSSCategories(from item: RSSFeedItem) -> [FeedItemCategory]? {
        guard let cats = item.categories, !cats.isEmpty else { return nil }
        return cats.compactMap { cat in
            guard let value = cat.value, !value.isEmpty else { return nil }
            return FeedItemCategory(term: value, scheme: cat.attributes?.domain, label: nil)
        }
    }

    private func extractRSSAttribution(from item: RSSFeedItem) -> FeedItemAttribution? {
        guard let src = item.source?.value, !src.isEmpty else { return nil }
        return FeedItemAttribution(
            title: src,
            url: item.source?.attributes?.url,
            feedURL: nil
        )
    }

    private func extractRSSEnclosures(from item: RSSFeedItem, source: FeedSource) -> [FeedEnclosure]? {
        var enclosures: [FeedEnclosure] = []

        // Standard enclosure
        if let enc = item.enclosure?.attributes, let url = enc.url, !url.isEmpty {
            enclosures.append(FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: url, baseURL: source.url)?.absoluteString ?? url,
                mimeType: enc.type,
                length: enc.length.flatMap(Int64.init),
                duration: nil,
                medium: classifyMedium(mimeType: enc.type, url: url)
            ))
        }

        // Media RSS contents
        for media in (item.media?.mediaContents ?? []) {
            guard let attr = media.attributes, let url = attr.url, !url.isEmpty else { continue }
            enclosures.append(FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: url, baseURL: source.url)?.absoluteString ?? url,
                mimeType: attr.type,
                length: attr.fileSize.flatMap(Int64.init),
                duration: attr.duration.map(TimeInterval.init),
                medium: attr.medium ?? classifyMedium(mimeType: attr.type, url: url)
            ))
        }

        return enclosures.isEmpty ? nil : enclosures
    }

    private func extractAtomAuthors(from entry: AtomFeedEntry) -> [FeedItemAuthor]? {
        guard let authors = entry.authors, !authors.isEmpty else { return nil }
        return authors.map { author in
            FeedItemAuthor(name: author.name, email: author.email, uri: author.uri)
        }
    }

    private func extractAtomCategories(from entry: AtomFeedEntry) -> [FeedItemCategory]? {
        guard let cats = entry.categories, !cats.isEmpty else { return nil }
        return cats.compactMap { cat in
            guard let term = cat.attributes?.term, !term.isEmpty else { return nil }
            return FeedItemCategory(term: term, scheme: cat.attributes?.scheme, label: cat.attributes?.label)
        }
    }

    private func extractAtomAttribution(from entry: AtomFeedEntry) -> FeedItemAttribution? {
        guard let source = entry.source, let title = source.title, !title.isEmpty else { return nil }
        return FeedItemAttribution(title: title, url: nil, feedURL: nil)
    }

    private func extractAtomEnclosures(from entry: AtomFeedEntry, source: FeedSource) -> [FeedEnclosure]? {
        guard let links = entry.links, !links.isEmpty else { return nil }
        let enclosures = links.compactMap { link -> FeedEnclosure? in
            guard let href = link.attributes?.href, !href.isEmpty else { return nil }
            return FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: href, baseURL: source.url)?.absoluteString ?? href,
                mimeType: link.attributes?.type,
                length: link.attributes?.length.flatMap(Int64.init),
                duration: nil,
                medium: classifyMedium(mimeType: link.attributes?.type, url: href)
            )
        }
        return enclosures.isEmpty ? nil : enclosures
    }

    private func extractAtomAlternateLinks(from entry: AtomFeedEntry, source: FeedSource) -> [FeedAlternateLink]? {
        guard let links = entry.links, !links.isEmpty else { return nil }
        let alternates = links.compactMap { link -> FeedAlternateLink? in
            guard let href = link.attributes?.href, !href.isEmpty else { return nil }
            let resolved = FeedItem.resolvedMediaURL(from: href, baseURL: source.url)?.absoluteString ?? href
            return FeedAlternateLink(
                url: resolved,
                mimeType: link.attributes?.type,
                language: link.attributes?.hreflang,
                rel: link.attributes?.rel
            )
        }
        return alternates.isEmpty ? nil : alternates
    }

    private func extractJSONAuthors(from jsonItem: JSONFeedItem) -> [FeedItemAuthor]? {
        guard let author = jsonItem.author else { return nil }
        return [FeedItemAuthor(name: author.name, email: nil, uri: author.url)]
    }

    private func extractJSONCategories(from jsonItem: JSONFeedItem) -> [FeedItemCategory]? {
        guard let tags = jsonItem.tags, !tags.isEmpty else { return nil }
        return tags.map { FeedItemCategory(term: $0, scheme: nil, label: nil) }
    }

    private func extractJSONEnclosures(from jsonItem: JSONFeedItem, source: FeedSource) -> [FeedEnclosure]? {
        guard let attachments = jsonItem.attachments, !attachments.isEmpty else { return nil }
        let enclosures = attachments.compactMap { att -> FeedEnclosure? in
            guard let url = att.url, !url.isEmpty else { return nil }
            return FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: url, baseURL: source.url)?.absoluteString ?? url,
                mimeType: att.mimeType,
                length: att.sizeInBytes.flatMap(Int64.init),
                duration: att.durationInSeconds,
                medium: classifyMedium(mimeType: att.mimeType, url: url)
            )
        }
        return enclosures.isEmpty ? nil : enclosures
    }

    /// Classify an enclosure as audio/video/image based on MIME type and URL extension.
    private func classifyMedium(mimeType: String?, url: String) -> String? {
        let type = mimeType?.lowercased() ?? ""
        if type.hasPrefix("audio/") { return "audio" }
        if type.hasPrefix("video/") { return "video" }
        if type.hasPrefix("image/") { return "image" }
        let path = (URL(string: url)?.path ?? url).lowercased()
        let audioExts = ["mp3", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav", "flac"]
        let videoExts = ["mp4", "mov", "webm", "avi", "mkv"]
        let imageExts = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic"]
        if audioExts.contains(where: path.hasSuffix) { return "audio" }
        if videoExts.contains(where: path.hasSuffix) { return "video" }
        if imageExts.contains(where: path.hasSuffix) { return "image" }
        return nil
    }

    // MARK: - Private

    func extractItems(fromFeedData data: Data, source: FeedSource) -> [FeedItem] {
        guard case .success(let feed) = FeedParser(data: data).parse() else { return [] }
        return extractItems(from: feed, source: source)
    }

    private func extractItems(from feed: Feed, source: FeedSource) -> [FeedItem] {
        // Channel-level image fallback for podcasts (many RSS feeds have
        // artwork at the channel level but not per-episode).
        let feedImage: String? = {
            // Aggregator channel artwork identifies the transport, not the
            // article. Reusing the Google News logo on every card makes many
            // publishers look like one repeated feed.
            if URL(string: source.url)?.host?.lowercased() == "news.google.com" {
                return nil
            }
            let image: String? = {
                switch feed {
                case .atom(let a): return a.logo ?? a.icon
                case .rss(let r):  return r.iTunes?.iTunesImage?.attributes?.href ?? r.image?.url
                case .json(let j): return j.icon ?? j.favicon
                }
            }()
            // Skip obvious favicons and tiny site logos — they block article
            // image resolution. A missing image triggers ArticleImageResolver
            // which finds the actual article artwork.
            //
            // Exception: podcasts (audio sources). The channel-level image
            // IS the correct podcast artwork. Rejecting it leaves the podcast
            // card permanently without artwork since episode pages are audio
            // links, not article pages with OG images.
            if let image, Self.isLikelyFaviconOrLogo(image) {
                if source.mediaKind != .audio { return nil }
                // For podcasts, only reject truly tiny images, not artwork
                if Self.isObviouslyTooSmall(image) { return nil }
            }
            return image
        }()

        let entries: [FeedItem] = {
            switch feed {
            case .atom(let atomFeed):
                let atomEntries = (atomFeed.entries as? [AtomFeedEntry]) ?? []
                return atomEntries.compactMap { entry in
                    let rawContent = entry.content?.value ?? entry.summary?.value ?? ""
                    let audio = extractAtomAudio(from: entry, source: source)
                    let entryLink = entry.links?.first(where: { link in
                        let rel = link.attributes?.rel?.lowercased()
                        let type = link.attributes?.type?.lowercased() ?? ""
                        return (rel == nil || rel == "alternate")
                            && !type.contains("atom")
                            && !type.contains("rss")
                    })?.attributes?.href
                        ?? entry.links?.first(where: {
                            $0.attributes?.rel?.lowercased() != "enclosure"
                        })?.attributes?.href
                    let img = bestMediaImageURL(from: entry.media)
                        ?? extractFirstImageFromHTML(rawContent)
                        ?? feedImage
                    let metadata = ParsedItemMetadata(
                        authors: extractAtomAuthors(from: entry),
                        categories: extractAtomCategories(from: entry),
                        rights: entry.rights,
                        attribution: extractAtomAttribution(from: entry),
                        enclosures: extractAtomEnclosures(from: entry, source: source),
                        language: nil,
                        alternateLinks: extractAtomAlternateLinks(from: entry, source: source),
                        publishedAt: entry.published,
                        updatedAt: entry.updated
                    )
                    return makeItem(
                        guid: entry.id,
                        link: entryLink ?? entry.id,
                        title: entry.title,
                        source: source,
                        rawDescription: entry.summary?.value ?? entry.content?.value,
                        rawContent: entry.content?.value,
                        imageURL: img,
                        audioURL: audio,
                        metadata: metadata
                    )
                }
            case .rss(let rssFeed):
                let rssItems = (rssFeed.items as? [RSSFeedItem]) ?? []
                return rssItems.compactMap { item in
                    let audio = extractAudio(from: item, source: source)
                    let duration = extractDuration(from: item) ?? audio?.duration
                    let img = extractImageURL(from: item) ?? feedImage
                    let metadata = ParsedItemMetadata(
                        authors: extractRSSAuthors(from: item),
                        categories: extractRSSCategories(from: item),
                        rights: nil,
                        attribution: extractRSSAttribution(from: item),
                        enclosures: extractRSSEnclosures(from: item, source: source),
                        language: rssFeed.language,
                        alternateLinks: nil,
                        publishedAt: item.pubDate,
                        updatedAt: nil
                    )
                    return makeItem(
                        guid: item.guid?.value,
                        link: item.link,
                        title: item.title,
                        source: source,
                        itemSourceTitle: item.source?.value,
                        rawDescription: item.description,
                        rawContent: item.content?.contentEncoded,
                        imageURL: img,
                        audioURL: audio?.url,
                        duration: duration,
                        metadata: metadata
                    )
                }
            case .json(let jsonFeed):
                let jsonItems = (jsonFeed.items as? [JSONFeedItem]) ?? []
                return jsonItems.compactMap { jsonItem in
                    let audio = extractJSONAudio(from: jsonItem, source: source)
                    // Check attachments for image types (e.g., "image/jpeg")
                    let attachmentImage = jsonItem.attachments?.first { attachment in
                        Self.isSupportedRasterMIMEType(attachment.mimeType)
                    }?.url
                    let img = jsonItem.image ?? jsonItem.bannerImage ?? attachmentImage ?? feedImage
                    let metadata = ParsedItemMetadata(
                        authors: extractJSONAuthors(from: jsonItem),
                        categories: extractJSONCategories(from: jsonItem),
                        rights: nil,
                        attribution: nil,
                        enclosures: extractJSONEnclosures(from: jsonItem, source: source),
                        language: nil, // JSON Feed language not exposed by FeedKit 9.x
                        alternateLinks: nil,
                        publishedAt: jsonItem.datePublished,
                        updatedAt: jsonItem.dateModified
                    )
                    return makeItem(
                        guid: jsonItem.id,
                        link: jsonItem.url,
                        title: jsonItem.title,
                        source: source,
                        rawDescription: jsonItem.summary ?? jsonItem.contentText,
                        rawContent: jsonItem.contentHtml,
                        imageURL: img,
                        audioURL: audio?.url,
                        duration: audio?.duration,
                        metadata: metadata
                    )
                }
            }
        }()

        return entries
    }

    private func makeItem(
        guid: String?,
        link: String?,
        title: String?,
        source: FeedSource,
        itemSourceTitle: String? = nil,
        rawDescription: String?,
        rawContent: String?,
        imageURL: String?,
        audioURL: String? = nil,
        duration: TimeInterval? = nil,
        metadata: ParsedItemMetadata = ParsedItemMetadata()
    ) -> FeedItem? {
        let resolvedLink = [link, audioURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        // Text items need a clickable URL. Podcast items can use their
        // enclosure URL, because tapping them starts playback instead.
        guard let resolvedLink else { return nil }

        // A visible card without a real headline is worse than skipping an
        // incomplete feed item. Some malformed feeds encode CDATA as text;
        // sanitizedHTMLText unwraps that form before this check.
        let sanitizedTitle = Self.sanitizedHTMLText(title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedTitle.isEmpty else { return nil }
        let truncatedTitle = String(sanitizedTitle.prefix(200))

        let itemPubDate = metadata.publishedAt ?? metadata.updatedAt

        let id = FeedItem.generateID(
            sourceURL: source.url,
            guid: guid,
            link: link,
            title: sanitizedTitle,
            publishedAt: itemPubDate
        )

        let excerpt = extractExcerpt(
            description: rawDescription,
            content: rawContent
        )

        // Resolve relative image URLs against the article URL
        let resolvedImageURL = resolveImageURL(imageURL, baseURL: link ?? source.url)

        // Sanitize: truncate long titles, strip HTML, cap source names
        let isGoogleNews = URL(string: source.url)?.host?.lowercased() == "news.google.com"
        let preferredSourceTitle: String? = if isGoogleNews {
            if let publisher = itemSourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !publisher.isEmpty {
                publisher
            } else {
                "Google News"
            }
        } else {
            nil
        }
        let sanitizedSource = String(
            Self.sanitizedHTMLText(
                preferredSourceTitle?.isEmpty == false ? preferredSourceTitle! : source.title
            ).prefix(80)
        )

        return FeedItem(
            id: id,
            sourceTitle: sanitizedSource,
            sourceURL: source.url,
            category: source.category,
            title: truncatedTitle,
            excerpt: excerpt,
            url: resolvedLink,
            imageURL: resolvedImageURL,
            publishedAt: itemPubDate ?? Date(),
            audioURL: audioURL,
            duration: duration,
            region: source.region,
            language: metadata.language,
            updatedAt: metadata.updatedAt,
            authors: metadata.authors,
            itemCategories: metadata.categories,
            rights: metadata.rights,
            attribution: metadata.attribution,
            enclosures: metadata.enclosures,
            languageFromFeed: metadata.language,
            alternateLinks: metadata.alternateLinks
        )
    }

    /// Pick the best image URL from a Media RSS namespace — largest width
    /// wins; "image/*" type preferred over "thumbnail/*" when sizes match.
    /// Checks both item-level and ``MediaGroup`` children so that feeds
    /// wrapping their media in ``<media:group>`` (e.g. YouTube) are covered.
    private func bestMediaImageURL(from media: MediaNamespace?) -> String? {
        guard let media else { return nil }

        // Collect media:content from both the item and its optional media:group.
        // FeedKit maps <media:group/media:content> into media.mediaGroup.mediaContents
        // but <media:group/media:thumbnail> is NOT mapped (MediaGroup lacks the
        // property), so we also check group-level media:content for image/* types.
        let allContents = (media.mediaContents ?? []) + (media.mediaGroup?.mediaContents ?? [])

        // media:content may represent audio, video, documents, or browser
        // players. Only direct raster images are valid card artwork.
        let imageContents = allContents.filter { content in
            guard let attributes = content.attributes else { return false }
            if attributes.medium?.lowercased() == "image" {
                return !Self.isUnsupportedImageURL(attributes.url)
            }
            if Self.isSupportedRasterMIMEType(attributes.type) {
                return !Self.isUnsupportedImageURL(attributes.url)
            }
            guard attributes.medium == nil, attributes.type == nil else { return false }
            return Self.hasRasterImageExtension(attributes.url)
        }
        if !imageContents.isEmpty {
            let best = imageContents.max { a, b in
                let aW = a.attributes?.width.flatMap(Int.init) ?? 0
                let bW = b.attributes?.width.flatMap(Int.init) ?? 0
                return aW < bW
            }
            if let url = best?.attributes?.url { return url }
        }

        // 2. media:thumbnails — pick largest by width (item-level only;
        //    MediaGroup has no mediaThumbnails property in FeedKit 9.x).
        if let thumbs = media.mediaThumbnails, !thumbs.isEmpty {
            let best = thumbs.max { a, b in
                let aW = a.attributes?.width.flatMap(Int.init) ?? 0
                let bW = b.attributes?.width.flatMap(Int.init) ?? 0
                return aW < bW
            }
            if let url = best?.attributes?.url { return url }
        }

        return nil
    }

    /// Extract image URL from RSS item, picking the best available image.
    private func extractImageURL(from item: RSSFeedItem) -> String? {
        // 1. media:content / media:thumbnail (Media RSS namespace)
        if let url = bestMediaImageURL(from: item.media) { return url }

        // 2. Episode artwork used by most podcast publishers.
        if let url = item.iTunes?.iTunesImage?.attributes?.href { return url }

        // 3. enclosure with a supported raster image type
        if let enclosure = item.enclosure,
           let type = enclosure.attributes?.type,
           Self.isSupportedRasterMIMEType(type),
           let url = enclosure.attributes?.url {
            return url
        }

        // 4. First <img> in content
        if let content = item.content?.contentEncoded ?? item.description {
            return extractFirstImageFromHTML(content)
        }

        return nil
    }

    /// Resolve a possibly-relative image URL against the article's base URL.
    private func resolveImageURL(_ imageURL: String?, baseURL: String?) -> String? {
        guard let original = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !original.isEmpty else { return nil }
        let raw = original
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#038;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
        // Reject tracking pixels and spacer GIFs at the source so they never
        // enter the database or pollute the What's New carousel.
        let lower = raw.lowercased()
        if lower.contains("tracking") && lower.contains("pixel") { return nil }
        if lower.contains("/tracker/") || lower.contains("count.gif") || lower.contains("track-rss-story") { return nil }
        if lower.contains("spacer") && (lower.hasSuffix(".gif") || lower.hasSuffix(".png")) { return nil }
        if lower.hasSuffix("1x1.gif") || lower.hasSuffix("1x1.png") { return nil }
        if Self.isUnsupportedImageURL(raw) { return nil }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            let schemeLen = lower.hasPrefix("https://") ? 8 : 7
            let tail = lower.dropFirst(schemeLen)
            let nestedSchemes = ["http://", "https://"].compactMap { tail.range(of: $0) }
            if let firstNested = nestedSchemes.min(by: { $0.lowerBound < $1.lowerBound }) {
                let prefix = tail[..<firstNested.lowerBound]
                // URL proxies commonly use /https://... or ?url=https://...
                // A bare image.jpghttps://... sequence is malformed.
                if prefix.last != "/" && prefix.last != "=" { return nil }
            }
        }
        // Already absolute — upgrade HTTP to HTTPS so images don't fail
        // under ATS (NSAllowsArbitraryLoadsForMedia only covers AV media).
        if raw.hasPrefix("http://") {
            let upgraded = "https://" + raw.dropFirst("http://".count)
            return Self.validHTTPImageURL(String(upgraded))
        }
        if raw.hasPrefix("https://") { return Self.validHTTPImageURL(raw) }
        // Data URIs are accepted only for raster formats supported by ImageIO.
        if lower.hasPrefix("data:image/") { return raw }
        if lower.hasPrefix("data:") { return nil }
        // Protocol-relative URL
        if raw.hasPrefix("//") { return Self.validHTTPImageURL("https:\(raw)") }
        // Relative URL — resolve against base
        guard let base = baseURL, let baseURL = URL(string: base) else { return nil }
        guard let resolved = URL(string: raw, relativeTo: baseURL) else { return nil }
        return Self.validHTTPImageURL(resolved.absoluteString)
    }

    private static func isSupportedRasterMIMEType(_ value: String?) -> Bool {
        guard let type = value?.lowercased(), type.hasPrefix("image/") else { return false }
        return !type.contains("svg")
    }

    private static func hasRasterImageExtension(_ value: String?) -> Bool {
        guard let value, let components = URLComponents(string: value) else { return false }
        let extensions = Set(["jpg", "jpeg", "jfif", "png", "gif", "webp", "avif", "heic", "heif", "bmp", "tif", "tiff"])
        return extensions.contains((components.path as NSString).pathExtension.lowercased())
    }

    private static func isUnsupportedImageURL(_ value: String?) -> Bool {
        guard let value else { return true }
        let lower = value.lowercased()
        if lower.hasPrefix("data:image/svg") { return true }
        if lower.contains("youtube.com/embed/") { return true }
        guard let components = URLComponents(string: value) else { return true }
        let ext = (components.path as NSString).pathExtension.lowercased()
        return ["svg", "mp3", "m4a", "aac", "wav", "ogg", "opus", "mp4", "mov", "webm"].contains(ext)
    }

    private static func validHTTPImageURL(_ value: String) -> String? {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              !isUnsupportedImageURL(value) else { return nil }
        return url.absoluteString
    }

    /// Extract the first plausible content image from an HTML fragment. Feed
    /// bodies often begin with a favicon, avatar, sharing button, or tracking
    /// image; when an img has srcset, use its largest declared variant.
    private func extractFirstImageFromHTML(_ html: String) -> String? {
        // Quick pre-check — skip if no img tag present
        guard html.contains("<img") || html.contains("&lt;img") else { return nil }

        let decoded = html
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        for candidate in [decoded, html] {
            let fullRange = NSRange(candidate.startIndex..., in: candidate)
            for match in Self.imgTagRegex.matches(in: candidate, range: fullRange) {
                guard let tagRange = Range(match.range, in: candidate) else { continue }
                let tag = String(candidate[tagRange])
                let attributes = Self.imageAttributeRegex.matches(
                    in: tag,
                    range: NSRange(tag.startIndex..., in: tag)
                ).compactMap { attribute -> (name: String, value: String)? in
                    guard let nameRange = Range(attribute.range(at: 1), in: tag),
                          let valueRange = Range(attribute.range(at: 2), in: tag) else { return nil }
                    return (String(tag[nameRange]).lowercased(), String(tag[valueRange]))
                }

                let valueForFirstAttribute: ([String]) -> String? = { names in
                    names.lazy.compactMap { name in
                        attributes.first(where: { $0.name == name })?.value
                    }.first
                }
                let srcset = valueForFirstAttribute(["data-lazy-srcset", "data-srcset", "srcset"])
                let src = valueForFirstAttribute([
                    "data-lazy-src", "data-original", "data-orig-file", "data-src", "src",
                ])
                let imageURL = Self.preferredSrcsetCandidate(srcset) ?? src
                guard let imageURL, !Self.isLikelyDecorativeImageURL(imageURL) else { continue }
                return Self.upgradedKnownThumbnailURL(imageURL)
            }
        }
        return nil
    }

    private static func preferredSrcsetCandidate(_ srcset: String?) -> String? {
        guard let srcset else { return nil }
        let candidates = srcset.split(separator: ",")
            .compactMap { entry -> (url: String, value: Double, unit: Character)? in
                let parts = entry.split(whereSeparator: \Character.isWhitespace)
                guard let first = parts.first else { return nil }
                let descriptor = parts.dropFirst().last.map(String.init) ?? ""
                guard let unit = descriptor.last,
                      unit == "w" || unit == "x",
                      let number = Double(descriptor.dropLast()) else { return nil }
                return (String(first), number, unit)
            }
        let widthCandidates = candidates.filter { $0.unit == "w" }.sorted { $0.value < $1.value }
        if let sufficient = widthCandidates.first(where: { $0.value >= 960 }) { return sufficient.url }
        if let largest = widthCandidates.last { return largest.url }
        let densityCandidates = candidates.filter { $0.unit == "x" }.sorted { $0.value < $1.value }
        if let retina = densityCandidates.first(where: { $0.value >= 2 }) { return retina.url }
        return densityCandidates.last?.url
    }

    private static func isLikelyDecorativeImageURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        let markers = [
            "favicon", "gravatar.com/avatar", "/emoji/", "s.w.org/images/core/emoji",
            "addtoany.com/buttons", "share_save", "icon_facebook", "tracking",
            "spacer", "pixel.gif", "count.gif",
        ]
        if markers.contains(where: lower.contains) { return true }
        return lower.range(of: #"(?:^|[-_/])(16|18|24|32)x(?:11|12|16|18|24|29|30|31|32)(?:[-_.?/]|$)"#,
                           options: .regularExpression) != nil
    }

    /// Rejects channel-level images that are obviously favicons or tiny logos.
    /// Using these as article images blocks ArticleImageResolver from finding
    /// the actual article artwork.
    private static func isLikelyFaviconOrLogo(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains("favicon") || lower.contains("cropped") { return true }
        // Match tiny favicon dimensions (-32x32, -150x150) but not large
        // artwork (-1400x1400, -3000x3000). Threshold: ≤150px on either side.
        if let range = lower.range(of: #"[-.](\d{2,4})x(\d{2,4})"#, options: .regularExpression) {
            let match = String(lower[range]).dropFirst()  // strip leading - or .
            let parts = match.split(separator: "x").compactMap { Int($0) }
            if let w = parts.first, let h = parts.last, w <= 150 && h <= 150 {
                return true
            }
        }
        // Site logos used as channel images (not article artwork)
        if lower.contains("/logo") || lower.contains("-logo") || lower.contains("_logo") {
            return true
        }
        return false
    }

    /// Returns true only if the URL clearly indicates a tiny image (< 150px).
    /// Used as a secondary filter for podcast artwork — podcast covers that
    /// happen to contain "logo" in the URL should not be blanket-rejected.
    private static func isObviouslyTooSmall(_ url: String) -> Bool {
        let lower = url.lowercased()
        if let range = lower.range(of: #"[-.](\d{2,3})x(\d{2,3})"#, options: .regularExpression) {
            let match = String(lower[range]).dropFirst()
            let parts = match.split(separator: "x").compactMap { Int($0) }
            if let w = parts.first, let h = parts.last, w <= 100 && h <= 100 {
                return true
            }
        }
        return false
    }

    private static func upgradedKnownThumbnailURL(_ value: String) -> String {
        guard let url = URL(string: value),
              let host = url.host?.lowercased(),
              host.contains("blogger.googleusercontent.com") || host.hasSuffix(".blogspot.com") else {
            return value
        }
        return value.replacingOccurrences(
            of: #"/s(?:72|144|320)(?:-w\d+-h\d+)?(?:-[a-z]+)?/"#,
            with: "/s1200/",
            options: .regularExpression
        )
    }

    /// Extract excerpt from available fields in priority order.
    private func extractExcerpt(description: String?, content: String?) -> String {
        let raw = description ?? content ?? ""
        let stripped = Self.sanitizedHTMLText(raw)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "No description" }
        // Find last full word within 200 char limit
        let capped = String(stripped.prefix(200))
        if let lastSpace = capped.lastIndex(of: " "), lastSpace > capped.startIndex {
            return String(capped[..<lastSpace]).trimmingCharacters(in: .whitespaces)
        }
        return capped
    }

    private static let imgTagRegex = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)
    private static let imageAttributeRegex = try! NSRegularExpression(
        pattern: #"\s(data-lazy-srcset|data-srcset|srcset|data-lazy-src|data-original|data-orig-file|data-src|src)\s*=\s*["']([^"']+)["']"#,
        options: .caseInsensitive
    )

    /// Convert feed HTML/XML fragments into display text without pulling in
    /// NSAttributedString's HTML parser for every item.
    nonisolated static func sanitizedHTMLText(_ html: String) -> String {
        FeedTextSanitizer.sanitizedHTMLText(html)
    }
}

enum FeedTextSanitizer {
    private static let htmlTagRegex = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let htmlEntityRegex = try! NSRegularExpression(
        pattern: #"&#(?:x[0-9A-Fa-f]+|[0-9]+);?|&[A-Za-z][A-Za-z0-9]{1,31};"#
    )

    /// Convert feed HTML/XML fragments into display text without pulling in
    /// NSAttributedString's HTML parser for every item.
    static func sanitizedHTMLText(_ html: String) -> String {
        let decodedMarkup = unwrapCDATA(in: decodeHTMLEntities(in: html))
        let range = NSRange(decodedMarkup.startIndex..., in: decodedMarkup)
        let stripped = htmlTagRegex.stringByReplacingMatches(in: decodedMarkup, range: range, withTemplate: " ")
        return decodeHTMLEntities(in: stripped)
    }

    /// A few publishers write an escaped CDATA wrapper inside an XML element
    /// (`&lt;![CDATA[headline]]&gt;`). Once entities are decoded it looks like a
    /// tag, so the normal HTML stripper would erase the headline entirely.
    private static func unwrapCDATA(in input: String) -> String {
        var text = input
        while let start = text.range(of: "<![CDATA["),
              let end = text.range(of: "]]>", range: start.upperBound..<text.endIndex) {
            text.replaceSubrange(start.lowerBound..<end.upperBound, with: text[start.upperBound..<end.lowerBound])
        }
        return text
    }

    private static func decodeHTMLEntities(in text: String) -> String {
        guard text.contains("&") else { return text }

        let matches = htmlEntityRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var decoded = ""
        decoded.reserveCapacity(text.count)
        var cursor = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            decoded.append(contentsOf: text[cursor..<range.lowerBound])
            let token = String(text[range])
            decoded.append(decodedHTMLEntity(token) ?? token)
            cursor = range.upperBound
        }

        decoded.append(contentsOf: text[cursor...])
        return decoded
    }

    private static func decodedHTMLEntity(_ token: String) -> String? {
        guard token.hasPrefix("&") else { return nil }
        var body = String(token.dropFirst())
        if body.hasSuffix(";") {
            body.removeLast()
        }

        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            let hex = String(body.dropFirst(2))
            guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) else { return nil }
            return scalar.value == 160 ? " " : String(scalar)
        }

        if body.hasPrefix("#") {
            let decimal = String(body.dropFirst())
            guard let value = UInt32(decimal, radix: 10), let scalar = UnicodeScalar(value) else { return nil }
            return scalar.value == 160 ? " " : String(scalar)
        }

        // Try exact match first — HTML entities are case-sensitive
        // (&Agrave; is À, &agrave; is à). Fall back to lowercase
        // for feeds that use unconventional casing.
        if let exact = namedHTMLEntities[body] { return exact }
        return namedHTMLEntities[body.lowercased()]
    }

    /// Comprehensive HTML4 named character entity table.
    /// Covers Latin-1 Supplement, Latin Extended-A/B, Greek letters,
    /// general punctuation, mathematical operators, arrows, and
    /// miscellaneous symbols commonly found in RSS/Atom feeds.
    private static let namedHTMLEntities: [String: String] = [
        // MARK: - Basic & Punctuation
        "amp": "&",
        "apos": "'",
        "gt": ">",
        "lt": "<",
        "nbsp": " ",
        "quot": "\"",

        // MARK: - Latin-1 Supplement (U+00A0–U+00FF)
        "iexcl":  "\u{00A1}",  // ¡
        "cent":   "\u{00A2}",  // ¢
        "pound":  "\u{00A3}",  // £
        "curren": "\u{00A4}",  // ¤
        "yen":    "\u{00A5}",  // ¥
        "brvbar": "\u{00A6}",  // ¦
        "sect":   "\u{00A7}",  // §
        "uml":    "\u{00A8}",  // ¨
        "copy":   "\u{00A9}",  // ©
        "ordf":   "\u{00AA}",  // ª
        "laquo":  "\u{00AB}",  // «
        "not":    "\u{00AC}",  // ¬
        "shy":    "\u{00AD}",  // ­ (soft hyphen)
        "reg":    "\u{00AE}",  // ®
        "macr":   "\u{00AF}",  // ¯
        "deg":    "\u{00B0}",  // °
        "plusmn": "\u{00B1}",  // ±
        "sup2":   "\u{00B2}",  // ²
        "sup3":   "\u{00B3}",  // ³
        "acute":  "\u{00B4}",  // ´
        "micro":  "\u{00B5}",  // µ
        "para":   "\u{00B6}",  // ¶
        "middot": "\u{00B7}",  // ·
        "cedil":  "\u{00B8}",  // ¸
        "sup1":   "\u{00B9}",  // ¹
        "ordm":   "\u{00BA}",  // º
        "raquo":  "\u{00BB}",  // »
        "frac14": "\u{00BC}",  // ¼
        "frac12": "\u{00BD}",  // ½
        "frac34": "\u{00BE}",  // ¾
        "iquest": "\u{00BF}",  // ¿
        // Uppercase accented
        "Agrave": "\u{00C0}",  // À
        "Aacute": "\u{00C1}",  // Á
        "Acirc":  "\u{00C2}",  // Â
        "Atilde": "\u{00C3}",  // Ã
        "Auml":   "\u{00C4}",  // Ä
        "Aring":  "\u{00C5}",  // Å
        "AElig":  "\u{00C6}",  // Æ
        "Ccedil": "\u{00C7}",  // Ç
        "Egrave": "\u{00C8}",  // È
        "Eacute": "\u{00C9}",  // É
        "Ecirc":  "\u{00CA}",  // Ê
        "Euml":   "\u{00CB}",  // Ë
        "Igrave": "\u{00CC}",  // Ì
        "Iacute": "\u{00CD}",  // Í
        "Icirc":  "\u{00CE}",  // Î
        "Iuml":   "\u{00CF}",  // Ï
        "ETH":    "\u{00D0}",  // Ð
        "Ntilde": "\u{00D1}",  // Ñ
        "Ograve": "\u{00D2}",  // Ò
        "Oacute": "\u{00D3}",  // Ó
        "Ocirc":  "\u{00D4}",  // Ô
        "Otilde": "\u{00D5}",  // Õ
        "Ouml":   "\u{00D6}",  // Ö
        "times":  "\u{00D7}",  // ×
        "Oslash": "\u{00D8}",  // Ø
        "Ugrave": "\u{00D9}",  // Ù
        "Uacute": "\u{00DA}",  // Ú
        "Ucirc":  "\u{00DB}",  // Û
        "Uuml":   "\u{00DC}",  // Ü
        "Yacute": "\u{00DD}",  // Ý
        "THORN":  "\u{00DE}",  // Þ
        "szlig":  "\u{00DF}",  // ß
        // Lowercase accented
        "agrave": "\u{00E0}",  // à
        "aacute": "\u{00E1}",  // á
        "acirc":  "\u{00E2}",  // â
        "atilde": "\u{00E3}",  // ã
        "auml":   "\u{00E4}",  // ä
        "aring":  "\u{00E5}",  // å
        "aelig":  "\u{00E6}",  // æ
        "ccedil": "\u{00E7}",  // ç
        "egrave": "\u{00E8}",  // è
        "eacute": "\u{00E9}",  // é
        "ecirc":  "\u{00EA}",  // ê
        "euml":   "\u{00EB}",  // ë
        "igrave": "\u{00EC}",  // ì
        "iacute": "\u{00ED}",  // í
        "icirc":  "\u{00EE}",  // î
        "iuml":   "\u{00EF}",  // ï
        "eth":    "\u{00F0}",  // ð
        "ntilde": "\u{00F1}",  // ñ
        "ograve": "\u{00F2}",  // ò
        "oacute": "\u{00F3}",  // ó
        "ocirc":  "\u{00F4}",  // ô
        "otilde": "\u{00F5}",  // õ
        "ouml":   "\u{00F6}",  // ö
        "divide": "\u{00F7}",  // ÷
        "oslash": "\u{00F8}",  // ø
        "ugrave": "\u{00F9}",  // ù
        "uacute": "\u{00FA}",  // ú
        "ucirc":  "\u{00FB}",  // û
        "uuml":   "\u{00FC}",  // ü
        "yacute": "\u{00FD}",  // ý
        "thorn":  "\u{00FE}",  // þ
        "yuml":   "\u{00FF}",  // ÿ

        // MARK: - Latin Extended-A
        "OElig":   "\u{0152}",  // Œ
        "oelig":   "\u{0153}",  // œ
        "Scaron":  "\u{0160}",  // Š
        "scaron":  "\u{0161}",  // š
        "Yuml":    "\u{0178}",  // Ÿ

        // MARK: - Latin Extended-B
        "fnof": "\u{0192}",  // ƒ

        // MARK: - Greek
        "Alpha":   "\u{0391}",
        "Beta":    "\u{0392}",
        "Gamma":   "\u{0393}",
        "Delta":   "\u{0394}",
        "Epsilon": "\u{0395}",
        "Zeta":    "\u{0396}",
        "Eta":     "\u{0397}",
        "Theta":   "\u{0398}",
        "Iota":    "\u{0399}",
        "Kappa":   "\u{039A}",
        "Lambda":  "\u{039B}",
        "Mu":      "\u{039C}",
        "Nu":      "\u{039D}",
        "Xi":      "\u{039E}",
        "Omicron": "\u{039F}",
        "Pi":      "\u{03A0}",
        "Rho":     "\u{03A1}",
        "Sigma":   "\u{03A3}",
        "Tau":     "\u{03A4}",
        "Upsilon": "\u{03A5}",
        "Phi":     "\u{03A6}",
        "Chi":     "\u{03A7}",
        "Psi":     "\u{03A8}",
        "Omega":   "\u{03A9}",
        "alpha":   "\u{03B1}",
        "beta":    "\u{03B2}",
        "gamma":   "\u{03B3}",
        "delta":   "\u{03B4}",
        "epsilon": "\u{03B5}",
        "zeta":    "\u{03B6}",
        "eta":     "\u{03B7}",
        "theta":   "\u{03B8}",
        "iota":    "\u{03B9}",
        "kappa":   "\u{03BA}",
        "lambda":  "\u{03BB}",
        "mu":      "\u{03BC}",
        "nu":      "\u{03BD}",
        "xi":      "\u{03BE}",
        "omicron": "\u{03BF}",
        "pi":      "\u{03C0}",
        "rho":     "\u{03C1}",
        "sigmaf":  "\u{03C2}",
        "sigma":   "\u{03C3}",
        "tau":     "\u{03C4}",
        "upsilon": "\u{03C5}",
        "phi":     "\u{03C6}",
        "chi":     "\u{03C7}",
        "psi":     "\u{03C8}",
        "omega":   "\u{03C9}",
        "thetasym": "\u{03D1}",
        "upsih":   "\u{03D2}",
        "piv":     "\u{03D6}",

        // MARK: - General Punctuation
        "bull":    "\u{2022}",  // •
        "hellip":  "\u{2026}",  // …
        "prime":   "\u{2032}",  // ′
        "Prime":   "\u{2033}",  // ″
        "oline":   "\u{203E}",  // ‾
        "frasl":   "\u{2044}",  // ⁄

        // MARK: - Currency
        "euro":  "\u{20AC}",  // €

        // MARK: - Letterlike Symbols
        "image":  "\u{2111}",  // ℑ
        "weierp": "\u{2118}",  // ℘
        "real":   "\u{211C}",  // ℜ
        "trade":  "\u{2122}",  // ™
        "alefsym": "\u{2135}", // ℵ

        // MARK: - Arrows
        "larr":  "\u{2190}",
        "uarr":  "\u{2191}",
        "rarr":  "\u{2192}",
        "darr":  "\u{2193}",
        "harr":  "\u{2194}",
        "crarr": "\u{21B5}",
        "lArr":  "\u{21D0}",
        "uArr":  "\u{21D1}",
        "rArr":  "\u{21D2}",
        "dArr":  "\u{21D3}",
        "hArr":  "\u{21D4}",

        // MARK: - Mathematical Operators
        "forall":  "\u{2200}",
        "part":    "\u{2202}",
        "exist":   "\u{2203}",
        "empty":   "\u{2205}",
        "nabla":   "\u{2207}",
        "isin":    "\u{2208}",
        "notin":   "\u{2209}",
        "ni":      "\u{220B}",
        "prod":    "\u{220F}",
        "sum":     "\u{2211}",
        "minus":   "\u{2212}",
        "lowast":  "\u{2217}",
        "radic":   "\u{221A}",
        "prop":    "\u{221D}",
        "infin":   "\u{221E}",
        "ang":     "\u{2220}",
        "and":     "\u{2227}",
        "or":      "\u{2228}",
        "cap":     "\u{2229}",
        "cup":     "\u{222A}",
        "int":     "\u{222B}",
        "there4":  "\u{2234}",
        "sim":     "\u{223C}",
        "cong":    "\u{2245}",
        "asymp":   "\u{2248}",
        "ne":      "\u{2260}",
        "equiv":   "\u{2261}",
        "le":      "\u{2264}",
        "ge":      "\u{2265}",
        "sub":     "\u{2282}",
        "sup":     "\u{2283}",
        "nsub":    "\u{2284}",
        "sube":    "\u{2286}",
        "supe":    "\u{2287}",
        "oplus":   "\u{2295}",
        "otimes":  "\u{2297}",
        "perp":    "\u{22A5}",
        "sdot":    "\u{22C5}",

        // MARK: - Miscellaneous Technical
        "lceil":  "\u{2308}",
        "rceil":  "\u{2309}",
        "lfloor": "\u{230A}",
        "rfloor": "\u{230B}",
        "lang":   "\u{2329}",
        "rang":   "\u{232A}",

        // MARK: - Geometric Shapes
        "loz": "\u{25CA}",  // ◊

        // MARK: - Miscellaneous Symbols
        "spades":   "\u{2660}",
        "clubs":    "\u{2663}",
        "hearts":   "\u{2665}",
        "diams":    "\u{2666}",

        // MARK: - Quotes & Dashes (typographic)
        "ensp":   "\u{2002}",
        "emsp":   "\u{2003}",
        "thinsp": "\u{2009}",
        "zwnj":   "\u{200C}",
        "zwj":    "\u{200D}",
        "lrm":    "\u{200E}",
        "rlm":    "\u{200F}",
        "ndash":  "\u{2013}",  // –
        "mdash":  "\u{2014}",  // —
        "lsquo":  "\u{2018}",  // '
        "rsquo":  "\u{2019}",  // '
        "sbquo":  "\u{201A}",  // ‚
        "ldquo":  "\u{201C}",  // "
        "rdquo":  "\u{201D}",  // "
        "bdquo":  "\u{201E}",  // „
        "dagger": "\u{2020}",  // †
        "Dagger": "\u{2021}",  // ‡
        "permil": "\u{2030}",  // ‰
        "lsaquo": "\u{2039}",  // ‹
        "rsaquo": "\u{203A}",  // ›
    ]
}
