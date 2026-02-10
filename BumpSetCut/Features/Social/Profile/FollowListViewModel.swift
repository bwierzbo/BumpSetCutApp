//
//  FollowListViewModel.swift
//  BumpSetCut
//
//  Manages paginated followers/following lists for a user profile.
//

import Foundation
import Observation

enum FollowListMode {
    case followers
    case following
}

@MainActor
@Observable
final class FollowListViewModel {
    private(set) var users: [UserProfile] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMorePages = true

    let userId: String
    let mode: FollowListMode
    private let apiClient: any APIClient
    private var currentPage = 0
    private let pageSize = 20

    init(userId: String, mode: FollowListMode, apiClient: (any APIClient)? = nil) {
        self.userId = userId
        self.mode = mode
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    var title: String {
        switch mode {
        case .followers: return "Followers"
        case .following: return "Following"
        }
    }

    func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true

        do {
            switch mode {
            case .followers:
                let wrappers: [FollowerWrapper] = try await apiClient.request(
                    .getFollowers(userId: userId, page: 0)
                )
                users = wrappers.map(\.follower)
                hasMorePages = wrappers.count >= pageSize
            case .following:
                let wrappers: [FollowingWrapper] = try await apiClient.request(
                    .getFollowing(userId: userId, page: 0)
                )
                users = wrappers.map(\.following)
                hasMorePages = wrappers.count >= pageSize
            }
            currentPage = 1
        } catch {
            // Keep empty on failure
        }

        isLoading = false
    }

    func loadMore() async {
        guard hasMorePages, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            switch mode {
            case .followers:
                let wrappers: [FollowerWrapper] = try await apiClient.request(
                    .getFollowers(userId: userId, page: currentPage)
                )
                users.append(contentsOf: wrappers.map(\.follower))
                hasMorePages = wrappers.count >= pageSize
            case .following:
                let wrappers: [FollowingWrapper] = try await apiClient.request(
                    .getFollowing(userId: userId, page: currentPage)
                )
                users.append(contentsOf: wrappers.map(\.following))
                hasMorePages = wrappers.count >= pageSize
            }
            currentPage += 1
        } catch {
            // Silently fail pagination
        }
    }
}
