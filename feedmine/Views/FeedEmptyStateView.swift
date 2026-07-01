import SwiftUI

struct FeedEmptyStateView: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(Color(.systemGray6))
                    .frame(width: 100, height: 100)

                Image(systemName: iconName)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }

            // Title
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            // Description
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Action buttons
            if showActions {
                VStack(spacing: 12) {
                    Button {
                        Task { await loader.refresh() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh Now")
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if loader.disabledSourceIDs.count > 0 {
                        Text("Tip: \(loader.disabledSourceIDs.count) source\(loader.disabledSourceIDs.count == 1 ? " is" : "s are") disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.top, 40)
    }

    private var iconName: String {
        if loader.loadingState == .initial {
            return "antenna.radiowaves.left.and.right"
        } else if loader.fetchErrorCount > 0 && loader.totalFetched == 0 {
            return "wifi.slash"
        } else if loader.sources.isEmpty {
            return "folder.badge.questionmark"
        } else {
            return "newspaper.fill"
        }
    }

    private var title: String {
        if loader.loadingState == .initial {
            return "Loading your feed..."
        } else if loader.fetchErrorCount > 0 && loader.totalFetched == 0 {
            return "Couldn't load feeds"
        } else if loader.sources.isEmpty {
            return "No sources found"
        } else {
            return "No articles yet"
        }
    }

    private var description: String {
        if loader.loadingState == .initial {
            return "Fetching articles from \(loader.sourceCount) sources."
        } else if loader.fetchErrorCount > 0 && loader.totalFetched == 0 {
            return "All \(loader.fetchErrorCount) sources failed to load. Check your internet connection and pull to refresh."
        } else if loader.sources.isEmpty {
            return "Add .opml files to the Resources/Feeds folder in Xcode and rebuild the app."
        } else {
            return "Articles will appear here as they're published. Pull to refresh or check back later."
        }
    }

    private var showActions: Bool {
        loader.loadingState != .initial
    }
}
