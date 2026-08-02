import SwiftUI

/// Personal many-to-many playlists of sources. These collections are user
/// state: they never rename, move, duplicate, or delete catalog/OPML sources.
struct CollectionManagementView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var collections: [SourceCollection] = []
    @State private var newName = ""
    @State private var renameTarget: SourceCollection?
    @State private var deleteTarget: SourceCollection?
    @State private var showCreate = false
    @State private var showRename = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if collections.isEmpty {
                    ContentUnavailableView(
                        "No source collections",
                        systemImage: "rectangle.stack.badge.plus",
                        description: Text("Create a reusable playlist of sources. A source can belong to more than one collection.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(collections) { collection in
                                NavigationLink {
                                    SourceCollectionDetailView(collection: collection)
                                } label: {
                                    HStack {
                                        Label(collection.name, systemImage: "rectangle.stack.fill")
                                        Spacer()
                                        Text("\(collection.memberCount) sources")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { deleteTarget = collection } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        renameTarget = collection
                                        newName = collection.name
                                        showRename = true
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .onMove(perform: moveCollections)
                        } footer: {
                            Text("Collections reference sources by their normalized feed address. Deleting one removes only the playlist, never the source or its OPML placement.")
                        }
                    }
                }
            }
            .navigationTitle("Source Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !collections.isEmpty { EditButton() }
                    Button { newName = ""; showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create source collection")
                }
            }
            .alert("New Source Collection", isPresented: $showCreate) {
                TextField("Name", text: $newName)
                Button("Create") { Task { await createCollection() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Use it like a playlist: add any mix of bundled and imported sources.")
            }
            .alert("Rename Source Collection", isPresented: $showRename) {
                TextField("Name", text: $newName)
                Button("Rename") { Task { await renameCollection() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete \"\(deleteTarget?.name ?? "")\"?",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Collection", role: .destructive) {
                    guard let target = deleteTarget else { return }
                    deleteTarget = nil
                    Task { await deleteCollection(target) }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("The sources and their editorial classifications stay intact.")
            }
            .alert("Could not update collections", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
        .task { await reload() }
        .presentationDetents([.medium, .large])
    }

    private func reload() async {
        do { collections = try await loader.loadSourceCollections() }
        catch { errorMessage = error.localizedDescription }
    }

    private func createCollection() async {
        do {
            _ = try await loader.createSourceCollection(name: newName)
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func renameCollection() async {
        guard let target = renameTarget else { return }
        do {
            try await loader.renameSourceCollection(id: target.id, name: newName)
            renameTarget = nil
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteCollection(_ collection: SourceCollection) async {
        do {
            try await loader.deleteSourceCollection(id: collection.id)
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func moveCollections(from offsets: IndexSet, to destination: Int) {
        collections.move(fromOffsets: offsets, toOffset: destination)
        let ids = collections.map(\.id)
        Task {
            do { try await loader.reorderSourceCollections(ids: ids) }
            catch { errorMessage = error.localizedDescription; await reload() }
        }
    }
}

private struct SourceCollectionDetailView: View {
    @Environment(FeedLoader.self) private var loader
    let collection: SourceCollection
    @State private var members: [SourceCollectionMember] = []
    @State private var selectedSource: SourceReference?
    @State private var showFeed = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button { showFeed = true } label: {
                    Label("Open Collection Feed", systemImage: "play.rectangle.on.rectangle")
                }
                .disabled(members.isEmpty)
            } footer: {
                Text("Opening refreshes this exact set of sources and merges their available posts into one feed.")
            }

            Section("Sources") {
                if members.isEmpty {
                    Text("Add sources from a card or source result.")
                        .foregroundStyle(.secondary)
                }
                ForEach(members) { member in
                    Button {
                        selectedSource = loader.sourceReference(for: member)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: member.mediaKind))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.title).foregroundStyle(.primary)
                                Text(URL(string: member.sourceURL)?.host ?? member.sourceURL)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await remove(member) }
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                }
                .onMove(perform: moveMembers)
            }
        }
        .navigationTitle(collection.name)
        .toolbar { EditButton() }
        .task { await reload() }
        .sheet(item: $selectedSource) { SourceFeedView(source: $0) }
        .sheet(isPresented: $showFeed) { SourceCollectionFeedView(collection: collection) }
        .alert("Could not update collection", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func reload() async {
        do { members = try await loader.sourceCollectionMembers(collectionID: collection.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func remove(_ member: SourceCollectionMember) async {
        do {
            try await loader.removeSource(member.sourceURL, fromCollectionID: collection.id)
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func moveMembers(from offsets: IndexSet, to destination: Int) {
        members.move(fromOffsets: offsets, toOffset: destination)
        let urls = members.map(\.sourceURL)
        Task {
            do { try await loader.reorderSourceCollectionMembers(collectionID: collection.id, sourceURLs: urls) }
            catch { errorMessage = error.localizedDescription; await reload() }
        }
    }
}

struct AddSourceToCollectionSheet: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let source: SourceReference
    @State private var collections: [SourceCollection] = []
    @State private var memberships: Set<Int64> = []
    @State private var newName = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Collections") {
                    if collections.isEmpty {
                        Text("Create the first collection below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(collections) { collection in
                        Button { Task { await toggle(collection) } } label: {
                            HStack {
                                Text(collection.name).foregroundStyle(.primary)
                                Spacer()
                                if memberships.contains(collection.id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                } else {
                                    Image(systemName: "circle").foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                Section("Create and add") {
                    TextField("Collection name", text: $newName)
                    Button {
                        Task { await createAndAdd() }
                    } label: {
                        Label("Create Collection", systemImage: "plus.circle.fill")
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add \(source.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await reload() }
        .presentationDetents([.medium, .large])
        .alert("Could not update collections", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func reload() async {
        do {
            async let lists = loader.loadSourceCollections()
            async let ids = loader.sourceCollectionIDs(containing: source.feedURL)
            collections = try await lists
            memberships = try await ids
        } catch { errorMessage = error.localizedDescription }
    }

    private func toggle(_ collection: SourceCollection) async {
        do {
            if memberships.contains(collection.id) {
                try await loader.removeSource(source.feedURL, fromCollectionID: collection.id)
                memberships.remove(collection.id)
            } else {
                try await loader.addSource(source, toCollectionID: collection.id)
                memberships.insert(collection.id)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func createAndAdd() async {
        do {
            let id = try await loader.createSourceCollection(name: newName)
            try await loader.addSource(source, toCollectionID: id)
            newName = ""
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SourceFeedView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let source: SourceReference
    @State private var items: [FeedItem] = []
    /// Terminal card presentations keyed by item ID for O(1) lookup.
    /// Built during load() so FeedItemCardView receives pre-resolved images
    /// and layouts — same behavior as the main feed's cardsByID dictionary.
    @State private var cards: [String: FeedCardPresentation] = [:]
    @State private var displayPhase: SourceDisplayPhase = .preparing
    @State private var result: SourceContentResult?
    @State private var articleItem: FeedItem?
    @State private var sourceToCollect: SourceReference?
    /// Tracks the in-flight preparation Task so it can be cancelled on dismiss.
    @State private var preparationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    sourceHeader
                    switch displayPhase {
                    case .preparing:
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Preparing posts…")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    case .ready where items.isEmpty:
                        ContentUnavailableView(
                            emptyTitle,
                            systemImage: result?.fetchStatus == .failed ? "wifi.exclamationmark" : "tray",
                            description: Text(emptyDescription)
                        )
                        .padding(.top, 30)
                    case .failed(let message):
                        VStack(spacing: 16) {
                            ContentUnavailableView(
                                "Unable to load source",
                                systemImage: "wifi.exclamationmark",
                                description: Text(message)
                            )
                            Button {
                                Task { await load() }
                            } label: {
                                Label("Try Again", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 30)
                    case .ready:
                        ForEach(items) { item in
                            FeedItemView(
                                item: item,
                                presentation: cards[item.id],
                                onOpen: { articleItem = item },
                                onAddSourceToCollection: { sourceToCollect = source }
                            )
                            .padding(.horizontal, 6)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .refreshable { await load() }
            .navigationTitle(source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { sourceToCollect = source } label: {
                        Image(systemName: "rectangle.stack.badge.plus")
                    }
                    .accessibilityLabel("Add source to collection")
                }
            }
        }
        .task(id: source.id) { await load() }
        .onDisappear { preparationTask?.cancel() }
        .sheet(item: $articleItem) { ArticleReaderView(item: $0) }
        .sheet(item: $sourceToCollect) { AddSourceToCollectionSheet(source: $0) }
        .accessibilityIdentifier("source-feed-\(source.id)")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
                .background(.ultraThinMaterial)
        }
    }

    private var sourceHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: icon(for: source.mediaKind))
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title).font(.title2.bold())
                    if let host = source.displayHost {
                        Text(host).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if let description = source.sourceDescription, !description.isEmpty {
                Text(description).font(.subheadline)
            }
            if !source.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(source.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.11), in: Capsule())
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if let activity = source.activity {
                    Label(activity.capitalized, systemImage: "waveform.path.ecg")
                }
                if let language = source.language {
                    Label(language.uppercased(), systemImage: "character.book.closed")
                }
                if let result {
                    Label("\(result.items.count) posts", systemImage: "doc.on.doc")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !source.defaultEnabled {
                Label(
                    "Dormant in the automatic feed. Opening it here is intentional and does not enable future refreshes.",
                    systemImage: "archivebox"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button { loader.toggleSource(source.feedURL) } label: {
                    Label(loader.isSourceEnabled(source.feedURL) ? "Disable" : "Enable", systemImage: "antenna.radiowaves.left.and.right")
                }
                if let rawSiteURL = source.siteURL, let siteURL = URL(string: rawSiteURL) {
                    Link(destination: siteURL) { Label("Website", systemImage: "safari") }
                }
                ShareLink(item: source.feedURL) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.bordered)

            Text("Includes all posts currently exposed by the feed plus retained local history. A publisher website may keep older archives that RSS/Atom does not expose.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
    }

    private var emptyTitle: String {
        result?.fetchStatus == .failed ? "Source unavailable" : "No posts exposed"
    }

    private var emptyDescription: String {
        if result?.fetchStatus == .failed {
            return "Feedmine could not refresh this source, and no local history is available. Try again or open its website."
        }
        return "The feed endpoint returned no posts. Its website may still have an archive."
    }

    // MARK: - Loading

    /// Loads source content with a cache-first strategy:
    /// 1. Show cached items immediately (if any) so the user never sees a dead-end.
    /// 2. Fetch fresh content in the background, racing against a 15 s timeout.
    /// 3. Prepare card presentations for the first page and publish atomically.
    /// 4. Background-prepare remaining items with a longer deadline.
    private func load() async {
        preparationTask?.cancel()

        // ── Phase 1: Cache-first ──────────────────────────────────────────
        // Show cached items immediately so the screen always has content
        // (matches the old behavior before the card-preparation refactor).
        let cached = await loader.sourceContentFromCache(source)
        if !cached.isEmpty {
            items = cached
            cards = placeholderCards(for: cached)
            displayPhase = .ready
        } else {
            displayPhase = .preparing
        }
        result = nil

        // ── Phase 2: Fetch fresh content with timeout ────────────────────
        // Race the network fetch against a 15 s deadline so the UI never
        // dead-ends on waitsForConnectivity or a hung server.
        let loaded: SourceContentResult
        if let fetched = await fetchWithTimeout() {
            loaded = fetched
        } else {
            // Timeout fired — stay on cached content if available, otherwise
            // show the failed state so the user has a clear retry path.
            if cached.isEmpty {
                displayPhase = .failed("The request timed out. Check your connection and try again.")
            }
            return
        }

        result = loaded
        let allItems = loaded.items

        guard !allItems.isEmpty else {
            // Fresh fetch returned nothing. If we already showed cached items,
            // leave them in place; otherwise show the empty state.
            if cached.isEmpty {
                items = []
                cards = [:]
                displayPhase = .ready
            }
            return
        }

        // ── Phase 3: Prepare card presentations ──────────────────────────
        let pageSize = 20
        let firstPage = Array(allItems.prefix(pageSize))
        let rest = Array(allItems.dropFirst(pageSize))

        let firstPresentations = await prepareBatch(firstPage, deadline: .seconds(6))
        var allCards = Dictionary(uniqueKeysWithValues: firstPresentations.map { ($0.id, $0) })

        // Fill remaining slots with terminal placeholders so every row has a
        // presentation. The background task upgrades them as images arrive.
        for item in rest {
            if allCards[item.id] == nil {
                allCards[item.id] = terminalPlaceholder(for: item)
            }
        }

        // Publish atomically — items and cards land in the same MainActor
        // transaction so the UI never sees a card without its presentation.
        items = allItems
        cards = allCards
        displayPhase = .ready

        // ── Phase 4: Background preparation of remaining items ────────────
        if !rest.isEmpty {
            let capturedRest = rest
            preparationTask = Task { @MainActor in
                let restPresentations = await prepareBatch(capturedRest, deadline: .seconds(30))
                guard !Task.isCancelled else { return }
                for pres in restPresentations {
                    cards[pres.id] = pres
                }
            }
        }
    }

    /// Races `loadSourceContent` against a 15 s timeout.
    /// Returns `nil` when the timeout fires first; the caller should fall back
    /// to cached content or show a `.failed` state.
    private func fetchWithTimeout() async -> SourceContentResult? {
        await withTaskGroup(of: SourceContentResult?.self) { group in
            group.addTask {
                await loader.loadSourceContent(source)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return nil  // timeout
            }
            // First to complete wins; cancel the other.
            guard let result = await group.next() else { return nil }
            group.cancelAll()
            return result
        }
    }

    /// Creates terminal placeholder cards for a set of cached items.
    /// Used during cache-first display so every row has a presentation slot
    /// even before image resolution begins.
    private func placeholderCards(for items: [FeedItem]) -> [String: FeedCardPresentation] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, terminalPlaceholder(for: $0)) })
    }

    // MARK: - Batch preparation

    /// Resolves a batch of items into terminal FeedCardPresentation values.
    /// Each item races against `deadline` — if the deadline fires first the
    /// item gets a terminal placeholder so the batch always completes.
    /// nonisolated — called from Task.detached and TaskGroup closures.
    private nonisolated func prepareBatch(_ items: [FeedItem], deadline: Duration) async -> [FeedCardPresentation] {
        let deadlineInstant = ContinuousClock().now.advanced(by: deadline)
        return await withTaskGroup(of: FeedCardPresentation.self) { group in
            for item in items {
                group.addTask {
                    await resolveWithDeadline(item, deadline: deadlineInstant)
                }
            }
            var results: [FeedCardPresentation] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// Races a single item's image resolution against a hard deadline.
    /// Uses the same raceWithDeadline pattern as CardPreparationCoordinator:
    /// if the deadline fires first the item gets a terminal placeholder —
    /// the deadline is a hard guarantee, not cooperative cancellation.
    /// nonisolated — called from TaskGroup closures off the main actor.
    private nonisolated func resolveWithDeadline(
        _ item: FeedItem,
        deadline: ContinuousClock.Instant
    ) async -> FeedCardPresentation {
        await withTaskGroup(of: FeedCardPresentation.self) { group in
            group.addTask {
                let imageURL = item.bestImageURL.flatMap(URL.init(string:))
                let articleURL = item.canResolveArticleImage ? URL(string: item.url) : nil

                let media: ResolvedCardMedia
                if let resolvedImage = await ImageLoader.resolveImage(
                    url: imageURL, articleURL: articleURL
                ) {
                    media = .image(resolvedImage)
                } else if item.hasPotentialImage {
                    media = .placeholder
                } else {
                    media = .none
                }

                let layout: FeedCardLayout = media == .none ? .textOnly : .hero

                return FeedCardPresentation(
                    item: item,
                    media: media,
                    layout: layout,
                    isRead: item.isRead,
                    isBookmarked: item.isBookmarked
                )
            }
            group.addTask {
                try? await Task.sleep(until: deadline, clock: .continuous)
                return terminalPlaceholder(for: item)
            }
            // First to complete wins; cancel the other.
            let result = await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Creates a terminal placeholder presentation for items whose images
    /// haven't been resolved yet. Uses hasPotentialImage (which checks
    /// bestImageURL + canResolveArticleImage) for consistency with the
    /// main feed's CardPreparationCoordinator.
    /// nonisolated — called from TaskGroup closures off the main actor.
    private nonisolated func terminalPlaceholder(for item: FeedItem) -> FeedCardPresentation {
        let hasImageSlot = item.hasPotentialImage
        return FeedCardPresentation(
            item: item,
            media: hasImageSlot ? .placeholder : .none,
            layout: hasImageSlot ? .hero : .textOnly,
            isRead: item.isRead,
            isBookmarked: item.isBookmarked
        )
    }
}

private enum SourceDisplayPhase {
    case preparing
    case ready
    case failed(String)
}

private struct SourceCollectionFeedView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let collection: SourceCollection
    @State private var items: [FeedItem] = []
    @State private var isLoading = true
    @State private var result: SourceCollectionContentResult?
    @State private var errorMessage: String?
    @State private var articleItem: FeedItem?
    @State private var selectedSource: SourceReference?
    @State private var sourceToCollect: SourceReference?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let result {
                        HStack {
                            Label("\(result.sourceCount) sources", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if result.failedSourceCount > 0 {
                                Text("\(result.failedSourceCount) unavailable").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 16)
                    }
                    if isLoading {
                        ProgressView("Refreshing collection sources…").padding()
                    } else if items.isEmpty {
                        ContentUnavailableView(
                            "No collection posts",
                            systemImage: "rectangle.stack",
                            description: Text(errorMessage ?? "Add a source or try refreshing this collection.")
                        )
                        .padding(.top, 40)
                    }
                    ForEach(items) { item in
                        FeedItemView(
                            item: item,
                            onOpen: { articleItem = item },
                            onViewSource: { selectedSource = loader.sourceReference(for: item) },
                            onAddSourceToCollection: { sourceToCollect = loader.sourceReference(for: item) }
                        )
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 12)
            }
            .refreshable { await load() }
            .navigationTitle(collection.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await load() }
        .sheet(item: $articleItem) { ArticleReaderView(item: $0) }
        .sheet(item: $selectedSource) { SourceFeedView(source: $0) }
        .sheet(item: $sourceToCollect) { AddSourceToCollectionSheet(source: $0) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
                .background(.ultraThinMaterial)
        }
    }

    private func load() async {
        isLoading = true
        do {
            let loaded = try await loader.loadSourceCollectionContent(collectionID: collection.id)
            result = loaded
            items = loaded.items
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private func icon(for kind: MediaKind) -> String {
    switch kind {
    case .text: return "doc.text"
    case .video: return "play.rectangle.fill"
    case .audio: return "headphones"
    case .forum: return "bubble.left.and.bubble.right.fill"
    }
}
