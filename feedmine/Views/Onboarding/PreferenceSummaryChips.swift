import SwiftUI

/// Shows 3-5 human-readable chips summarizing what was learned.
struct PreferenceSummaryChips: View {
    let profile: CuratedProfileDefinition
    let accent: Color
    let onAdjust: ((String, Double) -> Void)?

    private var topSignals: [(key: String, name: String, weight: Double)] {
        let topics = CuratedPreferenceEngine.topTopicWeights(in: profile, limit: 3)
        let editorials = profile.weights
            .filter { $0.key.hasPrefix("editorial:") && $0.value != 0 }
            .sorted { abs($0.value) > abs($1.value) }
            .prefix(2)

        var signals: [(String, String, Double)] = []
        for t in topics {
            signals.append((t.topic.featureKey, t.topic.displayName, t.weight))
        }
        for e in editorials {
            let name = e.key.curatedFeatureDisplayName
            signals.append((e.key, name, e.value))
        }
        return signals
    }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(topSignals, id: \.key) { signal in
                ChipView(
                    name: signal.name,
                    weight: signal.weight,
                    accent: accent,
                    onAdjust: onAdjust.map { fn in
                        { newWeight in fn(signal.key, newWeight) }
                    }
                )
            }
        }
    }
}

private struct ChipView: View {
    let name: String
    let weight: Double
    let accent: Color
    let onAdjust: ((Double) -> Void)?

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 4) {
            if onAdjust != nil {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        expanded.toggle()
                    }
                } label: {
                    chipContent
                }
                .buttonStyle(.plain)
            } else {
                chipContent
            }

            if expanded, let onAdjust {
                HStack(spacing: 4) {
                    Text("Less").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { weight },
                        set: onAdjust
                    ), in: -3...3, step: 0.5)
                    .tint(weight < 0 ? .secondary : accent)
                    .frame(width: 100)
                    Text("More").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    private var chipContent: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.subheadline)
                .fontWeight(.medium)
            if weight > 0.1 {
                Image(systemName: "arrow.up")
                    .font(.caption2)
            } else if weight < -0.1 {
                Image(systemName: "arrow.down")
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(accent.opacity(0.1), in: Capsule())
        .overlay(Capsule().stroke(accent.opacity(0.2), lineWidth: 0.5))
    }
}

/// Simple horizontal wrapping layout.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > (proposal.width ?? .infinity) && lineWidth > 0 {
                width = max(width, lineWidth)
                height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + (lineWidth > 0 ? spacing : 0)
            lineHeight = max(lineHeight, size.height)
        }
        width = max(width, lineWidth)
        height += lineHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
