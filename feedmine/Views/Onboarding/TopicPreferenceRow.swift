import SwiftUI

/// Single topic row. Tapping cycles Normal → More → Less → Normal.
/// State displayed as a trailing chip (filled = More, plain = Normal,
/// outlined = Less). Does NOT use card category stripe geometry.
struct TopicPreferenceRow: View {
    let topicKey: String
    let topicName: String
    @Binding var level: PreferenceLevel
    let accent: Color

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                level = level.next()
            }
        } label: {
            HStack {
                Text(topicName)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()

                stateChip
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(topicName): \(level.topicLabel)"))
        .accessibilityHint(String(localized: "Double-tap to cycle through Less, Normal, and More"))
    }

    @ViewBuilder
    private var stateChip: some View {
        switch level {
        case .neutral:
            Text(level.topicLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .more:
            Text(level.topicLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    Capsule()
                        .fill(accent)
                }
        case .less:
            Text(level.topicLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    Capsule()
                        .strokeBorder(.secondary.opacity(0.4))
                }
        }
    }
}
