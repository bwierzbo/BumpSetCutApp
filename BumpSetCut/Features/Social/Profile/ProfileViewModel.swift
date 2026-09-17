//
//  ProfileViewModel.swift
//  BumpSetCut
//
//  Manages user profile data and their highlights.
//

import Foundation
import Observation

@MainActor
@Observable
final class ProfileViewModel {
    private(set) var profile: UserProfile?
    private(set) var highlights: [Highlight] = []
    private(set) var isLoading = false
    private(set) var isFollowing = false
    private(set) var error: Error?
    /// Transient message for a failed background action (e.g. a reverted
    /// optimistic follow). The view consumes it into a toast and clears it.
    var actionError: String?

    let userId: String
    private let apiClient: any APIClient
    private var currentPage = 0

    init(userId: String, apiClient: (any APIClient)? = nil) {
        self.userId = userId
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    func loadProfile() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil

        // Profile, highlights and follow-status are independent — fetch them
        // concurrently instead of as three sequential round-trips.
        async let profileResult: UserProfile = apiClient.request(.getProfile(userId: userId))
        async let highlightsResult: [Highlight] = apiClient.request(.getUserHighlights(userId: userId, page: 0))
        async let followResult: [FollowRow] = apiClient.request(.checkFollowStatus(userId: userId))

        do {
            profile = try await profileResult
            highlights = try await highlightsResult
            currentPage = 1
        } catch {
            self.error = error
        }

        do {
            isFollowing = !(try await followResult).isEmpty
        } catch {
            // Don't break profile loading, but log — a swallowed decode failure here is
            // exactly how the "always shows Follow" bug hid for so long.
            print("⚠️ [ProfileViewModel] loadFollowStatus(\(userId)) failed: \(error)")
        }

        isLoading = false
    }

    // MARK: - Player Info

    /// What the Player Info card should show. The lock is derived entirely
    /// from state the client already has — RLS is the real enforcement, and it
    /// simply returns no row, which is indistinguishable from "not filled in".
    enum PlayerInfoState: Equatable {
        case locked
        case empty
        case visible(PlayerInfo)
    }

    func playerInfoState(isOwnProfile: Bool) -> PlayerInfoState {
        guard let profile else { return .empty }
        if !isOwnProfile && profile.privacyLevel != .public && !isFollowing { return .locked }
        if let details = profile.details, !details.isEmpty { return .visible(details) }
        return .empty
    }

    /// Re-fetch just the profile. Used after following someone, so the details
    /// embed — which RLS withheld a moment ago — appears without a full reload.
    private func reloadProfileOnly() async {
        guard let refreshed: UserProfile = try? await apiClient.request(.getProfile(userId: userId)) else { return }
        profile = refreshed
    }

    func deleteHighlight(_ highlight: Highlight) async -> Bool {
        do {
            let _: EmptyResponse = try await apiClient.request(.deleteHighlight(id: highlight.id))
            highlights.removeAll { $0.id == highlight.id }
            if var p = profile {
                p.highlightsCount = max(0, p.highlightsCount - 1)
                profile = p
            }
            return true
        } catch {
            print("⚠️ [ProfileViewModel] deleteHighlight(\(highlight.id)) failed: \(error)")
            return false
        }
    }

    func toggleLike(for highlight: Highlight) async {
        guard let index = highlights.firstIndex(where: { $0.id == highlight.id }) else { return }

        let wasLiked = highlights[index].isLikedByMe
        highlights[index].isLikedByMe = !wasLiked
        highlights[index].likesCount += wasLiked ? -1 : 1

        do {
            if wasLiked {
                let _: EmptyResponse = try await apiClient.request(.unlikeHighlight(id: highlight.id))
            } else {
                let _: EmptyResponse = try await apiClient.request(.likeHighlight(id: highlight.id))
            }
        } catch {
            // Re-resolve by id — the pre-await index is stale if the array
            // shrank or reordered while the request was in flight
            if let idx = highlights.firstIndex(where: { $0.id == highlight.id }) {
                highlights[idx].isLikedByMe = wasLiked
                highlights[idx].likesCount += wasLiked ? 1 : -1
            }
        }
    }

    @discardableResult
    func toggleFollow() async -> Bool {
        guard let profile else { return false }

        isFollowing.toggle()
        var updated = profile
        updated.followersCount += isFollowing ? 1 : -1
        self.profile = updated

        do {
            if isFollowing {
                let _: EmptyResponse = try await apiClient.request(.follow(userId: userId))
            } else {
                let _: EmptyResponse = try await apiClient.request(.unfollow(userId: userId))
            }
            // Following/unfollowing changes what the viewer may see, so pick up
            // (or lose) the player-info embed right away.
            await reloadProfileOnly()
            return true
        } catch {
            // Revert
            isFollowing.toggle()
            updated.followersCount += isFollowing ? 1 : -1
            self.profile = updated
            actionError = "Couldn't update follow"
            return false
        }
    }
}
