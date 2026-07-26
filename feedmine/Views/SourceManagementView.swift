import SwiftUI
import UniformTypeIdentifiers
import GRDB

struct SourceManagementView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var isTesting = false
    /// Keyed by source URL (not title) — many feeds share a title, which would
    /// collide and overwrite each other's result. Title is carried in the value
    /// for display.
    @State private var testResults: [String: TestResult] = [:]
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var pendingCategoryIDs = Set<String>()
    @State private var enabledPendingCategoryIDs = Set<String>()

    struct TestResult {
        let title: String
        var status: SourceStatus
    }

    enum SourceStatus {
        case ok, failed, testing
        var icon: String {
            switch self { case .ok: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"; case .testing: "circle.dashed" }
        }
        var color: Color {
            switch self { case .ok: .green; case .failed: .red; case .testing: .gray }
        }
        var label: String {
            switch self { case .ok: "OK"; case .failed: "Failed"; case .testing: "Testing..." }
        }
    }

    private var sourcesByCategory: [(String, [FeedSource])] {
        let grouped = Dictionary(grouping: loader.sources, by: \.category)
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            List {
                if loader.sources.isEmpty {
                    ContentUnavailableView(
                        "No Sources",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Add .opml files to Resources/Feeds/ to populate sources.")
                    )
                }

                // Category toggles
                Section("Categories") {
                    ForEach(sourcesByCategory, id: \.0) { category, sources in
                        HStack {
                            Label("\(category) (\(sources.count))", systemImage: categoryIcon(category))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: {
                                    pendingCategoryIDs.contains(category)
                                        ? enabledPendingCategoryIDs.contains(category)
                                        : loader.isCategoryEnabled(category)
                                },
                                set: { setCategory(category, enabled: $0) }
                            ))
                            .labelsHidden()
                            .tint(.green)
                        }
                    }
                }

                ForEach(sourcesByCategory, id: \.0) { category, sources in
                    Section {
                        ForEach(sources, id: \.url) { source in
                            NavigationLink(destination: SourceDetailView(source: source, loader: loader)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(source.title)
                                                .font(.subheadline)
                                            let health = loader.healthFor(source)
                                            if health.isStale {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                            if health.consecutiveFailures > 0 {
                                                Text("\(health.consecutiveFailures) fails")
                                                    .font(.caption2)
                                                    .foregroundStyle(.red)
                                            }
                                        }
                                        Text(source.url)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Toggle("", isOn: Binding(
                                        get: { loader.isSourceEnabled(source.url) },
                                        set: { _ in
                                            loader.toggleSource(source.url)
                                        }
                                    ))
                                    .labelsHidden()
                                    .tint(.green)
                                }
                            }
                        }
                    } header: {
                        Label(category, systemImage: categoryIcon(category))
                            .font(.subheadline)
                    }
                }

                Section {
                    HStack {
                        Text("Enabled")
                        Spacer()
                        Text("\(loader.enabledSources.count) of \(loader.sources.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Disabled")
                        Spacer()
                        Text("\(loader.disabledSourceIDs.count)")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Disabled sources are skipped during feed fetching. Changes take effect on next refresh.")
                }

                Section {
                    Button {
                        Task { await testSources() }
                    } label: {
                        HStack {
                            Label("Test All Sources", systemImage: "checkmark.circle")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)

                    if !testResults.isEmpty {
                        ForEach(testResults.sorted(by: { $0.value.title < $1.value.title }), id: \.key) { _, result in
                            HStack {
                                Image(systemName: result.status.icon)
                                    .font(.caption)
                                    .foregroundStyle(result.status.color)
                                Text(result.title)
                                    .font(.caption)
                                Spacer()
                                Text(result.status.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Health Check")
                } footer: {
                    if !testResults.isEmpty {
                        let ok = testResults.values.filter { $0.status == .ok }.count
                        Text("\(ok)/\(testResults.count) sources responding")
                    }
                }

                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import OPML File", systemImage: "doc.badge.plus")
                    }
                    if let error = importError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    NavigationLink {
                        ExportView()
                    } label: {
                        Label("Export Sources", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Import & Export")
                } footer: {
                    Text("Import an OPML file or export in multiple formats (OPML, CSV, Markdown, HTML, JSON).")
                }
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.xml, UTType(filenameExtension: "opml") ?? .xml]) { result in
            switch result {
            case .success(let url):
                do {
                    let newSources = try OPMLParser.parseImportedFile(url: url)
                    loader.addSources(newSources)
                    importError = nil
                } catch {
                    importError = "Failed to parse: \(error.localizedDescription)"
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private func setCategory(_ category: String, enabled: Bool) {
        pendingCategoryIDs.insert(category)
        if enabled {
            enabledPendingCategoryIDs.insert(category)
        } else {
            enabledPendingCategoryIDs.remove(category)
        }
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()

        DispatchQueue.main.async {
            guard pendingCategoryIDs.contains(category), enabledPendingCategoryIDs.contains(category) == enabled else { return }
            loader.setCategoryEnabled(category, enabled: enabled)
            if enabledPendingCategoryIDs.contains(category) == enabled {
                pendingCategoryIDs.remove(category)
            }
        }
    }

    private func testSources() async {
        isTesting = true
        testResults = [:]

        for source in loader.sources {
            testResults[source.url] = TestResult(title: source.title, status: .testing)
        }

        // Bound concurrency with a sliding window. loader.sources can hold
        // thousands of feeds; firing that many simultaneous URLSession requests
        // exhausts the connection pool and produces mass false failures. Keep
        // at most `cap` in flight, refilling each slot as it completes.
        let cap = 10
        await withTaskGroup(of: (String, SourceStatus).self) { group in
            var iterator = loader.sources.makeIterator()
            var started = 0
            while started < cap, let source = iterator.next() {
                group.addTask { await Self.testSource(source) }
                started += 1
            }
            while let (url, status) = await group.next() {
                testResults[url]?.status = status
                if let source = iterator.next() {
                    group.addTask { await Self.testSource(source) }
                }
            }
        }

        isTesting = false
    }

    private static func testSource(_ source: FeedSource) async -> (String, SourceStatus) {
        guard let url = URL(string: source.url) else {
            return (source.url, .failed)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("FeedminePrototype/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return (source.url, .ok)
            }
            return (source.url, .failed)
        } catch {
            return (source.url, .failed)
        }
    }

    private func categoryIcon(_ category: String) -> String {
        switch category.lowercased() {
        case "tech": return "laptopcomputer"
        case "news": return "newspaper.fill"
        case "science": return "flask.fill"
        case "design": return "paintpalette.fill"
        case "culture": return "theatermasks.fill"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Source Detail View

struct SourceDetailView: View {
    let source: FeedSource
    let loader: FeedLoader

    @State private var autoDownloadEnabled = false
    @State private var maxEpisodes = 3
    @State private var downloadMode: DownloadMode = .wifi
    @State private var ruleError: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.title)
                        .font(.headline)
                    Text(source.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if DownloadManager.isEnabled {
                Section {
                    Toggle(isOn: $autoDownloadEnabled) {
                        Label("Auto-download", systemImage: "arrow.down.circle")
                        Text("New episodes automatically")
                    }

                    if autoDownloadEnabled {
                        Picker("Keep latest", selection: $maxEpisodes) {
                            Text("1 episode").tag(1)
                            Text("3 episodes").tag(3)
                            Text("5 episodes").tag(5)
                            Text("10 episodes").tag(10)
                            Text("All").tag(0)
                        }

                        Picker("On", selection: $downloadMode) {
                            Text("WiFi only").tag(DownloadMode.wifi)
                            Text("WiFi + Cellular").tag(DownloadMode.cellular)
                        }
                    }
                } header: {
                    Text("Downloads")
            }
            }  // if DownloadManager.isEnabled
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRule() }
        .onChange(of: autoDownloadEnabled) { _, _ in Task { await saveRule() } }
        .onChange(of: maxEpisodes) { _, _ in Task { await saveRule() } }
        .onChange(of: downloadMode) { _, _ in Task { await saveRule() } }
    }

    @MainActor
    private func loadRule() async {
        let db = await FeedStore.sharedDB()
        do {
            let rule = try await db.read { db in
                try DownloadRuleRecord
                    .filter(Column("target_type") == "source" && Column("target_id") == source.url)
                    .fetchOne(db)
            }
            if let rule {
                autoDownloadEnabled = rule.enabled
                maxEpisodes = rule.maxItems
                downloadMode = DownloadMode(rawValue: rule.mode) ?? .wifi
            }
            ruleError = nil
        } catch {
            Log.feed.error("Failed to load download rule for \(source.url): \(error.localizedDescription)")
            ruleError = "Could not load download settings"
        }
    }

    @MainActor
    private func saveRule() async {
        let db = await FeedStore.sharedDB()
        do {
            if autoDownloadEnabled {
                try await db.write { db in
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO download_rule (target_type, target_id, max_items, mode, enabled)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: ["source", source.url, maxEpisodes, downloadMode.rawValue, true])
                }
            } else {
                try await db.write { db in
                    try db.execute(sql: "DELETE FROM download_rule WHERE target_type = 'source' AND target_id = ?",
                                  arguments: [source.url])
                }
            }
            ruleError = nil
        } catch {
            Log.feed.error("Failed to save download rule for \(source.url): \(error.localizedDescription)")
            ruleError = "Could not save download settings"
        }
    }
}
