import SwiftUI

/// Sheet that shows feed previews from Share Extension pending items.
/// Each feed is fetched, previewed with 3 recent items, and selectable.
struct FeedDiscoverySheet: View {
    @Environment(PendingItemsMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    @State private var feedStates: [String: FeedPreviewState] = [:]  // keyed by feed URL
    @State private var selectedFeeds: Set<String> = []
    @State private var isProcessing = false

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

    private func feedRow(url: String, title: String) -> some View {
        guard let state = feedStates[url] else {
            return AnyView(EmptyView())
        }

        return AnyView(
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
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(.leading, 28)
                }
            }
            .padding(.vertical, 4)
        )
    }

    private func directFeedRow(sourceURL: String) -> some View {
        feedRow(url: sourceURL, title: URL(string: sourceURL)?.host ?? sourceURL)
    }

    private func opmlSection(_ item: PendingItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.blue)
                Text(item.fileName ?? "OPML File")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let count = item.feedCount {
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
        let allURLs = monitor.pendingItems.flatMap { item -> [(String, String)] in
            if item.type == .opmlImport {
                // OPML items show a summary section; their parsed feeds are
                // surfaced as individual feed_direct / feed_discovery items.
                return []
            }
            if item.foundFeeds.isEmpty {
                let title = URL(string: item.sourceURL)?.host ?? item.sourceURL
                return [(item.sourceURL, title)]
            }
            return item.foundFeeds.map { ($0.url, $0.title) }
        }

        // Initialize all states
        for (url, title) in allURLs {
            feedStates[url] = FeedPreviewState(title: title, url: url, status: .loading)
        }

        // Fetch each feed and populate state
        await withTaskGroup(of: (String, FeedPreviewState).self) { group in
            for (url, _) in allURLs {
                group.addTask {
                    await fetchFeedPreview(url: url)
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

    private func fetchFeedPreview(url: String) async -> (String, FeedPreviewState) {
        let existingTitle = feedStates[url]?.title ?? URL(string: url)?.host ?? url

        // Check if already in the registry
        let normalized = OPMLParser.normalizeURL(url)
        let store = monitor.store
        let alreadyAdded = store.registry.sources.contains {
            OPMLParser.normalizeURL($0.url) == normalized
        }
        if alreadyAdded {
            return (url, FeedPreviewState(title: existingTitle, url: url, status: .alreadyAdded))
        }

        // Validate URL
        guard URL(string: url) != nil else {
            return (url, FeedPreviewState(title: existingTitle, url: url, status: .error("Invalid URL")))
        }

        let source = FeedSource(title: existingTitle, url: url, category: "Imported", region: "imported", mediaKind: .text)
        let fetcher = RSSFetcher()
        let result = await fetcher.fetchAll([source], maxConcurrent: 1)

        if let error = result.sourceStatuses[url], error == .failed {
            return (url, FeedPreviewState(title: existingTitle, url: url, status: .error("Couldn't reach feed")))
        }

        let feedItems = result.items.filter { $0.sourceURL == url }
        if feedItems.isEmpty {
            return (url, FeedPreviewState(title: existingTitle, url: url, status: .empty))
        }

        // Use the feed's declared title if available
        let resolvedTitle = feedItems.first?.sourceTitle ?? existingTitle
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
