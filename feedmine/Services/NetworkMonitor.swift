import Network
import SwiftUI

@MainActor
@Observable
final class NetworkMonitor {
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
                // Airplane Mode = zero available interfaces (no WiFi radio, no cellular radio)
                self.isAirplaneMode = path.availableInterfaces.isEmpty
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
