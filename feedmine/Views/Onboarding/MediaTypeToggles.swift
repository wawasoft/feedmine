import SwiftUI

/// Simple on/off toggles for content types.
struct MediaTypeToggles: View {
    @Binding var selected: Set<MediaType>
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Content types"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(MediaType.allCases, id: \.self) { type in
                Toggle(isOn: Binding(
                    get: { selected.contains(type) },
                    set: { isOn in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            if isOn {
                                selected.insert(type)
                            } else {
                                selected.remove(type)
                            }
                        }
                    }
                )) {
                    Text(type.displayName)
                        .font(.body)
                        .frame(minHeight: 44)
                }
                .tint(accent)
                .accessibilityLabel(String(localized: "Include \(type.displayName)"))
            }
        }
    }
}
