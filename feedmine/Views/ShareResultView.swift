import SwiftUI

/// Post-detection sheet: loading → result → destination picker.
/// Shows detection progress, then the result (single feed, multiple feeds,
/// OPML sources, or an error/empty state).
struct ShareResultView: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        NavigationStack {
            Group {
                if loader.isDetecting {
                    detectionProgress
                } else if let result = loader.detectedResult {
                    resultContent(result)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Feed Detected")
        }
    }

    // MARK: - Loading

    private var detectionProgress: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Checking for feeds...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView(
            "No Result",
            systemImage: "magnifyingglass",
            description: Text("No feed information available")
        )
    }

    // MARK: - Result

    @ViewBuilder
    private func resultContent(_ result: FeedDetector.DetectionResult) -> some View {
        switch result {
        case .feed(let source):
            feedResultView(source)
        case .multipleFeeds(let sources):
            multipleFeedsView(sources)
        case .opml(let sources):
            opmlResultView(sources)
        case .noFeedFound:
            ContentUnavailableView(
                "No Feeds Found",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Could not find any RSS, Atom, or podcast feeds at this URL.")
            )
        case .error(let message):
            ContentUnavailableView(
                "Detection Error",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    // MARK: - Single Feed

    private func feedResultView(_ source: FeedSource) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label(source.title, systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)
                    Text(source.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Multiple Feeds

    private func multipleFeedsView(_ sources: [FeedSource]) -> some View {
        List(sources, id: \.url) { source in
            VStack(alignment: .leading, spacing: 4) {
                Label(source.title, systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Text(source.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - OPML

    private func opmlResultView(_ sources: [FeedSource]) -> some View {
        List(sources, id: \.url) { source in
            VStack(alignment: .leading, spacing: 4) {
                Label(source.title, systemImage: "doc.text")
                    .font(.headline)
                Text(source.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
