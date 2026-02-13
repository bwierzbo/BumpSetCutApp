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
    var processedVideos: Int = 0
    var isLoading: Bool = false

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
        isLoading = true

        // Count videos in Processed Games library
        processedVideos = mediaStore.getAllVideos(in: .processed).count

        // Count rallies from metadata (from all videos with metadata)
        totalRallies = countTotalRallies()

        isLoading = false
    }

    private func countTotalRallies() -> Int {
        var count = 0

        for video in mediaStore.getAllVideos() {
            if video.hasProcessingMetadata {
                if let metadata = try? metadataStore.loadMetadata(for: video.id) {
                    count += metadata.rallySegments.count
                }
            }
        }

        return count
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
                    color: .bscOrange
                ),
                StatItem(
                    icon: "checkmark.seal.fill",
                    value: "\(processedVideos)",
                    label: "Processed",
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
            // Free users: Show processing stats + remaining limit
            let remaining = subscriptionService.remainingProcessingCredits() ?? 0
            let batteryIcon: String
            if remaining == 3 {
                batteryIcon = "battery.100"
            } else if remaining == 2 {
                batteryIcon = "battery.75"
            } else if remaining == 1 {
                batteryIcon = "battery.25"
            } else {
                batteryIcon = "battery.0"
            }

            return [
                StatItem(
                    icon: "figure.volleyball",
                    value: "\(totalRallies)",
                    label: "Rallies",
                    color: .bscOrange
                ),
                StatItem(
                    icon: "checkmark.seal.fill",
                    value: "\(processedVideos)",
                    label: "Processed",
                    color: .bscTeal
                ),
                StatItem(
                    icon: batteryIcon,
                    value: "\(remaining)/3",
                    label: "This Week",
                    color: remaining > 0 ? .bscBlue : .red
                )
            ]
        }
    }
}
