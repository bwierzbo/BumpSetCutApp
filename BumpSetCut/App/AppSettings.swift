//
//  AppSettings.swift
//  BumpSetCut
//
//  App-wide configuration and feature toggles
//

import SwiftUI
import Foundation

// MARK: - App Settings

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Feature Toggles

    /// Enable debug features and logging
    @Published var enableDebugFeatures: Bool {
        didSet {
            UserDefaults.standard.set(enableDebugFeatures, forKey: "enableDebugFeatures")
        }
    }

    /// Show performance metrics in debug builds
    @Published var showPerformanceMetrics: Bool {
        didSet {
            UserDefaults.standard.set(showPerformanceMetrics, forKey: "showPerformanceMetrics")
        }
    }

    /// Track rally view usage for analytics
    @Published var enableAnalytics: Bool {
        didSet {
            UserDefaults.standard.set(enableAnalytics, forKey: "enableAnalytics")
        }
    }

    private init() {
        // Initialize with defaults based on build configuration
        #if DEBUG
        self.enableDebugFeatures = UserDefaults.standard.object(forKey: "enableDebugFeatures") as? Bool ?? true
        self.showPerformanceMetrics = UserDefaults.standard.object(forKey: "showPerformanceMetrics") as? Bool ?? false
        #else
        self.enableDebugFeatures = false
        self.showPerformanceMetrics = false
        #endif

        self.enableAnalytics = UserDefaults.standard.object(forKey: "enableAnalytics") as? Bool ?? true

        print("🎛️ AppSettings initialized")
    }

    // MARK: - Analytics Helpers

    func logRallyViewUsage(viewType: RallyViewType, duration: TimeInterval, rallyCount: Int) {
        guard enableAnalytics else { return }

        let analyticsData: [String: Any] = [
            "view_type": viewType.rawValue,
            "session_duration": duration,
            "rally_count": rallyCount,
            "timestamp": Date().timeIntervalSince1970
        ]

        print("📊 Rally view analytics: \(analyticsData)")
        // TODO: Send to analytics service when available
    }

    func logRallyGestureUsage(gestureType: RallyGestureType, rallyIndex: Int) {
        guard enableAnalytics else { return }

        let gestureData: [String: Any] = [
            "gesture_type": gestureType.rawValue,
            "rally_index": rallyIndex,
            "timestamp": Date().timeIntervalSince1970
        ]

        print("👆 Rally gesture analytics: \(gestureData)")
        // TODO: Send to analytics service when available
    }
}

// MARK: - Analytics Types

enum RallyViewType: String, CaseIterable {
    case rally = "RallyPlayerView"
    case fallback = "VideoPlayerView"
}

enum RallyGestureType: String, CaseIterable {
    case swipeNext = "swipe_next"
    case swipePrevious = "swipe_previous"
    case tapPlayPause = "tap_play_pause"
    case doubleTapDebug = "double_tap_debug"
    case edgeBounce = "edge_bounce"
}

// MARK: - View Extension

extension View {
    func withAppSettings() -> some View {
        self.environmentObject(AppSettings.shared)
    }
}