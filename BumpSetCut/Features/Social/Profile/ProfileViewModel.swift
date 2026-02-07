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
            profile = UserProfile(id: userId, displayName: "Volleyball Player", username: "player_\(userId.prefix(4))")
        }

        isLoading = false
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
