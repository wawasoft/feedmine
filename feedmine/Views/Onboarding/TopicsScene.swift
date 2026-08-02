import SwiftUI

/// Multi-select topics screen — "What fascinates you?"
///
/// Grid of tappable topic chips. Max 5 selections to keep the feed focused.
/// The selected topics seed the CuratedOnboardingSession profile weights
/// before the story duels begin.
struct TopicsScene: View {
    @Binding var selectedTopics: Set<String>
    let accent: Color
    let onContinue: () -> Void

    @State private var appeared = false

    private let maxSelection = 5

    /// All available topics in display order, using the existing CuratedTopic
    /// vocabulary for consistency with the preference engine.
    private let topics: [CuratedTopic] = CuratedTopic.allCases

    private var selectionCount: Int {
        selectedTopics.count
    }

    private var hasSelection: Bool {
        !selectedTopics.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Question
            VStack(spacing: 10) {
                Text("Almost there")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("What fascinates you?")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text("Pick up to \(maxSelection) — this helps us find stories you'll love.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 6)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)

            // Topic grid
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 8
            ) {
                ForEach(topics) { topic in
                    TopicChip(
                        topic: topic,
                        isSelected: selectedTopics.contains(topic.featureKey),
                        isDisabled: selectionCount >= maxSelection
                            && !selectedTopics.contains(topic.featureKey),
                        accent: accent,
                        action: {
                            toggle(topic)
                        }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)

            Spacer()

            // Continue
            Button(action: onContinue) {
                HStack(spacing: 8) {
                    Text("Continue")
                        .fontWeight(.semibold)
                    if selectionCount > 0 {
                        Text("(\(selectionCount))")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .opacity(0.8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .opacity(hasSelection ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.25), value: hasSelection)
            .disabled(!hasSelection)
            .accessibilityIdentifier("topics-continue")
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) { appeared = true }
        }
    }

    private func toggle(_ topic: CuratedTopic) {
        let key = topic.featureKey
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if selectedTopics.contains(key) {
                selectedTopics.remove(key)
            } else if selectedTopics.count < maxSelection {
                selectedTopics.insert(key)
            }
        }
    }
}

// MARK: - Topic chip

private struct TopicChip: View {
    let topic: CuratedTopic
    let isSelected: Bool
    let isDisabled: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: topic.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : accent)

                Text(topic.shortName)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? accent : Color.clear)
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.thinMaterial)
                    .opacity(isSelected ? 0 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? Color.clear : Color.primary.opacity(0.08),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.2), value: isDisabled)
        .accessibilityIdentifier("topic-\(topic.rawValue)")
    }
}
