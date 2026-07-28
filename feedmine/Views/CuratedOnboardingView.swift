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
    @State private var languageSearch = ""
    @State private var session: CuratedOnboardingSession?
    @State private var feedName = "My Curated Feed"
    @State private var candidateTask: Task<Void, Never>?
    @State private var answerDelayTask: Task<Void, Never>?
    @State private var candidateAttempts = 0
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var answerPulse = 0

    // Animation state
    @State private var welcomeAppeared = false
    @State private var headlineVisible = false
    @State private var ctaVisible = false
    @State private var choiceFeedback: (id: String, position: CGPoint)? = nil
    @State private var constellationNodes: [CGPoint] = []

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
                topBar
                Group {
                    switch stage {
                    case .welcome:
                        welcomePage
                    case .languages:
                        languagePage
                    case .comparisons:
                        comparisonPage
                    case .review:
                        reviewPage
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity.animation(.easeInOut(duration: 0.35)),
                        removal: .opacity.animation(.easeInOut(duration: 0.2))
                    )
                )
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
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if stage != .welcome {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("Back")
            } else {
                Color.clear.frame(width: 36, height: 36)
            }

            VStack(spacing: 5) {
                Text(stageTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(engine.accent.opacity(0.12))
                        Capsule()
                            .fill(engine.accent)
                            .frame(width: geometry.size.width * stageProgress)
                    }
                }
                .frame(height: 3)
            }

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel(isFirstRun ? "Use Everything for now" : "Close")
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var stageTitle: String {
        switch stage {
        case .welcome: return "WELCOME"
        case .languages: return "YOUR LANGUAGES"
        case .comparisons:
            return session.map { "CHOICE \($0.answerCount + 1)" } ?? "CURATING"
        case .review: return "OPEN HOOD"
        }
    }

    private var stageProgress: Double {
        switch stage {
        case .welcome: return 0.08
        case .languages: return 0.2
        case .comparisons: return 0.2 + (session?.progress ?? 0) * 0.62
        case .review: return 1
        }
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        ZStack {
            // Background: ghostly feed cards drifting behind heavy glass
            feedCardsBehindGlass

            // Foreground content
            VStack(spacing: 0) {
                Spacer()

                // Icon with orbiting ring
                ZStack {
                    Circle()
                        .stroke(engine.accent.opacity(0.2), lineWidth: 1.5)
                        .frame(width: 100, height: 100)
                        .scaleEffect(welcomeAppeared ? 1 : 0.3)
                        .opacity(welcomeAppeared ? 1 : 0)

                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(engine.accent)
                            .frame(width: 6, height: 6)
                            .offset(y: -50)
                            .rotationEffect(.degrees(Double(i) * 120 + (welcomeAppeared ? 360 : 0)))
                            .animation(
                                .linear(duration: 8).repeatForever(autoreverses: false),
                                value: welcomeAppeared
                            )
                    }

                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(engine.accent)
                        .scaleEffect(welcomeAppeared ? 1 : 0.5)
                        .opacity(welcomeAppeared ? 1 : 0)
                }
                .padding(.bottom, 48)

                // Headline — staggered word reveal
                staggeredHeadline
                    .padding(.bottom, 20)

                // Body
                Text("Choose between real stories. Feedmine learns what you want\nwithout guessing who you are — and shows every preference it creates.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.horizontal, 32)
                    .opacity(headlineVisible ? 1 : 0)
                    .offset(y: headlineVisible ? 0 : 20)

                Spacer()

                // CTA
                VStack(spacing: 14) {
                    Button {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                            stage = .languages
                        }
                    } label: {
                        Text("Build my feed")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .padding(.horizontal, 24)
                    .opacity(ctaVisible ? 1 : 0)
                    .offset(y: ctaVisible ? 0 : 16)
                    .accessibilityIdentifier("curated-onboarding-start")

                    Button(isFirstRun ? "Use Everything for now" : "Not now") {
                        onCancel()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .opacity(ctaVisible ? 1 : 0)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            animateWelcomeEntrance()
        }
    }

    // Ghostly feed cards drifting behind heavy glass.
    // Uses hashed values (not random) to keep positions stable across body recomputations.
    private var feedCardsBehindGlass: some View {
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
                    .rotationEffect(.degrees(Double(i) * 23 + (welcomeAppeared ? 5 : -5)))
                    .offset(x: spec.x, y: spec.y)
                    .opacity(welcomeAppeared ? spec.opacity : 0)
                    .animation(
                        .easeInOut(duration: 1.2)
                            .delay(Double(i) * 0.12),
                        value: welcomeAppeared
                    )
            }
        }
        .overlay(.ultraThinMaterial.opacity(0.92))
        .allowsHitTesting(false)
    }

    // Word-by-word headline reveal
    private var staggeredHeadline: some View {
        let words = ["A feed that", "explains itself."]
        return VStack(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(engine.font(for: .articleHeadline, size: 38))
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .opacity(headlineVisible ? 1 : 0)
                    .offset(y: headlineVisible ? 0 : 24)
                    .blur(radius: headlineVisible ? 0 : 8)
                    .animation(
                        .spring(response: 0.6, dampingFraction: 0.7)
                            .delay(0.25 + Double(i) * 0.18),
                        value: headlineVisible
                    )
            }
        }
    }

    private func animateWelcomeEntrance() {
        withAnimation(.easeOut(duration: 0.6)) { welcomeAppeared = true }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.35)) {
            headlineVisible = true
        }
        withAnimation(.easeOut(duration: 0.5).delay(0.9)) { ctaVisible = true }
    }

    // MARK: - Languages

    private var languagePage: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What can you comfortably read?")
                    .font(engine.font(for: .articleHeadline, size: 28))
                    .fontWeight(.bold)
                Text("Language is the only thing we ask directly. It says nothing about where you live or who you are.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 12)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find a language", text: $languageSearch)
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 22)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(filteredLanguageOptions) { language in
                        languageButton(language)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }

            Button {
                startComparisons()
            } label: {
                HStack {
                    Text(selectedLanguages.count == 1
                        ? "Continue with 1 language"
                        : "Continue with \(selectedLanguages.count) languages")
                    Image(systemName: "arrow.right")
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .disabled(selectedLanguages.isEmpty)
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
            .accessibilityIdentifier("curated-languages-continue")
        }
    }

    private func languageButton(_ language: FeedLoader.LanguageInfo) -> some View {
        let selected = selectedLanguages.contains(language.code)
        return Button {
            if selected {
                selectedLanguages.remove(language.code)
            } else {
                selectedLanguages.insert(language.code)
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 10) {
                Text(language.flag)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text("\(language.totalFeedCount) sources")
                        .font(.caption2)
                        .foregroundStyle(selected ? .white.opacity(0.75) : .secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .white : .secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(selected ? .white : .primary)
            .background(
                selected ? AnyShapeStyle(engine.accent) : AnyShapeStyle(.thinMaterial),
                in: RoundedRectangle(cornerRadius: 15)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("curated-language-\(language.code)")
        .accessibilityValue(selected ? "selected" : "not selected")
    }

    private var filteredLanguageOptions: [FeedLoader.LanguageInfo] {
        let options = languageOptions
        let query = languageSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.code.localizedCaseInsensitiveContains(query)
        }
    }

    private var languageOptions: [FeedLoader.LanguageInfo] {
        let live = loader.availableLanguages
        if !live.isEmpty { return live }
        let common = ["en", "pt", "es", "fr", "de", "it", "ar", "hi", "zh", "ja", "he", "ru"]
        return common.map { code in
            FeedLoader.LanguageInfo(
                code: code,
                name: Locale.current.localizedString(forLanguageCode: code) ?? code,
                flag: fallbackFlag(for: code),
                feedCount: 0,
                totalFeedCount: 0
            )
        }
    }

    // MARK: - Comparisons

    @ViewBuilder
    private var comparisonPage: some View {
        if let session {
            VStack(spacing: 10) {
                comparisonHeader(session)

                if let pair = session.currentPair {
                    VStack(spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            CuratedStoryChoiceCard(
                                candidate: pair.left,
                                marker: "A",
                                accent: engine.accent
                            ) {
                                answer(.left)
                            }

                            CuratedStoryChoiceCard(
                                candidate: pair.right,
                                marker: "B",
                                accent: engine.accent
                            ) {
                                answer(.right)
                            }
                        }
                        .id(pair.id)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            )
                        )

                        HStack(spacing: 10) {
                            alternativeButton("Both", icon: "square.on.square") {
                                answer(.both)
                            }
                            alternativeButton("Neither", icon: "minus.circle") {
                                answer(.neither)
                            }
                        }

                        HStack {
                            Button {
                                answerDelayTask?.cancel()
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    session.undo()
                                }
                            } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                            }
                            .disabled(!session.canUndo)
                            .opacity(session.canUndo ? 1 : 0.3)

                            Spacer()

                            if session.canFinish {
                                Button(session.reachedTarget ? "Review my feed" : "Finish now") {
                                    withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                                        stage = .review
                                    }
                                }
                                .fontWeight(.semibold)
                                .accessibilityIdentifier("curated-review")
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding(.horizontal, 18)
                } else {
                    candidateLoadingState(session)
                }
                Spacer(minLength: 8)
            }
        } else {
            ProgressView()
        }
    }

    private func comparisonHeader(_ session: CuratedOnboardingSession) -> some View {
        VStack(spacing: 8) {
            Text("Which would you open first?")
                .font(engine.font(for: .articleHeadline, size: 25))
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            Text(comparisonSubtitle(session))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Constellation progress: dots connect as answers accumulate
            HStack(spacing: 5) {
                ForEach(0..<CuratedOnboardingSession.targetAnswers, id: \.self) { i in
                    Circle()
                        .fill(i < session.answerCount ? engine.accent : engine.accent.opacity(0.15))
                        .frame(
                            width: i < session.answerCount ? 8 : 5,
                            height: i < session.answerCount ? 8 : 5
                        )
                        .scaleEffect(i == session.answerCount ? 1.4 : 1)
                        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: session.answerCount)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            if session.answerCount > 0 {
                Text("\(session.answerCount) of \(CuratedOnboardingSession.targetAnswers)")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func comparisonSubtitle(_ session: CuratedOnboardingSession) -> String {
        if session.answerCount < 3 {
            return "Two editorially selected stories. No answer defines you."
        }
        if session.answerCount < CuratedOnboardingSession.minimumAnswers {
            return "Topics, references, specialists, and distinctive voices."
        }
        if session.reachedTarget {
            return "Your feed is ready. Keep going or inspect the result."
        }
        return "We have a first mix. A few more choices improve confidence."
    }

    private func alternativeButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(engine.accent.opacity(0.1), lineWidth: 0.5)
        )
        .accessibilityIdentifier("curated-choice-\(title.lowercased())")
    }

    private func candidateLoadingState(
        _ session: CuratedOnboardingSession
    ) -> some View {
        VStack(spacing: 20) {
            Spacer()
            // Animated orbiting dots
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

    // MARK: - Review

    @ViewBuilder
    private var reviewPage: some View {
        if let session {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(engine.accent.opacity(0.12))
                                .frame(width: 70, height: 70)
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(engine.accent)
                        }
                        Text("Your feed, in plain sight.")
                            .font(engine.font(for: .articleHeadline, size: 29))
                            .fontWeight(.bold)
                        Text("These are preferences, not a personality verdict. Change anything before saving.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 26)
                    }
                    .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("NAME")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                        TextField("Curated Feed name", text: $feedName)
                            .font(.headline)
                            .padding(14)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 22)

                    CuratedProfileControls(
                        profile: session.profile,
                        accent: engine.accent,
                        onTopicChange: { session.setTopicWeight($0, $1) },
                        onEditorialChange: { session.setEditorialWeight($0, $1) },
                        onDiscoveryChange: { session.setDiscoveryLevel($0) },
                        onLearningChange: { session.setLearningEnabled($0) }
                    )
                    .padding(.horizontal, 22)

                    Button {
                        Task { await save(session) }
                    } label: {
                        Group {
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Label("Save & open this feed", systemImage: "checkmark")
                            }
                        }
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .disabled(
                        isSaving
                            || feedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .padding(.horizontal, 22)
                    .accessibilityIdentifier("curated-save")

                    Text("Stored only on this device. You can inspect, edit, duplicate, or delete it later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.bottom, 28)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

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
        Task {
            let feeds = (try? await loader.loadCuratedFeeds()) ?? []
            let count = feeds.count
            if count > 0 {
                feedName = "Curated Feed \(count + 1)"
            }
        }
    }

    private func startComparisons() {
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

                // Warm images for the pending pair BEFORE publishing it.
                // Cards must never render with placeholder gradients.
                if let pair = session.pendingPair {
                    await warmPairImages(pair)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        session.publishPendingPair()
                    }
                    return
                }
                // No pair yet — wait and retry.
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// Pre-load images for both cards in a pair so they render with photos,
    /// not placeholder gradients. Waits for BOTH images — cards must never
    /// appear with one loaded and one still downloading. Times out at 4
    /// seconds so onboarding never stalls.
    private func warmPairImages(_ pair: CuratedComparisonPair) async {
        let urlStrings = [pair.left, pair.right].compactMap {
            $0.item.bestImageURL ?? $0.item.imageURL
        }
        guard !urlStrings.isEmpty else { return }

        let urls = urlStrings.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return }

        // Initiate prefetch through the loader's prefetcher
        await loader.prefetcher.prefetch(urls: urls.map(\.absoluteString), priorityURLs: urls.map(\.absoluteString))

        // Wait up to 4 seconds for ALL available images to land in cache.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if Task.isCancelled { break }
            if urls.allSatisfy({ ImageCache.hasCachedImageData(for: $0) }) { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func answer(_ outcome: CuratedChoiceOutcome) {
        guard let session else { return }

        // Cancel any in-flight warming from the previous answer
        answerDelayTask?.cancel()

        // Celebration feedback sequence
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            answerPulse += 1
            session.answer(outcome)
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

        // session.answer(outcome) sets the next pair directly via chooseNextPair().
        // Warm images for the newly visible pair in the background.
        if let nextPair = session.currentPair {
            answerDelayTask = Task { @MainActor in
                await warmPairImages(nextPair)
            }
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
        do {
            let saved = try await loader.createCuratedFeed(
                name: feedName,
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

private struct CuratedPressStyle: ButtonStyle {
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
