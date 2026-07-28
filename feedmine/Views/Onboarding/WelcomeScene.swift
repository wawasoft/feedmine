import SwiftUI

/// Opening screen — real feed cards blurred behind glass, hinting at what's
/// inside. No orbital icons, no slider symbol — the content is the decoration.
struct WelcomeScene: View {
    let accent: Color
    let onStart: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            // Ghost feed cards behind heavy glass
            blurredFeedBackground

            // Foreground content
            VStack(spacing: 0) {
                Spacer()

                // Headline
                Text("A feed you can see through.")
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)

                // Body
                Text("Choose a few real stories. Feedmine will build a mix you can inspect and change anytime.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)

                // Trust signals
                HStack(spacing: 16) {
                    trustBadge("On-device")
                    Circle().fill(.secondary).frame(width: 3, height: 3)
                    trustBadge("No account")
                    Circle().fill(.secondary).frame(width: 3, height: 3)
                    trustBadge("Fully editable")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 20)
                .opacity(appeared ? 1 : 0)

                Spacer()

                // CTAs
                VStack(spacing: 14) {
                    Button(action: onStart) {
                        Text("Build my first feed")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                    .accessibilityIdentifier("welcome-start")

                    Button("Start with everything") {
                        onSkip()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .opacity(appeared ? 1 : 0)
                    .accessibilityIdentifier("welcome-skip")
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
        }
    }

    /// Ghost feed cards behind heavy blur — real content exists behind the
    /// glass, hinting at what Feedmine reveals inside.
    private var blurredFeedBackground: some View {
        let cardSpecs: [(w: CGFloat, h: CGFloat, x: CGFloat, y: CGFloat, opacity: Double)] = [
            (160, 110, -120, -200, 0.35), (185, 125, 100, -140, 0.42),
            (150, 100, -140, 160, 0.30),  (175, 115, 130, 180, 0.38),
            (195, 130, -80, -250, 0.45), (165, 105, 90, 210, 0.33),
        ]
        return ZStack {
            ForEach(0..<6, id: \.self) { i in
                let spec = cardSpecs[i]
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .frame(width: spec.w, height: spec.h)
                    .offset(x: spec.x, y: spec.y)
                    .opacity(appeared ? spec.opacity : 0)
                    .animation(
                        .easeInOut(duration: 1.0).delay(Double(i) * 0.1),
                        value: appeared
                    )
            }
        }
        .overlay(.ultraThinMaterial.opacity(0.92))
        .allowsHitTesting(false)
    }

    private func trustBadge(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption2)
            Text(text)
        }
    }
}
