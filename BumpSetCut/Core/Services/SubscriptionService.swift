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
    var isPro: Bool {
        #if DEBUG
        return true // TODO: Remove before release
        #endif
        return StoreManager.shared.hasActiveSubscription
    }

    // MARK: - Free Tier Limits
    static let weeklyProcessingLimit = 3 // Free users can process 3 videos per week
    static let maxVideoSizeMB: Int64 = 500 // 500MB max for free users (Pro: unlimited)

    // MARK: - Pro Entitlements
    enum ProFeature: String, CaseIterable {
        case offlineProcessing = "Offline Processing"
        case unlimitedVideos = "Unlimited Videos"
        case noWatermark = "No Watermark"
        case prioritySupport = "Priority Support"
        case advancedSettings = "Advanced Settings"

        var icon: String {
            switch self {
            case .offlineProcessing: return "airplane"
            case .unlimitedVideos: return "infinity"
            case .noWatermark: return "eye.slash"
            case .prioritySupport: return "person.fill.checkmark"
            case .advancedSettings: return "gearshape.2"
            }
        }

        var description: String {
            switch self {
            case .offlineProcessing:
                return "Process videos offline without any internet connection"
            case .unlimitedVideos:
                return "No limits on video uploads or processing per week"
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
        // Subscription status is automatically managed by StoreManager
    }

    // MARK: - Subscription Management

    func refreshSubscriptionStatus() async {
        await StoreManager.shared.updateSubscriptionStatus()
        print("💎 Subscription status refreshed: \(isPro ? "Pro" : "Free")")
    }

    #if DEBUG
    // MARK: - Testing Helpers (DEBUG ONLY)

    func setProStatus(_ status: Bool) {
        // This only works in DEBUG builds for testing
        // In production, subscription status comes from StoreKit only
        UserDefaults.standard.set(status, forKey: "debug_force_pro")
        print("💎 [DEBUG] Pro status set to: \(status)")
    }

    private var debugForcePro: Bool {
        return UserDefaults.standard.bool(forKey: "debug_force_pro")
    }
    #endif

    // MARK: - Feature Checks

    func canAccessFeature(_ feature: ProFeature) -> Bool {
        return isPro
    }

    func requiresProMessage(for feature: ProFeature) -> String {
        return "\(feature.rawValue) is a Pro feature. Upgrade to unlock!"
    }

    // MARK: - Processing Limit Tracking

    private let processingHistoryKey = "processing_history"

    /// Track when a video was processed
    func recordVideoProcessing() {
        var history = getProcessingHistory()
        history.append(Date())
        saveProcessingHistory(history)
        print("📊 Recorded video processing. This week: \(processedThisWeek())/\(SubscriptionService.weeklyProcessingLimit)")
    }

    /// Get processing history from UserDefaults
    private func getProcessingHistory() -> [Date] {
        guard let data = UserDefaults.standard.data(forKey: processingHistoryKey),
              let dates = try? JSONDecoder().decode([Date].self, from: data) else {
            return []
        }
        return dates
    }

    /// Save processing history to UserDefaults
    private func saveProcessingHistory(_ dates: [Date]) {
        if let data = try? JSONEncoder().encode(dates) {
            UserDefaults.standard.set(data, forKey: processingHistoryKey)
        }
    }

    /// Get the start of the current week (Monday at 00:00)
    private func startOfCurrentWeek() -> Date {
        let calendar = Calendar.current
        let now = Date()

        // Get components for current date
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)

        // Set to Monday (weekday = 2 in Gregorian calendar where Sunday = 1)
        components.weekday = 2 // Monday
        components.hour = 0
        components.minute = 0
        components.second = 0

        return calendar.date(from: components) ?? now
    }

    /// Count how many videos processed this week
    func processedThisWeek() -> Int {
        let history = getProcessingHistory()
        let weekStart = startOfCurrentWeek()

        return history.filter { $0 >= weekStart }.count
    }

    /// Check if user can process another video this week
    func canProcessVideo() -> (allowed: Bool, message: String?) {
        if isPro {
            return (true, nil)
        }

        let processed = processedThisWeek()

        if processed >= SubscriptionService.weeklyProcessingLimit {
            let resetDate = getNextResetDate()
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE" // Day name
            let resetDay = formatter.string(from: resetDate)

            return (false, "You've reached the free limit of \(SubscriptionService.weeklyProcessingLimit) videos this week. Your limit resets \(resetDay). Upgrade to Pro for unlimited processing!")
        }

        return (true, nil)
    }

    /// Get remaining processing credits for this week
    func remainingProcessingCredits() -> Int? {
        if isPro { return nil } // Unlimited
        let processed = processedThisWeek()
        return max(0, SubscriptionService.weeklyProcessingLimit - processed)
    }

    /// Get the next reset date (next Monday)
    func getNextResetDate() -> Date {
        let calendar = Calendar.current
        let now = Date()

        // Get next Monday
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        components.weekday = 2 // Monday
        components.weekOfYear = (components.weekOfYear ?? 0) + 1 // Next week
        components.hour = 0
        components.minute = 0
        components.second = 0

        return calendar.date(from: components) ?? now
    }

    // MARK: - Video Size Limit

    /// Check if video size is allowed for upload
    func canUploadVideoSize(fileSizeBytes: Int64) -> (allowed: Bool, message: String?) {
        if isPro {
            return (true, nil)
        }

        let fileSizeMB = fileSizeBytes / (1024 * 1024)

        if fileSizeMB > SubscriptionService.maxVideoSizeMB {
            return (false, "Video size (\(fileSizeMB)MB) exceeds the free limit of \(SubscriptionService.maxVideoSizeMB)MB. Upgrade to Pro for unlimited file sizes!")
        }

        return (true, nil)
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
