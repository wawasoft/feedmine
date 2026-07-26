import Network
import SwiftUI

@MainActor
@Observable
final class NetworkMonitor {
    /// Shared singleton — must be started once (FeedStore does this).
    nonisolated(unsafe) static let shared = NetworkMonitor()

    private nonisolated(unsafe) var monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.feedmine.network-monitor")

    /// Initialized optimistically — callers should treat as "unknown" until
    /// the first path update arrives. See `hasReceivedFirstUpdate`.
    private(set) var isConnected = true
    private(set) var isAirplaneMode = false
    /// Whether the current path uses an expensive (cellular/hotspot) interface.
    private(set) var isExpensive = false
    var wasDisconnected = false
    private var wasStopped = false
    private var hasStarted = false
    /// True after the first path update — use to gate connectivity-dependent
    /// work that must not run before the real network state is known.
    private(set) var hasReceivedFirstUpdate = false

    deinit {
        monitor.cancel()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if wasStopped {
            monitor = NWPathMonitor()
            wasStopped = false
            hasReceivedFirstUpdate = false
        }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnected = path.status == .satisfied
                self.wasDisconnected = self.wasDisconnected || !self.isConnected
                self.isAirplaneMode = path.availableInterfaces.isEmpty
                self.isExpensive = path.isExpensive
                self.hasReceivedFirstUpdate = true
            }
        }
        monitor.start(queue: queue)
    }

    /// Stops the monitor. The singleton can be restarted because we recreate
    /// the NWPathMonitor — `cancel()` alone permanently kills it.
    func stop() {
        monitor.cancel()
        hasStarted = false
        wasStopped = true
    }

    /// Thread-safe connectivity snapshot for non-MainActor callers.
    nonisolated func snapshot() -> (isConnected: Bool, isAirplaneMode: Bool, isExpensive: Bool) {
        var result: (isConnected: Bool, isAirplaneMode: Bool, isExpensive: Bool) = (true, false, false)
        queue.sync {
            let path = monitor.currentPath
            result = (
                isConnected: path.status == .satisfied,
                isAirplaneMode: path.availableInterfaces.isEmpty,
                isExpensive: path.isExpensive
            )
        }
        return result
    }

    /// The singleton init must be callable from any context.
    nonisolated init() {}
}
