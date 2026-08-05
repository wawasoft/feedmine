import SwiftUI

/// The main Composer screen — preview cards above, editorial sheet below.
/// Controls update instantly; preview recomposition is coalesced at 100ms.
struct FeedComposerScene: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(CircadianEngine.self) private var engine

    @Binding var recipe: FeedRecipeDefinition
    let onSave: () -> Void
    let onStartBroad: () -> Void
    let onReset: () -> Void

    @State private var previewCards: [FeedCardPresentation] = []
    @State private var previewTask: Task<Void, Never>?
    @State private var previewState: PreviewState = .preparing
    @State private var recipeVersion = 0

    enum PreviewState {
        case preparing
        case ready
        case noResults
        case error(String)
    }

    var body: some View {
        ZStack {
            engine.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Preview zone
                previewZone
                    .frame(maxHeight: .infinity)

                // Editorial sheet
                editorialSheet
            }
        }
        .onAppear { requestPreview() }
        .onChange(of: recipeVersion) { _, _ in
            schedulePreviewUpdate()
        }
        .onDisappear {
            previewTask?.cancel()
        }
    }

    // MARK: - Preview Zone

    private var previewZone: some View {
        VStack(spacing: 8) {
            switch previewState {
            case .preparing:
                previewPlaceholders
            case .ready:
                previewCardsView
            case .noResults:
                noResultsView
            case .error(let message):
                errorView(message)
            }
        }
        .padding(.top, 12)
    }

    private var previewCardsView: some View {
        VStack(spacing: 8) {
            ForEach(previewCards) { card in
                FeedItemCardView(
                    item: card.item,
                    isRead: card.isRead,
                    isBookmarked: card.isBookmarked,
                    presentation: card
                )
                .padding(.horizontal, 16)
            }

            // Peek hint
            if previewCards.count >= 2 {
                Text(String(localized: "Scroll for more"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
    }

    private var previewPlaceholders: some View {
        VStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14)
                    .fill(.thinMaterial)
                    .frame(height: 120)
                    .padding(.horizontal, 16)
            }
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(String(localized: "This combination is very specific."))
                .font(.body)
                .multilineTextAlignment(.center)
            Text(String(localized: "Try adjusting one of the controls."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
            Button(String(localized: "Retry")) { requestPreview() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Editorial Sheet

    private var editorialSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Shape your first feed"))
                        .font(.title.weight(.bold))
                        .fontDesign(.serif)

                    Text(String(localized: "Optional. Change anything later."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Languages
                sectionLabel(String(localized: "Languages"))
                LanguageSelectionControl(
                    selectedLanguages: Binding(
                        get: { Set(recipe.languages) },
                        set: { langs in
                            recipe.languages = Array(langs).sorted()
                            bumpRecipe()
                        }
                    ),
                    availableLanguages: loader.availableLanguages,
                    accent: engine.accent
                )

                Divider()

                // Discovery
                DiscoverySlider(
                    value: Binding(
                        get: { recipe.discoveryLevel },
                        set: { val in
                            recipe.discoveryLevel = val
                            bumpRecipe()
                        }
                    ),
                    accent: engine.accent
                )

                Divider()

                // Source balance
                EditorialBalanceControl(
                    preferences: Binding(
                        get: { recipe.editorialPreferences },
                        set: { prefs in
                            recipe.editorialPreferences = prefs
                            bumpRecipe()
                        }
                    ),
                    accent: engine.accent
                )

                Divider()

                // Topics
                sectionLabel(String(localized: "Topics"))
                ForEach(CuratedTopic.allCases) { topic in
                    TopicPreferenceRow(
                        topicKey: topic.featureKey,
                        topicName: topic.displayName,
                        level: Binding(
                            get: {
                                recipe.topicPreferences[topic.featureKey, default: .neutral]
                            },
                            set: { level in
                                if level == .neutral {
                                    recipe.topicPreferences.removeValue(forKey: topic.featureKey)
                                } else {
                                    recipe.topicPreferences[topic.featureKey] = level
                                }
                                bumpRecipe()
                            }
                        ),
                        accent: engine.accent
                    )
                    Divider().opacity(0.3)
                }

                Divider()

                // Media types
                MediaTypeToggles(
                    selected: Binding(
                        get: { recipe.mediaTypes },
                        set: { types in
                            recipe.mediaTypes = types
                            bumpRecipe()
                        }
                    ),
                    accent: engine.accent
                )

                // Open my feed button — always visible
                Button(action: onSave) {
                    Text(String(localized: "Open my feed"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .tint(engine.accent)
                .padding(.top, 8)
            }
            .padding(20)
        }
        .background(.regularMaterial)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 20,
                topTrailingRadius: 20
            )
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Preview Scheduling

    /// Increment the recipe version to trigger a coalesced preview update.
    private func bumpRecipe() {
        recipeVersion += 1
    }

    /// Coalesce at 100ms — cancel previous task, schedule new one.
    private func schedulePreviewUpdate() {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            requestPreview()
        }
    }

    private func requestPreview() {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            previewState = .preparing

            let evidence = CuratedProfileDefinition(languages: recipe.languages)
            let cards = await loader.previewCuratedCards(
                recipe: recipe,
                evidence: evidence,
                limit: 3
            )

            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.25)) {
                if cards.isEmpty {
                    previewCards = []
                    previewState = .noResults
                } else {
                    previewCards = cards
                    previewState = .ready
                }
            }
        }
    }
}
