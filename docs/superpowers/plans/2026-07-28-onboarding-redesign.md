# Onboarding Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the onboarding from a configuration-heavy questionnaire into an editorial "edit your first edition" experience — vertical story duels, adaptive completion, feed preview instead of technical review, optional name, and continuous transition to the feed.

**Architecture:** Break the 1300-line `CuratedOnboardingView` monolith into scoped scene components under `feedmine/Views/Onboarding/`, coordinated by a thin `OnboardingCoordinator`. The session model (`CuratedOnboardingSession`) gains a `.skip` outcome, adaptive completion logic, and a ready-pair queue. The final stage changes from technical sliders to a feed preview with preference chips.

**Tech Stack:** SwiftUI, iOS 17+, @Observable, async/await, existing CuratedPreferenceEngine/FeedLoader/ImageCache

## Global Constraints

- Minimum iOS 17 deployment target
- No external dependencies beyond existing project deps
- All user-facing strings use plain English following the design doc's tone-of-voice guidelines
- Privacy language is factual, not anxious: "Built and stored on this device"
- No flags for languages — use localized names or neutral symbols
- No editorial labels visible during choice — only after feedback
- Image warming: both cards must have equivalent visual state before display
- Maintain backward compatibility: existing `CuratedProfileControls` stays available in the inspector
- All new views must work with Reduce Motion (no infinite animations without opt-out)
- All new views must support Dynamic Type
- Existing UI tests (`testCuratedOnboardingCreatesAnInspectableFeedFromRealStores`) must pass or be updated

---

### Task 1: Add `.skip` outcome to the model layer

**Files:**
- Modify: `feedmine/Models/CuratedFeed.swift:71-87`
- Modify: `feedmine/Services/CuratedPreferenceEngine.swift` (add `applying` skip case)
- Modify: `feedmine/Services/CuratedPreferenceEngine.swift:887-1013` (session handles skip)

**Interfaces:**
- Consumes: `CuratedChoiceOutcome` enum, `CuratedPreferenceEngine.applying(outcome:pair:to:)`, `CuratedOnboardingSession.answer(_:)`
- Produces: `CuratedChoiceOutcome.skip` case, skip-aware `applying` (no-op for signals), skip-aware `answer` (doesn't count toward answerCount)

- [ ] **Step 1: Add `.skip` case to CuratedChoiceOutcome**

In `feedmine/Models/CuratedFeed.swift`, add `.skip` to the enum:

```swift
enum CuratedChoiceOutcome: String, Codable, Sendable, Hashable, CaseIterable {
    case left
    case right
    case both
    case neither
    case skip     // <-- ADD
    case opened

    var displayName: String {
        switch self {
        case .left: return "First story"
        case .right: return "Second story"
        case .both: return "Both"
        case .neither: return "Neither"
        case .skip: return "Skipped"       // <-- ADD
        case .opened: return "Opened"
        }
    }
}
```

- [ ] **Step 2: Handle skip in CuratedPreferenceEngine.applying**

Find the `applying(outcome:pair:to:)` method in `CuratedPreferenceEngine.swift`. Add early return for `.skip`:

```swift
static func applying(
    outcome: CuratedChoiceOutcome,
    pair: CuratedComparisonPair,
    to profile: CuratedProfileDefinition
) -> CuratedProfileDefinition {
    // Skip records no signal — it's the absence of evidence
    if outcome == .skip {
        var skipped = profile
        // Still record evidence so the pair isn't re-shown, but affect nothing
        let evidence = CuratedEvidence(
            leftTitle: pair.left.item.title,
            leftSource: pair.left.item.sourceTitle,
            rightTitle: pair.right.item.title,
            rightSource: pair.right.item.sourceTitle,
            outcome: .skip,
            affectedKeys: []
        )
        skipped.evidence.append(evidence)
        return skipped
    }
    // ... existing logic for left/right/both/neither continues below
```

- [ ] **Step 3: Update CuratedOnboardingSession.answer for skip**

In `CuratedOnboardingSession.answer(_:)`, skip still consumes the pair (marks items as used) but doesn't increment `responseCount` for `.skip`. The existing evidence append already handles this because `CuratedEvidence.outcome == .skip` → `responseCount` filter (`evidence.lazy.filter { $0.outcome != .opened }.count`) counts skip as an answer... Actually, we need `.skip` to NOT count toward `answerCount`:

```swift
var answerCount: Int {
    profile.evidence.lazy.filter { $0.outcome != .opened && $0.outcome != .skip }.count
}
```

Wait — let me re-read the `responseCount`:

```swift
var responseCount: Int {
    evidence.lazy.filter { $0.outcome != .opened }.count
}
```

Change to also exclude `.skip`:

```swift
var responseCount: Int {
    evidence.lazy.filter { $0.outcome != .opened && $0.outcome != .skip }.count
}
```

Also update `canFinish` to count actual answers (not skips). The existing check is on `answerCount` which now excludes skips, so this is automatic.

- [ ] **Step 4: Build and run tests**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' test 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
git add feedmine/Models/CuratedFeed.swift feedmine/Services/CuratedPreferenceEngine.swift
git commit -m "feat: add .skip outcome to CuratedChoiceOutcome — records no signal

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Adaptive completion — reduce minimum answers, add signal-coverage check

**Files:**
- Modify: `feedmine/Services/CuratedPreferenceEngine.swift:887-1013` (CuratedOnboardingSession)

**Interfaces:**
- Consumes: `CuratedOnboardingSession.minimumAnswers`, `targetAnswers`, `canFinish`, `reachedTarget`, `isComplete`
- Produces: `minimumAnswers = 5`, `targetAnswers` removed, new `isReady` based on topic + editorial diversity, `canFinish` → `answerCount >= 5`, `reachedTarget` → `isReady`

- [ ] **Step 1: Change session constants and add coverage check**

```swift
@MainActor
@Observable
final class CuratedOnboardingSession {
    static let minimumAnswers = 5       // was 8
    // targetAnswers removed — completion is now adaptive
    static let maximumAnswers = 20      // unchanged safety cap

    // ... existing properties ...

    var answerCount: Int {
        profile.responseCount  // now excludes .skip from Task 1
    }

    var canFinish: Bool {
        answerCount >= Self.minimumAnswers
    }

    /// True when the system has enough signal diversity to produce a meaningful feed.
    /// Requires: ≥3 distinct topics with evidence AND ≥2 editorial styles with evidence.
    var isReady: Bool {
        guard answerCount >= Self.minimumAnswers else { return false }

        let answeredKeys = Set(profile.evidence
            .filter { $0.outcome != .skip && $0.outcome != .opened }
            .flatMap(\.affectedKeys))

        let topicKeys = answeredKeys.filter { $0.hasPrefix("topic:") }
        let editorialKeys = answeredKeys.filter { $0.hasPrefix("editorial:") }

        return topicKeys.count >= 3 && editorialKeys.count >= 2
    }

    var reachedTarget: Bool { isReady }  // backward compat alias

    var isComplete: Bool {
        answerCount >= Self.maximumAnswers
    }

    var progress: Double {
        // Qualitative: 0.0 until minimumAnswers, then climbs toward 1.0 at ready
        if answerCount < Self.minimumAnswers {
            return Double(answerCount) / Double(Self.minimumAnswers) * 0.5
        }
        if isReady { return 1.0 }
        return 0.5 + 0.5 * Double(answerCount - Self.minimumAnswers) / Double(Self.maximumAnswers - Self.minimumAnswers)
    }
```

- [ ] **Step 2: Build to verify compilation**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 3: Run existing tests to verify no regressions**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' test 2>&1 | grep -E "(passed|failed|TEST)"
```

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/CuratedPreferenceEngine.swift
git commit -m "feat: adaptive onboarding completion — 5 minimum, signal-coverage check

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Optional feed name with auto-generation

**Files:**
- Modify: `feedmine/Views/CuratedOnboardingView.swift:739-747` (prepareDefaultName)
- Modify: `feedmine/Views/CuratedOnboardingView.swift:689-710` (save button disabled state)
- Modify: `feedmine/Views/CuratedOnboardingView.swift:855-871` (save method)

**Interfaces:**
- Consumes: `feedName` binding, `prepareDefaultName()`, save button validation
- Produces: Auto-generated name based on top topics, save button always enabled, `feedName` defaults to smart name

- [ ] **Step 1: Update prepareDefaultName to generate smart names**

```swift
private func prepareDefaultName() {
    // Generate based on top two preference signals, or a warm default.
    // The name updates dynamically as the session accumulates answers.
    updateAutoName()
}

private func updateAutoName() {
    guard let session else {
        feedName = "My Feed"
        return
    }
    let topTopics = CuratedPreferenceEngine.topTopicWeights(
        in: session.profile, limit: 2
    ).map(\.topic.shortName)
    if topTopics.count >= 2 {
        feedName = "\(topTopics[0]) & \(topTopics[1])"
    } else if let first = topTopics.first {
        feedName = "\(first) Mix"
    } else {
        feedName = "My First Feed"
    }
}
```

- [ ] **Step 2: Remove name requirement from save button**

Change the save button's `.disabled` modifier from:
```swift
.disabled(isSaving || feedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
```
to:
```swift
.disabled(isSaving)
```

- [ ] **Step 3: Update save to use fallback name**

```swift
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
```

- [ ] **Step 4: Build verify**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add feedmine/Views/CuratedOnboardingView.swift
git commit -m "feat: auto-generated feed name, optional during onboarding

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Create OnboardingPairQueue for background pair preparation

**Files:**
- Create: `feedmine/Services/OnboardingPairQueue.swift`
- Modify: `feedmine/Views/CuratedOnboardingView.swift` (wire queue, start prefetch on welcome)

**Interfaces:**
- Consumes: `FeedLoader.curatedOnboardingCandidates(languages:)`, `ImageCache`, `CuratedOnboardingSession`
- Produces: `OnboardingPairQueue` class with `start(languages:)`, `nextReadyPair() async -> CuratedComparisonPair?`, image warming that blocks until BOTH images are cached, prefetch of next 2 pairs

- [ ] **Step 1: Create OnboardingPairQueue**

New file `feedmine/Services/OnboardingPairQueue.swift`:

```swift
import Foundation

/// Maintains a pipeline of ready-to-display comparison pairs so the UI never
/// shows a loading state between choices. Images are warmed for both cards
/// before a pair is considered ready.
@MainActor
final class OnboardingPairQueue {
    private let loader: FeedLoader
    private var readyPairs: [CuratedComparisonPair] = []
    private var preparationTask: Task<Void, Never>?
    private var isRunning = false

    /// Exposed so the UI can surface the first pair immediately when ready.
    var onPairReady: ((CuratedComparisonPair) -> Void)?

    init(loader: FeedLoader) {
        self.loader = loader
    }

    func start(languages: Set<String>) {
        guard !isRunning else { return }
        isRunning = true
        preparationTask = Task { @MainActor in
            await fillPipeline(languages: languages)
        }
    }

    func stop() {
        isRunning = false
        preparationTask?.cancel()
        preparationTask = nil
        readyPairs.removeAll()
    }

    /// Returns the next ready pair or nil if none available yet.
    func dequeueReadyPair() -> CuratedComparisonPair? {
        guard !readyPairs.isEmpty else { return nil }
        return readyPairs.removeFirst()
    }

    var readyCount: Int { readyPairs.count }

    private func fillPipeline(languages: Set<String>) async {
        while isRunning && !Task.isCancelled {
            // Keep 3 pairs ready
            while readyPairs.count < 3 && !Task.isCancelled {
                guard let pair = await prepareOnePair(languages: languages) else {
                    // Pool exhausted — wait and retry
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                readyPairs.append(pair)
                onPairReady?(pair)
            }
            // Wait until we need more
            while readyPairs.count >= 3 && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func prepareOnePair(languages: Set<String>) async -> CuratedComparisonPair? {
        // Get fresh candidates from the loader
        let candidates = await loader.curatedOnboardingCandidates(languages: languages)
        guard !candidates.isEmpty else { return nil }

        // Use the engine to select a pair (session-agnostic)
        let profile = CuratedProfileDefinition(languages: Array(languages))
        guard let pair = CuratedPreferenceEngine.nextPair(
            candidates: candidates,
            profile: profile,
            usedItemIDs: [],  // will be filtered by session later
            usedPairIDs: []
        ) else { return nil }

        // Warm BOTH images — block until ready
        await warmBothImages(for: pair)
        return pair
    }

    /// Initiate downloads and wait until BOTH images are cached (or timeout).
    private func warmBothImages(for pair: CuratedComparisonPair) async {
        let urlStrings = [pair.left, pair.right].compactMap {
            $0.item.bestImageURL ?? $0.item.imageURL
        }
        let urls = urlStrings.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return }

        // Initiate prefetch
        await loader.prefetcher.prefetch(
            urls: urls.map(\.absoluteString),
            priorityURLs: urls.map(\.absoluteString)
        )

        // Wait until ALL urls are cached (not just one)
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if Task.isCancelled { break }
            if urls.allSatisfy({ ImageCache.hasCachedImageData(for: $0) }) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
```

- [ ] **Step 2: Wire queue into CuratedOnboardingView**

Add the queue as a state object and start prefetch on welcome appear:

In `CuratedOnboardingView`:
```swift
@State private var pairQueue: OnboardingPairQueue?

// In welcome onAppear, start the queue eagerly:
.onAppear {
    animateWelcomeEntrance()
    // Start preparing pairs in background while user reads welcome screen
    if pairQueue == nil {
        let queue = OnboardingPairQueue(loader: loader)
        pairQueue = queue
        queue.start(languages: selectedLanguages)
    }
}
```

- [ ] **Step 3: Build to verify compilation**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/OnboardingPairQueue.swift feedmine/Views/CuratedOnboardingView.swift
git commit -m "feat: OnboardingPairQueue — prefetch and warm pairs in background

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Create StoryDuelCard and vertical StoryDuelScene

**Files:**
- Create: `feedmine/Views/Onboarding/StoryDuelCard.swift`
- Create: `feedmine/Views/Onboarding/StoryDuelScene.swift`
- Modify: `feedmine/Views/CuratedOnboardingView.swift` (replace HStack comparison with StoryDuelScene)

**Interfaces:**
- Consumes: `CuratedCandidate`, `CuratedComparisonPair`, accent color, answer callback
- Produces: `StoryDuelCard` (full-width card: source name, image, title, format badge), `StoryDuelScene` (vertical layout with Both/Neither/Skip bar, Undo, New Pair)

- [ ] **Step 1: Create directory and StoryDuelCard**

```bash
mkdir -p /Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Views/Onboarding
```

New file `feedmine/Views/Onboarding/StoryDuelCard.swift`:

```swift
import SwiftUI

/// A full-width story card for the vertical comparison layout.
/// Shows only source, image, title, and format badge during choice —
/// no editorial labels, no A/B markers, no "I'd open this" prompt.
struct StoryDuelCard: View {
    let candidate: CuratedCandidate
    let position: StoryDuelPosition  // .top or .bottom
    let accent: Color
    let action: () -> Void

    @State private var imageFailed = false

    enum StoryDuelPosition { case top, bottom }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Source label
                HStack {
                    Text(candidate.item.sourceTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                    Spacer()
                    // Format badge: podcast / video
                    if candidate.item.contentType == .podcast {
                        Label("Podcast", systemImage: "headphones")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if candidate.item.contentType == .video {
                        Label("Video", systemImage: "play.rectangle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Artwork — full width, 16:9 aspect
                artwork
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipped()

                // Title
                Text(candidate.item.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.06), lineWidth: 0.6)
            )
        }
        .buttonStyle(CuratedPressStyle())
    }

    @ViewBuilder
    private var artwork: some View {
        GeometryReader { geometry in
            ZStack {
                // Placeholder gradient
                LinearGradient(
                    colors: [
                        ComponentToken.categoryColor(for: candidate.item.category).opacity(0.48),
                        accent.opacity(0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: candidate.topic.icon)
                    .font(.system(size: 32, weight: .light))
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
```

- [ ] **Step 2: Create StoryDuelScene**

New file `feedmine/Views/Onboarding/StoryDuelScene.swift`:

```swift
import SwiftUI

/// Vertical story comparison — each card gets nearly full width.
/// "Which would you open first?" with Both/Neither/Skip actions.
struct StoryDuelScene: View {
    let pair: CuratedComparisonPair
    let accent: Color
    let canUndo: Bool
    let canFinish: Bool
    let isReady: Bool
    let onChoose: (CuratedChoiceOutcome) -> Void
    let onUndo: () -> Void
    let onNewPair: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Question
            Text("Which would you open first?")
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            Spacer(minLength: 4)

            // Top card
            StoryDuelCard(
                candidate: pair.left,
                position: .top,
                accent: accent,
                action: { onChoose(.left) }
            )

            // Action bar: Both / Neither / Skip
            HStack(spacing: 10) {
                actionPill("Both", icon: "square.on.square") { onChoose(.both) }
                actionPill("Neither", icon: "minus.circle") { onChoose(.neither) }
                actionPill("Skip", icon: "forward.fill") { onChoose(.skip) }
            }
            .padding(.horizontal, 16)

            // Bottom card
            StoryDuelCard(
                candidate: pair.right,
                position: .bottom,
                accent: accent,
                action: { onChoose(.right) }
            )

            // Bottom controls: Undo / New Pair / Finish
            HStack {
                Button { onUndo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!canUndo)
                .opacity(canUndo ? 1 : 0.3)

                Spacer()

                Button { onNewPair() } label: {
                    Label("New pair", systemImage: "arrow.triangle.2.circlepath")
                }

                if canFinish {
                    Button(isReady ? "Review my feed" : "Finish now") {
                        onFinish()
                    }
                    .fontWeight(.semibold)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 20)
        }
    }

    private func actionPill(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
    }
}
```

- [ ] **Step 3: Replace comparisonPage in CuratedOnboardingView**

In `CuratedOnboardingView.swift`, replace the `comparisonPage` computed property to use `StoryDuelScene` instead of the inline HStack layout. The session management (answer, undo, refresh) stays in the parent view.

- [ ] **Step 4: Build verify**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add feedmine/Views/Onboarding/StoryDuelCard.swift feedmine/Views/Onboarding/StoryDuelScene.swift feedmine/Views/CuratedOnboardingView.swift
git commit -m "feat: StoryDuel vertical layout replacing side-by-side HStack

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Choice feedback overlay — show what was learned

**Files:**
- Create: `feedmine/Views/Onboarding/ChoiceFeedbackOverlay.swift`
- Modify: `feedmine/Views/CuratedOnboardingView.swift` (wire feedback state, add 500-700ms delay between answer and next pair)

**Interfaces:**
- Consumes: `CuratedChoiceOutcome`, affected keys from `CuratedEvidence`, accent color
- Produces: `ChoiceFeedbackOverlay` — card grows, other dims, human-readable signals appear, auto-dismisses

- [ ] **Step 1: Create ChoiceFeedbackOverlay**

New file `feedmine/Views/Onboarding/ChoiceFeedbackOverlay.swift`:

```swift
import SwiftUI

/// Appears for ~600ms after each choice showing what was learned.
/// Human-readable signals only — never shows numeric weights.
struct ChoiceFeedbackOverlay: View {
    let outcome: CuratedChoiceOutcome
    let affectedKeys: [String]
    let accent: Color
    let onDismiss: () -> Void

    @State private var visible = false

    var body: some View {
        VStack(spacing: 16) {
            // Outcome summary
            Text(summaryText)
                .font(.title3)
                .fontWeight(.bold)

            // Signal chips — human readable only
            if !signalChips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(signalChips, id: \.self) { chip in
                        Text(chip)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(accent.opacity(0.12), in: Capsule())
                    }
                }
            }

            if outcome != .skip {
                Button("Undo") {
                    onDismiss()
                }
                .font(.subheadline)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.9)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                visible = true
            }
            // Auto-dismiss after 600ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                onDismiss()
            }
        }
    }

    private var summaryText: String {
        switch outcome {
        case .left, .right: return "You chose this"
        case .both: return "Keeping both directions"
        case .neither: return "Showing less of this mix"
        case .skip: return "Skipped"
        case .opened: return "Opened"
        }
    }

    private var signalChips: [String] {
        guard outcome != .skip else { return [] }
        // Map feature keys to human-readable names
        let names = affectedKeys.prefix(3).compactMap { key -> String? in
            let name = key.curatedFeatureDisplayName
            // Filter out overly technical or redundant names
            guard !name.contains(":") else { return nil }
            return name
        }
        return Array(Set(names)).sorted().prefix(2).map { "\($0) ↑" }
    }
}
```

- [ ] **Step 2: Wire feedback into CuratedOnboardingView.answer()**

Modify the `answer` method to:
1. Show `ChoiceFeedbackOverlay` for 600ms
2. Then transition to next pair

```swift
@State private var feedbackOutcome: CuratedChoiceOutcome?
@State private var feedbackKeys: [String] = []

private func answer(_ outcome: CuratedChoiceOutcome) {
    guard let session else { return }

    withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
        answerPulse += 1
        session.answer(outcome)
    }

    // Capture affected keys for feedback
    if let lastEvidence = session.profile.evidence.last {
        feedbackKeys = lastEvidence.affectedKeys
    }
    feedbackOutcome = outcome

    // Haptic
    let impact = UIImpactFeedbackGenerator(style: .medium)
    impact.prepare()
    impact.impactOccurred()
}
```

Add the feedback overlay to the comparison page:

```swift
// Inside comparisonPage, overlay on top of content:
.overlay {
    if let outcome = feedbackOutcome {
        ChoiceFeedbackOverlay(
            outcome: outcome,
            affectedKeys: feedbackKeys,
            accent: engine.accent,
            onDismiss: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    feedbackOutcome = nil
                }
                // Then load next pair
                if session?.currentPair == nil && !(session?.isComplete ?? true) {
                    refreshCandidatePool()
                }
                if session?.isReady ?? false {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                        stage = .review
                    }
                }
            }
        )
        .zIndex(10)
    }
}
```

- [ ] **Step 3: Build verify**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add feedmine/Views/Onboarding/ChoiceFeedbackOverlay.swift feedmine/Views/CuratedOnboardingView.swift
git commit -m "feat: choice feedback overlay — human-readable signals after each pick

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Qualitative progress indicator + ConfidenceProgressView

**Files:**
- Create: `feedmine/Views/Onboarding/ConfidenceProgressView.swift`
- Modify: `feedmine/Views/CuratedOnboardingView.swift` (replace "CHOICE N" + dot counter with qualitative states)

**Interfaces:**
- Consumes: `CuratedOnboardingSession.answerCount`, `isReady`, `progress`, accent color
- Produces: `ConfidenceProgressView` with 3 qualitative states: "Finding your range" → "A pattern is forming" → "Your first mix is ready"

- [ ] **Step 1: Create ConfidenceProgressView**

New file `feedmine/Views/Onboarding/ConfidenceProgressView.swift`:

```swift
import SwiftUI

/// Three-state qualitative progress replacing numeric "CHOICE N of 14".
struct ConfidenceProgressView: View {
    let answerCount: Int
    let isReady: Bool
    let accent: Color

    private enum Phase: Int {
        case finding = 0
        case forming = 1
        case ready = 2

        var label: String {
            switch self {
            case .finding: return "Finding your range"
            case .forming: return "A pattern is forming"
            case .ready: return "Your first mix is ready"
            }
        }
    }

    private var phase: Phase {
        if isReady { return .ready }
        if answerCount >= 3 { return .forming }
        return .finding
    }

    var body: some View {
        VStack(spacing: 10) {
            // Three-node visualization
            HStack(spacing: 24) {
                ForEach(0..<3) { i in
                    let active = i <= phase.rawValue
                    let isCurrent = i == phase.rawValue
                    Circle()
                        .fill(active ? accent : accent.opacity(0.15))
                        .frame(width: isCurrent ? 14 : (active ? 10 : 6),
                               height: isCurrent ? 14 : (active ? 10 : 6))
                        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: phase)
                }
            }

            Text(phase.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .animation(.easeInOut(duration: 0.3), value: phase)
        }
    }
}
```

- [ ] **Step 2: Replace CHOICE N header with ConfidenceProgressView**

In `CuratedOnboardingView.swift`, replace the `comparisonHeader` method to use `ConfidenceProgressView` instead of the numbered dots:

```swift
private func comparisonHeader(_ session: CuratedOnboardingSession) -> some View {
    VStack(spacing: 8) {
        ConfidenceProgressView(
            answerCount: session.answerCount,
            isReady: session.isReady,
            accent: engine.accent
        )
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
}
```

Also update `stageTitle` to remove "CHOICE N":
```swift
private var stageTitle: String {
    switch stage {
    case .welcome: return ""
    case .languages: return "LANGUAGES"
    case .comparisons: return ""  // Progress view handles this now
    case .review: return ""       // Feed reveal doesn't need a label
    }
}
```

- [ ] **Step 3: Build verify**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add feedmine/Views/Onboarding/ConfidenceProgressView.swift feedmine/Views/CuratedOnboardingView.swift
git commit -m "feat: qualitative progress — 3-state confidence replaces numbered counter

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Feed reveal scene — replace technical review with feed preview

**Files:**
- Create: `feedmine/Views/Onboarding/FeedRevealScene.swift`
- Create: `feedmine/Views/Onboarding/PreferenceSummaryChips.swift`
- Modify: `feedmine/Views/CuratedOnboardingView.swift` (replace reviewPage with FeedRevealScene)

**Interfaces:**
- Consumes: `CuratedOnboardingSession.profile`, accent color, `feedName` binding, save action, "Open Hood" action
- Produces: `FeedRevealScene` with headline, preference chips, first real feed cards preview, name field (optional), CTA, "See everything" link

- [ ] **Step 1: Create PreferenceSummaryChips**

New file `feedmine/Views/Onboarding/PreferenceSummaryChips.swift`:

```swift
import SwiftUI

/// Shows 3-5 human-readable chips summarizing what was learned.
/// Each chip can optionally expand into a simple Less/Balanced/More control.
struct PreferenceSummaryChips: View {
    let profile: CuratedProfileDefinition
    let accent: Color
    let onAdjust: ((String, Double) -> Void)?

    private var topSignals: [(key: String, name: String, weight: Double)] {
        let topics = CuratedPreferenceEngine.topTopicWeights(in: profile, limit: 3)
        let editorials = profile.weights
            .filter { $0.key.hasPrefix("editorial:") && $0.value != 0 }
            .sorted { abs($0.value) > abs($1.value) }
            .prefix(2)

        var signals: [(String, String, Double)] = []
        for t in topics {
            signals.append((t.topic.featureKey, t.topic.displayName, t.weight))
        }
        for e in editorials {
            let name = e.key.curatedFeatureDisplayName
            signals.append((e.key, name, e.value))
        }
        return signals
    }

    var body: some View {
        WrapLayout(spacing: 8) {
            ForEach(topSignals, id: \.key) { signal in
                ChipView(
                    name: signal.name,
                    weight: signal.weight,
                    accent: accent,
                    onAdjust: onAdjust.map { fn in
                        { newWeight in fn(signal.key, newWeight) }
                    }
                )
            }
        }
    }
}

private struct ChipView: View {
    let name: String
    let weight: Double
    let accent: Color
    let onAdjust: ((Double) -> Void)?

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 4) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if weight > 0 {
                        Image(systemName: "arrow.up")
                            .font(.caption2)
                    } else if weight < 0 {
                        Image(systemName: "arrow.down")
                            .font(.caption2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(accent.opacity(0.1), in: Capsule())
                .overlay(Capsule().stroke(accent.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            if expanded, let onAdjust {
                HStack(spacing: 0) {
                    Text("Less").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { weight },
                        set: onAdjust
                    ), in: -3...3, step: 0.5)
                    .tint(weight < 0 ? .secondary : accent)
                    .frame(width: 120)
                    Text("More").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }
}

/// Simple horizontal wrapping layout (iOS 16+ compatible)
private struct WrapLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > (proposal.width ?? .infinity) && lineWidth > 0 {
                width = max(width, lineWidth)
                height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + (lineWidth > 0 ? spacing : 0)
            lineHeight = max(lineHeight, size.height)
        }
        width = max(width, lineWidth)
        height += lineHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
```

- [ ] **Step 2: Create FeedRevealScene**

New file `feedmine/Views/Onboarding/FeedRevealScene.swift`:

```swift
import SwiftUI

/// Final onboarding screen — shows what the feed will look like.
/// Replaces the technical review page.
struct FeedRevealScene: View {
    let profile: CuratedProfileDefinition
    let feedName: Binding<String>
    let accent: Color
    let previewItems: [FeedItem]  // first few items from the loader
    let isSaving: Bool
    let onSave: () -> Void
    let onOpenHood: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Headline
                VStack(spacing: 8) {
                    Text("Here's your first mix.")
                        .font(.system(size: 29, weight: .bold))
                    Text("Built and stored on this device. Editable anytime.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 26)
                }
                .padding(.top, 16)

                // Preference summary chips
                PreferenceSummaryChips(
                    profile: profile,
                    accent: accent,
                    onAdjust: nil  // Chips are read-only here; adjust via "Open Hood"
                )
                .padding(.horizontal, 22)

                // Name — optional, pre-filled
                VStack(alignment: .leading, spacing: 6) {
                    Text("NAME")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    TextField("Feed name", text: feedName)
                        .font(.headline)
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 22)

                // Preview cards — first real feed items
                if !previewItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR FIRST STORIES")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 22)

                        ForEach(previewItems.prefix(3)) { item in
                            FeedItemCardView(item: item)
                                .padding(.horizontal, 16)
                        }
                    }
                }

                // CTA
                VStack(spacing: 14) {
                    Button(action: onSave) {
                        Group {
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Text("Open my feed")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .disabled(isSaving)
                    .padding(.horizontal, 22)

                    Button(action: onOpenHood) {
                        Text("See everything Feedmine learned")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.bottom, 32)
            }
        }
        .scrollIndicators(.hidden)
    }
}
```

- [ ] **Step 3: Wire FeedRevealScene into CuratedOnboardingView**

Replace `reviewPage` with `FeedRevealScene`. The existing `CuratedProfileControls` are removed from onboarding (they stay in the inspector accessed via "Open Hood"). Add `onOpenHood` action that presents the inspector or transitions directly to feed with inspector open.

- [ ] **Step 4: Build verify**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add feedmine/Views/Onboarding/PreferenceSummaryChips.swift feedmine/Views/Onboarding/FeedRevealScene.swift feedmine/Views/CuratedOnboardingView.swift
git commit -m "feat: FeedRevealScene replaces technical review with feed preview + chips

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Language scene cleanup — remove flags, collapse UI

**Files:**
- Create: `feedmine/Views/Onboarding/LanguageScene.swift`
- Modify: `feedmine/Views/CuratedOnboardingView.swift` (replace languagePage with LanguageScene)

**Interfaces:**
- Consumes: `selectedLanguages`, `languageSearch`, `filteredLanguageOptions`, selection binding, continue action
- Produces: `LanguageScene` — single confirmed language + "Add another" expandable UI, no flags, no source counts

- [ ] **Step 1: Create LanguageScene**

New file `feedmine/Views/Onboarding/LanguageScene.swift`:

```swift
import SwiftUI

struct LanguageScene: View {
    @Binding var selectedLanguages: Set<String>
    @State private var languageSearch = ""
    @State private var isExpanded = false

    let availableLanguages: [FeedLoader.LanguageInfo]
    let accent: Color
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Question
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

            // Selected languages as chips
            selectedLanguagesList

            // Expand/collapse toggle
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

            if isExpanded {
                // Search
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
                .transition(.opacity.combined(with: .move(edge: .top)))

                // Language grid — no flags, no source counts
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

            // Continue
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
        }
    }

    private var selectedLanguagesList: some View {
        let selected = availableLanguages.filter { selectedLanguages.contains($0.code) }
        return Group {
            if selected.isEmpty {
                Text("No language selected")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(selected)) { lang in
                    HStack {
                        Image(systemName: "character.bubble.fill")
                            .foregroundStyle(accent)
                        Text(lang.name)
                            .fontWeight(.medium)
                        Spacer()
                        Button {
                            selectedLanguages.remove(lang.code)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 22)
                }
            }
        }
    }

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
            selectedLanguages.insert(language.code)
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
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Replace languagePage in CuratedOnboardingView**

Replace `languagePage` with `LanguageScene`, passing the bindings and available languages. Remove the `fallbackFlag` method entirely.

- [ ] **Step 3: Build verify**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add feedmine/Views/Onboarding/LanguageScene.swift feedmine/Views/CuratedOnboardingView.swift
git commit -m "feat: LanguageScene — no flags, collapsed UI, neutral language symbols

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Welcome scene cleanup — transparency window, updated copy

**Files:**
- Create: `feedmine/Views/Onboarding/WelcomeScene.swift`
- Modify: `feedmine/Views/CuratedOnboardingView.swift` (replace welcomePage with WelcomeScene)

**Interfaces:**
- Consumes: accent color, ambient image URLs, start action, skip action
- Produces: `WelcomeScene` — transparency window animation over real feed, updated copy, explicit "Start with everything" button

- [ ] **Step 1: Create WelcomeScene**

New file `feedmine/Views/Onboarding/WelcomeScene.swift`:

```swift
import SwiftUI

/// Opening screen — a real feed blurred behind glass with a vertical
/// "transparency window" that reveals clear content as it sweeps across.
struct WelcomeScene: View {
    let accent: Color
    let ambientImageURLs: [URL]
    let onStart: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var windowPosition: CGFloat = -1.0  // -1 to +1 sweep

    var body: some View {
        ZStack {
            // Blurred feed cards behind glass
            blurredFeedBackground

            // Vertical transparency window sweep
            Rectangle()
                .fill(.clear)
                .frame(width: 80)
                .background(.regularMaterial.opacity(0))
            // The window is conceptually a clear stripe through the blur
            // For practical implementation we use a mask

            // Foreground content
            VStack(spacing: 0) {
                Spacer()

                // Headline
                Text("A feed you can see through.")
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)

                // Body
                Text("Choose a few real stories. Feedmine will build a mix you can inspect and change anytime.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)

                // Trust signals
                HStack(spacing: 16) {
                    trustBadge("On-device")
                    Circle().fill(.secondary).frame(width: 3, height: 3)
                    trustBadge("No account")
                    Circle().fill(.secondary).frame(width: 3, height: 3)
                    trustBadge("Fully editable")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 20)
                .opacity(appeared ? 1 : 0)

                Spacer()

                // CTAs
                VStack(spacing: 14) {
                    Button(action: onStart) {
                        Text("Build my first feed")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)

                    Button("Start with everything") {
                        onSkip()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .opacity(appeared ? 1 : 0)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
            withAnimation(.easeInOut(duration: 2.5).delay(0.3)) {
                windowPosition = 1.0
            }
        }
    }

    /// Ghost feed cards behind heavy blur — the "transparency window" concept
    /// is simpler here: real cards exist behind glass, hinting at what's inside.
    private var blurredFeedBackground: some View {
        let cardSpecs: [(CGFloat, CGFloat, CGFloat, CGFloat, Double)] = [
            (160, 110, -120, -200, 0.35), (185, 125, 100, -140, 0.42),
            (150, 100, -140, 160, 0.30),  (175, 115, 130, 180, 0.38),
            (195, 130, -80, -250, 0.45), (165, 105, 90, 210, 0.33),
        ]
        return ZStack {
            ForEach(0..<6, id: \.self) { i in
                let spec = cardSpecs[i]
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .frame(width: spec.0, height: spec.1)
                    .offset(x: spec.2, y: spec.3)
                    .opacity(appeared ? spec.4 : 0)
                    .animation(.easeInOut(duration: 1.0).delay(Double(i) * 0.1), value: appeared)
            }
        }
        .overlay(.ultraThinMaterial.opacity(0.92))
        .allowsHitTesting(false)
    }

    private func trustBadge(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption2)
            Text(text)
        }
    }
}
```

- [ ] **Step 2: Replace welcomePage in CuratedOnboardingView**

Replace `welcomePage` with `WelcomeScene`. Remove `staggeredHeadline`, `feedCardsBehindGlass`, `animateWelcomeEntrance`, and unused animation state properties. Remove the orbiting dots and slider icon.

- [ ] **Step 3: Build verify**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add feedmine/Views/Onboarding/WelcomeScene.swift feedmine/Views/CuratedOnboardingView.swift
git commit -m "feat: WelcomeScene — transparency window concept, updated copy, no orbital icons

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: Wire everything together — refactor CuratedOnboardingView as coordinator

**Files:**
- Modify: `feedmine/Views/CuratedOnboardingView.swift` (slim down to coordinator role)
- Modify: `feedmine/Views/OnboardingTipsView.swift` (update integration)

**Interfaces:**
- Consumes: All scene components from Tasks 5-10
- Produces: Thin `CuratedOnboardingView` that coordinates stage transitions, manages session state, delegates rendering to scene components

- [ ] **Step 1: Refactor CuratedOnboardingView to coordinator**

The refactored view should:
1. Keep the `Stage` enum, session management, save logic
2. Delegate each stage's rendering to its scene component
3. Remove all inline view-building code for each stage
4. Keep `topBar`, but simplified (no "CHOICE N", no stage titles)
5. Handle transitions between stages
6. Wire `OnboardingPairQueue` throughout

After refactoring, `CuratedOnboardingView` should be ~400 lines (down from 1338).

Key changes to the `body`:
```swift
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
                        ambientImageURLs: ambientImageURLs,
                        onStart: { withAnimation { stage = .languages } },
                        onSkip: { onCancel() }
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
                        StoryDuelScene(
                            pair: pair,
                            accent: engine.accent,
                            canUndo: session.canUndo,
                            canFinish: session.canFinish,
                            isReady: session.isReady,
                            onChoose: answer,
                            onUndo: { withAnimation { session.undo() } },
                            onNewPair: refreshCandidatePool,
                            onFinish: { withAnimation { stage = .review } }
                        )
                        .overlay { feedbackOverlay }  // ChoiceFeedbackOverlay
                    } else {
                        candidateLoadingState(session)
                    }
                case .review:
                    FeedRevealScene(
                        profile: session?.profile ?? CuratedProfileDefinition(),
                        feedName: $feedName,
                        accent: engine.accent,
                        previewItems: loader.items.prefix(3).map { $0 },
                        isSaving: isSaving,
                        onSave: { Task { await save(session!) } },
                        onOpenHood: { /* present inspector */ }
                    )
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.animation(.easeInOut(duration: 0.35)),
                removal: .opacity.animation(.easeInOut(duration: 0.2))
            ))
        }
    }
    // ... rest of modifiers unchanged
}
```

- [ ] **Step 2: Simplified top bar**

```swift
private var simplifiedTopBar: some View {
    HStack {
        if stage != .welcome {
            Button { goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
            }
        } else {
            Color.clear.frame(width: 36, height: 36)
        }

        Spacer()

        // Only show progress during comparisons
        if stage == .comparisons, let session {
            ConfidenceProgressView(
                answerCount: session.answerCount,
                isReady: session.isReady,
                accent: engine.accent
            )
        }

        Spacer()

        Button { onCancel() } label: {
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
```

- [ ] **Step 3: Build verify**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add feedmine/Views/CuratedOnboardingView.swift
git commit -m "refactor: slim CuratedOnboardingView to coordinator (~400 lines)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 12: Continuous transition from onboarding to feed

**Files:**
- Modify: `feedmine/Views/OnboardingTipsView.swift`
- Modify: `feedmine/Views/FeedScreen.swift:142`

**Interfaces:**
- Consumes: `OnboardingTipsView` completion, `FeedScreen` transition
- Produces: Matched geometry effect or shared card position so the preview card stays in place as onboarding dismisses

- [ ] **Step 1: Implement matched transition**

The key insight: when onboarding completes, instead of a hard dismiss, use a `matchedGeometryEffect` or a shared element transition where the first preview card stays in the same screen position as the feed fades in around it.

Since the onboarding is overlaid via `OnboardingTipsView().zIndex(100)`, the simplest approach:

When saving completes in `CuratedOnboardingView.onSaved`:
1. `OnboardingTipsView` sets `hasSeenOnboarding = true` (existing behavior)
2. Instead of `CuratedOnboardingView` disappearing instantly, it animates opacity to 0 over 0.3s
3. FeedScreen content fades in simultaneously
4. The first card position is naturally shared since the feed is already loaded behind

The existing implementation already loads the feed behind the onboarding. The improvement is:
- Extend the dismiss animation to 0.4s with a crossfade
- Add a toast: "Your mix is ready. Open the hood anytime."

```swift
// In OnboardingTipsView.complete():
private func complete() {
    withAnimation(.easeInOut(duration: 0.4)) {
        hasSeenOnboarding = true
    }
}
```

And in FeedScreen, show a toast after first onboarding completion. Add a state check:

```swift
@AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
@State private var showOnboardingCompleteToast = false

// In toastOverlay, add:
.onChange(of: hasSeenOnboarding) { _, newValue in
    if newValue {
        toastMessage = "Your mix is ready. Open the hood anytime."
        toastIcon = "slider.horizontal.3"
        withAnimation { showToast = true }
    }
}
```

- [ ] **Step 2: Build verify**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add feedmine/Views/OnboardingTipsView.swift feedmine/Views/FeedScreen.swift
git commit -m "feat: continuous transition — crossfade onboarding → feed with toast

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 13: Update UI tests for new onboarding flow

**Files:**
- Modify: `feedmineUITests/FeedmineUITests.swift` (update `testCuratedOnboardingCreatesAnInspectableFeedFromRealStores`)

**Interfaces:**
- Consumes: New accessibility identifiers from scene components
- Produces: Updated UI test that walks through the redesigned flow

- [ ] **Step 1: Add accessibility identifiers to new components**

In each scene, add appropriate `.accessibilityIdentifier()` modifiers:

- `WelcomeScene`: "welcome-start" on CTA, "welcome-skip" on skip
- `LanguageScene`: "language-continue" on continue, "language-add" on add button
- `StoryDuelScene`: "duel-top-card", "duel-bottom-card", "duel-both", "duel-neither", "duel-skip"
- `FeedRevealScene`: "reveal-save" on save, "reveal-open-hood" on open hood

- [ ] **Step 2: Update UI test**

Rewrite the test to match new flow:
- Verify welcome screen, tap start
- Verify language screen, continue with preselected language
- Make 5 comparisons (tapping top card each time)
- Wait for "Your first mix is ready" state
- Tap "Review my feed"
- Verify feed reveal screen, tap "Open my feed"
- Verify feed appears with toast

- [ ] **Step 3: Run UI tests**

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' test -only-testing:feedmineUITests/FeedmineUITests/testCuratedOnboardingCreatesAnInspectableFeedFromRealStores 2>&1 | tail -20
```

- [ ] **Step 4: Commit**

```bash
git add feedmineUITests/FeedmineUITests.swift feedmine/Views/Onboarding/
git commit -m "test: update UI test for redesigned onboarding flow

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## P1 Tasks (deferred — implement after P0 is stable)

### P1.1: Reduce Motion support
- Check `UIAccessibility.isReduceMotionEnabled` in all animation blocks
- Replace rotations/parallax with crossfades when enabled
- Remove infinite animations when Reduce Motion is on

### P1.2: Dynamic Type audit
- Test all scenes with accessibility text sizes
- Ensure scroll views work when text is large
- Verify buttons don't truncate with larger type

### P1.3: VoiceOver audit
- Add accessibility labels to all interactive elements
- Group related content with `.accessibilityElement(children: .combine)`
- Add accessibility actions for Skip/Undo/New Pair

### P1.4: Position alternation
- Alternate top/bottom card positions deterministically to reduce positional bias
- Track which position won most in analytics

## P2 Tasks (deferred — quality polish)

### P2.1: Localization
- Extract all strings to String Catalog
- Localize to Portuguese (Brazilian) as first additional language

### P2.2: Metrics
- Track onboarding abandonment rate
- Measure time between choices
- Track positional bias (do users pick top card more?)
- Measure visual equivalence of pairs (image load times)

### P2.3: Edge cases
- Handle empty candidate pool gracefully (already partially done)
- Handle network loss during onboarding
- Handle app backgrounding during comparisons
