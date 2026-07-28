import Foundation

/// Maintains a pipeline of ready-to-display comparison pairs so the UI never
/// shows a loading state between choices. Images are warmed for both cards
/// before a pair is dequeued — no asymmetric visuals.
@MainActor
final class OnboardingPairQueue {
    private let loader: FeedLoader
    private var readyPairs: [CuratedComparisonPair] = []
    private var usedItemIDs: Set<String> = []
    private var usedPairIDs: Set<String> = []
    private var preparationTask: Task<Void, Never>?
    private var isRunning = false

    /// Called on the main actor when a new pair is ready for immediate display.
    var onPairReady: ((CuratedComparisonPair) -> Void)?

    init(loader: FeedLoader) {
        self.loader = loader
    }

    func start(languages: Set<String>) {
        guard !isRunning else { return }
        isRunning = true
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fillPipeline(languages: languages)
        }
    }

    func stop() {
        isRunning = false
        preparationTask?.cancel()
        preparationTask = nil
        readyPairs.removeAll()
    }

    /// Returns the next fully-warmed pair, or nil if none is ready yet.
    func dequeueReadyPair() -> CuratedComparisonPair? {
        guard !readyPairs.isEmpty else { return nil }
        return readyPairs.removeFirst()
    }

    var readyCount: Int { readyPairs.count }

    /// Mark items as used so they won't be re-presented.
    func markUsed(_ pair: CuratedComparisonPair) {
        usedItemIDs.insert(pair.left.id)
        usedItemIDs.insert(pair.right.id)
        usedPairIDs.insert(pair.id)
    }

    // MARK: - Private

    private func fillPipeline(languages: Set<String>) async {
        while isRunning && !Task.isCancelled {
            while readyPairs.count < 3 && !Task.isCancelled {
                guard let pair = await prepareOnePair(languages: languages) else {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                readyPairs.append(pair)
                onPairReady?(pair)
            }
            while readyPairs.count >= 3 && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func prepareOnePair(languages: Set<String>) async -> CuratedComparisonPair? {
        let candidates = await loader.curatedOnboardingCandidates(languages: languages)
        guard !candidates.isEmpty else { return nil }

        let profile = CuratedProfileDefinition(languages: Array(languages))
        guard let pair = CuratedPreferenceEngine.nextPair(
            candidates: candidates,
            profile: profile,
            usedItemIDs: usedItemIDs,
            usedPairIDs: usedPairIDs
        ) else { return nil }

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

        await loader.prefetcher.prefetch(
            urls: urls.map(\.absoluteString),
            priorityURLs: urls.map(\.absoluteString)
        )

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if Task.isCancelled { break }
            if urls.allSatisfy({ ImageCache.hasCachedImageData(for: $0) }) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
