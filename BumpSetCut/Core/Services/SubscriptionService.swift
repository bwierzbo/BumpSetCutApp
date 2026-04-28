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
        return debugForcePro
        #else
        return StoreManager.shared.hasActiveSubscription
        #endif
    }

    // MARK: - Free Tier Limits
    static let weeklyProcessingDurationMinutes: Double = 60 // Free users get 60 min/week

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
                return "No weekly duration limit on video processing"
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

    private(set) var debugForcePro: Bool = UserDefaults.standard.object(forKey: "debug_force_pro") as? Bool ?? true

    func setProStatus(_ status: Bool) {
        UserDefaults.standard.set(status, forKey: "debug_force_pro")
        debugForcePro = status
        print("💎 [DEBUG] Pro status set to: \(status)")
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

    /// Entry tracking a processed video's date and duration
    private struct ProcessingEntry: Codable {
        let date: Date
        let durationSeconds: Double
    }

    /// Track when a video was processed with its duration
    func recordVideoProcessing(durationSeconds: Double) {
        var history = getProcessingHistory()
        history.append(ProcessingEntry(date: Date(), durationSeconds: durationSeconds))
        saveProcessingHistory(history)
        let used = processedMinutesThisWeek()
        print("📊 Recorded video processing (\(Int(durationSeconds))s). This week: \(String(format: "%.1f", used))/\(Int(SubscriptionService.weeklyProcessingDurationMinutes)) min")
    }

    /// Get processing history from UserDefaults, migrating from legacy format if needed
    private func getProcessingHistory() -> [ProcessingEntry] {
        guard let data = UserDefaults.standard.data(forKey: processingHistoryKey) else {
            return []
        }

        // Try new format first
        if let entries = try? JSONDecoder().decode([ProcessingEntry].self, from: data) {
            return entries
        }

        // Fall back to legacy [Date] format — treat each as 0 seconds (grandfathered)
        if let dates = try? JSONDecoder().decode([Date].self, from: data) {
            return dates.map { ProcessingEntry(date: $0, durationSeconds: 0) }
        }

        return []
    }

    /// Save processing history to UserDefaults
    private func saveProcessingHistory(_ entries: [ProcessingEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
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

    /// Total minutes of video processed this week
    func processedMinutesThisWeek() -> Double {
        let history = getProcessingHistory()
        let weekStart = startOfCurrentWeek()

        let totalSeconds = history
            .filter { $0.date >= weekStart }
            .reduce(0.0) { $0 + $1.durationSeconds }

        return totalSeconds / 60.0
    }

    /// Check if user can process a video of the given duration this week
    func canProcessVideo(durationSeconds: Double) -> (allowed: Bool, message: String?) {
        if isPro {
            return (true, nil)
        }

        let usedMinutes = processedMinutesThisWeek()
        let videoMinutes = durationSeconds / 60.0
        let cap = SubscriptionService.weeklyProcessingDurationMinutes
        let remaining = max(0, cap - usedMinutes)

        if usedMinutes + videoMinutes > cap {
            let resetDate = getNextResetDate()
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE" // Day name
            let resetDay = formatter.string(from: resetDate)

            return (false, "This video is \(String(format: "%.1f", videoMinutes)) min but you only have \(String(format: "%.1f", remaining)) min remaining this week. Your limit resets \(resetDay). Upgrade to Pro for unlimited processing!")
        }

        return (true, nil)
    }

    /// Get remaining processing minutes for this week (nil = unlimited for Pro)
    func remainingProcessingMinutes() -> Double? {
        if isPro { return nil } // Unlimited
        let used = processedMinutesThisWeek()
        return max(0, SubscriptionService.weeklyProcessingDurationMinutes - used)
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
