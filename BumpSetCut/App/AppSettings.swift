//
//  AppSettings.swift
//  BumpSetCut
//
//  App-wide configuration and feature toggles
//

import SwiftUI

// MARK: - Appearance Mode

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - App Settings

@MainActor
@Observable class AppSettings {
    static let shared = AppSettings()

    // MARK: - Appearance

    var appearanceMode: AppTheme {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
        }
    }

    // MARK: - Feature Toggles

    /// Enable debug features and logging
    var enableDebugFeatures: Bool {
        didSet {
            UserDefaults.standard.set(enableDebugFeatures, forKey: "enableDebugFeatures")
        }
    }

    /// Show performance metrics in debug builds
    var showPerformanceMetrics: Bool {
        didSet {
            UserDefaults.standard.set(showPerformanceMetrics, forKey: "showPerformanceMetrics")
        }
    }

    /// Track rally view usage for analytics
    var enableAnalytics: Bool {
        didSet {
            UserDefaults.standard.set(enableAnalytics, forKey: "enableAnalytics")
        }
    }

    // MARK: - Processing Settings

    /// Use thorough analysis with dynamic frame stride, trajectory tracking,
    /// classification, and quality metrics. When OFF, uses quick mode that
    /// just detects rallies without extra analysis.
    var useThoroughAnalysis: Bool {
        didSet {
            UserDefaults.standard.set(useThoroughAnalysis, forKey: "useThoroughAnalysis")
        }
    }

    // MARK: - Onboarding State

    /// Whether user has completed the app onboarding tutorial
    var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
    }

    /// Whether user has seen the rally gesture tips overlay
    var hasSeenRallyTips: Bool {
        didSet {
            UserDefaults.standard.set(hasSeenRallyTips, forKey: "hasSeenRallyTips")
        }
    }


    private init() {
        // Appearance
        let storedTheme = UserDefaults.standard.string(forKey: "appearanceMode") ?? "System"
        self.appearanceMode = AppTheme(rawValue: storedTheme) ?? .system

        // Initialize with defaults based on build configuration
        #if DEBUG
        self.enableDebugFeatures = UserDefaults.standard.object(forKey: "enableDebugFeatures") as? Bool ?? true
        self.showPerformanceMetrics = UserDefaults.standard.object(forKey: "showPerformanceMetrics") as? Bool ?? false
        #else
        self.enableDebugFeatures = false
        self.showPerformanceMetrics = false
        #endif

        self.enableAnalytics = UserDefaults.standard.object(forKey: "enableAnalytics") as? Bool ?? true

        // Processing settings - default to thorough analysis
        self.useThoroughAnalysis = UserDefaults.standard.object(forKey: "useThoroughAnalysis") as? Bool ?? true

        // Onboarding state
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        self.hasSeenRallyTips = UserDefaults.standard.bool(forKey: "hasSeenRallyTips")

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
        self.environment(AppSettings.shared)
    }
}