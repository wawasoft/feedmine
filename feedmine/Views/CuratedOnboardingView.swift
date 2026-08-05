import SwiftUI
import UIKit

/// Two-stage onboarding: a brand welcome screen, then an optional composer
/// where the user shapes their first feed recipe. "Start broad" saves an
/// immediately usable neutral recipe and dismisses.
struct CuratedOnboardingView: View {
    enum Stage {
        case welcome
        case composer
    }

    @Environment(FeedLoader.self) private var loader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = CircadianEngine.shared
    @State private var stage: Stage = .welcome
    @State private var recipe: FeedRecipeDefinition
    @State private var isSaving = false
    @State private var errorMessage: String?

    let isFirstRun: Bool
    var onCancel: () -> Void = {}
    var onSaved: (CuratedFeed) -> Void = { _ in }

    init(
        isFirstRun: Bool,
        onCancel: @escaping () -> Void = {},
        onSaved: @escaping (CuratedFeed) -> Void = { _ in }
    ) {
        self.isFirstRun = isFirstRun
        self.onCancel = onCancel
        self.onSaved = onSaved
        _recipe = State(initialValue: FeedRecipeDefinition.neutral(
            languages: [Self.deviceLanguageCode]
        ))
    }

    /// Device language, used to seed the neutral recipe on first run,
    /// Start broad, and Reset to neutral.
    private static var deviceLanguageCode: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    /// Article images from the visible feed — used as ambient backdrop glows
    /// so the background reflects real content, not static decor.
    private var ambientImageURLs: [URL] {
        loader.items.prefix(8).compactMap {
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
                        WelcomeScene(
                            accent: engine.accent,
                            onShape: moveToComposer,
                            onStartBroad: startBroad
                        )
                    case .composer:
                        FeedComposerScene(
                            recipe: $recipe,
                            onSave: { Task { await save() } },
                            onStartBroad: startBroad,
                            onReset: resetToNeutral
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
        .alert(String(localized: "Couldn’t save this feed"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack {
            Color.clear.frame(width: 36, height: 36)

            Spacer()

            Button { onCancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel(String(localized: "Close"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Actions

    private func moveToComposer() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.7)) {
            stage = .composer
        }
    }

    /// "Start broad" — reset the recipe to neutral and save immediately.
    private func startBroad() {
        recipe = FeedRecipeDefinition.neutral(languages: [Self.deviceLanguageCode])
        Task { await save() }
    }

    /// Reset the composer's recipe in place without saving.
    private func resetToNeutral() {
        recipe = FeedRecipeDefinition.neutral(languages: [Self.deviceLanguageCode])
    }

    /// Save the current recipe as a new curated feed: resolve the effective
    /// profile from recipe + evidence, persist it, activate it, then dismiss.
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let name = autoName()
        let evidence = CuratedProfileDefinition(languages: recipe.languages)
        let effectiveProfile = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        do {
            let saved = try await loader.createCuratedFeed(
                name: name,
                definition: effectiveProfile,
                recipe: recipe
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

    /// Feed name from the topics the user asked for more of, falling back
    /// to a warm default when no explicit preferences exist yet.
    private func autoName() -> String {
        let moreTopics = recipe.topicPreferences
            .filter { $0.value == .more }
            .compactMap { kv in
                CuratedTopic.allCases.first { $0.featureKey == kv.key }?.displayName
            }
        if moreTopics.count == 1 {
            return moreTopics[0]
        } else if moreTopics.count >= 2 {
            return "\(moreTopics[0]) & \(moreTopics[1])"
        }
        return "My Feed"
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

struct CuratedPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? -0.025 : 0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: - Decorative artwork

/// Ambient backdrop built from real article images in the visible feed.
/// Heavily blurred and dimmed so they create atmosphere without distracting.
private struct CuratedBackdrop: View {
    let accent: Color
    let imageURLs: [URL]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 4 + Double(i)).repeatForever(autoreverses: true),
                        value: loadedImages.count
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)  // decorative backdrop
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
        if reduceMotion {
            loadedImages = images
        } else {
            withAnimation(.easeInOut(duration: 2)) {
                loadedImages = images
            }
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
