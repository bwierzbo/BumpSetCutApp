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
        return forcePro
        #else
        // Testers get Pro with a Settings toggle (TestFlight runs against the
        // StoreKit sandbox). Everyone else — App Review included — goes
        // through the real subscription.
        if isTester { return forcePro }
        return StoreManager.shared.hasActiveSubscription
        #endif
    }

    /// The signed-in account is on the server's app_testers allowlist. Not
    /// derived from the install: App Review installs carry the same sandbox
    /// receipt as TestFlight ones.
    private(set) var isTester = false

    /// Re-check the allowlist for the signed-in account (nil = signed out).
    /// The last answer per account is cached, so testers keep their tools
    /// offline; a failed check keeps the cached answer.
    func refreshTesterStatus(userId: String?, apiClient: (any APIClient)? = nil) async {
        guard let userId else {
            isTester = false
            return
        }
        let cacheKey = "tester_status_\(userId)"
        isTester = UserDefaults.standard.bool(forKey: cacheKey)
        do {
            let client = apiClient ?? SupabaseAPIClient.shared
            let tester: Bool = try await client.request(.amITester)
            isTester = tester
            UserDefaults.standard.set(tester, forKey: cacheKey)
        } catch {
            print("💎 Tester check failed, keeping cached answer: \(error.localizedDescription)")
        }
    }

    // MARK: - Free Tier Limits
    static let weeklyProcessingDurationMinutes: Double = 30 // Free users get 30 min/week

    // MARK: - Pro Entitlements
    enum ProFeature: String, CaseIterable {
        case offlineProcessing = "Offline Processing"
        case unlimitedVideos = "Unlimited Videos"
        case noWatermark = "No Watermark"

        var icon: String {
            switch self {
            case .offlineProcessing: return "airplane"
            case .unlimitedVideos: return "infinity"
            case .noWatermark: return "eye.slash"
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

    // MARK: - Tier Override (DEBUG builds + allowlisted testers)

    /// Manual Pro/Free override. Consulted by `isPro` only in DEBUG builds and
    /// for allowlisted testers — everyone else ignores it entirely.
    private(set) var forcePro: Bool = {
        // UI tests pass --force-free to exercise the free tier and paywall
        if CommandLine.arguments.contains("--force-free") { return false }
        return UserDefaults.standard.object(forKey: "debug_force_pro") as? Bool ?? true
    }()

    func setProStatus(_ status: Bool) {
        UserDefaults.standard.set(status, forKey: "debug_force_pro")
        forcePro = status
        print("💎 Pro override set to: \(status)")
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

}
