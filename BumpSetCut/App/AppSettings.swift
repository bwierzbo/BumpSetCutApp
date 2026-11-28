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

    /// Contribute clips of every processed rally (plus the detector's
    /// per-frame evidence) so the model can be retrained. On by default
    /// (D-046, `sharesFootageByDefault`): onboarding says so and offers to
    /// turn it off, as Settings does at any time. Turning it back on goes
    /// through the consent sheet.
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

    /// Whether an install that has not had the default applied yet is switched
    /// on by it (D-046). Everyone is, except a person who turned sharing off
    /// themselves: the stored switch is off although they once had it on — by
    /// agreeing to a consent, or as a tester under the earlier tester default.
    /// A person switched off only because the consent copy changed (the
    /// stored switch still on) never chose off, and is switched on.
    static func sharesFootageByDefault(storedSwitch: Bool, consentVersion: String, testerDefaultWasApplied: Bool) -> Bool {
        storedSwitch || (consentVersion.isEmpty && !testerDefaultWasApplied)
    }

    /// The onboarding page's answer, or any deliberate turning on outside the
    /// consent sheet: sharing on, recorded as agreed to under `version`.
    func shareFootage(agreedTo version: String) {
        flywheelConsentVersion = version
        flywheelOptInDate = Date()
        enableDataFlywheel = true
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

    /// The last camera position picked before processing — preselected for the
    /// next video, since most people film the same way every time.
    var lastCameraSetup: CameraSetup? {
        didSet {
            UserDefaults.standard.set(lastCameraSetup.flatMap { try? JSONEncoder().encode($0) },
                                      forKey: "lastCameraSetup")
        }
    }

    /// Whether user has seen the "press & hold to trim" hint in the favorites feed
    var hasSeenFavoritesTrimHint: Bool {
        didSet {
            UserDefaults.standard.set(hasSeenFavoritesTrimHint, forKey: "hasSeenFavoritesTrimHint")
        }
    }

    /// Whether user has seen the Favorites feature tour (first visit overlay)
    var hasSeenFavoritesOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasSeenFavoritesOnboarding, forKey: "hasSeenFavoritesOnboarding")
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

        // Data flywheel: on by default (D-046), applied once per install so
        // that turning it off sticks. Not under UI tests, which process real
        // recordings and must not send them anywhere.
        let defaults = UserDefaults.standard
        var consent = defaults.string(forKey: "flywheelConsentVersion") ?? ""
        let storedSwitch = defaults.bool(forKey: "enableDataFlywheel")
        // Agreed to an earlier consent (stills of hard rallies, not clips of
        // every rally): not on under that consent.
        var sharing = storedSwitch && FlywheelConsent.inForce.contains(consent)
        var optInDate = defaults.object(forKey: "flywheelOptInDate") as? Date
        if !defaults.bool(forKey: "flywheelDefaultOnApplied"), !CommandLine.arguments.contains("--uitesting") {
            defaults.set(true, forKey: "flywheelDefaultOnApplied")
            if !sharing, Self.sharesFootageByDefault(storedSwitch: storedSwitch, consentVersion: consent,
                                                     testerDefaultWasApplied: defaults.bool(forKey: "flywheelTesterDefaultApplied")) {
                sharing = true
                consent = FlywheelConsent.defaultOn
                optInDate = Date()
                defaults.set(true, forKey: "enableDataFlywheel")
                defaults.set(consent, forKey: "flywheelConsentVersion")
                defaults.set(optInDate, forKey: "flywheelOptInDate")
            }
        }
        self.enableDataFlywheel = sharing
        self.flywheelConsentVersion = consent
        self.flywheelOptInDate = optInDate

        // Onboarding state
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        self.hasSeenRallyTips = UserDefaults.standard.bool(forKey: "hasSeenRallyTips")
        self.hasSeenFavoritesTrimHint = UserDefaults.standard.bool(forKey: "hasSeenFavoritesTrimHint")
        self.lastCameraSetup = UserDefaults.standard.data(forKey: "lastCameraSetup")
            .flatMap { try? JSONDecoder().decode(CameraSetup.self, from: $0) }
        self.hasSeenFavoritesOnboarding = UserDefaults.standard.bool(forKey: "hasSeenFavoritesOnboarding")
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