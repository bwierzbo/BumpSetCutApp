//
//  NetworkMonitor.swift
//  BumpSetCut
//
//  Monitors network connectivity and distinguishes between WiFi and cellular.
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkMonitor {

    // MARK: - Singleton
    static let shared = NetworkMonitor()

    // MARK: - Public Properties
    private(set) var isConnected: Bool = false
    private(set) var connectionType: ConnectionType = .none

    enum ConnectionType {
        case wifi
        case cellular
        case wired
        case none

        var displayName: String {
            switch self {
            case .wifi: return "WiFi"
            case .cellular: return "Cellular"
            case .wired: return "Ethernet"
            case .none: return "No Connection"
            }
        }

        var icon: String {
            switch self {
            case .wifi: return "wifi"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .wired: return "network"
            case .none: return "wifi.slash"
            }
        }
    }

    // MARK: - Private Properties
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    // MARK: - Initialization
    private init() {
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.updateConnectionStatus(path: path)
            }
        }
        monitor.start(queue: queue)
    }

    private func stopMonitoring() {
        monitor.cancel()
    }

    private func updateConnectionStatus(path: NWPath) {
        isConnected = path.status == .satisfied

        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .wired
        } else if path.status == .satisfied {
            // Connected but unknown type - treat as wifi for permissive behavior
            connectionType = .wifi
        } else {
            connectionType = .none
        }

        print("🌐 Network status changed: \(connectionType.displayName), Connected: \(isConnected)")
    }

    // MARK: - Public Methods

    /// Check if user can process video based on network and subscription status
    func canProcessVideo(isPro: Bool) -> (allowed: Bool, reason: String?) {
        // Pro users can process offline (e.g., on a plane)
        if isPro {
            return (true, nil)
        }

        // Free users require any network connection (WiFi or cellular)
        guard isConnected else {
            return (false, "Internet connection required. Please connect to WiFi or cellular to process videos. Upgrade to Pro to process offline.")
        }

        return (true, nil)
    }

    /// Check if currently on WiFi (or wired)
    var isOnWiFi: Bool {
        return connectionType == .wifi || connectionType == .wired
    }
}
