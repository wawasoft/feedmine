import SwiftUI

struct DebugStatusBar: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        VStack(spacing: 1) {
            // Line 1: Pipeline stats
            HStack(spacing: 0) {
                Text("\(loader.items.count) shown")
                Text(" · ")
                Text("\(loader.reservoirCount) queued")
                Text(" · ")
                Text("\(loader.enabledSources.count)/\(loader.sourceCount) sources")
                Text(" · ")
                Text("\(loader.totalFetched) fetched")
                Text(" · ")
                Text("\(loader.loadedIDsCount) uniq")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)

            // Line 2: Errors + status
            HStack(spacing: 0) {
                if loader.totalDiscarded > 0 {
                    Text("\(loader.totalDiscarded) discarded")
                    Text(" · ")
                }
                if loader.fetchErrorCount > 0 {
                    Text("\(loader.fetchErrorCount) fetch err")
                        .foregroundStyle(loader.fetchErrorCount > 0 ? .orange : .secondary)
                    Text(" · ")
                }
                if loader.opmlErrorCount > 0 {
                    Text("\(loader.opmlErrorCount) OPML err")
                        .foregroundStyle(.red)
                    Text(" · ")
                }
                if loader.duplicateSourceCount > 0 {
                    Text("\(loader.duplicateSourceCount) src dup")
                        .foregroundStyle(.secondary)
                    Text(" · ")
                }
                Text(loader.catalogDiagnosticsStatus.compactLabel)
                    .foregroundStyle(loader.catalogDiagnosticsStatus.phase == .failed ? .red : .secondary)
                Text(" · ")
                statusIndicator
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch loader.loadingState {
        case .idle:
            Text("✓ idle").foregroundStyle(.green)
        case .initial:
            Text("⏳ loading").foregroundStyle(.blue)
        case .refreshing:
            Text("⟳ refreshing").foregroundStyle(.blue)
        case .loadingMore:
            Text("↓ more").foregroundStyle(.blue)
        }
    }
}
