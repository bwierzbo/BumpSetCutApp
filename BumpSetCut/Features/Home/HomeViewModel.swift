import SwiftUI
import Observation

// MARK: - HomeViewModel
@MainActor
@Observable
final class HomeViewModel {
    // MARK: - Properties
    private let mediaStore: MediaStore
    private let metadataStore: MetadataStore

    var savedVideos: Int = 0
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

        // Count videos in Saved Games library
        savedVideos = mediaStore.getAllVideos(in: .saved).count

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
    var stats: [StatItem] {
        [
            StatItem(
                icon: "video.fill",
                value: "\(savedVideos)",
                label: "Saved",
                color: .bscBlue
            ),
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
            )
        ]
    }
}
