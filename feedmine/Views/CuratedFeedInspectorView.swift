import SwiftUI

/// The "open hood" editor for a saved Curated Feed. Every learned value is
/// readable and mutable; the model intentionally contains no identity labels.
struct CuratedFeedInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FeedLoader.self) private var loader
    @State private var engine = CircadianEngine.shared
    @State private var feed: CuratedFeed?
    @State private var name = ""
    @State private var profile = CuratedProfileDefinition()
    @State private var showAllLanguages = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    let curatedFeedID: Int64

    var body: some View {
        NavigationStack {
            ZStack {
                engine.pageBackground.ignoresSafeArea()
                CuratedInspectorBackdrop(accent: engine.accent)
                    .ignoresSafeArea()

                if feed == nil {
                    ProgressView("Opening the hood…")
                } else {
                    inspector
                }
            }
            .navigationTitle("Curated Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaving || normalizedName.isEmpty)
                }
            }
        }
        .tint(engine.accent)
        .task { await load() }
        .alert("Couldn’t update this feed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(spacing: 18) {
                identityCard
                languageCard
                CuratedProfileControls(
                    profile: profile,
                    accent: engine.accent,
                    onTopicChange: setTopic,
                    onEditorialChange: setEditorial,
                    onDiscoveryChange: setDiscovery,
                    onLearningChange: setLearning
                )
                evidenceCard
                privacyNote
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(engine.accent, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text("OPEN HOOD")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(engine.accent)
                    Text("Nothing hidden here.")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Edit what Feedmine learned, or turn learning off.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Feed name", text: $name)
                .font(.headline)
                .padding(14)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))

            HStack(spacing: 8) {
                metric("\(profile.responseCount)", "choices")
                metric("\(activePreferenceCount)", "signals")
                metric("\(Int(profile.discoveryLevel * 100))%", "discovery")
            }
        }
        .padding(17)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(engine.accent.opacity(0.12), lineWidth: 0.6)
        )
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showAllLanguages.toggle()
                }
            } label: {
                HStack {
                    Label("Languages", systemImage: "character.book.closed.fill")
                        .font(.headline)
                    Spacer()
                    Text("\(profile.languages.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: showAllLanguages ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if !profile.languages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(profile.languages, id: \.self) { code in
                            Label(languageName(code), systemImage: "checkmark")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .foregroundStyle(engine.accent)
                                .background(engine.accent.opacity(0.1), in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if showAllLanguages {
                Divider()
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(languageOptions) { language in
                        languageToggle(language)
                    }
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func languageToggle(_ language: FeedLoader.LanguageInfo) -> some View {
        let selected = profile.languages.contains(language.code)
        return Button {
            var languages = Set(profile.languages)
            if selected, languages.count > 1 {
                languages.remove(language.code)
            } else {
                languages.insert(language.code)
            }
            profile.languages = languages.sorted()
        } label: {
            HStack(spacing: 7) {
                Text(language.flag)
                Text(language.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            }
            .font(.caption)
            .fontWeight(selected ? .semibold : .regular)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42)
            .foregroundStyle(selected ? engine.accent : .primary)
            .background(
                selected ? engine.accent.opacity(0.1) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
    }

    private var evidenceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Why this mix?", systemImage: "list.bullet.clipboard.fill")
                .font(.headline)

            if profile.evidence.isEmpty {
                Text("This feed started balanced. Adjust the controls above whenever you like.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Its preference trail is local and human-readable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(profile.evidence.suffix(12).reversed())) { item in
                    evidenceRow(item)
                    if item.id != profile.evidence.suffix(12).first?.id {
                        Divider().opacity(0.55)
                    }
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func evidenceRow(_ item: CuratedEvidence) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(item.outcome.displayName)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(engine.accent)
                Spacer()
                Text(item.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if item.outcome == .left || item.outcome == .both || item.outcome == .opened {
                storyLine(
                    item.leftTitle,
                    source: item.leftSource,
                    marker: item.outcome == .opened ? "↗" : "A"
                )
            }
            if item.outcome == .right || item.outcome == .both {
                storyLine(item.rightTitle, source: item.rightSource, marker: "B")
            }
            if item.outcome == .neither {
                Text("Neither “\(item.leftTitle)” nor “\(item.rightTitle)”")
                    .font(.caption)
                    .lineLimit(3)
            }

            Text(item.affectedKeys.map(\.curatedFeatureDisplayName).joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func storyLine(_ title: String, source: String, marker: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker)
                .font(.caption2)
                .fontWeight(.black)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(engine.accent, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var privacyNote: some View {
        Label {
            Text("No personality, religion, ethnicity, gender, location, or demographic label is inferred or stored.")
        } icon: {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(engine.accent)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    private var languageOptions: [FeedLoader.LanguageInfo] {
        if !loader.availableLanguages.isEmpty {
            return loader.availableLanguages
        }
        return profile.languages.map { code in
            FeedLoader.LanguageInfo(
                code: code,
                name: languageName(code),
                flag: "🌐",
                feedCount: 0,
                totalFeedCount: 0
            )
        }
    }

    private var activePreferenceCount: Int {
        profile.weights.values.filter { abs($0) > 0.05 }.count
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    private func setTopic(_ topic: CuratedTopic, _ value: Double) {
        profile.weights[topic.featureKey] = min(3, max(-3, value))
    }

    private func setEditorial(_ style: CuratedEditorialStyle, _ value: Double) {
        profile.weights[style.featureKey] = min(3, max(-3, value))
    }

    private func setDiscovery(_ value: Double) {
        profile.discoveryLevel = min(1, max(0, value))
    }

    private func setLearning(_ enabled: Bool) {
        profile.learningEnabled = enabled
    }

    @MainActor
    private func load() async {
        do {
            guard let loaded = try await loader.loadCuratedFeeds()
                .first(where: { $0.id == curatedFeedID }) else {
                errorMessage = "This Curated Feed no longer exists."
                return
            }
            feed = loaded
            name = loaded.name
            profile = loaded.definition
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard var updated = feed else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            updated = try await loader.updateCuratedFeed(
                id: updated.id,
                name: normalizedName,
                definition: profile
            )
            feed = updated
            loader.setActivePreset(.curatedFeed(
                curatedFeedID: updated.id,
                curatedFeedName: updated.name
            ))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CuratedInspectorBackdrop: View {
    let accent: Color

    var body: some View {
        GeometryReader { geometry in
            Circle()
                .fill(accent.opacity(0.08))
                .frame(width: 280, height: 280)
                .blur(radius: 38)
                .position(x: geometry.size.width + 35, y: 90)
        }
        .allowsHitTesting(false)
    }
}
