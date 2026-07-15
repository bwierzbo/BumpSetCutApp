import SwiftUI
import Observation

// MARK: - HomeViewModel
@MainActor
@Observable
final class HomeViewModel {
    // MARK: - Properties
    private let mediaStore: MediaStore
    private let metadataStore: MetadataStore

    var totalRallies: Int = 0
    /// Total dead time removed across all processed videos (source length − rally time).
    var totalTimeCutSeconds: Double = 0

    /// Compact display of total time cut, scaling up through units:
    /// "45s" → "38m" → "2h 14m" → "3d 4h" → "1y 23d".
    var timeCutDisplay: String {
        let total = Int(totalTimeCutSeconds.rounded())
        let minute = 60
        let hour = 3600
        let day = 86_400
        let year = 365 * day

        if total >= year {
            return "\(total / year)y \((total % year) / day)d"
        }
        if total >= day {
            return "\(total / day)d \((total % day) / hour)h"
        }
        if total >= hour {
            return "\(total / hour)h \((total % hour) / minute)m"
        }
        if total >= minute {
            return "\(total / minute)m"
        }
        return "\(total)s"
    }

    // MARK: - Initialization
    init(mediaStore: MediaStore, metadataStore: MetadataStore) {
        self.mediaStore = mediaStore
        self.metadataStore = metadataStore
        loadStats()
    }

    // MARK: - Public Methods
    func refresh() {
        loadStats()
    }

    // MARK: - Private Methods
    private func loadStats() {
        // Lifetime stats are cumulative (UserDefaults) and maintained incrementally
        // by ProcessingCoordinator. Reading them is cheap, so reflect them immediately.
        totalRallies = LifetimeStatsStore.shared.totalRallies
        totalTimeCutSeconds = LifetimeStatsStore.shared.totalTimeCutSeconds

        // The only expensive work is the one-time upgrade backfill, which reads every
        // processed video's metadata file. It runs at most once per install — skip the
        // whole scan once it's done (previously it ran on every Home appear/refresh).
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

        totalRallies = LifetimeStatsStore.shared.totalRallies
        totalTimeCutSeconds = LifetimeStatsStore.shared.totalTimeCutSeconds
    }
}

// MARK: - Stat Item
struct StatItem: Identifiable {
    let id = UUID()
    let icon: String
    let value: String
    let label: String
    let color: Color
}

extension HomeViewModel {
    func stats(isPro: Bool) -> [StatItem] {
        let subscriptionService = SubscriptionService.shared

        if isPro {
            // Pro users: Show processing stats + Pro badge
            return [
                StatItem(
                    icon: "figure.volleyball",
                    value: "\(totalRallies)",
                    label: "Rallies",
                    color: .bscPrimary
                ),
                StatItem(
                    icon: "scissors",
                    value: timeCutDisplay,
                    label: "Time Cut",
                    color: .bscTeal
                ),
                StatItem(
                    icon: "crown.fill",
                    value: "Pro",
                    label: "Unlimited",
                    color: .yellow
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
                    value: "\(totalRallies)",
                    label: "Rallies",
                    color: .bscPrimary
                ),
                StatItem(
                    icon: "scissors",
                    value: timeCutDisplay,
                    label: "Time Cut",
                    color: .bscTeal
                ),
                StatItem(
                    icon: batteryIcon,
                    value: "\(Int(remainingMin))m",
                    label: "This Week",
                    color: remainingMin > 0 ? .bscBlue : .red
                )
            ]
        }
    }
}
