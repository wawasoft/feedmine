import SwiftUI

/// Single continuous slider for discovery level.
/// Maps 0.0 (Focused) … 1.0 (Exploratory). No percentage display.
struct DiscoverySlider: View {
    @Binding var value: Double
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Discovery"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Slider(value: $value, in: 0...1) {
                Text(String(localized: "Discovery level"))
            }
            .tint(accent)
            .frame(minHeight: 44)
            .accessibilityValue(
                String(localized: "\(Int(value * 100)) percent toward exploratory")
            )

            HStack {
                Text(String(localized: "Focused"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(localized: "Exploratory"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Discovery"))
        .accessibilityHint(String(localized: "Slide left for focused, right for exploratory"))
    }
}
