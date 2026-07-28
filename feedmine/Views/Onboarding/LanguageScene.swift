import SwiftUI
import UIKit

/// Language selection — single confirmed language + "Add another" expandable UI.
/// No flags, no source counts — just language names and codes.
struct LanguageScene: View {
    @Binding var selectedLanguages: Set<String>
    @State private var languageSearch = ""
    @State private var isExpanded = false

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

            selectedLanguagesList

            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Add another language")
                }
                .font(.subheadline)
                .foregroundStyle(accent)
            }
            .accessibilityIdentifier("language-add")

            if isExpanded {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Find a language", text: $languageSearch)
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background { RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial) }
                .padding(.horizontal, 22)
                .transition(.opacity.combined(with: .move(edge: .top)))

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(filteredOptions) { language in
                            languageButton(language)
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .transition(.opacity)
            }

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

    // MARK: - Selected languages

    @ViewBuilder
    private var selectedLanguagesList: some View {
        let selected = availableLanguages.filter { selectedLanguages.contains($0.code) }
        if selected.isEmpty {
            AnyView(
                HStack {
                    Image(systemName: "character.bubble.fill")
                        .foregroundStyle(accent)
                    Text("No language selected")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background { RoundedRectangle(cornerRadius: 14).fill(.thinMaterial) }
                .padding(.horizontal, 22)
            )
        } else {
            AnyView(
                ForEach(selected, id: \.code) { lang in
                    HStack {
                        Image(systemName: "character.bubble.fill")
                            .foregroundStyle(accent)
                        Text(lang.name)
                            .fontWeight(.medium)
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                _ = selectedLanguages.remove(lang.code)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background { RoundedRectangle(cornerRadius: 14).fill(.thinMaterial) }
                    .padding(.horizontal, 22)
                }
            )
        }
    }

    // MARK: - Language options

    private var filteredOptions: [FeedLoader.LanguageInfo] {
        let query = languageSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let unselected = availableLanguages.filter { !selectedLanguages.contains($0.code) }
        guard !query.isEmpty else { return unselected }
        return unselected.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.code.localizedCaseInsensitiveContains(query)
        }
    }

    private func languageButton(_ language: FeedLoader.LanguageInfo) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedLanguages.insert(language.code)
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "character.bubble.fill")
                    .foregroundStyle(accent)
                Text(language.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(language.code.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background { RoundedRectangle(cornerRadius: 14).fill(.thinMaterial) }
        }
        .buttonStyle(.plain)
    }
}
