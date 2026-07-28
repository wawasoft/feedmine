import SwiftUI
import UIKit

/// Non-reactive impression counter — mutated on every card `.onAppear`
/// without triggering SwiftUI body re-evaluation.
private final class ImpressionTracker {
    var seen = Set<String>()
    var count: Int { seen.count }
    func mark(_ id: String) { seen.insert(id) }
}

struct FeedScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(FeedLoader.self) private var loader
    @State private var articleItem: FeedItem?
    private let impressions = ImpressionTracker()
    @State private var showScrollButton = false
    @State private var lastScrollIndex: Int = 0
    /// Uncommitted text in the field. It does not trigger a search until Return
    /// or the add button turns it into a tag.
    @State private var searchText = ""
    @State private var searchTerms: [SearchTerm] = []
    @State private var isSearching = false
    @State private var selectedSource: SourceReference?
    @State private var sourceToCollect: SourceReference?
    @FocusState private var searchFocused: Bool
    @State private var showSettings = false
    @State private var showSources = false
    @State private var showFilters = false
    @State private var showBookmarks = false
    @State private var showAddFeed = false
    @State private var addFeedCollectionID: Int64?
    @State private var addFeedCollectionName: String?
    @State private var showCollections = false
    @State private var showExport = false
    @State private var showCollectionExport = false
    @State private var showCollectionImporter = false
    @State private var showCreateCollectionPrompt = false
    @State private var createCollectionName = ""
    @State private var pendingCollectionSources: [SourceReference] = []
    @State private var showCreateSmartFeedPrompt = false
    @State private var createSmartFeedName = ""
    @State private var showDeleteSmartFeedConfirmation = false
    @State private var showCuratedOnboarding = false
    @State private var showCuratedInspector = false
    @State private var showDeleteCuratedFeedConfirmation = false
    @State private var showCatalogExplore = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastIcon = "checkmark"
    @State private var headerHeight: CGFloat = 48
    @State private var searchControlsHeight: CGFloat = 92
    @State private var filterLensExpanded = true
    @State private var lastScrollOffset: CGFloat = 0
    @State private var filterLensCollapseTask: Task<Void, Never>?
    @State private var engine = CircadianEngine.shared
    @AppStorage("showDebugBar") private var showDebugBar = false
    @AppStorage("nightMode") private var nightMode = false
    @AppStorage("lastScrollItemID") private var lastScrollItemID = ""
    @AppStorage("filterLensDismissedSignature") private var filterLensDismissedSignature = ""
    @AppStorage("searchIncludesSources") private var searchIncludesSources = true
    @AppStorage("searchIncludesContents") private var searchIncludesContents = false
    @State private var scrollTargetID: String? = nil
    /// True once the user has actually scrolled the feed. Gates the one-shot
    /// cold-start position restore so it can never yank a user who already
    /// started reading. (Feed is sacred: it doesn't move on its own.)
    @State private var userHasScrolled = false
    @State private var didRestoreScroll = false
    @State private var didRecordFirstScreen = false
    @State private var didRecordFirstUsefulContent = false
    @State private var player = AudioPlayerManager.shared

    private var emptyMode: FeedEmptyMode {
        let activeTopic = (loader.activePreset.isSmartFeed || loader.activePreset.isCuratedFeed)
            ? loader.activePreset.displayName
            : loader.selectedNodeNames.joined(separator: ", ")
        if loader.sources.isEmpty || (!loader.isGlobalFeedsEnabled && !loader.isAnyCountryEnabled) {
            return .noSourcesEnabled
        }
        if loader.hasActiveFilters && loader.items.isEmpty && (loader.loadingState == .refreshing || loader.isUrgentFetching) {
            return .fetching(
                topic: activeTopic,
                fetched: loader.emptyStateFetchedCount,
                total: loader.selectedNodeIDs.reduce(0) { $0 + (TaxonomyStore.shared.node(id: $1)?.feedCount ?? 0) }
            )
        }
        if loader.hasActiveFilters && loader.items.isEmpty && loader.loadingState == .idle {
            return .noResults(topic: activeTopic)
        }
        return .generic
    }

    var body: some View {
        screenWithSheets
    }

    private var screenContent: some View {
        ZStack(alignment: .top) {
            // Full-bleed feed content with circadian page tint
            engine.pageBackground.ignoresSafeArea()

            if isSearching && hasCommittedSearch {
                unifiedSearchPanel
            } else if loader.items.isEmpty
                && (loader.isPreparingInitialRunway
                    || loader.loadingState == .initial
                    || ((loader.activePreset.collectionID != nil
                        || loader.activePreset.isSmartFeed
                        || loader.activePreset.isCuratedFeed)
                        && loader.loadingState == .refreshing)) {
                InitialFeedLoadingView()
            } else if loader.items.isEmpty && loader.loadingState != .initial {
                FeedEmptyStateView(mode: emptyMode)
            } else {
                feedScrollView
            }

            // Floating compact header
            VStack(spacing: 0) {
                compactHeader
                if isSearching { searchBar.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
            }

            // Shake detector
            ShakeDetector { loader.shakeToRefresh() }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            // Mini player bar — full-width bottom bar, always on top
            VStack {
                Spacer()
                MiniPlayerBar()
                    .background(.ultraThinMaterial)
            }

            // Toast + Onboarding overlays
            toastOverlay
            OnboardingTipsView()
        }
    }

    private var lifecycleObservedScreen: some View {
        screenContent
        .task {
            await startScreen()
        }
        .onAppear { recordFirstScreenMetric() }
        .onChange(of: loader.items.count) { _, count in recordFirstUsefulContentMetric(count: count) }
        .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            handleWillEnterForeground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            loader.emergencyTrim()
        }
    }

    private var searchObservedScreen: some View {
        lifecycleObservedScreen
        .onChange(of: searchIncludesSources) { _, value in
            loader.searchIncludesSources = value
            if !searchTerms.isEmpty {
                loader.submitSearchTerms(searchTerms)
            }
        }
        .onChange(of: searchIncludesContents) { _, value in
            loader.searchIncludesContents = value
            if !searchTerms.isEmpty {
                loader.submitSearchTerms(searchTerms)
            }
        }
        .onChange(of: loader.submittedSearchTerms) { _, terms in
            if searchTerms != terms {
                searchTerms = terms
            }
        }
        .onChange(of: filterLensSignature) { _, _ in
            handleFilterLensContentChange()
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused && searchText.isEmpty && searchTerms.isEmpty {
                isSearching = false
            }
        }
    }

    private var observedScreen: some View {
        searchObservedScreen
        .onChange(of: loader.readItemIDs.count) { _, _ in updateBadge() }
        .onChange(of: loader.lastToggleMessage) { _, msg in
            if let msg {
                toastMessage = msg; toastIcon = "antenna.radiowaves.left.and.right"
                withAnimation { showToast = true }
                loader.clearToggleMessage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedImportCompleted)) { notification in
            if let msg = notification.userInfo?["message"] as? String {
                toastMessage = msg; toastIcon = "plus.circle.fill"
                withAnimation { showToast = true }
            }
        }
        .onChange(of: player.lastPlaybackError) { _, error in
            if let error {
                toastMessage = error; toastIcon = "exclamationmark.triangle"
                withAnimation { showToast = true }
                player.clearPlaybackError()
            }
        }
        .onChange(of: loader.networkMonitor.isConnected) { _, connected in
            if connected && loader.fetchErrorCount > 0 {
                // Only fetch new content into reservoir — don't clear visible items
                Task { await loader.refreshIfStale() }
            }
        }
    }

    private var screenWithSheets: some View {
        observedScreen
        .sheet(item: $articleItem) { item in ArticleReaderView(item: item) }
        .sheet(item: $selectedSource) { SourceFeedView(source: $0) }
        .sheet(item: $sourceToCollect) { AddSourceToCollectionSheet(source: $0) }
        .sheet(isPresented: $showSettings) { SettingsSheetView() }
        .sheet(isPresented: $showSources) { SourceManagementView() }
        .sheet(isPresented: $showFilters) { FilterSheetView() }
        .sheet(isPresented: $showBookmarks) { BookmarkBoxesView() }
        .sheet(isPresented: $showAddFeed) {
            AddFeedView(
                targetCollectionID: addFeedCollectionID,
                targetCollectionName: addFeedCollectionName
            )
        }
        .sheet(isPresented: $showCollections) { CollectionManagementView() }
        .sheet(isPresented: $showExport) { ExportView() }
        .fullScreenCover(isPresented: $showCuratedOnboarding) {
            CuratedOnboardingView(
                isFirstRun: false,
                onCancel: { showCuratedOnboarding = false },
                onSaved: { feed in
                    showCuratedOnboarding = false
                    toastMessage = "\(feed.name) is ready"
                    toastIcon = "slider.horizontal.3"
                    withAnimation { showToast = true }
                }
            )
        }
        .sheet(isPresented: $showCuratedInspector) {
            if let curatedFeedID = loader.activePreset.curatedFeedID {
                CuratedFeedInspectorView(curatedFeedID: curatedFeedID)
            }
        }
        .sheet(isPresented: $showCollectionExport) {
            if let collectionID = loader.activePreset.collectionID {
                CollectionOPMLExportView(
                    collectionID: collectionID,
                    collectionName: loader.activePreset.displayName
                )
            }
        }
        .sheet(isPresented: $showCatalogExplore) {
            if let databaseURL = FeedEngineCatalogDiagnostics.activeDatabaseURL(),
               let repository = try? SQLiteCatalogRepository(databaseURL: databaseURL, readOnly: true) {
                CatalogExploreView(engine: repository)
            } else {
                ContentUnavailableView(
                    "Catalog unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The local catalog could not be opened.")
                )
            }
        }
        .tint(engine.accent)
        .animation(.easeInOut(duration: 2.0), value: engine.period)
        .overlay { if nightMode { nightOverlay } }
        .fileImporter(
            isPresented: $showCollectionImporter,
            allowedContentTypes: [.xml, .init(filenameExtension: "opml")!]
        ) { result in
            handleCollectionImport(result)
        }
        .alert("Create collection from filters", isPresented: $showCreateCollectionPrompt) {
            TextField("Collection name", text: $createCollectionName)
            Button("Create") { Task { await createCollectionFromContext() } }
                .disabled(createCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(pendingCollectionSources.count) matching source\(pendingCollectionSources.count == 1 ? "" : "s") will be added.")
        }
        .alert("Save as Smart Bookmark", isPresented: $showCreateSmartFeedPrompt) {
            TextField("Smart Bookmark name", text: $createSmartFeedName)
            Button("Save") { Task { await createSmartFeedFromSearch() } }
                .disabled(createSmartFeedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New matching content will be added automatically. Seen items stay available at the end of the feed.")
        }
        .alert("Delete Smart Bookmark?", isPresented: $showDeleteSmartFeedConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await deleteActiveSmartFeed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved search and its cache. It does not delete sources or articles from Feedmine.")
        }
        .alert("Delete Curated Feed?", isPresented: $showDeleteCuratedFeedConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await deleteActiveCuratedFeed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes its preference profile. Sources and articles stay in Feedmine.")
        }
        .onDisappear {
            filterLensCollapseTask?.cancel()
        }
    }

    private var hasFilterLensContent: Bool {
        loader.activeFilterCount > 0
    }

    private var isFilterLensDismissedForCurrentSelection: Bool {
        hasFilterLensContent
            && !filterLensSignature.isEmpty
            && filterLensDismissedSignature == filterLensSignature
    }

    private var isFilterLensVisible: Bool {
        !isSearching && hasFilterLensContent && filterLensExpanded && !isFilterLensDismissedForCurrentSelection
    }

    private var feedTopPadding: CGFloat {
        max(48, headerHeight)
            + (isSearching ? searchControlsHeight : (isFilterLensVisible ? 20 : 0))
    }

    @State private var _cachedFilterLensKey: String = ""
    @State private var _cachedFilterLensSig: String = ""

    private var filterLensSignature: String {
        guard hasFilterLensContent else { return "" }
        // Cache against filter state to avoid string join on every scroll frame
        let key = "\(loader.selectedRegion ?? ".")|\(loader.selectedContentType.rawValue)|\(loader.selectedMood.rawValue)|\(loader.searchQuery)"
        if key == _cachedFilterLensKey { return _cachedFilterLensSig }
        var parts: [String] = []
        parts.append(loader.activePreset.displayName)
        parts.append(loader.selectedRegion ?? "")
        parts.append(loader.selectedContentType.rawValue)
        parts.append(loader.selectedMood.rawValue)
        parts.append(loader.selectedNodeIDs.sorted().joined(separator: ","))
        parts.append(loader.selectedLanguages.sorted().joined(separator: ","))
        parts.append(loader.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        let sig = parts.joined(separator: "|")
        _cachedFilterLensKey = key
        _cachedFilterLensSig = sig
        return sig
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            CompactErrorBanner()
            HStack(spacing: 8) {
                if showDebugBar {
                    CompactDebugInfo()
                } else {
                    CompactFeedStatus()
                }

                Spacer()

                HStack(spacing: 4) {
                    Button {
                        if isSearching {
                            closeSearch()
                        } else {
                            loader.searchIncludesSources = searchIncludesSources
                            loader.searchIncludesContents = searchIncludesContents
                            withAnimation(.easeInOut(duration: 0.3)) { isSearching = true }
                            searchFocused = true
                        }
                    } label: {
                        Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
                            .headerButtonStyle(accent: engine.accent)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityIdentifier("search-button")
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        showBookmarks = true
                    } label: {
                        Image(systemName: loader.selectedBookmarkListID != nil ? "bookmark.fill" : "bookmark")
                            .headerButtonStyle(accent: engine.accent)
                    }
                    .overlay(alignment: .topTrailing) {
                        if loader.selectedBookmarkListID != nil {
                            Circle().fill(engine.accent).frame(width: 6, height: 6)
                        }
                    }
                    filterButton
                    if showDebugBar {
                        Button {
                            showCatalogExplore = true
                        } label: {
                            Image(systemName: "books.vertical")
                                .headerButtonStyle(accent: engine.accent)
                        }
                        .accessibilityLabel("Explore Catalog")
                    }
                    Menu {
                        Button {
                            showCuratedOnboarding = true
                        } label: {
                            Label("Create Curated Feed", systemImage: "wand.and.stars")
                        }
                        if loader.activePreset.isCuratedFeed {
                            Button {
                                showCuratedInspector = true
                            } label: {
                                Label("Open Curated Feed hood", systemImage: "slider.horizontal.3")
                            }
                            Button(role: .destructive) {
                                showDeleteCuratedFeedConfirmation = true
                            } label: {
                                Label("Delete Curated Feed", systemImage: "trash")
                            }
                        }
                        Divider()
                        if shouldOfferCreateSmartFeed {
                            Button { prepareSmartFeedFromSearch() } label: {
                                Label(
                                    "Save as Smart Bookmark",
                                    systemImage: "sparkles.rectangle.stack"
                                )
                            }
                        }
                        if shouldOfferCreateCollection {
                            Button { prepareCollectionFromContext() } label: {
                                Label("Collect these sources", systemImage: "folder.badge.plus")
                            }
                        }
                        if let collectionID = loader.activePreset.collectionID {
                            Button { showCollectionExport = true } label: {
                                Label("Export collection", systemImage: "square.and.arrow.up")
                            }
                            Button { showCollectionImporter = true } label: {
                                Label("Import to collection", systemImage: "square.and.arrow.down")
                            }
                            Button {
                                addFeedCollectionID = collectionID
                                addFeedCollectionName = loader.activePreset.displayName
                                showAddFeed = true
                            } label: {
                                Label("Add feed to collection", systemImage: "link.badge.plus")
                            }
                            Divider()
                        }
                        if loader.activePreset.isSmartFeed {
                            Button(role: .destructive) {
                                showDeleteSmartFeedConfirmation = true
                            } label: {
                                Label("Delete Smart Bookmark", systemImage: "trash")
                            }
                            Divider()
                        }
                        Button {
                            addFeedCollectionID = nil
                            addFeedCollectionName = nil
                            showAddFeed = true
                        } label: {
                            Label("Add Feed", systemImage: "plus.circle")
                        }
                        Button { showExport = true } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        Button { showCollections = true } label: {
                            Label("Source Collections", systemImage: "rectangle.stack.fill")
                        }
                        Button { showSources = true } label: {
                            Label("Sources", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .headerButtonStyle(accent: engine.accent)
                    }
                    .accessibilityIdentifier("more-menu")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Divider().opacity(0.3)
            }

            if isFilterLensVisible {
                FilterLensBar {
                    dismissFilterLensForCurrentSelection()
                }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .readHeaderHeight($headerHeight)
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Add a term · use -term to exclude", text: $searchText)
                    .focused($searchFocused)
                    .accessibilityIdentifier("unified-search-field")
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onSubmit { commitSearchDraft() }
                if !searchText.isEmpty {
                    Button {
                        commitSearchDraft()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(engine.accent)
                    }
                    .accessibilityLabel("Add search term")
                }
                Button("Cancel") {
                    closeSearch()
                }
                .font(.caption).foregroundStyle(engine.accent)
            }

            if !searchTerms.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(searchTerms) { term in
                            searchTermChip(term)
                        }
                    }
                }
                .accessibilityIdentifier("search-term-tags")
            }

            HStack(spacing: 18) {
                searchScopeButton(
                    title: "Sources",
                    isOn: $searchIncludesSources,
                    accessibilityID: "search-sources-toggle"
                )
                searchScopeButton(
                    title: "Contents",
                    isOn: $searchIncludesContents,
                    accessibilityID: "search-contents-toggle"
                )
                Spacer()
            }
            .font(.caption.weight(.medium))

            if !searchTerms.isEmpty {
                searchActivityLine
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
        .onAppear { searchFocused = true }
        .readSearchControlsHeight($searchControlsHeight)
    }

    private func searchTermChip(_ term: SearchTerm) -> some View {
        HStack(spacing: 5) {
            Image(systemName: term.isExcluded ? "minus.circle.fill" : "tag.fill")
                .font(.caption2)
            Text(term.displayText)
                .lineLimit(1)
            Button {
                removeSearchTerm(term)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .accessibilityLabel("Remove \(term.displayText)")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(term.isExcluded ? Color.red : engine.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            (term.isExcluded ? Color.red : engine.accent).opacity(0.1),
            in: Capsule()
        )
    }

    @ViewBuilder
    private var searchActivityLine: some View {
        let expression = SearchExpression(terms: searchTerms)
        if !expression.canSearch {
            Label("Add at least one positive term to search", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        } else if searchIncludesContents && loader.isSearchScanning {
            HStack(spacing: 7) {
                Image(systemName: "network")
                    .foregroundStyle(engine.accent)
                Text("\(loader.searchScannedSourceCount) sources checked")
                if loader.searchDiscoveredItemCount > 0 {
                    Text("· \(loader.searchDiscoveredItemCount) new cached")
                }
            }
            .foregroundStyle(.secondary)
        } else if searchIncludesContents && loader.searchScanCompleted {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("\(loader.searchScannedSourceCount) sources checked")
                if loader.searchDiscoveredItemCount > 0 {
                    Text("· \(loader.searchDiscoveredItemCount) new cached")
                }
            }
            .foregroundStyle(.secondary)
        } else if loader.isSearchLoading {
            Label("Searching…", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
        }
    }

    private func searchScopeButton(
        title: String,
        isOn: Binding<Bool>,
        accessibilityID: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Label(
                title,
                systemImage: isOn.wrappedValue ? "checkmark.square.fill" : "square"
            )
            .foregroundStyle(isOn.wrappedValue ? engine.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityValue(isOn.wrappedValue ? "selected" : "not selected")
    }

    private var unifiedSearchPanel: some View {
        let results = loader.unifiedSearchResults
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if loader.isSearchLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching the local library…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                }

                if !results.sources.isEmpty {
                    searchSectionHeader("Sources", count: results.sources.count, icon: "antenna.radiowaves.left.and.right")
                    ForEach(results.sources) { source in
                        Button {
                            searchFocused = false
                            selectedSource = source.sourceReference
                        } label: {
                            SourceSearchRow(source: source)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("source-result-\(source.id)")
                        .contextMenu {
                            Button {
                                searchFocused = false
                                selectedSource = source.sourceReference
                            } label: {
                                Label("View Source", systemImage: "rectangle.stack")
                            }
                            Button { sourceToCollect = source.sourceReference } label: {
                                Label("Add Source to Collection", systemImage: "rectangle.stack.badge.plus")
                            }
                        }
                    }
                }

                if !results.savedItems.isEmpty {
                    searchSectionHeader("Saved", count: results.savedItems.count, icon: "bookmark.fill")
                    ForEach(results.savedItems) { item in
                        searchContentRow(item, saved: true)
                    }
                }

                if !results.localItems.isEmpty {
                    searchSectionHeader("History & local content", count: results.localItems.count, icon: "clock.arrow.circlepath")
                    ForEach(results.localItems) { item in
                        searchContentRow(item, saved: false)
                    }
                }

                if !loader.isSearchLoading && results.isEmpty {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "magnifyingglass",
                        description: Text(loader.isSearchScanning
                            ? "Results will appear here while sources are checked online."
                            : "Try another term or adjust the active filters.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 90)
        }
        .scrollDismissesKeyboard(.interactively)
        .padding(.top, headerHeight + searchControlsHeight)
        .accessibilityIdentifier("unified-search-results")
    }

    private func searchSectionHeader(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(title).fontWeight(.semibold)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .foregroundStyle(engine.accent)
        .padding(.top, 8)
    }

    private func searchContentRow(_ item: FeedItem, saved: Bool) -> some View {
        Button {
            searchFocused = false
            loader.markAsClicked(item.id)
            articleItem = item
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: saved ? "bookmark.fill" : (item.isRead ? "clock.fill" : "doc.text"))
                    .foregroundStyle(saved ? engine.accent : Color.secondary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(item.sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var filterButton: some View {
        let activeCount = loader.activeFilterCount
        return Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            showFilters = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease")
                    .headerButtonStyle(accent: engine.accent)
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(engine.accent))
                        .offset(x: 2, y: -2)
                }
            }
        }
        .accessibilityIdentifier("filter-button")
        .accessibilityValue("\(activeCount)")
    }

    // MARK: - Feed Scroll

    private var feedScrollView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(spacing: engine.cardGap) {
                        Color.clear.frame(height: 0).id("top")
                        // Bookmark box header — replaces What's New in bookmark mode
                        if loader.selectedBookmarkListID != nil {
                            HStack {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(engine.accent)
                                Text(loader.selectedBookmarkListName ?? "Bookmarks")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        }
                        ForEach(loader.dateSections) { section in
                            Section {
                                ForEach(section.items) { item in
                                    FeedItemView(item: item,
                                        onOpen: {
                                            guard !searchFocused else {
                                                searchFocused = false
                                                return
                                            }
                                            articleItem = item
                                        },
                                        onCopy: { toastMessage = "Link copied"; toastIcon = "doc.on.doc"; withAnimation { showToast = true } },
                                        onPlaybackFailed: {
                                            toastMessage = "Audio unavailable"
                                            toastIcon = "exclamationmark.triangle"
                                            withAnimation { showToast = true }
                                        },
                                        onViewSource: { selectedSource = loader.sourceReference(for: item) },
                                        onAddSourceToCollection: { sourceToCollect = loader.sourceReference(for: item) }
                                    )
                                    .id(item.id)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                    .onScrollVisibilityChange(threshold: 0.5) { visible in
                                        if visible {
                                            loader.markAsSeen(item.id)
                                        }
                                    }
                                    .onAppear {
                                        impressions.mark(item.id)
                                        loader.noteVisibleIndex(for: item)
                                        if impressions.count % 8 == 0 {
                                            let idx = loader.currentVisibleIndex
                                            let goingUp = idx < lastScrollIndex
                                            lastScrollIndex = idx
                                            let shouldShow = goingUp && idx > 12
                                            if shouldShow != showScrollButton {
                                                showScrollButton = shouldShow
                                            }
                                        }
                                        Task { await loader.loadMoreIfNeeded(currentItem: item) }
                                    }
                                }
                            } header: {
                                if section.showsHeader {
                                    sectionHeader(section.title)
                                }
                            }
                        }

                        // Filters/search matched nothing, but the feed itself
                        // has content — show guidance instead of a blank screen.
                        if loader.dateSections.isEmpty && !loader.items.isEmpty {
                            EmptyFilterView(category: loader.selectedNodeNames.joined(separator: ", "))
                        }
                    }
                    .padding(.top, feedTopPadding)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 60).background(.ultraThinMaterial)
                    }
                }
                .refreshable {
                    await loader.pullToRefresh()
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: CGFloat.self, of: { geo in
                    geo.contentOffset.y
                }, action: { _, newOffset in
                    handleScrollOffset(newOffset)
                })
                if showScrollButton { floatingButtons(proxy: proxy) }
            }
            .onChange(of: scrollTargetID) { _, targetID in
                guard let targetID else { return }
                // Short delay so LazyVStack has time to lay out the target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(targetID, anchor: .top)
                    }
                }
                scrollTargetID = nil
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Floating Buttons

    private func floatingButtons(proxy: ScrollViewProxy) -> some View {
        HStack {
            Spacer()
            Button {
                let impact = UIImpactFeedbackGenerator(style: .soft)
                impact.impactOccurred()
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo("top", anchor: .top)
                }
                showScrollButton = false
            } label: {
                Image(systemName: "arrow.up")
                    .frame(width: 36, height: 36)
                    .background(engine.accent.opacity(0.12))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Scroll to top")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showScrollButton)
    }

    // MARK: - Overlays

    private var toastOverlay: some View {
        VStack {
            Spacer()
            if showToast {
                HStack(spacing: 8) {
                    Image(systemName: toastIcon).font(.subheadline)
                    Text(toastMessage).font(.subheadline).fontWeight(.medium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.black.opacity(0.8), in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showToast = false }
                }}
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showToast)
            }
        }
    }

    private var nightOverlay: some View {
        Color.black.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
    }

    // MARK: - Helpers

    private func startScreen() async {
        loader.searchIncludesSources = searchIncludesSources
        loader.searchIncludesContents = searchIncludesContents
        searchTerms = loader.submittedSearchTerms
        await loader.start()
        await loader.refreshBookmarkState()
        updateBadge()
        engine.refresh()
        // Restore scroll position once on cold start, but never if the user
        // already started reading.
        if !didRestoreScroll && !userHasScrolled
            && !lastScrollItemID.isEmpty && !loader.items.isEmpty {
            scrollTargetID = lastScrollItemID
        }
        didRestoreScroll = true
    }

    private var shouldOfferCreateCollection: Bool {
        hasCommittedSearch || loader.activeFilterCount >= 2
    }

    private var shouldOfferCreateSmartFeed: Bool {
        isSearching
            && hasCommittedSearch
            && (searchIncludesSources || searchIncludesContents)
    }

    private var currentContextSources: [SourceReference] {
        var candidates: [SourceReference] = []
        if isSearching && hasCommittedSearch {
            let results = loader.unifiedSearchResults
            candidates.append(contentsOf: results.sources.map(\.sourceReference))
            candidates.append(contentsOf: (results.savedItems + results.localItems).map {
                loader.sourceReference(for: $0)
            })
        } else if loader.activePreset.collectionID == nil,
                  loader.selectedMood == .all {
            candidates.append(contentsOf: loader.activeSources.map {
                SourceReference(source: $0)
            })
        } else {
            candidates.append(contentsOf: loader.filteredItems.map {
                loader.sourceReference(for: $0)
            })
        }

        var seen = Set<String>()
        return candidates.filter {
            seen.insert(OPMLParser.normalizeURL($0.feedURL)).inserted
        }
    }

    private func prepareCollectionFromContext() {
        pendingCollectionSources = currentContextSources
        guard !pendingCollectionSources.isEmpty else {
            toastMessage = "No matching sources to collect"
            toastIcon = "folder.badge.questionmark"
            withAnimation { showToast = true }
            return
        }
        let query = SearchExpression(terms: searchTerms).displayQuery
        createCollectionName = query.isEmpty ? "Filtered feeds" : query
        showCreateCollectionPrompt = true
    }

    private func createCollectionFromContext() async {
        do {
            let name = createCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = try await loader.createSourceCollection(name: name)
            for source in pendingCollectionSources {
                try await loader.addSource(source, toCollectionID: id)
            }
            toastMessage = "\(pendingCollectionSources.count) sources added to \(name)"
            toastIcon = "folder.badge.plus"
            pendingCollectionSources = []
            withAnimation { showToast = true }
        } catch {
            toastMessage = "Could not create collection"
            toastIcon = "exclamationmark.triangle"
            withAnimation { showToast = true }
        }
    }

    private func prepareSmartFeedFromSearch() {
        let expression = SearchExpression(terms: searchTerms)
        guard expression.canSearch, searchIncludesSources || searchIncludesContents else {
            return
        }
        createSmartFeedName = expression.displayQuery
        showCreateSmartFeedPrompt = true
    }

    private func createSmartFeedFromSearch() async {
        let name = createSmartFeedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = SearchExpression(terms: searchTerms)
        guard !name.isEmpty, expression.canSearch else { return }
        do {
            let smartFeed = try await loader.createSmartFeed(
                name: name,
                terms: searchTerms,
                includeSources: searchIncludesSources,
                includeContents: searchIncludesContents
            )
            loader.setActivePreset(.smartFeed(
                smartFeedID: smartFeed.id,
                smartFeedName: smartFeed.name
            ))
            closeSearch()
            toastMessage = "\(smartFeed.name) saved as a Smart Bookmark"
            toastIcon = "sparkles.rectangle.stack.fill"
            withAnimation { showToast = true }
        } catch {
            toastMessage = error.localizedDescription
            toastIcon = "exclamationmark.triangle"
            withAnimation { showToast = true }
        }
    }

    private func deleteActiveSmartFeed() async {
        guard let id = loader.activePreset.smartFeedID else { return }
        do {
            try await loader.deleteSmartFeed(id: id)
            toastMessage = "Smart Bookmark deleted"
            toastIcon = "trash"
        } catch {
            toastMessage = "Could not delete Smart Bookmark"
            toastIcon = "exclamationmark.triangle"
        }
        withAnimation { showToast = true }
    }

    private func deleteActiveCuratedFeed() async {
        guard let id = loader.activePreset.curatedFeedID else { return }
        do {
            try await loader.deleteCuratedFeed(id: id)
            toastMessage = "Curated Feed deleted"
            toastIcon = "trash"
        } catch {
            toastMessage = "Could not delete Curated Feed"
            toastIcon = "exclamationmark.triangle"
        }
        withAnimation { showToast = true }
    }

    private func handleCollectionImport(_ result: Result<URL, Error>) {
        guard let collectionID = loader.activePreset.collectionID else { return }
        switch result {
        case .failure:
            toastMessage = "Could not open OPML"
            toastIcon = "exclamationmark.triangle"
            withAnimation { showToast = true }
        case .success(let url):
            Task {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let data = try Data(contentsOf: url)
                    let imported = await loader.importOPML(
                        data: data,
                        fileName: url.deletingPathExtension().lastPathComponent,
                        validate: false
                    )
                    let sourceURLs = imported.items.compactMap { item -> String? in
                        switch item.status {
                        case .imported, .duplicate: return item.url
                        case .invalid, .unreachable: return nil
                        }
                    }
                    let count = try await loader.addSourceURLs(
                        sourceURLs,
                        toCollectionID: collectionID
                    )
                    toastMessage = "\(count) feed\(count == 1 ? "" : "s") added to \(loader.activePreset.displayName)"
                    toastIcon = "square.and.arrow.down"
                } catch {
                    toastMessage = "Could not import OPML"
                    toastIcon = "exclamationmark.triangle"
                }
                withAnimation { showToast = true }
            }
        }
    }

    private func closeSearch() {
        searchText = ""
        searchTerms = []
        searchFocused = false
        loader.clearSubmittedSearch()
        withAnimation(.easeInOut(duration: 0.25)) { isSearching = false }
    }

    private var hasCommittedSearch: Bool {
        SearchExpression(terms: searchTerms).canSearch
    }

    private func commitSearchDraft() {
        guard let term = SearchTerm(input: searchText) else { return }
        var updatedTerms = searchTerms
        let normalized = SearchExpression.normalized(term.text)
        // Re-entering a term replaces its previous polarity, which makes
        // correcting "term" to "-term" (or back) a single action.
        updatedTerms.removeAll {
            SearchExpression.normalized($0.text) == normalized
        }
        updatedTerms.append(term)
        searchTerms = updatedTerms
        searchText = ""
        loader.searchIncludesSources = searchIncludesSources
        loader.searchIncludesContents = searchIncludesContents
        loader.submitSearchTerms(updatedTerms)
        searchFocused = true
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func removeSearchTerm(_ term: SearchTerm) {
        searchTerms.removeAll { $0.id == term.id }
        loader.submitSearchTerms(searchTerms)
        searchFocused = true
    }

    private func handleScrollOffset(_ newOffset: CGFloat) {
        if newOffset > 40 { userHasScrolled = true }

        let delta = newOffset - lastScrollOffset
        lastScrollOffset = newOffset

        guard hasFilterLensContent, !isSearching, !isFilterLensDismissedForCurrentSelection else { return }

        if delta > 8 && newOffset > 24 {
            collapseFilterLens()
        } else if delta < -8 {
            revealFilterLens()
        }
    }

    private func revealFilterLens(scheduleAutoCollapse: Bool = false) {
        guard hasFilterLensContent, !isFilterLensDismissedForCurrentSelection else { return }
        filterLensCollapseTask?.cancel()

        if !filterLensExpanded {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                filterLensExpanded = true
            }
        }

        if scheduleAutoCollapse {
            scheduleFilterLensCollapse()
        }
    }

    private func handleFilterLensContentChange() {
        guard hasFilterLensContent else {
            filterLensCollapseTask?.cancel()
            filterLensExpanded = true
            filterLensDismissedSignature = ""
            return
        }

        if isFilterLensDismissedForCurrentSelection {
            filterLensCollapseTask?.cancel()
            filterLensExpanded = false
        } else {
            revealFilterLens(scheduleAutoCollapse: true)
        }
    }

    private func dismissFilterLensForCurrentSelection() {
        guard hasFilterLensContent, !filterLensSignature.isEmpty else { return }
        filterLensCollapseTask?.cancel()
        filterLensDismissedSignature = filterLensSignature
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            filterLensExpanded = false
        }
    }

    private func collapseFilterLens() {
        filterLensCollapseTask?.cancel()
        guard hasFilterLensContent, filterLensExpanded else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            filterLensExpanded = false
        }
    }

    private func scheduleFilterLensCollapse() {
        filterLensCollapseTask?.cancel()
        filterLensCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, hasFilterLensContent, !isSearching else { return }
            if filterLensExpanded {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    filterLensExpanded = false
                }
            }
        }
    }

    private func updateBadge() {
        let unread = loader.items.count - loader.readItemIDs.count
        Task { @MainActor in UIApplication.shared.applicationIconBadgeNumber = max(0, unread) }
    }

    private func recordFirstScreenMetric() {
        guard !didRecordFirstScreen else { return }
        didRecordFirstScreen = true
        FeedMetrics.event("UI.firstScreenRendered")
        FeedMetrics.memory("firstScreenRendered")
    }

    private func recordFirstUsefulContentMetric(count: Int) {
        guard count > 0, !didRecordFirstUsefulContent else { return }
        didRecordFirstUsefulContent = true
        FeedMetrics.event("UI.firstUsefulContent", "count=\(count)")
        FeedMetrics.memory("firstUsefulContent")
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            loader.setActivityState(.active)
            engine.refresh()
            // Do NOT restore scroll on foreground: SwiftUI already preserves
            // the position across background, so re-scrolling here only makes
            // the feed jump under the user. (Feed is sacred.)
        case .inactive:
            loader.setActivityState(.inactive)
        case .background:
            loader.setActivityState(.background)
            SmartFeedBackgroundScheduler.shared.schedule()
            AudioPlayerManager.shared.savePosition()
            let allItems = loader.dateSections.flatMap(\.items)
            let idx = min(lastScrollIndex, allItems.count - 1)
            if idx >= 0, idx < allItems.count {
                lastScrollItemID = allItems[idx].id
            }
        @unknown default:
            break
        }
    }

    private func handleWillEnterForeground() {
        Task {
            engine.refresh()
            await loader.refreshIfStale()
        }
    }
}

private struct CollectionOPMLExportView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let collectionID: Int64
    let collectionName: String
    @State private var fileURL: URL?
    @State private var sourceCount = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Collection", value: collectionName)
                    LabeledContent("Sources", value: "\(sourceCount)")
                }

                Section {
                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Export OPML", systemImage: "square.and.arrow.up")
                        }
                    } else if let errorMessage {
                        ContentUnavailableView(
                            "Export unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text(errorMessage)
                        )
                    } else {
                        HStack {
                            ProgressView()
                            Text("Preparing OPML…")
                        }
                    }
                } footer: {
                    Text("The OPML contains exactly the sources in this collection.")
                }
            }
            .navigationTitle("Export collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await prepareExport() }
        .presentationDetents([.medium])
    }

    private func prepareExport() async {
        do {
            let members = try await loader.sourceCollectionMembers(collectionID: collectionID)
            let sources = members.map { loader.sourceReference(for: $0).feedSource }
            sourceCount = sources.count
            let data = ExportEngine.opml(sources: sources, title: collectionName)
            let safeName = collectionName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safeName).opml")
            try data.write(to: url, options: .atomic)
            fileURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Compact Subviews

struct CompactDebugInfo: View {
    @Environment(FeedLoader.self) private var loader
    private var unread: Int { loader.items.count - loader.readItemIDs.count }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(loader.loadingState == .idle ? Color.green : Color.blue).frame(width: 6, height: 6)
            Text("\(loader.filteredItems.count)")
                .font(.caption).fontWeight(.semibold).contentTransition(.numericText())
            if unread > 0 {
                Text("\(unread) new")
                    .font(.caption2).fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.blue))
            }
            if loader.podcastItemCount > 0 {
                Text("🎧\(loader.podcastItemCount)").font(.caption2).foregroundStyle(.purple)
            }
            if loader.fetchErrorCount > 0 {
                Text("·\(loader.fetchErrorCount) err").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 48
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct SearchControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 92
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    func readHeaderHeight(_ height: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: HeaderHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(HeaderHeightKey.self) { height.wrappedValue = $0 }
    }

    func readSearchControlsHeight(_ height: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SearchControlsHeightKey.self,
                    value: proxy.size.height
                )
            }
        }
        .onPreferenceChange(SearchControlsHeightKey.self) {
            height.wrappedValue = $0
        }
    }
}

struct CompactFeedStatus: View {
    @Environment(FeedLoader.self) private var loader
    @State private var engine = CircadianEngine.shared
    @State private var showReadyPulse = false
    @AppStorage("showDebugBar") private var showDebugBar = false

    private var isShowingStartupProgress: Bool {
        loader.isPreparingInitialRunway || showReadyPulse
    }

    private var startupTotal: Int {
        max(loader.startupTotalSourceCount, loader.sourceCount)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image("Symbol-Gradient")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text("Feedmine").font(.caption).fontWeight(.bold)
            if isShowingStartupProgress {
                HStack(spacing: 3) {
                    Text("· \(loader.startupFetchedSourceCount)/\(startupTotal)")
                        .contentTransition(.numericText())
                    if showReadyPulse {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolEffect(.pulse, value: showReadyPulse)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(showReadyPulse ? Color.green : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(
                    "\(loader.startupFetchedSourceCount) de \(startupTotal) fontes verificadas"
                )
            } else {
                Text("·\(loader.activeSourceCount)/\(loader.sourceCount) sources")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        // Secret gesture: triple-tap the feed status to toggle debug bar.
        // Not exposed in Settings — intentional, for development use only.
        .onTapGesture(count: 3) {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            withAnimation(.easeInOut(duration: 0.3)) {
                showDebugBar.toggle()
            }
        }
        .task(id: loader.startupRunwayReady) {
            guard loader.startupRunwayReady else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showReadyPulse = true
            }
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                showReadyPulse = false
            }
        }
    }
}

struct CompactErrorBanner: View {
    @Environment(FeedLoader.self) private var loader
    var body: some View {
        if loader.fetchErrorCount > 0 && !loader.networkMonitor.isConnected {
            HStack {
                Image(systemName: "wifi.slash").font(.caption2)
                Text("Offline").font(.caption2)
            }
            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color.red.opacity(0.85))
        }
    }
}

private struct SourceSearchRow: View {
    let source: SourceSearchResult

    private var mediaIcon: String {
        switch source.mediaKind {
        case .text: return "doc.text"
        case .video: return "play.rectangle.fill"
        case .audio: return "headphones"
        case .forum: return "bubble.left.and.bubble.right.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: mediaIcon)
                .foregroundStyle(source.defaultEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(source.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if !source.defaultEnabled {
                        Text("DORMANT")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.13), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if let description = source.sourceDescription, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 5) {
                    if let host = source.displayHost {
                        Text(host).lineLimit(1)
                    }
                    ForEach(source.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.09), in: Capsule())
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SourceSearchDetailView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let source: SourceSearchResult

    private var isEnabled: Bool { loader.isSourceEnabled(source.feedURL) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.title)
                            .font(.title2.bold())
                        if let host = source.displayHost {
                            Text(host).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let description = source.sourceDescription {
                            Text(description).font(.body)
                        }
                    }

                    if !source.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Topics").font(.headline)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(source.tags, id: \.self) { tag in
                                        Text(tag)
                                            .font(.caption)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 6)
                                            .background(Color.secondary.opacity(0.12), in: Capsule())
                                    }
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Label(source.mediaKind.rawValue.capitalized, systemImage: "dot.radiowaves.left.and.right")
                        if let activity = source.activity {
                            Label(activity.capitalized, systemImage: "waveform.path.ecg")
                        }
                        if let language = source.language {
                            Label(language, systemImage: "character.book.closed")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !source.defaultEnabled {
                        Label(
                            "Kept for discovery, but not refreshed by default because this current-sensitive source is dormant.",
                            systemImage: "archivebox"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        loader.toggleSource(source.feedURL)
                    } label: {
                        Label(
                            isEnabled ? "Disable source" : "Enable source",
                            systemImage: isEnabled ? "minus.circle" : "plus.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    HStack {
                        if let rawSiteURL = source.siteURL, let siteURL = URL(string: rawSiteURL) {
                            Link(destination: siteURL) {
                                Label("Website", systemImage: "safari")
                            }
                        }
                        Spacer()
                        ShareLink(item: source.feedURL) {
                            Label("Share feed", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
            }
            .navigationTitle("Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Initial Feed Loading

struct InitialFeedLoadingView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = CircadianEngine.shared
    @State private var displayedSourceName = ""
    @State private var nextSourceNameIndex = 0

    private var progressFraction: Double {
        guard loader.startupTargetSourceCount > 0 else { return 0 }
        return min(
            1,
            Double(loader.startupFetchedSourceCount) / Double(loader.startupTargetSourceCount)
        )
    }

    private var loadingTitle: String {
        loader.hasPreviouslyLoadedContent
            ? String(localized: "Loading your feed...")
            : String(localized: "Loading articles")
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: max(88, proxy.size.height * 0.13))

                StartupSignalView(
                    accent: engine.accent,
                    isReady: loader.startupRunwayReady,
                    reduceMotion: reduceMotion
                )
                .frame(width: 152, height: 72)

                Text(loadingTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, 22)

                Text(String(localized: "We are keeping you entertained while the content arrives."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
                    .padding(.top, 8)

                VStack(spacing: 8) {
                    GeometryReader { bar in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.14))
                            Capsule()
                                .fill(loader.startupRunwayReady ? Color.green : engine.accent)
                                .frame(width: max(4, bar.size.width * progressFraction))
                        }
                    }
                    .frame(height: 5)

                    HStack {
                        Text(verbatim: "\(loader.startupFetchedSourceCount)/\(loader.startupTargetSourceCount)")
                            .contentTransition(.numericText())
                        Spacer()
                        Text(verbatim: "\(Int((progressFraction * 100).rounded()))%")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 290)
                .padding(.top, 28)

                VStack(spacing: 7) {
                    Text(String(localized: "Loading articles"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    ZStack {
                        Text(displayedSourceName.isEmpty ? loadingTitle : displayedSourceName)
                            .id(displayedSourceName)
                            .transition(.opacity)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(engine.accent)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300, minHeight: 42)
                }
                .padding(.top, 34)

                Spacer(minLength: 44)
            }
            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            .padding(.horizontal, 24)
        }
        .disabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(loadingTitle)
        .accessibilityValue(
            "\(loader.startupFetchedSourceCount)/\(loader.startupTargetSourceCount)"
        )
        .task {
            while !Task.isCancelled {
                let names = loader.startupRecentSourceNames
                if nextSourceNameIndex < names.count {
                    let backlog = names.count - nextSourceNameIndex
                    let step = max(1, backlog / 4)
                    let index = min(names.count - 1, nextSourceNameIndex + step - 1)
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                        displayedSourceName = names[index]
                    }
                    nextSourceNameIndex = index + 1
                }
                try? await Task.sleep(for: .milliseconds(650))
            }
        }
    }
}

private struct StartupSignalView: View {
    let accent: Color
    let isReady: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<13, id: \.self) { index in
                    let wave = reduceMotion
                        ? 0.45
                        : (sin(time * 4.2 + Double(index) * 0.72) + 1) / 2
                    Capsule()
                        .fill((isReady ? Color.green : accent).opacity(0.35 + wave * 0.65))
                        .frame(width: 5, height: 12 + wave * 42)
                }
            }
            .frame(width: 152, height: 72)
            .animation(.easeInOut(duration: 0.25), value: isReady)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Empty Filter
struct EmptyFilterView: View {
    let category: String
    var body: some View {
        ContentUnavailableView("No \(category) articles", systemImage: "rectangle.stack.fill", description: Text("This category has articles in the feed, but they may have been trimmed from the visible buffer. Try scrolling through All first.")).padding(.top, 80)
    }
}

// MARK: - Header Button Style

extension View {
    func headerButtonStyle(accent: Color) -> some View {
        self.frame(width: 36, height: 36)
            .background(accent.opacity(0.1))
            .clipShape(Circle())
    }
}
