import SwiftUI

/// Appears for ~600ms after each choice showing what was learned.
/// Human-readable signals only — never shows numeric weights.
struct ChoiceFeedbackOverlay: View {
    let outcome: CuratedChoiceOutcome
    let weightChanges: [String: Double]
    let accent: Color
    let onDismiss: () -> Void
    let onUndo: (() -> Void)?

    @State private var visible = false
    @State private var dismissWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 16) {
            Text(summaryText)
                .font(.title3)
                .fontWeight(.bold)

            if !signalChips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(signalChips, id: \.self) { chip in
                        Text(chip)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(accent.opacity(0.12), in: Capsule())
                    }
                }
            }

            if outcome != .skip, let onUndo {
                Button("Undo") { onUndo() }
                    .font(.subheadline)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.9)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                visible = true
            }
            let workItem = DispatchWorkItem { onDismiss() }
            dismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
        }
        .onDisappear {
            dismissWorkItem?.cancel()
        }
    }

    private var summaryText: String {
        switch outcome {
        case .left, .right: return "You chose this"
        case .both: return "Keeping both directions"
        case .neither: return "Showing less of this mix"
        case .skip: return "Skipped"
        case .opened: return "Opened"
        }
    }

    private var signalChips: [String] {
        guard outcome != .skip else { return [] }
        let entries = weightChanges
            .sorted { abs($0.value) > abs($1.value) }
            .prefix(3)
            .compactMap { (key, delta) -> String? in
                let name = key.curatedFeatureDisplayName
                guard !name.contains(":") else { return nil }
                let arrow = delta > 0 ? "↑" : "↓"
                return "\(name) \(arrow)"
            }
        return Array(entries.prefix(2))
    }
}
