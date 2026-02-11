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

        do {
            profile = try await apiClient.request(.getProfile(userId: userId))
            let page: [Highlight] = try await apiClient.request(.getUserHighlights(userId: userId, page: 0))
            highlights = page
            currentPage = 1
        } catch {
            self.error = error
            // Stub data
            profile = UserProfile(id: userId, username: "player_\(userId.prefix(4))")
        }

        await loadFollowStatus()
        isLoading = false
    }

    private func loadFollowStatus() async {
        do {
            let rows: [FollowRow] = try await apiClient.request(.checkFollowStatus(userId: userId))
            isFollowing = !rows.isEmpty
        } catch {
            // Auth failure or network issue — don't break profile loading
        }
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
            highlights[index].isLikedByMe = wasLiked
            highlights[index].likesCount += wasLiked ? 1 : -1
        }
    }

    func toggleFollow() async {
        guard let profile else { return }

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
        } catch {
            // Revert
            isFollowing.toggle()
            updated.followersCount += isFollowing ? 1 : -1
            self.profile = updated
        }
    }
}
