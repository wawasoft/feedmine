import Foundation

/// Exponential moving averages and counters for runway health monitoring.
struct RunwayMetrics: Sendable {
    var scrollCardsPerSecondEMA: Double = 1.0
    var prepareCardsPerSecondEMA: Double = 0.5
    var resolveImagesPerSecondEMA: Double = 0.3
    var failureRateEMA: Double = 0.0
    var prepareLatencyP50: Double = 0.0
    var prepareLatencyP95: Double = 0.0

    let smoothingFactor: Double = 0.2

    mutating func recordScroll(cardsPerSecond: Double) {
        scrollCardsPerSecondEMA = scrollCardsPerSecondEMA * (1 - smoothingFactor)
            + cardsPerSecond * smoothingFactor
    }

    mutating func recordPrepare(cardsPerSecond: Double) {
        prepareCardsPerSecondEMA = prepareCardsPerSecondEMA * (1 - smoothingFactor)
            + cardsPerSecond * smoothingFactor
    }

    mutating func recordResolve(imagesPerSecond: Double) {
        resolveImagesPerSecondEMA = resolveImagesPerSecondEMA * (1 - smoothingFactor)
            + imagesPerSecond * smoothingFactor
    }

    /// Estimated seconds of runway given current render-ready buffer and scroll rate.
    func estimatedRunwaySeconds(renderReadyCount: Int, publishedAhead: Int) -> Double {
        let rate = max(scrollCardsPerSecondEMA, 0.1)
        return Double(publishedAhead + renderReadyCount) / rate
    }
}
