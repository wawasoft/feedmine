import SwiftUI

/// Sheet that shows feed previews from Share Extension pending items.
/// Each feed is fetched, previewed with 3 recent items, and selectable.
struct FeedDiscoverySheet: View {
    @Environment(PendingItemsMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    @State private var feedStates: [String: FeedPreviewState] = [:]  // keyed by feed URL
    @State private var selectedFeeds: Set<String> = []
    @State private var isProcessing = false
    /// Parsed OPML feeds keyed by pending item ID.
    @State private var parsedOpmlFeeds: [String: [PendingItem.DiscoveredFeed]] = [:]

    struct FeedPreviewState {
        let title: String
        let url: String
        var status: Status
        var recentItems: [FeedItem] = []

        enum Status: Equatable {
            case loading
            case loaded
            case alreadyAdded
            case error(String)
            case empty
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isProcessing {
                    processingView
                } else if feedStates.isEmpty {
                    loadingView
                } else {
                    feedList
                }
            }
            .navigationTitle("New Feeds Found")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        monitor.processSkipped()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selectedFeeds.count))") {
                        confirmImport()
                    }
                    .disabled(selectedFeeds.isEmpty || isProcessing)
                    .fontWeight(.semibold)
                }
            }
        }
        .task {
            await loadAllFeeds()
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Fetching feed previews...")
                .foregroundStyle(.secondary)
        }
    }

    private var processingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Adding feeds...")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Feed list

    private var feedList: some View {
        List {
            ForEach(monitor.pendingItems) { pendingItem in
                Section {
                    if pendingItem.type == .opmlImport {
                        opmlSection(pendingItem)
                        if let opmlFeeds = parsedOpmlFeeds[pendingItem.id], !opmlFeeds.isEmpty {
                            ForEach(opmlFeeds, id: \.url) { feed in
                                feedRow(url: feed.url, title: feed.title)
                            }
                        }
                    } else if pendingItem.foundFeeds.isEmpty {
                        directFeedRow(sourceURL: pendingItem.sourceURL)
                    } else {
                        ForEach(pendingItem.foundFeeds, id: \.url) { discovered in
                            feedRow(url: discovered.url, title: discovered.title)
                        }
                    }
                } header: {
                    Text(pendingItem.sourceURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Feed row

    @ViewBuilder
    private func feedRow(url: String, title: String) -> some View {
        if let state = feedStates[url] {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle(isOn: Binding(
                        get: { selectedFeeds.contains(url) },
                        set: { isOn in
                            if isOn { selectedFeeds.insert(url) }
                            else { selectedFeeds.remove(url) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.title)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .toggleStyle(.automatic)
                    .disabled(state.status == .alreadyAdded)
                }

                switch state.status {
                case .loading:
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .loaded:
                    if !state.recentItems.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(state.recentItems.count) recent articles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(state.recentItems.prefix(3)) { item in
                                Text("• \(item.title)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.leading, 28)
                    } else {
                        Text("No recent items — will be added anyway")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 28)
                    }

                case .empty:
                    Text("No recent items — will be added anyway")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)

                case .alreadyAdded:
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Already in Feedmine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 28)

                case .error(let message):
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button("Retry") {
                                Task {
                                    feedStates[url]?.status = .loading
                                    let (_, newState) = await fetchFeedPreview(url: url, title: state.title, isAlreadyAdded: false)
                                    feedStates[url] = newState
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }
                    }
                    .padding(.leading, 28)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func directFeedRow(sourceURL: String) -> some View {
        feedRow(url: sourceURL, title: URL(string: sourceURL)?.host ?? sourceURL)
    }

    private func opmlSection(_ item: PendingItem) -> some View {
        let feedCount = parsedOpmlFeeds[item.id]?.count ?? item.feedCount
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.blue)
                Text(item.fileName ?? "OPML File")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let count = feedCount {
                    Text("\(count) feeds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Feeds from this file will be processed after adding.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Load all feeds

    private func loadAllFeeds() async {
        // Step 1: Collect all URLs on the MainActor, including parsing OPML files.
        var allURLs: [(String, String)] = []
        for item in monitor.pendingItems {
            if item.type == .opmlImport {
                // Parse the OPML file to surface its feeds for preview.
                guard let fileURL = URL(string: item.sourceURL),
                      FileManager.default.fileExists(atPath: fileURL.path) else {
                    continue
                }
                do {
                    let feeds = try OPMLParser.parseImportedFile(url: fileURL)
                    let discovered = feeds.map { PendingItem.DiscoveredFeed(title: $0.title, url: $0.url) }
                    parsedOpmlFeeds[item.id] = discovered
                    allURLs.append(contentsOf: feeds.map { ($0.url, $0.title) })
                } catch {
                    print("[FeedDiscoverySheet] Failed to parse OPML: \(error)")
                }
            } else if item.foundFeeds.isEmpty {
                let title = URL(string: item.sourceURL)?.host ?? item.sourceURL
                allURLs.append((item.sourceURL, title))
            } else {
                allURLs.append(contentsOf: item.foundFeeds.map { ($0.url, $0.title) })
            }
        }

        // Step 2: Check registry once on the MainActor.
        let registrySources = monitor.store.registry.sources
        let alreadyAddedSet = Set(registrySources.map { OPMLParser.normalizeURL($0.url) })

        // Step 3: Initialize feedStates on the MainActor.
        for (url, title) in allURLs {
            feedStates[url] = FeedPreviewState(title: title, url: url, status: .loading)
        }

        // Step 4: Fetch each feed in child tasks — no @MainActor access inside.
        await withTaskGroup(of: (String, FeedPreviewState).self) { group in
            for (url, title) in allURLs {
                let isAlreadyAdded = alreadyAddedSet.contains(OPMLParser.normalizeURL(url))
                group.addTask {
                    await fetchFeedPreview(url: url, title: title, isAlreadyAdded: isAlreadyAdded)
                }
            }
            for await (url, state) in group {
                feedStates[url] = state
                // Pre-select all successfully loaded/empty feeds
                if case .loaded = state.status { selectedFeeds.insert(url) }
                if case .empty = state.status { selectedFeeds.insert(url) }
            }
        }
    }

    /// Pure fetch function — does NOT access `self`, `feedStates`, or `monitor`.
    /// All `@MainActor` values are pre-computed and passed in.
    private func fetchFeedPreview(url: String, title: String, isAlreadyAdded: Bool) async -> (String, FeedPreviewState) {
        if isAlreadyAdded {
            return (url, FeedPreviewState(title: title, url: url, status: .alreadyAdded))
        }

        // Validate URL
        guard URL(string: url) != nil else {
            return (url, FeedPreviewState(title: title, url: url, status: .error("Invalid URL")))
        }

        let source = FeedSource(title: title, url: url, category: "Imported", region: "imported", mediaKind: .text)
        let fetcher = RSSFetcher()
        let result = await fetcher.fetchAll([source], maxConcurrent: 1)

        if let error = result.sourceStatuses[url], error == .failed {
            return (url, FeedPreviewState(title: title, url: url, status: .error("Couldn't reach feed")))
        }

        let feedItems = result.items.filter { $0.sourceURL == url }
        if feedItems.isEmpty {
            return (url, FeedPreviewState(title: title, url: url, status: .empty))
        }

        // Use the feed's declared title if available
        let resolvedTitle = feedItems.first?.sourceTitle ?? title
        return (url, FeedPreviewState(
            title: resolvedTitle,
            url: url,
            status: .loaded,
            recentItems: Array(feedItems.prefix(10))
        ))
    }

    // MARK: - Confirmation

    private func confirmImport() {
        isProcessing = true

        let newSources = selectedFeeds.compactMap { url -> FeedSource? in
            guard let state = feedStates[url] else { return nil }
            return FeedSource(
                title: state.title,
                url: url,
                category: "Imported",
                region: "imported",
                mediaKind: mediaKind(for: url)
            )
        }

        monitor.processConfirmed(newSources)
        dismiss()
    }

    private func mediaKind(for url: String) -> MediaKind {
        let lower = url.lowercased()
        if lower.contains("podcast") || lower.contains("anchor.fm")
            || lower.contains("spreaker.com") || lower.contains("feeds.simplecast.com")
            || lower.contains("feeds.transistor.fm") || lower.contains("feeds.buzzsprout.com")
            || lower.contains("media.rss.com") {
            return .audio
        }
        if lower.contains("youtube.com/feeds") { return .video }
        return .text
    }
}
