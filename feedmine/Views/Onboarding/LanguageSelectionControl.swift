import SwiftUI

/// Reusable language picker — chips for selected languages + expandable
/// search grid. Enforces minimum 1 language (reverts to device language).
struct LanguageSelectionControl: View {
    @Binding var selectedLanguages: Set<String>
    @State private var languageSearch = ""
    @State private var isExpanded = false

    let availableLanguages: [FeedLoader.LanguageInfo]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Selected language chips
            if !selectedLanguages.isEmpty {
                FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(selectedLanguages).sorted(), id: \.self) { code in
                        languageChip(code)
                    }
                }
            }

            // Add another language
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text(String(localized: "Add another language"))
                }
                .font(.subheadline)
                .foregroundStyle(accent)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "Add another language"))
            .accessibilityIdentifier("language-add")

            if isExpanded {
                searchAndPicker
            }
        }
        .onChange(of: selectedLanguages) { _, newValue in
            // Enforce minimum 1 language — revert to device language
            if newValue.isEmpty {
                let deviceCode = Locale.current.language.languageCode?
                    .identifier ?? "en"
                selectedLanguages = [deviceCode]
            }
        }
    }

    private func languageChip(_ code: String) -> some View {
        let name = availableLanguages
            .first(where: { $0.code == code })?.name
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                _ = selectedLanguages.remove(code)
            }
        } label: {
            HStack(spacing: 4) {
                Text(name)
                    .font(.subheadline)
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background {
                Capsule()
                    .fill(accent.opacity(0.15))
            }
            .overlay {
                Capsule()
                    .strokeBorder(accent.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Remove \(name)"))
        .accessibilityHint(String(localized: "Removes this language from your feed"))
    }

    private var filteredOptions: [FeedLoader.LanguageInfo] {
        let query = languageSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availableLanguages }
        return availableLanguages.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || $0.code.localizedCaseInsensitiveContains(query)
        }
    }

    private var searchAndPicker: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Find a language"), text: $languageSearch)
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.thinMaterial)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(filteredOptions) { language in
                        languageOptionButton(language)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private func languageOptionButton(_ language: FeedLoader.LanguageInfo) -> some View {
        let isSelected = selectedLanguages.contains(language.code)
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                if isSelected {
                    _ = selectedLanguages.remove(language.code)
                } else {
                    selectedLanguages.insert(language.code)
                }
                languageSearch = ""
            }
        } label: {
            HStack(spacing: 6) {
                Text(language.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? accent.opacity(0.18) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? accent.opacity(0.4) : Color.secondary.opacity(0.15)
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.name)
        .accessibilityIdentifier("language-\(language.code)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected
            ? String(localized: "Double-tap to remove this language")
            : String(localized: "Double-tap to add this language"))
    }
}
