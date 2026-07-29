import Foundation

/// Actor that monitors runway health and adapts preparation intensity.
/// Observes four stocks (editorial, resolved, render-ready, published-ahead)
/// and adjusts concurrency/pressure based on watermarks and scroll velocity.
actor FeedRunwayController {

    private let policy: RunwayPolicy
    private let coordinator: CardPreparationCoordinator
    private var metrics = RunwayMetrics()

    private var pressureState: RunwayPressure = .bootstrap
    private var activeContext: FeedPresentationContext?

    private var publishedAhead: Int = 0
    private var lastViewportTime: Date = Date()
    private var lastViewportIndex: Int = 0

    private var isEvaluating = false

    // MARK: - Hysteresis tracking

    /// Timestamp of the last pressure state transition. Used to enforce a
    /// minimum dwell time before allowing another transition.
    private var lastTransition: Date = Date()
    private let minimumDwell: TimeInterval = 5

    init(policy: RunwayPolicy, coordinator: CardPreparationCoordinator) {
        self.policy = policy
        self.coordinator = coordinator
    }

    // MARK: - Public API

    func start(context: FeedPresentationContext) {
        activeContext = context
        pressureState = .bootstrap
        lastTransition = Date()
    }

    func stop(context: FeedPresentationContext) {
        guard context == activeContext else { return }
        activeContext = nil
    }

    /// Called on each scroll event. Tracks velocity and published-ahead depth.
    func reportViewport(
        currentIndex: Int,
        publishedCount: Int
    ) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastViewportTime)
        let indexDelta = Double(max(0, currentIndex - lastViewportIndex))
        if elapsed > 0 {
            let rate = indexDelta / elapsed
            metrics.recordScroll(cardsPerSecond: rate)
        }
        lastViewportTime = now
        lastViewportIndex = currentIndex
        publishedAhead = max(0, publishedCount - currentIndex)
    }

    /// Evaluate runway health and adjust preparation intensity.
    /// Called after each promotion batch and periodically.
    func evaluate() async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        guard let ctx = activeContext else { return }

        let renderReadyCount = await coordinator.renderReadyCount
        let resolvedCount = await coordinator.resolvedCount
        let editorialCount = await coordinator.editorialCount

        let estimatedSeconds = metrics.estimatedRunwaySeconds(
            renderReadyCount: renderReadyCount,
            publishedAhead: publishedAhead
        )

        let newPressure = computePressure(
            renderReadyCount: renderReadyCount,
            resolvedCount: resolvedCount,
            editorialCount: editorialCount,
            estimatedSeconds: estimatedSeconds
        )

        guard newPressure != pressureState else { return }

        // Hysteresis: don't transition faster than minimumDwell
        let now = Date()
        guard now.timeIntervalSince(lastTransition) > minimumDwell else { return }

        pressureState = newPressure
        lastTransition = now

        switch newPressure {
        case .critical, .bootstrap:
            await coordinator.fillRunway(
                targetRenderReady: policy.initialPublishedCount + policy.publishedAheadLow,
                context: ctx
            )

        case .filling:
            await coordinator.fillRunway(
                targetRenderReady: policy.renderReadyTarget,
                context: ctx
            )

        case .cruising:
            // Light maintenance — top up to target
            if renderReadyCount < policy.renderReadyTarget {
                await coordinator.fillRunway(
                    targetRenderReady: policy.renderReadyTarget,
                    context: ctx
                )
            }

        case .maintenance:
            // Buffers full — pause new preparation
            break

        case .constrained:
            await coordinator.handleMemoryPressure()
        }
    }

    // MARK: - Private

    private func computePressure(
        renderReadyCount: Int,
        resolvedCount: Int,
        editorialCount: Int,
        estimatedSeconds: Double
    ) -> RunwayPressure {
        // Critical: very low runway
        if renderReadyCount < 20 || estimatedSeconds < 30 {
            return .critical
        }

        // Bootstrap: no initial page yet
        if renderReadyCount < policy.initialPublishedCount {
            return .bootstrap
        }

        // Filling: below low watermarks
        if renderReadyCount < policy.renderReadyLow
            || resolvedCount < policy.resolvedLow
            || editorialCount < policy.editorialLow {
            return .filling
        }

        // Maintenance: above high watermarks
        if renderReadyCount >= policy.renderReadyHigh
            && resolvedCount >= policy.resolvedHigh
            && editorialCount >= policy.editorialHigh {
            return .maintenance
        }

        // Default: cruising
        return .cruising
    }
}

// MARK: - Runway Pressure

enum RunwayPressure: Sendable, Equatable {
    /// Extremely low runway — max priority, suspend non-essential work.
    case critical
    /// Initial page not yet complete.
    case bootstrap
    /// First page exists but buffers below low watermarks.
    case filling
    /// Buffers above targets — light top-up only.
    case cruising
    /// All buffers above high watermarks — pause preparation.
    case maintenance
    /// Low power, thermal, memory pressure, or expensive connection.
    case constrained
}
