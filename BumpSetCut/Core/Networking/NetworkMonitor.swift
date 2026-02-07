import Foundation
import Network
import Observation

// MARK: - Connection Type

enum ConnectionType {
    case wifi
    case cellular
    case wiredEthernet
    case none
}

// MARK: - Network Monitor

@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isConnected: Bool = true
    private(set) var connectionType: ConnectionType = .wifi

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.bumpsetcut.networkmonitor")

    init() {
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnected = path.status == .satisfied
                self.connectionType = self.mapConnectionType(path)
            }
        }
        monitor.start(queue: queue)
    }

    private func mapConnectionType(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
        return .none
    }
}
