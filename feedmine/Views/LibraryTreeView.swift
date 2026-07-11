import SwiftUI
import UIKit

// MARK: - LibraryTreeMode

/// Controls the interaction mode of the library tree view.
///
/// - ``navigation``: Full browser with enable/disable toggles and disclosure groups.
///   Used by `LibraryBrowser`.
/// - ``selection(_:)``: Destination picker with radio selection. Binds the
///   selected node ID. Used by `ShareResultView`.
enum LibraryTreeMode {
    /// Full browser with enable/disable toggles and disclosure groups.
    case navigation
    /// Destination picker with radio selection.
    case selection(selectedNodeID: Binding<Int64?>)
}

// MARK: - LibraryTreeView

/// A reusable tree view component for displaying library nodes.
///
/// Renders a recursive disclosure tree using `DisclosureGroup`. Each row shows
/// the node name, source count, and either an enable/disable toggle or a
/// selection indicator depending on the mode.
///
/// **Usage — navigation mode (LibraryBrowser):**
/// ```swift
/// LibraryTreeView(
///     mode: .navigation,
///     nodes: rootNodes,
///     childNodes: { id in children[id] ?? [] },
///     sourceCount: { id in sourceCounts[id] ?? 0 },
///     onToggle: { nodeID in store.toggleNode(nodeID) }
/// )
/// ```
///
/// **Usage — selection mode (ShareResultView destination picker):**
/// ```swift
/// LibraryTreeView(
///     mode: .selection(selectedNodeID: $selectedNodeID),
///     nodes: rootNodes,
///     childNodes: { id in children[id] ?? [] },
///     sourceCount: { id in sourceCounts[id] ?? 0 }
/// )
/// ```
struct LibraryTreeView: View {
    let mode: LibraryTreeMode
    let nodes: [LibraryNode]
    let childNodes: (Int64) -> [LibraryNode]
    let sourceCount: (Int64) -> Int
    var onToggle: ((Int64) -> Void)?

    @State private var engine = CircadianEngine.shared

    var body: some View {
        List {
            ForEach(nodes) { node in
                TreeNodeView(
                    node: node,
                    mode: mode,
                    childNodes: childNodes,
                    sourceCount: sourceCount,
                    onToggle: onToggle
                )
            }
        }
        .listStyle(.plain)
        .tint(engine.accent)
    }
}

// MARK: - TreeNodeView

private struct TreeNodeView: View {
    let node: LibraryNode
    let mode: LibraryTreeMode
    let childNodes: (Int64) -> [LibraryNode]
    let sourceCount: (Int64) -> Int
    let onToggle: ((Int64) -> Void)?

    @State private var isExpanded = false
    @State private var engine = CircadianEngine.shared

    private var children: [LibraryNode] { childNodes(node.id) }
    private var hasChildren: Bool { !children.isEmpty }
    private var nodeSourceCount: Int { sourceCount(node.id) }

    var body: some View {
        nodeContent
    }

    @ViewBuilder
    private var nodeContent: some View {
        if hasChildren {
            DisclosureGroup(
                isExpanded: $isExpanded,
                content: {
                    ForEach(children) { child in
                        TreeNodeView(
                            node: child,
                            mode: mode,
                            childNodes: childNodes,
                            sourceCount: sourceCount,
                            onToggle: onToggle
                        )
                    }
                },
                label: { nodeRow }
            )
            .animation(.easeInOut(duration: 0.2), value: isExpanded)
        } else {
            nodeRow
        }
    }

    private var nodeRow: some View {
        HStack(spacing: 8) {
            // Name
            Text(node.name)
                .font(.system(size: 15))
                .fontWeight(engine.activeFontWeight ?? .regular)
                .lineLimit(1)
                .foregroundStyle(.primary)

            // Source count badge for groups
            if nodeSourceCount > 0 {
                Text("(\(nodeSourceCount))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            switch mode {
            case .navigation:
                toggleControl
            case .selection(let selectedNodeID):
                selectionControl(selectedNodeID: selectedNodeID)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(selectionHighlight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { handleTap() }
    }

    // MARK: - Controls

    private var toggleControl: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            onToggle?(node.id)
        } label: {
            Image(systemName: node.enabled ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(engine.accent)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func selectionControl(selectedNodeID: Binding<Int64?>) -> some View {
        if selectedNodeID.wrappedValue == node.id {
            Image(systemName: "circle.fill")
                .font(.title3)
                .foregroundStyle(engine.accent)
        } else {
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(engine.accent)
        }
    }

    @ViewBuilder
    private var selectionHighlight: some View {
        if case .selection(let selectedNodeID) = mode,
           selectedNodeID.wrappedValue == node.id {
            engine.accent.opacity(0.1)
        }
    }

    private func handleTap() {
        switch mode {
        case .navigation:
            break
        case .selection(let selectedNodeID):
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            selectedNodeID.wrappedValue = node.id
        }
    }
}

// MARK: - Previews

#Preview("Navigation Mode") {
    let root = LibraryNode(id: 1, parentId: nil, name: "Feedmine", sortOrder: 0, origin: .bundled, enabled: true)
    let child = LibraryNode(id: 2, parentId: 1, name: "Tech", sortOrder: 0, origin: .bundled, enabled: true, sourceCount: 12)
    let grandchild = LibraryNode(id: 3, parentId: 2, name: "Apple", sortOrder: 0, origin: .bundled, enabled: true, sourceCount: 5)
    let nodes = [root]
    let children: [Int64: [LibraryNode]] = [1: [child], 2: [grandchild]]

    LibraryTreeView(
        mode: .navigation,
        nodes: nodes,
        childNodes: { children[$0] ?? [] },
        sourceCount: { id in
            switch id {
            case 1: return 20
            case 2: return 12
            case 3: return 5
            default: return 0
            }
        },
        onToggle: { _ in }
    )
}

#Preview("Selection Mode") {
    struct SelectionPreview: View {
        @State private var selectedID: Int64? = nil

        let root = LibraryNode(id: 1, parentId: nil, name: "Feedmine", sortOrder: 0, origin: .bundled, enabled: true)
        let child = LibraryNode(id: 2, parentId: 1, name: "International", sortOrder: 0, origin: .bundled, enabled: true)

        var body: some View {
            LibraryTreeView(
                mode: .selection(selectedNodeID: $selectedID),
                nodes: [root, child],
                childNodes: { _ in [] },
                sourceCount: { _ in 5 }
            )
        }
    }

    return SelectionPreview()
}
