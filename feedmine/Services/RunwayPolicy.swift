import Foundation

/// Configurable buffer targets and deadlines for the feed preparation pipeline.
/// All values are initial proposals; adjust based on metrics.
struct RunwayPolicy: Sendable {
    // MARK: - Published feed
    var initialPublishedCount = 20
    var publishedAheadLow = 30
    var publishedAheadTarget = 50

    // MARK: - Render-ready runway (decoded images)
    var renderReadyLow = 60
    var renderReadyTarget = 120
    var renderReadyHigh = 180

    // MARK: - Resolved runway (disk-level, no UIImage)
    var resolvedLow = 200
    var resolvedTarget = 400
    var resolvedHigh = 600

    // MARK: - Editorial backlog
    var editorialLow = 500
    var editorialTarget = 1_000
    var editorialHigh = 1_500

    // MARK: - Per-item deadlines

    /// Total budget for items in the initial viewport (positions 0..<20).
    var initialViewportDeadline: Duration = .seconds(6)

    /// Total budget for items near the runway edge.
    var nearRunwayDeadline: Duration = .seconds(15)

    /// Total budget for items deep in the runway.
    var deepRunwayDeadline: Duration = .seconds(30)

    // MARK: - Adaptive targets

    /// Reduced targets for constrained devices (low memory, thermal, low power).
    func constrained() -> RunwayPolicy {
        var p = self
        p.renderReadyLow = 40
        p.renderReadyTarget = 70
        p.resolvedLow = 150
        p.resolvedTarget = 250
        p.editorialLow = 400
        p.editorialTarget = 700
        return p
    }

    /// Expanded targets for comfortable devices (ample memory, Wi-Fi, charging).
    func comfortable() -> RunwayPolicy {
        var p = self
        p.renderReadyLow = 120
        p.renderReadyTarget = 180
        p.resolvedLow = 500
        p.resolvedTarget = 700
        p.editorialLow = 1_200
        p.editorialTarget = 1_800
        return p
    }

    /// Select initial targets based on device physical memory.
    static func forDevice() -> RunwayPolicy {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        if physicalMemory < 2_000_000_000 {       // < 2 GB
            return RunwayPolicy().constrained()
        } else if physicalMemory > 6_000_000_000 { // > 6 GB
            return RunwayPolicy().comfortable()
        }
        return RunwayPolicy()  // default
    }
}
