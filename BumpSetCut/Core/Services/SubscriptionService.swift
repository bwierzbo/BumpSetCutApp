//
//  SubscriptionService.swift
//  BumpSetCut
//
//  Manages Pro subscription status and entitlements.
//

import Foundation
import Observation

@MainActor
@Observable
final class SubscriptionService {

    // MARK: - Singleton
    static let shared = SubscriptionService()

    // MARK: - Public Properties
    private(set) var isPro: Bool = false

    // MARK: - Free Tier Limits
    static let freeVideoLimit = 10

    // MARK: - Pro Entitlements
    enum ProFeature: String, CaseIterable {
        case offlineProcessing = "Offline Video Processing"
        case cellularProcessing = "Process on Cellular"
        case unlimitedVideos = "Unlimited Videos"
        case noWatermark = "No Watermark"
        case prioritySupport = "Priority Support"
        case advancedSettings = "Advanced Settings"

        var icon: String {
            switch self {
            case .offlineProcessing: return "wifi.slash"
            case .cellularProcessing: return "antenna.radiowaves.left.and.right"
            case .unlimitedVideos: return "infinity"
            case .noWatermark: return "eye.slash"
            case .prioritySupport: return "person.fill.checkmark"
            case .advancedSettings: return "gearshape.2"
            }
        }

        var description: String {
            switch self {
            case .offlineProcessing:
                return "Process videos without WiFi or internet connection"
            case .cellularProcessing:
                return "Process videos on cellular data without WiFi"
            case .unlimitedVideos:
                return "No limits on video uploads or processing"
            case .noWatermark:
                return "Remove BumpSetCut branding from exported videos"
            case .prioritySupport:
                return "Get help faster with priority customer support"
            case .advancedSettings:
                return "Fine-tune detection parameters for your needs"
            }
        }
    }

    // MARK: - Initialization
    private init() {
        loadSubscriptionStatus()
    }

    // MARK: - Subscription Management

    private func loadSubscriptionStatus() {
        // TODO: Load from StoreKit or subscription backend
        // For now, check UserDefaults for testing
        isPro = UserDefaults.standard.bool(forKey: "user_is_pro")
        print("💎 Subscription status loaded: \(isPro ? "Pro" : "Free")")
    }

    func refreshSubscriptionStatus() {
        // TODO: Refresh from StoreKit or subscription backend
        loadSubscriptionStatus()
    }

    // MARK: - Testing Helpers (Remove in production)

    func setProStatus(_ status: Bool) {
        isPro = status
        UserDefaults.standard.set(status, forKey: "user_is_pro")
        print("💎 Pro status set to: \(status)")
    }

    // MARK: - Feature Checks

    func canAccessFeature(_ feature: ProFeature) -> Bool {
        return isPro
    }

    func requiresProMessage(for feature: ProFeature) -> String {
        return "\(feature.rawValue) is a Pro feature. Upgrade to unlock!"
    }

    // MARK: - Video Limit Checks

    /// Check if user can upload more videos
    func canUploadVideo(currentVideoCount: Int) -> (allowed: Bool, message: String?) {
        if isPro {
            return (true, nil)
        }

        if currentVideoCount >= SubscriptionService.freeVideoLimit {
            return (false, "You've reached the free limit of \(SubscriptionService.freeVideoLimit) videos. Upgrade to Pro for unlimited videos!")
        }

        return (true, nil)
    }

    /// Get remaining videos for free users
    func remainingVideos(currentVideoCount: Int) -> Int? {
        if isPro { return nil } // Unlimited
        return max(0, SubscriptionService.freeVideoLimit - currentVideoCount)
    }

    // MARK: - Watermark

    /// Check if watermark should be added to exports
    var shouldAddWatermark: Bool {
        return !isPro
    }

    // MARK: - Paywall Presentation

    /// Check if user can access a feature, return error message if not
    func checkFeatureAccess(_ feature: ProFeature) -> (allowed: Bool, message: String?) {
        if isPro {
            return (true, nil)
        } else {
            return (false, requiresProMessage(for: feature))
        }
    }
}
