import SwiftUI
import GRDB

struct SettingsSheetView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(LocaleManager.self) private var localeManager
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = true
    @AppStorage("prefetchImages") private var prefetchImages = true
    @AppStorage("nightMode") private var nightMode = false
    @AppStorage("filterAutoExpire") private var filterAutoExpire = false
    @AppStorage("fontSize") private var fontSize = FontSize.medium.rawValue
    @AppStorage("circadianPaletteOn") private var circadianPaletteOn = true
    @AppStorage("paletteFamily") private var paletteFamilyRaw = PaletteFamily.warmEarth.rawValue
    @AppStorage("circadianTypographyOn") private var circadianTypographyOn = true
    @AppStorage("fontStyle") private var fontStyleRaw = FontStyle.system.rawValue

    @State private var showClearReadConfirmation = false
    @State private var showClearBookmarksConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showPalettePicker = false
    @State private var showFontStylePicker = false
    @State private var showRestartAlert = false

    // MARK: - Download settings
    @State private var downloadMode: DownloadMode = .wifi
    @State private var storageLimitOption = 2  // 2 GB default (index 2)
    @State private var autoDeleteOption = 0    // After read default (index 0)
    @State private var activeRules: [DownloadRuleRecord] = []
    @State private var freeSpaceBytes: Int64 = 0

    private var topCategory: String? {
        let readItems = loader.items.filter { loader.isRead($0.id) }
        let grouped = Dictionary(grouping: readItems, by: \.category)
        return grouped.max(by: { $0.value.count < $1.value.count })?.key
    }

    enum FontSize: String, CaseIterable { case small, medium, large }

    private var selectedPalette: PaletteFamily {
        PaletteFamily(rawValue: paletteFamilyRaw) ?? .warmEarth
    }

    private var selectedFontStyle: FontStyle {
        FontStyle(rawValue: fontStyleRaw) ?? .system
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Appearance
                Section("Appearance") {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Picker("", selection: $fontSize) {
                            Text("Small").tag(FontSize.small.rawValue)
                            Text("Medium").tag(FontSize.medium.rawValue)
                            Text("Large").tag(FontSize.large.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                }

                // MARK: - Language
                Section {
                    NavigationLink {
                        languagePickerView
                    } label: {
                        HStack {
                            Text("Language")
                            Spacer()
                            Text(localeManager.selectedLanguage.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("Changing the language requires restarting the app.")
                }

                // MARK: - Circadian Design
                Section {
                    Toggle("Adaptive Palette", systemImage: "paintpalette.fill", isOn: $circadianPaletteOn)
                        .tint(CircadianEngine.shared.accent)

                    if circadianPaletteOn {
                        Button {
                            showPalettePicker = true
                        } label: {
                            HStack {
                                Text("Palette Family")
                                Spacer()
                                Text(selectedPalette.label)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Toggle("Adaptive Typography", systemImage: "textformat.size", isOn: $circadianTypographyOn)
                        .tint(CircadianEngine.shared.accent)

                    Button {
                        showFontStylePicker = true
                    } label: {
                        HStack {
                            Text("Font Style")
                            Spacer()
                            Text(selectedFontStyle.label)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("Circadian Design")
                } footer: {
                    if circadianPaletteOn {
                        Text("Colors and typography shift subtly with the time of day. ")
                            + Text("\(CircadianEngine.shared.period.emoji) \(CircadianEngine.shared.period.label) now")
                            .foregroundStyle(CircadianEngine.shared.accent)
                    }
                }

                // MARK: - Performance
                Section("Performance") {
                    Toggle("Preload Images", systemImage: "photo.stack.fill", isOn: $prefetchImages)
                        .tint(.blue)
                }

                // MARK: - Downloads
                Section {
                    Picker("Prefer", selection: $downloadMode) {
                        Text("WiFi only").tag(DownloadMode.wifi)
                        Text("WiFi + Cellular").tag(DownloadMode.cellular)
                    }

                    Picker("Storage limit", selection: $storageLimitOption) {
                        Text("500 MB").tag(0)
                        Text("1 GB").tag(1)
                        Text("2 GB").tag(2)
                        Text("5 GB").tag(3)
                    }

                    Picker("Auto-delete", selection: $autoDeleteOption) {
                        Text("After read").tag(0)
                        Text("After 7 days").tag(1)
                        Text("Manual").tag(2)
                    }
                } header: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                } footer: {
                    Text("Free space: \(formattedFreeSpace) — Safe floor: 200 MB")
                }

                if !activeRules.isEmpty {
                    Section("Active rules") {
                        ForEach(activeRules, id: \.id) { rule in
                            HStack {
                                Text(ruleLabel(for: rule))
                                Spacer()
                                Text("\(rule.maxItems) ep")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Night Mode", systemImage: "moon.stars.fill", isOn: $nightMode)
                        .tint(.orange)
                    Toggle("Auto-clear Filters", systemImage: "clock.arrow.2.circlepath", isOn: $filterAutoExpire)
                        .tint(.blue)
                    NavigationLink {
                        ContentFilterView()
                    } label: {
                        HStack {
                            Label("Content Filters", systemImage: "eye.slash.fill")
                            Spacer()
                            let count = ContentFilterStore.shared.filters.filter(\.isEnabled).count
                            if count > 0 {
                                Text("\(count) active")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Reading")
                } footer: {
                    if filterAutoExpire {
                        Text("Category, mood, and content type filters reset after 4 hours away so you never open to an empty feed.")
                    }
                }

                // MARK: - Reading Data
                Section("Reading Data") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(loader.readItemIDs.count) articles read").font(.subheadline)
                            Text("\(loader.bookmarkedIDs.count) bookmarks")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Button(role: .destructive) {
                        showClearReadConfirmation = true
                    } label: {
                        Label("Clear Read History", systemImage: "eye.slash")
                    }
                    .disabled(loader.readItemIDs.isEmpty)
                    .confirmationDialog("Clear all read history?", isPresented: $showClearReadConfirmation) {
                        Button("Clear All", role: .destructive) {
                            loader.clearReadHistory()
                        }
                    }

                    Button(role: .destructive) {
                        showClearBookmarksConfirmation = true
                    } label: {
                        Label("Clear All Bookmarks", systemImage: "bookmark.slash")
                    }
                    .disabled(loader.bookmarkedIDs.isEmpty)
                    .confirmationDialog("Remove all bookmarks?", isPresented: $showClearBookmarksConfirmation) {
                        Button("Clear All", role: .destructive) {
                            loader.clearAllBookmarks()
                        }
                    }
                }

                // MARK: - Data Management
                Section("Storage") {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset All Data", systemImage: "trash")
                    }
                    .confirmationDialog(
                        "This will delete all bookmarks, read history, and source configuration. This cannot be undone.",
                        isPresented: $showResetConfirmation
                    ) {
                        Button("Reset Everything", role: .destructive) {
                            loader.clearReadHistory()
                            loader.clearAllBookmarks()
                            Settings.filterRegion = nil
                            Settings.filterTaxonomyNodes = []
                            Settings.filterContentType = FeedLoader.ContentType.all.rawValue
                            Settings.filterLanguages = []
                            Settings.filterMood = FeedLoader.MoodFilter.all.rawValue
                            Settings.filterDownloaded = false
                            Settings.filterSetAt = 0
                            Settings.hasInitializedLanguageDefault = false
                            Settings.hasInitializedSourceDefaults = false
                            Settings.activePreset = .everything
                        }
                    }

                    if let date = loader.lastRefreshDate {
                        HStack {
                            Text("Last saved")
                            Spacer()
                            Text(date, style: .relative).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }

                // MARK: - Share Stats
                Section {
                    Button {
                        let topCat = topCategory ?? "None"
                        if let image = renderStatsCard(
                            readCount: loader.readItemIDs.count,
                            bookmarkCount: loader.bookmarkedIDs.count,
                            streakCount: 1,
                            topCategory: topCat,
                            sourceCount: loader.sourceCount
                        ) {
                            let av = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let root = windowScene.windows.first?.rootViewController {
                                root.present(av, animated: true)
                            }
                        }
                    } label: {
                        Label("Share My Stats", systemImage: "chart.bar.fill")
                    }
                } header: { Text("Share") }

                // MARK: - About
                Section("About") {
                    HStack {
                        Text("Version"); Spacer()
                        Text("1.0 (Prototype)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Sources"); Spacer()
                        Text("\(loader.sourceCount) feeds · \(loader.opmlFileCount) files").foregroundStyle(.secondary)
                    }
                    Button {
                        hasSeenOnboarding = false
                    } label: {
                        Label("Re-watch Intro", systemImage: "sparkles")
                    }
                }

                Section {
                    Link(destination: URL(string: "mailto:wmontes@gmail.com?subject=Feedmine%20Feedback") ?? URL(string: "mailto:feedback@example.com")!) {
                        Label("Send Feedback", systemImage: "envelope.fill")
                    }
                    Link(destination: URL(string: "https://github.com/nmdias/FeedKit") ?? URL(string: "https://github.com")!) {
                        Label("FeedKit on GitHub", systemImage: "link")
                    }
                } header: { Text("Feedback") } footer: {
                    Text("Feedmine is an independent, open-source RSS reader. No algorithms, no ads, no accounts — just stories from around the world, on your terms.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPalettePicker) {
                palettePickerSheet
            }
            .sheet(isPresented: $showFontStylePicker) {
                fontStylePickerSheet
            }
            .alert(String(localized: "Restart Required", comment: "Language change alert title"),
                   isPresented: $showRestartAlert) {
                Button(String(localized: "OK", comment: "Dismiss alert")) { }
            } message: {
                Text("Please restart FeedMine to apply the new language.")
            }
            .task {
                await loadSettings()
            }
            .onChange(of: storageLimitOption) { _, opt in
                let limits: [Int64] = [500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000]
                Task { await DownloadManager.shared.storageLimit = limits[opt] }
            }
            .onChange(of: autoDeleteOption) { _, opt in
                let policies: [AutoDeletePolicy] = [.afterRead, .after7Days, .manual]
                Task { await DownloadManager.shared.autoDelete = policies[opt] }
            }
            .onChange(of: downloadMode) { _, mode in
                Task { await DownloadManager.shared.mode = mode }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Palette Picker Sheet

    private var palettePickerSheet: some View {
        NavigationStack {
            List {
                ForEach(PaletteFamily.allCases, id: \.rawValue) { family in
                    Button {
                        paletteFamilyRaw = family.rawValue
                        showPalettePicker = false
                    } label: {
                        HStack(spacing: 12) {
                            // Color swatches
                            HStack(spacing: 3) {
                                ForEach(CircadianPeriod.allCases, id: \.rawValue) { period in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(family.accent(for: period))
                                        .frame(width: 10, height: 24)
                                }
                            }
                            VStack(alignment: .leading) {
                                Text(family.label)
                                    .foregroundStyle(.primary)
                                Text(family.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if family == selectedPalette {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(CircadianEngine.shared.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Palette Family")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showPalettePicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Font Style Picker Sheet

    private var fontStylePickerSheet: some View {
        NavigationStack {
            List {
                ForEach(FontStyle.allCases, id: \.rawValue) { style in
                    Button {
                        fontStyleRaw = style.rawValue
                        showFontStylePicker = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(style.label)
                                    .font(style == .newYork
                                        ? .custom("New York", size: 17)
                                        : style == .sfMono
                                            ? .system(size: 17, design: .monospaced)
                                            : .system(size: 17))
                                    .foregroundStyle(.primary)
                                Text(styleDescription(style))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if style == selectedFontStyle {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(CircadianEngine.shared.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Font Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showFontStylePicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func styleDescription(_ style: FontStyle) -> String {
        switch style {
        case .system: return "San Francisco — weight shifts with time of day"
        case .newYork: return "New York — serif editorial, fixed"
        case .sfMono: return "SF Mono — technical, fixed"
        case .georgia: return "Georgia — serif headlines, SF body"
        }
    }

    // MARK: - Download Settings Helpers

    private var formattedFreeSpace: String {
        ByteCountFormatter.string(fromByteCount: freeSpaceBytes, countStyle: .file)
    }

    private func loadSettings() async {
        let manager = DownloadManager.shared
        downloadMode = await manager.mode
        let limits: [Int64] = [500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000]
        storageLimitOption = limits.firstIndex(of: await manager.storageLimit) ?? 2
        let policies: [AutoDeletePolicy] = [.afterRead, .after7Days, .manual]
        autoDeleteOption = policies.firstIndex(of: await manager.autoDelete) ?? 0
        freeSpaceBytes = await manager.freeDiskSpace()
        do {
            let db = await FeedStore.sharedDB()
            activeRules = try await db.read { db in
                try DownloadRuleRecord.filter(Column("enabled") == true).fetchAll(db)
            }
        } catch {
            activeRules = []
        }
    }

    private func ruleLabel(for rule: DownloadRuleRecord) -> String {
        switch rule.targetType {
        case "source": return "Source feed"
        case "collection": return "Collection"
        default: return "Rule"
        }
    }

    // MARK: - Language Picker

    private var languagePickerView: some View {
        List {
            ForEach(LocaleManager.supportedLanguages) { language in
                Button {
                    if language.code != localeManager.selectedLanguage.code {
                        localeManager.selectLanguage(language)
                        showRestartAlert = true
                    }
                } label: {
                    HStack {
                        Text(language.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(language.code)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if language.code == localeManager.selectedLanguage.code {
                            Image(systemName: "checkmark")
                                .foregroundStyle(CircadianEngine.shared.accent)
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Language", comment: "Language picker title"))
    }
}

// MARK: - Public helpers for font size

extension SettingsSheetView.FontSize {
    var titleSize: Font {
        switch self {
        case .small: return .subheadline
        case .medium: return .headline
        case .large: return .title3
        }
    }

    var bodySize: Font {
        switch self {
        case .small: return .caption
        case .medium: return .subheadline
        case .large: return .body
        }
    }
}
