import SwiftUI
import Observation

// MARK: - HomeViewModel
@MainActor
@Observable
final class HomeViewModel {
    // MARK: - Properties
    private let mediaStore: MediaStore
    private let metadataStore: MetadataStore
    private let subscriptionService: SubscriptionService

    /// Account-linked lifetime totals (server + not-yet-synced increments).
    var totalRallies: Int { LifetimeStatsStore.shared.totalRallies }
    /// Total dead time removed across all processed videos (source length − rally time).
    var totalTimeCutSeconds: Double { LifetimeStatsStore.shared.totalTimeCutSeconds }

    /// Compact display of total time cut, scaling up through units:
    /// "45s" → "38m" → "2h 14m" → "3d 4h" → "1y 23d" (locale-aware unit
    /// abbreviations; partial lower units are dropped, not rounded).
    var timeCutDisplay: String {
        Self.formatTimeCut(seconds: totalTimeCutSeconds)
    }

    static func formatTimeCut(seconds: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        let minute = 60
        let hour = 3600
        let day = 86_400
        let year = 365 * day

        let components: DateComponents
        let units: NSCalendar.Unit
        if total >= year {
            components = DateComponents(year: total / year, day: (total % year) / day)
            units = [.year, .day]
        } else if total >= day {
            components = DateComponents(day: total / day, hour: (total % day) / hour)
            units = [.day, .hour]
        } else if total >= hour {
            components = DateComponents(hour: total / hour, minute: (total % hour) / minute)
            units = [.hour, .minute]
        } else if total >= minute {
            components = DateComponents(minute: total / minute)
            units = [.minute]
        } else {
            components = DateComponents(second: total)
            units = [.second]
        }

        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = units
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: components) ?? ""
    }

    // MARK: - Initialization
    init(mediaStore: MediaStore, metadataStore: MetadataStore, subscriptionService: SubscriptionService? = nil) {
        self.mediaStore = mediaStore
        self.metadataStore = metadataStore
        self.subscriptionService = subscriptionService ?? .shared
        seedLifetimeStatsIfNeeded()
    }

    // MARK: - Unprocessed Videos (Process sheet)

    /// Saved-library videos that can still be processed, for the Process sheet.
    private(set) var unprocessedVideos: [VideoMetadata] = []

    /// One pass over the manifest: collect originals that already have a
    /// processed version, and the saved-library candidates, then drop the former.
    func loadUnprocessedVideos() {
        var processedOriginalIds = Set<UUID>()
        var candidates: [VideoMetadata] = []
        for video in mediaStore.getAllVideos() {
            if let originalId = video.originalVideoId {
                processedOriginalIds.insert(originalId)
            }
            if video.canBeProcessed && mediaStore.isPath(video.folderPath, in: .saved) {
                candidates.append(video)
            }
        }
        unprocessedVideos = candidates.filter { !processedOriginalIds.contains($0.id) }
    }

    // MARK: - Private Methods

    /// Lifetime totals are read live from LifetimeStatsStore (maintained by
    /// ProcessingCoordinator and synced to the account). The only expensive work
    /// is the one-time upgrade backfill, which reads every processed video's
    /// metadata file — it runs at most once per install.
    private func seedLifetimeStatsIfNeeded() {
        guard !LifetimeStatsStore.shared.hasSeeded else { return }

        let contributions: [(videoId: UUID, timeCutSeconds: Double, rallyCount: Int)] =
            mediaStore.getAllVideos()
                .filter { $0.hasProcessingMetadata }
                .compactMap { video in
                    guard let metadata = try? metadataStore.loadMetadata(for: video.id) else { return nil }
                    let cut: Double = {
                        guard let duration = video.duration, duration > 0 else { return 0 }
                        return max(0, duration - metadata.totalRallyDuration)
                    }()
                    return (video.id, cut, metadata.rallySegments.count)
                }
        LifetimeStatsStore.shared.seedIfNeeded(from: contributions)
    }
}

// MARK: - Stat Item
struct StatItem: Identifiable {
    let id = UUID()
    let icon: String
    /// Already-formatted display value (a number, duration, or tier name).
    let value: String
    let label: LocalizedStringResource
    let color: Color
}

extension HomeViewModel {
    /// Home stats card: rallies + time cut, then Pro badge or weekly minutes left.
    var stats: [StatItem] {
        if subscriptionService.isPro {
            // Pro users: Show processing stats + Pro badge
            return [
                StatItem(
                    icon: "figure.volleyball",
                    value: totalRallies.formatted(),
                    label: "Rallies",
                    color: .bscPrimaryText
                ),
                StatItem(
                    icon: "scissors",
                    value: timeCutDisplay,
                    label: "Time Cut",
                    color: .bscTealText
                ),
                StatItem(
                    icon: "crown.fill",
                    value: String(localized: "Pro", comment: "Subscription tier name shown as a stat value"),
                    label: "Unlimited",
                    color: .bscWarningText
                )
            ]
        } else {
            // Free users: Show processing stats + remaining minutes
            let remainingMin = subscriptionService.remainingProcessingMinutes() ?? 0
            let cap = SubscriptionService.weeklyProcessingDurationMinutes
            let fraction = remainingMin / cap
            let batteryIcon: String
            if fraction > 0.75 {
                batteryIcon = "battery.100"
            } else if fraction > 0.5 {
                batteryIcon = "battery.75"
            } else if fraction > 0.25 {
                batteryIcon = "battery.25"
            } else {
                batteryIcon = "battery.0"
            }

            return [
                StatItem(
                    icon: "figure.volleyball",
                    value: totalRallies.formatted(),
                    label: "Rallies",
                    color: .bscPrimaryText
                ),
                StatItem(
                    icon: "scissors",
                    value: timeCutDisplay,
                    label: "Time Cut",
                    color: .bscTealText
                ),
                StatItem(
                    icon: batteryIcon,
                    value: Duration.seconds(Int(max(0, remainingMin)) * 60)
                        .formatted(.units(allowed: [.minutes], width: .narrow, zeroValueUnits: .show(length: 1))),
                    label: "This Week",
                    color: remainingMin > 0 ? .bscPrimaryText : .bscErrorText
                )
            ]
        }
    }
}
