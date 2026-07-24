import Network
import SwiftUI

@MainActor
@Observable
final class NetworkMonitor {
    /// Shared singleton — must be started once (FeedStore does this).
    nonisolated(unsafe) static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.feedmine.network-monitor")

    private(set) var isConnected = true
    private(set) var isAirplaneMode = false
    var wasDisconnected = false

    deinit {
        monitor.cancel()
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnected = path.status == .satisfied
                self.wasDisconnected = self.wasDisconnected || !self.isConnected
                self.isAirplaneMode = path.availableInterfaces.isEmpty
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    /// Thread-safe connectivity snapshot for non-MainActor callers.
    nonisolated func snapshot() -> (isConnected: Bool, isAirplaneMode: Bool) {
        let path = monitor.currentPath
        return (path.status == .satisfied, path.availableInterfaces.isEmpty)
    }

    /// The singleton init must be callable from any context.
    nonisolated init() {}
}
