import SwiftUI

/// Three-row segmented control for source balance.
/// Less / Balanced / More per editorial style.
struct EditorialBalanceControl: View {
    @Binding var preferences: [String: PreferenceLevel]
    let accent: Color

    private let rows: [(key: String, label: String)] = [
        ("editorial:reference", String(localized: "Established references")),
        ("editorial:specialist", String(localized: "Specialist sources")),
        ("editorial:distinctive", String(localized: "Independent voices")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Source balance"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            ForEach(Array(rows.enumerated()), id: \.element.key) { index, row in
                balanceRow(key: row.key, label: row.label)
                if index < rows.count - 1 {
                    Divider()
                        .opacity(0.3)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Source balance"))
    }

    private func balanceRow(key: String, label: String) -> some View {
        let current = Binding<PreferenceLevel>(
            get: { preferences[key, default: .neutral] },
            set: { preferences[key] = $0 }
        )

        return HStack(spacing: 0) {
            Text(label)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(PreferenceLevel.allCases, id: \.self) { level in
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            current.wrappedValue = level
                        }
                    } label: {
                        Text(level.balanceLabel)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(minHeight: 44)
                            .background {
                                if current.wrappedValue == level {
                                    Capsule()
                                        .fill(accent)
                                }
                            }
                            .foregroundStyle(
                                current.wrappedValue == level
                                    ? .white
                                    : .secondary
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "\(label): \(level.balanceLabel)"))
                    .accessibilityAddTraits(
                        current.wrappedValue == level ? .isSelected : []
                    )
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(current.wrappedValue.balanceLabel)
    }
}
