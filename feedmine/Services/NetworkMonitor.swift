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

    /// `true` once the first NWPathMonitor path callback has fired. The
    /// path callback is asynchronous, so `isConnected == false` conflates
    /// "known offline" with "state not yet known". Offline fast paths must
    /// gate on `!isConnected && hasReceivedFirstPath` so an online launch
    /// whose first callback hasn't arrived isn't misclassified as offline.
    private(set) var hasReceivedFirstPath = false
    var wasDisconnected = false

    /// `true` only when connectivity is KNOWN to be unavailable. Gates that
    /// skip work when offline must use this instead of `!isConnected` — before
    /// the first path callback fires, `isConnected == false` means "unknown",
    /// not "offline", and an online launch would be misclassified.
    var isKnownOffline: Bool { !isConnected && hasReceivedFirstPath }

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
                self.hasReceivedFirstPath = true
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
