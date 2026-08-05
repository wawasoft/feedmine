import Network
import SwiftUI

@MainActor
@Observable
final class NetworkMonitor {
    private nonisolated(unsafe) var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.feedmine.network-monitor")

    /// Start as `false` — the true state is unknown until the first path
    /// update fires. Defaulting to `true` makes an offline launch believe
    /// it's online until that first callback.
    private(set) var isConnected = false
    var wasDisconnected = false

    deinit {
        monitor?.cancel()
    }

    /// Idempotent — creates a new monitor if the previous one was cancelled.
    /// NWPathMonitor is single-use; calling `start()` after `cancel()` raises
    /// an exception. Re-creating the monitor on each `start()` prevents this.
    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let connected = path.status == .satisfied
                if !connected {
                    self.wasDisconnected = true
                }
                self.isConnected = connected
            }
        }
        m.start(queue: queue)
        self.monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
