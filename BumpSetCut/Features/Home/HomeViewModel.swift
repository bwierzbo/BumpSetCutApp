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

    // Community stats (populated when authenticated)
    var followersCount: Int = 0
    var followingCount: Int = 0
    var highlightsShared: Int = 0
    var hasCommunityStats: Bool = false

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

    func loadCommunityStats(for user: UserProfile?, apiClient: (any APIClient)? = nil) async {
        guard let user else {
            hasCommunityStats = false
            return
        }

        let client = apiClient ?? SupabaseAPIClient.shared

        do {
            let profile: UserProfile = try await client.request(.getProfile(userId: user.id))
            followersCount = profile.followersCount
            followingCount = profile.followingCount
            highlightsShared = profile.highlightsCount
            hasCommunityStats = true
        } catch {
            // Use cached user data if API fails
            followersCount = user.followersCount
            followingCount = user.followingCount
            highlightsShared = user.highlightsCount
            hasCommunityStats = true
        }
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
    var stats: [StatItem] {
        if hasCommunityStats {
            return [
                StatItem(
                    icon: "person.2.fill",
                    value: "\(followersCount)",
                    label: "Followers",
                    color: .bscOrange
                ),
                StatItem(
                    icon: "heart.fill",
                    value: "\(followingCount)",
                    label: "Following",
                    color: .bscBlue
                ),
                StatItem(
                    icon: "play.rectangle.fill",
                    value: "\(highlightsShared)",
                    label: "Shared",
                    color: .bscTeal
                )
            ]
        } else {
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
                )
            ]
        }
    }
}
