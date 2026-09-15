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

    /// Whether the user has ever entered trim mode in the rally player.
    /// The in-player "Hold to trim" coach mark shows until this flips.
    var hasUsedRallyTrim: Bool {
        didSet {
            UserDefaults.standard.set(hasUsedRallyTrim, forKey: "hasUsedRallyTrim")
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

        // Data flywheel (opt-in, default off)
        self.enableDataFlywheel = UserDefaults.standard.bool(forKey: "enableDataFlywheel")
        self.flywheelConsentVersion = UserDefaults.standard.string(forKey: "flywheelConsentVersion") ?? ""
        self.flywheelOptInDate = UserDefaults.standard.object(forKey: "flywheelOptInDate") as? Date

        // Onboarding state
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        self.hasSeenRallyTips = UserDefaults.standard.bool(forKey: "hasSeenRallyTips")
        self.hasSeenFavoritesTrimHint = UserDefaults.standard.bool(forKey: "hasSeenFavoritesTrimHint")
        self.hasUsedRallyTrim = UserDefaults.standard.bool(forKey: "hasUsedRallyTrim")

        print("🎛️ AppSettings initialized")
    }
}

// MARK: - View Extension

extension View {
    func withAppSettings() -> some View {
        self.environment(AppSettings.shared)
    }
}