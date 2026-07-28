import SwiftUI

/// Vertical story comparison — each card gets nearly full width.
/// Both/Neither/Skip actions sit between the two cards.
struct StoryDuelScene: View {
    let pair: CuratedComparisonPair
    let accent: Color
    let canUndo: Bool
    let canFinish: Bool
    let isReady: Bool
    let onChoose: (CuratedChoiceOutcome) -> Void
    let onUndo: () -> Void
    let onNewPair: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // Question
            Text("Which would you open first?")
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            // Top card
            StoryDuelCard(
                candidate: pair.left,
                accent: accent,
                action: { onChoose(.left) }
            )
            .accessibilityIdentifier("duel-top-card")

            // Action bar: Both / Neither / Skip
            HStack(spacing: 10) {
                actionPill("Both", icon: "square.on.square") { onChoose(.both) }
                actionPill("Neither", icon: "minus.circle") { onChoose(.neither) }
                actionPill("Skip", icon: "forward.fill") { onChoose(.skip) }
            }
            .padding(.horizontal, 16)
            .accessibilityIdentifier("duel-action-bar")

            // Bottom card
            StoryDuelCard(
                candidate: pair.right,
                accent: accent,
                action: { onChoose(.right) }
            )
            .accessibilityIdentifier("duel-bottom-card")

            // Bottom controls
            HStack {
                Button { onUndo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!canUndo)
                .opacity(canUndo ? 1 : 0.3)
                .accessibilityIdentifier("duel-undo")

                Spacer()

                Button { onNewPair() } label: {
                    Label("New pair", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("duel-new-pair")

                if canFinish {
                    Button(isReady ? "Review my feed" : "Finish now") {
                        onFinish()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("duel-finish")
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 20)
        }
    }

    private func actionPill(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(accent.opacity(0.1), lineWidth: 0.5)
        )
        .accessibilityIdentifier("duel-\(title.lowercased())")
    }
}
