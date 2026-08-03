import SwiftUI

/// Single-select intent screen — "What brings you to Feedmine?"
///
/// Inspired by Insight Timer's one-question-per-screen rhythm: one tap on a
/// chip, then Continue. No typing, no pressure.
struct IntentScene: View {
    @Binding var selectedIntent: OnboardingIntent?
    let accent: Color
    let onContinue: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Question
            VStack(spacing: 10) {
                Text("Before we start")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Before we start — question label")

                Text("What brings you to Feedmine?")
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 24)
                    .accessibilityAddTraits(.isHeader)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)

            // Chips
            VStack(spacing: 10) {
                ForEach(OnboardingIntent.allCases) { intent in
                    IntentChip(
                        intent: intent,
                        isSelected: selectedIntent == intent,
                        accent: accent,
                        action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                selectedIntent = (selectedIntent == intent) ? nil : intent
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)

            Spacer()

            // Continue
            Button(action: onContinue) {
                Text("Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .opacity(selectedIntent != nil ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.25), value: selectedIntent != nil)
            .disabled(selectedIntent == nil)
            .accessibilityIdentifier("intent-continue")
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) { appeared = true }
        }
    }
}

// MARK: - Intent chip

private struct IntentChip: View {
    let intent: OnboardingIntent
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    /// Fill for the selected state: accent darkened so white label text
    /// holds WCAG AA (4.5:1) instead of ~2:1 on the raw accent.
    private var selectedFill: Color {
        accent.darkened(untilContrast: DesignTokens.minTextContrast, against: .white)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: intent.icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .white : accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(intent.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                    Text(intent.subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(2)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? selectedFill : Color.clear)
            )
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.thinMaterial)
                    .opacity(isSelected ? 0 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isSelected ? Color.clear : Color.primary.opacity(0.08),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("intent-\(intent.rawValue)")
        .accessibilityLabel("\(intent.displayName): \(intent.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
