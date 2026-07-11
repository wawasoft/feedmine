import SwiftUI
import GRDB

// MARK: - LibraryBrowser

/// Replaces CountriesListScreen + CountryDetailScreen + RegionDetailScreen.
///
/// Renders the library node tree with:
/// - Inline disclosure for tree depth 0-1 (user-visible levels 1-2)
/// - Pushed navigation with breadcrumbs for depth 2+ (user-visible level 3+)
/// - Search, edit mode, circadian styling, and haptics.
///
/// Presented as a NavigationStack sheet from `FeedScreen` (replaces
/// `SourceManagementView`).
struct LibraryBrowser: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var engine = CircadianEngine.shared

    // MARK: - Tree data

    @State private var allNodes: [LibraryNode] = []
    @State private var childMap: [Int64: [LibraryNode]] = [:]
    @State private var parentMap: [Int64: LibraryNode] = [:]
    @State private var sourceCounts: [Int64: Int] = [:]
    @State private var isLoading = true

    private var rootNodes: [LibraryNode] {
        allNodes.filter { $0.parentId == nil }
    }

    private var nothingEnabled: Bool {
        !allNodes.isEmpty && allNodes.allSatisfy { !$0.enabled }
    }

    // MARK: - Navigation path (breadcrumb stack)

    @State private var navPath: [LibraryNode] = []

    // MARK: - Search

    @State private var searchText = ""
    @State private var isSearching = false
    /// Snapshots of which nodes were expanded before search began, so we can
    /// restore the exact pre-search expansion state when search is cleared.
    @State private var preSearchExpandedIDs: Set<Int64> = []

    // MARK: - Expansion state

    /// Tracks which nodes are expanded inline. Persisted across push/pop so
    /// the user never has to re-expand after navigating back.
    @State private var expandedNodeIDs: Set<Int64> = []

    // MARK: - Edit mode

    @State private var isEditing = false
    @State private var showAddNode = false

    // MARK: - Toast

    @State private var toastMessage = ""
    @State private var showToast = false

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navPath) {
            mainContent
                .navigationTitle("Library")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .navigationDestination(for: LibraryNode.self) { node in
                    LibraryLevelView(
                        parentNode: node,
                        allNodes: allNodes,
                        childMap: childMap,
                        parentMap: parentMap,
                        sourceCounts: sourceCounts,
                        expandedIDs: $expandedNodeIDs,
                        searchText: searchText,
                        onToggle: { toggleNode($0) },
                        onAddNode: { showAddNode = true }
                    )
                    .environment(loader)
                }
                .sheet(isPresented: $showAddNode) {
                    // Placeholder — will be replaced by the AddNodeSheet
                    // when the node-creation UI is implemented in a later task.
                    NavigationStack {
                        VStack(spacing: 16) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 48))
                                .foregroundStyle(engine.accent)
                            Text("Add a Feed Collection")
                                .font(.headline)
                            Text("Paste a URL or search for feeds to add to your library.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .navigationTitle("New Node")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showAddNode = false }
                            }
                        }
                    }
                }
        }
        .task { await reloadData() }
        .tint(engine.accent)
        .animation(.easeInOut(duration: 2.0), value: engine.period)
        .overlay { toastOverlay }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            engine.pageBackground.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(engine.accent)
            } else if rootNodes.isEmpty {
                emptyStateNoUserFeeds
            } else if nothingEnabled {
                emptyStateAllDisabled
            } else {
                treeList
            }
        }
    }

    // MARK: - Tree List

    private var treeList: some View {
        List {
            let displayRoots = isSearching ? filteredNodes(rootNodes) : rootNodes
            ForEach(displayRoots) { node in
                TreeRowView(
                    node: node,
                    depth: 0,
                    childMap: childMap,
                    sourceCounts: sourceCounts,
                    expandedIDs: $expandedNodeIDs,
                    isSearching: isSearching,
                    searchQuery: searchText,
                    onToggle: { toggleNode($0) }
                )
            }
            .onDelete(perform: deleteNodes)
            .onMove(perform: moveNodes)

            if isEditing {
                Button(action: { showAddNode = true }) {
                    Label("Add Node", systemImage: "plus.circle")
                        .font(.body)
                        .foregroundStyle(engine.accent)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Search Handling

    /// Returns only nodes whose name matches the search query, with ancestors
    /// included so the path to each match is visible.
    private func filteredNodes(_ nodes: [LibraryNode]) -> [LibraryNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nodes }

        // Build set of matching node IDs
        let matchingIDs = Set(
            allNodes
                .filter { $0.name.lowercased().localizedCaseInsensitiveContains(query) }
                .map(\.id)
        )

        // Include ancestors of matches so the path is visible
        var visibleIDs = matchingIDs
        for id in matchingIDs {
            var current = parentMap[id]
            while let parent = current {
                visibleIDs.insert(parent.id)
                current = parentMap[parent.id]
            }
        }

        return nodes.filter { visibleIDs.contains($0.id) }
    }

    /// Whether a specific node is visible in the current search filter.
    private func isNodeVisible(_ nodeID: Int64) -> Bool {
        guard isSearching else { return true }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }

        // Visible if it matches or is an ancestor of a match
        if allNodes.first(where: { $0.id == nodeID })?.name.lowercased().localizedCaseInsensitiveContains(query) == true {
            return true
        }
        var current = parentMap[nodeID]
        while let parent = current {
            if allNodes.first(where: { $0.id == parent.id })?.name.lowercased().localizedCaseInsensitiveContains(query) == true {
                return true
            }
            current = parentMap[parent.id]
        }
        return false
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }
        }

        ToolbarItem(placement: .principal) {
            if isSearching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search collections\u{2026}", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 260)
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 4) {
                Button {
                    toggleSearch()
                } label: {
                    Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
                        .font(.body)
                }

                if !isSearching {
                    Button(isEditing ? "Done" : "Edit") {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        withAnimation { isEditing.toggle() }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func toggleSearch() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()

        if isSearching {
            // Restore pre-search expansion state
            searchText = ""
            expandedNodeIDs = preSearchExpandedIDs
            isSearching = false
        } else {
            // Snapshot current expansion before search
            preSearchExpandedIDs = expandedNodeIDs
            // Expand all nodes so the filtered tree is visible
            expandedNodeIDs = Set(allNodes.map(\.id))
            isSearching = true
        }
    }

    private func toggleNode(_ nodeID: Int64) {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        loader.toggleLibraryNode(nodeID)

        // Optimistically update local state
        if let index = allNodes.firstIndex(where: { $0.id == nodeID }) {
            allNodes[index].enabled.toggle()
            // Also update childMap entries
            for key in childMap.keys {
                if let idx = childMap[key]?.firstIndex(where: { $0.id == nodeID }) {
                    childMap[key]?[idx].enabled.toggle()
                }
            }
        }
    }

    private func moveNodes(from: IndexSet, to: Int) {
        guard isEditing else { return }
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        // Placeholder — full reorder support requires updating sort_order
        // in the database. The visual move is handled by .onMove.
    }

    private func deleteNodes(at offsets: IndexSet) {
        guard isEditing else { return }
        let impact = UIImpactFeedbackGenerator(style: .rigid)
        impact.impactOccurred()
        // Placeholder — wired when delete confirmation and DB update are added.
    }

    // MARK: - Data Loading

    private func reloadData() async {
        guard let data = await loader.loadLibraryTreeData() else {
            isLoading = false
            return
        }

        allNodes = data.nodes
        sourceCounts = data.sourceCounts

        // Build child and parent maps
        var children: [Int64: [LibraryNode]] = [:]
        var parents: [Int64: LibraryNode] = [:]
        for node in data.nodes {
            if let pid = node.parentId {
                children[pid, default: []].append(node)
                parents[node.id] = data.nodes.first(where: { $0.id == pid })
            }
        }
        childMap = children
        parentMap = parents

        // Auto-expand first level
        for node in data.nodes where node.parentId == nil {
            expandedNodeIDs.insert(node.id)
        }

        isLoading = false
    }

    // MARK: - Breadcrumb

    /// Build a breadcrumb path string for a node by following parent links to
    /// the root, returning segments from root to this node.
    private func breadcrumbPath(for node: LibraryNode) -> [LibraryNode] {
        var path: [LibraryNode] = [node]
        var current = parentMap[node.id]
        while let parent = current {
            path.append(parent)
            current = parentMap[parent.id]
        }
        return path.reversed()
    }

    // MARK: - Empty States

    private var emptyStateNoUserFeeds: some View {
        ContentUnavailableView {
            Label("Your Library", systemImage: "books.vertical.fill")
        } description: {
            Text("Share a link from Safari or paste a URL to get started.")
        } actions: {
            Button {
                showAddNode = true
            } label: {
                Label("Add a Feed", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.accent)
        }
    }

    private var emptyStateAllDisabled: some View {
        ContentUnavailableView {
            Label("Everything is Off", systemImage: "circle.slash")
        } description: {
            Text("Enable at least one collection to see content in your feed.")
        } actions: {
            Button("Reset to Defaults") {
                Task {
                    for node in allNodes {
                        if !node.enabled {
                            loader.toggleLibraryNode(node.id)
                        }
                    }
                    await reloadData()
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                    toastMessage = "All collections enabled"
                    withAnimation { showToast = true }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.accent)
        }
    }

    // MARK: - Toast

    private var toastOverlay: some View {
        VStack {
            Spacer()
            if showToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                    Text(toastMessage)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.black.opacity(0.8), in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                .padding(.bottom, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showToast = false
                        }
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showToast)
            }
        }
    }
}

// MARK: - TreeRowView

/// A single row in the library tree, rendered recursively.
///
/// - Depth 0-1: uses `DisclosureGroup` so children appear inline.
/// - Depth 2+: uses `NavigationLink` to push a new `LibraryLevelView`.
/// - Leaf nodes (no children): renders a plain row with toggle.
private struct TreeRowView: View {
    let node: LibraryNode
    let depth: Int
    let childMap: [Int64: [LibraryNode]]
    let sourceCounts: [Int64: Int]
    @Binding var expandedIDs: Set<Int64>
    let isSearching: Bool
    let searchQuery: String
    let onToggle: (Int64) -> Void

    @State private var engine = CircadianEngine.shared

    @State private var isExpanded: Bool = false

    private var children: [LibraryNode] { childMap[node.id] ?? [] }
    private var hasChildren: Bool { !children.isEmpty }
    private var nodeSourceCount: Int { sourceCounts[node.id] ?? 0 }

    /// Should children be rendered inline via DisclosureGroup?
    private var useInlineDisclosure: Bool { depth < 2 && hasChildren }

    /// Should this node push to a new screen?
    private var usePushNavigation: Bool { depth >= 2 && hasChildren }

    var body: some View {
        Group {
            if useInlineDisclosure {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedIDs.contains(node.id) },
                        set: { newValue in
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            if newValue { expandedIDs.insert(node.id) }
                            else { expandedIDs.remove(node.id) }
                        }
                    ),
                    content: {
                        if expandedIDs.contains(node.id) {
                            ForEach(children) { child in
                                TreeRowView(
                                    node: child,
                                    depth: depth + 1,
                                    childMap: childMap,
                                    sourceCounts: sourceCounts,
                                    expandedIDs: $expandedIDs,
                                    isSearching: isSearching,
                                    searchQuery: searchQuery,
                                    onToggle: onToggle
                                )
                            }
                        }
                    },
                    label: { rowContent }
                )
                .animation(.easeInOut(duration: 0.2), value: expandedIDs.contains(node.id))
            } else if usePushNavigation {
                NavigationLink {
                    LibraryLevelView(
                        parentNode: node,
                        allNodes: [],
                        childMap: childMap,
                        parentMap: [:],
                        sourceCounts: sourceCounts,
                        expandedIDs: $expandedIDs,
                        searchText: searchQuery,
                        onToggle: onToggle,
                        onAddNode: {}
                    )
                    .environment(engine)
                } label: {
                    rowContent
                }
            } else {
                rowContent
            }
        }
    }

    // MARK: - Row Content

    private var rowContent: some View {
        HStack(spacing: 8) {
            // Node name
            Text(node.name)
                .font(.system(size: 15))
                .fontWeight(engine.activeFontWeight ?? .regular)
                .lineLimit(1)
                .foregroundStyle(dimmed ? .tertiary : .primary)

            // Source count badge
            if nodeSourceCount > 0 {
                Text("(\(nodeSourceCount))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Toggle
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                onToggle(node.id)
            } label: {
                Image(systemName: node.enabled ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(engine.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var dimmed: Bool {
        // If the node is disabled, dim it
        !node.enabled && useInlineDisclosure
    }
}

// MARK: - LibraryLevelView

/// A pushed level of the library tree, shown when the user taps a node at
/// depth 2+ (user-visible level 3+).
///
/// Displays a breadcrumb header at the top and renders the node's children
/// using the same `TreeRowView` component.
struct LibraryLevelView: View {
    let parentNode: LibraryNode
    let allNodes: [LibraryNode]
    let childMap: [Int64: [LibraryNode]]
    let parentMap: [Int64: LibraryNode]
    let sourceCounts: [Int64: Int]
    @Binding var expandedIDs: Set<Int64>
    let searchText: String
    let onToggle: (Int64) -> Void
    let onAddNode: () -> Void

    @State private var engine = CircadianEngine.shared

    private var children: [LibraryNode] { childMap[parentNode.id] ?? [] }

    var body: some View {
        ZStack {
            engine.pageBackground.ignoresSafeArea()

            if children.isEmpty {
                ContentUnavailableView {
                    Label("No Feeds", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("This collection is empty.")
                }
            } else {
                List {
                    ForEach(children) { child in
                        TreeRowView(
                            node: child,
                            depth: 3,  // Depth 3+ always uses NavigationLink
                            childMap: childMap,
                            sourceCounts: sourceCounts,
                            expandedIDs: $expandedIDs,
                            isSearching: false,
                            searchQuery: "",
                            onToggle: onToggle
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(parentNode.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    onAddNode()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Library Browser") {
    LibraryBrowser()
        .environment(FeedLoader())
}
