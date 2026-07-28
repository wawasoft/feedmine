import SwiftUI
import UIKit

struct CuratedOnboardingView: View {
    enum Stage: Int {
        case welcome
        case languages
        case comparisons
        case review
    }

    @Environment(FeedLoader.self) private var loader
    @State private var engine = CircadianEngine.shared
    @State private var stage: Stage = .welcome
    @State private var selectedLanguages: Set<String> = []
    @State private var session: CuratedOnboardingSession?
    @State private var feedName = "My Feed"
    @State private var candidateTask: Task<Void, Never>?
    @State private var candidateAttempts = 0
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var answerPulse = 0
    @State private var answerDelayTask: Task<Void, Never>?
    @State private var feedbackOutcome: CuratedChoiceOutcome?
    @State private var feedbackChanges: [String: Double] = [:]
    @State private var warmNextTask: Task<Void, Never>?
    @State private var showInspector = false

    /// Snapshot of the global language filter before onboarding mutates it,
    /// restored on cancel so the main feed isn't left filtered.
    @State private var preOnboardingLanguages: Set<String>?

    /// Preview items computed once when entering the reveal stage, avoiding
    /// repeated MainActor work during body recomputation.
    @State private var previewItems: [FeedItem] = []

    let isFirstRun: Bool
    var onCancel: () -> Void = {}
    var onSaved: (CuratedFeed) -> Void = { _ in }

    /// Image URLs from the candidate pool or visible feed — used as ambient
    /// backdrop glows so the background reflects real content, not static decor.
    private var ambientImageURLs: [URL] {
        if let session, let pair = session.currentPair {
            return [pair.left, pair.right].compactMap {
                ($0.item.bestImageURL ?? $0.item.imageURL).flatMap(URL.init(string:))
            }
        }
        // During welcome/languages, use whatever's in the visible feed
        return loader.items.prefix(8).compactMap {
            ($0.bestImageURL ?? $0.imageURL).flatMap(URL.init(string:))
        }
    }

    var body: some View {
        ZStack {
            engine.pageBackground.ignoresSafeArea()
            CuratedBackdrop(accent: engine.accent, imageURLs: ambientImageURLs)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                simplifiedTopBar
                Group {
                    switch stage {
                    case .welcome:
                        WelcomeScene(
                            accent: engine.accent,
                            onStart: {
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                                    stage = .languages
                                }
                            },
                            onSkip: cancelOnboarding
                        )
                    case .languages:
                        LanguageScene(
                            selectedLanguages: $selectedLanguages,
                            availableLanguages: loader.availableLanguages,
                            accent: engine.accent,
                            onContinue: startComparisons
                        )
                    case .comparisons:
                        if let session, let pair = session.currentPair {
                            ZStack {
                                StoryDuelScene(
                                    pair: pair,
                                    accent: engine.accent,
                                    canUndo: session.canUndo,
                                    canFinish: session.canFinish,
                                    isReady: session.isReady,
                                    onChoose: answer,
                                    onUndo: {
                                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                            session.undo()
                                            updateAutoName()
                                        }
                                    },
                                    onFinish: {
                                        previewItems = loader.previewCuratedFeed(profile: session.profile, limit: 3)
                                        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                                            stage = .review
                                        }
                                    }
                                )
                                .id(pair.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)
                                ))
                                if let outcome = feedbackOutcome {
                                    ChoiceFeedbackOverlay(
                                        outcome: outcome,
                                        weightChanges: feedbackChanges,
                                        accent: engine.accent,
                                        onDismiss: { dismissFeedback() },
                                        onUndo: outcome != .skip ? { dismissFeedback(undo: true) } : nil
                                    )
                                    .zIndex(10)
                                }
                            }
                        } else {
                            candidateLoadingState(session)
                        }
                    case .review:
                        FeedRevealScene(
                            profile: session?.profile ?? CuratedProfileDefinition(),
                            feedName: $feedName,
                            accent: engine.accent,
                            previewItems: previewItems,
                            isSaving: isSaving,
                            onSave: { Task { await save(session!) } },
                            onOpenHood: { showInspector = true }
                        )
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeInOut(duration: 0.35)),
                    removal: .opacity.animation(.easeInOut(duration: 0.2))
                ))
            }
        }
        .tint(engine.accent)
        .preferredColorScheme(nil)
        .onAppear {
            seedLanguageSelection()
            prepareDefaultName()
        }
        .onDisappear {
            candidateTask?.cancel()
            answerDelayTask?.cancel()
            warmNextTask?.cancel()
        }
        .alert("Couldn’t save this feed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sensoryFeedback(.selection, trigger: answerPulse)
        .sheet(isPresented: $showInspector) {
            if let session {
                NavigationStack {
                    ScrollView {
                        CuratedProfileControls(
                            profile: session.profile,
                            accent: engine.accent,
                            onTopicChange: { session.setTopicWeight($0, $1) },
                            onEditorialChange: { session.setEditorialWeight($0, $1) },
                            onDiscoveryChange: { session.setDiscoveryLevel($0) },
                            onLearningChange: { session.setLearningEnabled($0) }
                        )
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                    }
                    .background(engine.pageBackground)
                    .navigationTitle("Everything learned")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showInspector = false }
                        }
                    }
                }
            }
        }
    }

    private var simplifiedTopBar: some View {
        HStack {
            if stage != .welcome {
                Button { goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("Back")
            } else {
                Color.clear.frame(width: 36, height: 36)
            }

            Spacer()

            if stage == .comparisons, let session {
                ConfidenceProgressView(
                    answerCount: session.answerCount,
                    isReady: session.isReady,
                    accent: engine.accent
                )
            }

            Spacer()

            Button { cancelOnboarding() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel(isFirstRun ? "Start with everything" : "Close")
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Helpers

    /// Cancel onboarding, restoring the global language filter if it was mutated.
    private func cancelOnboarding() {
        if let saved = preOnboardingLanguages {
            loader.applyCuratedLanguages(saved)
        }
        onCancel()
    }

    private func dismissFeedback(undo: Bool = false) {
        if undo, let session {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                session.undo()
                updateAutoName()
            }
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            feedbackOutcome = nil
        }
        guard let session, session.currentPair == nil, !session.isComplete else {
            return
        }
        refreshCandidatePool()
    }

    // MARK: - Actions

    // Old welcomePage content moved to WelcomeScene.swift — kept here for diff clarity:

    
// MARK: - Actions

    private func seedLanguageSelection() {
        guard selectedLanguages.isEmpty else { return }
        if !loader.selectedLanguages.isEmpty {
            selectedLanguages = loader.selectedLanguages
            return
        }
        if let deviceLanguage = CuratedPreferenceEngine.baseLanguage(
            Locale.current.language.languageCode?.identifier
        ) {
            selectedLanguages = [deviceLanguage]
        }
    }

    private func prepareDefaultName() {
        updateAutoName()
    }

    /// Generates a feed name from the top preference signals, falling back
    /// to a warm default when no signals exist yet. The name updates
    /// dynamically as the session accumulates answers.
    private func updateAutoName() {
        guard let session else {
            if feedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                feedName = "My Feed"
            }
            return
        }
        let topTopics = CuratedPreferenceEngine.topTopicWeights(
            in: session.profile, limit: 2
        ).filter { $0.weight > 0.1 }.map(\.topic.shortName)
        let generated: String
        if topTopics.count >= 2 {
            generated = "\(topTopics[0]) & \(topTopics[1])"
        } else if let first = topTopics.first {
            generated = "\(first) Mix"
        } else {
            generated = "My First Feed"
        }
        // Only overwrite if the user hasn't manually edited the name
        let trimmed = feedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "My Curated Feed" || trimmed == "My Feed" {
            feedName = generated
        }
    }

    private func startComparisons() {
        // Snapshot global filter before mutating — restored on cancel
        if preOnboardingLanguages == nil {
            preOnboardingLanguages = loader.selectedLanguages
        }
        loader.applyCuratedLanguages(selectedLanguages)
        let newSession = CuratedOnboardingSession(languages: selectedLanguages)
        session = newSession
        candidateAttempts = 0
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            stage = .comparisons
        }
        refreshCandidatePool()
    }

    private func refreshCandidatePool() {
        candidateTask?.cancel()
        candidateTask = Task { @MainActor in
            for attempt in 0..<10 {
                guard !Task.isCancelled, stage == .comparisons, let session else {
                    return
                }
                candidateAttempts = attempt + 1
                session.beginCandidateRefresh()
                let candidates = await loader.curatedOnboardingCandidates(
                    languages: selectedLanguages
                )
                guard !Task.isCancelled else { return }

                withAnimation(.easeInOut(duration: 0.25)) {
                    session.updateCandidates(candidates)
                }

                // Warm images for the current pair before showing cards.
                // The "Finding a fair comparison" state now does real work.
                if let pair = session.currentPair {
                    await warmPairImages(pair)
                    return
                }

                // No pair yet — wait and retry.
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// Pre-load images for both cards in a pair so they render with photos,
    /// not placeholder gradients. Actually initiates the download (unlike the
    /// previous version which only polled). Times out at 4 seconds.
    private func warmPairImages(_ pair: CuratedComparisonPair) async {
        let urlStrings = [pair.left, pair.right].compactMap {
            $0.item.bestImageURL ?? $0.item.imageURL
        }
        guard !urlStrings.isEmpty else { return }

        let urls = urlStrings.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return }

        // Initiate prefetch through the loader's prefetcher
        await loader.prefetcher.prefetch(urls: urls.map(\.absoluteString), priorityURLs: urls.map(\.absoluteString))

        // Wait up to 4 seconds for at least one to land in cache
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if Task.isCancelled { break }
            if urls.contains(where: { ImageCache.hasCachedImageData(for: $0) }) { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    @ViewBuilder
    private func candidateLoadingState(
        _ session: CuratedOnboardingSession?
    ) -> some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(engine.accent.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .offset(y: -54)
                        .rotationEffect(.degrees(Double(i) * 72))
                        .opacity(0.3 + 0.7 * abs(sin(Double(i) * 0.8)))
                }
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(engine.accent)
                    .symbolEffect(.pulse, options: .repeating.speed(0.8))
            }
            .frame(width: 120, height: 120)
            .rotationEffect(.degrees(candidateAttempts > 0 ? 360 : 0))
            .animation(
                .linear(duration: 4).repeatForever(autoreverses: false),
                value: candidateAttempts
            )

            Text("Finding a fair comparison")
                .font(.headline)
            Text("Feedmine is using real stories arriving through the normal feed.\nNothing is generated or sent away.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            if candidateAttempts >= 5 {
                Button("Start with a balanced feed") {
                    previewItems = loader.previewCuratedFeed(profile: session?.profile ?? CuratedProfileDefinition(), limit: 3)
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                        stage = .review
                    }
                }
                .buttonStyle(.bordered)
                .transition(.opacity.combined(with: .scale))
            }
            Spacer()
        }
    }

    private func answer(_ outcome: CuratedChoiceOutcome) {
        guard let session else { return }

        // Celebration feedback sequence
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            answerPulse += 1
            session.answer(outcome)
            updateAutoName()
        }

        // Capture feedback for overlay
        if let lastEvidence = session.profile.evidence.last {
            feedbackChanges = lastEvidence.weightChanges
        }
        feedbackOutcome = outcome

        // Warm the next pair while feedback overlay is displayed,
        // so cards render with images when the overlay dismisses.
        if let nextPair = session.currentPair {
            warmNextTask?.cancel()
            warmNextTask = Task { @MainActor in
                await warmPairImages(nextPair)
            }
        }

        // Haptic — prepare for next call, fire now
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.prepare()
        impact.impactOccurred()

        // If reached target, a stronger celebration
        if session.reachedTarget && !session.isComplete {
            let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
            heavyImpact.prepare()
            heavyImpact.impactOccurred()
        }

        if session.currentPair == nil && !session.isComplete {
            answerDelayTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                refreshCandidatePool()
            }
        }

        if session.isComplete {
            answerDelayTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, session.isComplete else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    stage = .review
                }
            }
        }
    }

    private func save(_ session: CuratedOnboardingSession) async {
        isSaving = true
        defer { isSaving = false }
        let name = feedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "My Feed" : feedName
        do {
            let saved = try await loader.createCuratedFeed(
                name: name,
                definition: session.profile
            )
            loader.setActivePreset(.curatedFeed(
                curatedFeedID: saved.id,
                curatedFeedName: saved.name
            ))
            onSaved(saved)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func goBack() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            switch stage {
            case .welcome: break
            case .languages: stage = .welcome
            case .comparisons:
                candidateTask?.cancel()
                stage = .languages
            case .review:
                stage = session?.answerCount ?? 0 > 0 ? .comparisons : .languages
            }
        }
    }

    private func fallbackFlag(for code: String) -> String {
        let mapping = [
            "en": "🌎", "pt": "🇧🇷", "es": "🇪🇸", "fr": "🇫🇷",
            "de": "🇩🇪", "it": "🇮🇹", "ar": "🌍", "hi": "🇮🇳",
            "zh": "🇨🇳", "ja": "🇯🇵", "he": "🇮🇱", "ru": "🌍",
        ]
        return mapping[code] ?? "🌐"
    }
}

// MARK: - Reusable profile controls

struct CuratedProfileControls: View {
    let profile: CuratedProfileDefinition
    let accent: Color
    let onTopicChange: (CuratedTopic, Double) -> Void
    let onEditorialChange: (CuratedEditorialStyle, Double) -> Void
    let onDiscoveryChange: (Double) -> Void
    let onLearningChange: (Bool) -> Void

    @State private var showAllTopics = false

    private var topics: [CuratedTopic] {
        if showAllTopics { return CuratedTopic.allCases }
        let learned = CuratedPreferenceEngine.topTopicWeights(
            in: profile,
            limit: 6
        ).map(\.topic)
        return learned.isEmpty
            ? Array(CuratedTopic.allCases.prefix(6))
            : learned
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Interest mix", systemImage: "circle.hexagongrid.fill")
                        .font(.headline)
                    Spacer()
                    Button(showAllTopics ? "Less" : "All topics") {
                        withAnimation { showAllTopics.toggle() }
                    }
                    .font(.caption)
                }

                ForEach(topics) { topic in
                    topicControl(topic)
                }
            }
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 14) {
                Label("Editorial range", systemImage: "text.book.closed.fill")
                    .font(.headline)
                Text("All sources clear the showcase quality floor. These controls describe the kind of editorial voice you want.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(CuratedEditorialStyle.allCases) { style in
                    editorialControl(style)
                }
            }
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Discovery", systemImage: "safari.fill")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(profile.discoveryLevel * 100))%")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { profile.discoveryLevel },
                        set: onDiscoveryChange
                    ),
                    in: 0...1
                )
                HStack {
                    Text("Familiar")
                    Spacer()
                    Text("Exploratory")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Divider()

                Toggle(
                    isOn: Binding(
                        get: { profile.learningEnabled },
                        set: onLearningChange
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep learning")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("Only explicit opens and choices — never a passing scroll.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(accent)
            }
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func editorialControl(_ style: CuratedEditorialStyle) -> some View {
        let weight = profile.weight(for: style.featureKey)
        let confidence = profile.confidence(for: style.featureKey)
        return VStack(spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: style.icon)
                    .foregroundStyle(accent)
                    .frame(width: 22)
                Text(style.displayName)
                    .font(.subheadline)
                Spacer()
                if confidence > 0 {
                    Text(confidenceLabel(confidence))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(signedWeight(weight))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { weight },
                    set: { onEditorialChange(style, $0) }
                ),
                in: -3...3,
                step: 0.1
            )
            .tint(weight < 0 ? .secondary : accent)
        }
    }

    private func topicControl(_ topic: CuratedTopic) -> some View {
        let weight = profile.weight(for: topic.featureKey)
        let confidence = profile.confidence(for: topic.featureKey)
        return VStack(spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: topic.icon)
                    .foregroundStyle(accent)
                    .frame(width: 22)
                Text(topic.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                if confidence > 0 {
                    Text(confidenceLabel(confidence))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(signedWeight(weight))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { weight },
                    set: { onTopicChange(topic, $0) }
                ),
                in: -3...3,
                step: 0.1
            )
            .tint(weight < 0 ? .secondary : accent)
        }
    }

    private func signedWeight(_ value: Double) -> String {
        let percentage = Int((value / 3) * 100)
        return percentage > 0 ? "+\(percentage)" : "\(percentage)"
    }

    private func confidenceLabel(_ value: Double) -> String {
        if value < 0.35 { return "learning" }
        if value < 0.72 { return "medium" }
        return "strong"
    }
}

// MARK: - Story choice card

private struct CuratedStoryChoiceCard: View {
    let candidate: CuratedCandidate
    let marker: String
    let accent: Color
    let action: () -> Void

    @State private var imageFailed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                artwork
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .clipped()

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(marker)
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(accent)
                            .frame(width: 20, height: 20)
                            .background(accent.opacity(0.12), in: Circle())
                        Text(candidate.item.sourceTitle)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(accent)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Label(
                            candidate.editorial.style.shortName,
                            systemImage: candidate.editorial.style.icon
                        )
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Text(candidate.item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Image(systemName: "hand.tap")
                        Text("I’d open this")
                    }
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 120,
                    maxHeight: 120,
                    alignment: .topLeading
                )
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.06), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
        }
        .buttonStyle(CuratedPressStyle())
        .accessibilityIdentifier("curated-choice-\(marker.lowercased())")
    }

    @ViewBuilder
    private var artwork: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [
                        ComponentToken.categoryColor(for: candidate.item.category).opacity(0.48),
                        accent.opacity(0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: candidate.topic.icon)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.82))

                if candidate.item.hasPotentialImage, !imageFailed {
                    CachedAsyncImage(
                        url: candidate.item.bestImageURL.flatMap(URL.init(string:)),
                        articleURL: candidate.item.canResolveArticleImage
                            ? URL(string: candidate.item.url) : nil,
                        onResult: { success in imageFailed = !success }
                    )
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
    }
}

struct CuratedPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? -0.025 : 0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: - Decorative artwork

/// Ambient backdrop built from real article images in the candidate pool.
/// Heavily blurred and dimmed so they create atmosphere without distracting.
private struct CuratedBackdrop: View {
    let accent: Color
    let imageURLs: [URL]

    @State private var loadedImages: [UIImage] = []

    var body: some View {
        ZStack {
            // Base accent glow
            Circle()
                .fill(accent.opacity(0.05))
                .frame(width: 300, height: 300)
                .blur(radius: 60)

            // Real article images as ambient glows
            ForEach(Array(loadedImages.enumerated()), id: \.offset) { i, image in
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: randomSize(i), height: randomSize(i))
                    .blur(radius: 60 + CGFloat(i) * 5)
                    .opacity(0.08)
                    .offset(
                        x: randomOffset(i, index: i).x,
                        y: randomOffset(i, index: i).y
                    )
                    .animation(
                        .easeInOut(duration: 4 + Double(i)).repeatForever(autoreverses: true),
                        value: loadedImages.count
                    )
            }
        }
        .allowsHitTesting(false)
        .task(id: imageURLs.map(\.absoluteString).joined()) {
            await loadAmbientImages()
        }
    }

    private func loadAmbientImages() async {
        var images: [UIImage] = []
        for url in imageURLs.prefix(5) {
            if let cached = await ImageCache.shared.diskImage(for: url) {
                images.append(cached)
            }
            guard images.count < 3 else { break }
        }
        withAnimation(.easeInOut(duration: 2)) {
            loadedImages = images
        }
    }

    private func randomSize(_ seed: Int) -> CGFloat {
        let sizes: [CGFloat] = [220, 280, 340, 190, 310]
        return sizes[seed % sizes.count]
    }

    private func randomOffset(_ seed: Int, index: Int) -> CGPoint {
        let offsets: [(CGFloat, CGFloat)] = [
            (-100, -200), (140, -100), (-120, 180), (160, 200), (0, -250),
        ]
        let (x, y) = offsets[index % offsets.count]
        return CGPoint(x: x + CGFloat(seed % 20) - 10, y: y + CGFloat(seed % 20) - 10)
    }
}

private struct CuratedOpenHoodGraphic: View {
    let accent: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 34)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 34)
                            .stroke(accent.opacity(0.14), lineWidth: 0.8)
                    )

                Path { path in
                    let points = [
                        CGPoint(x: width * 0.20, y: height * 0.30),
                        CGPoint(x: width * 0.48, y: height * 0.18),
                        CGPoint(x: width * 0.78, y: height * 0.34),
                        CGPoint(x: width * 0.66, y: height * 0.72),
                        CGPoint(x: width * 0.29, y: height * 0.76),
                    ]
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                    path.addLine(to: points[0])
                    path.move(to: points[0])
                    path.addLine(to: points[3])
                    path.move(to: points[1])
                    path.addLine(to: points[4])
                    path.move(to: points[2])
                    path.addLine(to: points[4])
                }
                .stroke(
                    accent.opacity(0.22),
                    style: StrokeStyle(lineWidth: 1.2, dash: [4, 6])
                )

                node("newspaper.fill", x: 0.20, y: 0.30, width: width, height: height)
                node("globe.americas.fill", x: 0.48, y: 0.18, width: width, height: height)
                node("atom", x: 0.78, y: 0.34, width: width, height: height)
                node("music.note", x: 0.66, y: 0.72, width: width, height: height)
                node("theatermasks.fill", x: 0.29, y: 0.76, width: width, height: height)

                ZStack {
                    Circle()
                        .fill(accent)
                        .frame(width: 76, height: 76)
                        .shadow(color: accent.opacity(0.28), radius: 18, y: 7)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .position(x: width * 0.5, y: height * 0.49)
            }
        }
    }

    private func node(
        _ symbol: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(accent)
            .frame(width: 45, height: 45)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(accent.opacity(0.15), lineWidth: 0.6))
            .position(x: width * x, y: height * y)
    }
}
