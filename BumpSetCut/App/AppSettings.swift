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

    // MARK: - Data Flywheel

    /// Opt in to contribute clips of rallies the detector struggled with (plus
    /// the detector's per-frame evidence) so the model can be retrained. Off by
    /// default; only flipped true after the consent sheet is accepted.
    var enableDataFlywheel: Bool {
        didSet {
            UserDefaults.standard.set(enableDataFlywheel, forKey: "enableDataFlywheel")
        }
    }

    /// Which version of the consent copy the user agreed to (empty until opted in).
    var flywheelConsentVersion: String {
        didSet {
            UserDefaults.standard.set(flywheelConsentVersion, forKey: "flywheelConsentVersion")
        }
    }

    /// When the user opted in (nil until opted in).
    var flywheelOptInDate: Date? {
        didSet {
            UserDefaults.standard.set(flywheelOptInDate, forKey: "flywheelOptInDate")
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

    /// Whether user has seen the "press & hold to trim" hint in the favorites feed
    var hasSeenFavoritesTrimHint: Bool {
        didSet {
            UserDefaults.standard.set(hasSeenFavoritesTrimHint, forKey: "hasSeenFavoritesTrimHint")
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

        // Data flywheel (opt-in, default off)
        self.enableDataFlywheel = UserDefaults.standard.bool(forKey: "enableDataFlywheel")
        self.flywheelConsentVersion = UserDefaults.standard.string(forKey: "flywheelConsentVersion") ?? ""
        self.flywheelOptInDate = UserDefaults.standard.object(forKey: "flywheelOptInDate") as? Date

        // Onboarding state
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        self.hasSeenRallyTips = UserDefaults.standard.bool(forKey: "hasSeenRallyTips")
        self.hasSeenFavoritesTrimHint = UserDefaults.standard.bool(forKey: "hasSeenFavoritesTrimHint")

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
    }

    func logRallyGestureUsage(gestureType: RallyGestureType, rallyIndex: Int) {
        guard enableAnalytics else { return }

        let gestureData: [String: Any] = [
            "gesture_type": gestureType.rawValue,
            "rally_index": rallyIndex,
            "timestamp": Date().timeIntervalSince1970
        ]

        print("👆 Rally gesture analytics: \(gestureData)")
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