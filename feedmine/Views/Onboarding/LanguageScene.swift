import SwiftUI

/// Language selection — single confirmed language + "Add another" expandable UI.
/// No flags, no source counts — just language names and codes.
struct LanguageScene: View {
    @Binding var selectedLanguages: Set<String>

    let availableLanguages: [FeedLoader.LanguageInfo]
    let accent: Color
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What do you read?")
                    .font(.system(size: 28, weight: .bold))
                Text("Feedmine will show stories in these languages.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 12)

            LanguageSelectionControl(
                selectedLanguages: $selectedLanguages,
                availableLanguages: availableLanguages,
                accent: accent
            )
            .padding(.horizontal, 22)

            Spacer()

            Button(action: onContinue) {
                Text("Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .disabled(selectedLanguages.isEmpty)
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
            .accessibilityIdentifier("language-continue")
        }
    }
}
