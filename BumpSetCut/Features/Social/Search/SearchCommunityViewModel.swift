//
//  SearchCommunityViewModel.swift
//  BumpSetCut
//
//  Manages community search: users and highlights with debounce and pagination.
//

import Foundation
import Observation

enum SearchScope: String, CaseIterable {
    case users = "Users"
    case posts = "Posts"
}

@MainActor
@Observable
final class SearchCommunityViewModel {
    var searchText = ""
    var searchScope: SearchScope = .users

    private(set) var users: [UserProfile] = []
    private(set) var highlights: [Highlight] = []
    private(set) var trendingTags: [String] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMorePages = true
    private(set) var followedUserIds: Set<String> = []

    private var currentPage = 0
    private let pageSize = 20
    private let apiClient: any APIClient
    private var debounceTask: Task<Void, Never>?

    init(apiClient: (any APIClient)? = nil) {
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    // MARK: - Debounced Search

    func searchTextChanged() {
        debounceTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            users = []
            highlights = []
            hasMorePages = true
            return
        }

        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    func scopeChanged() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        Task { await performSearch() }
    }

    // MARK: - Search

    func performSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isLoading else { return }

        isLoading = true
        currentPage = 0

        do {
            switch searchScope {
            case .users:
                let results: [UserProfile] = try await apiClient.request(
                    .searchUsers(query: query, page: 0)
                )
                users = results
                hasMorePages = results.count >= pageSize
                await checkFollowStatus(for: results.map(\.id))
            case .posts:
                let results: [Highlight] = try await apiClient.request(
                    .searchHighlights(query: query, page: 0)
                )
                highlights = results
                hasMorePages = results.count >= pageSize
            }
            currentPage = 1
        } catch {
            // Keep existing results on error
        }

        isLoading = false
    }

    // MARK: - Pagination

    func loadMore() async {
        guard hasMorePages, !isLoadingMore, !isLoading else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            switch searchScope {
            case .users:
                let results: [UserProfile] = try await apiClient.request(
                    .searchUsers(query: query, page: currentPage)
                )
                users.append(contentsOf: results)
                hasMorePages = results.count >= pageSize
                await checkFollowStatus(for: results.map(\.id))
            case .posts:
                let results: [Highlight] = try await apiClient.request(
                    .searchHighlights(query: query, page: currentPage)
                )
                highlights.append(contentsOf: results)
                hasMorePages = results.count >= pageSize
            }
            currentPage += 1
        } catch {
            // Silently fail pagination
        }
    }

    // MARK: - Trending Tags

    func loadTrendingTags() async {
        do {
            let recent: [Highlight] = try await apiClient.request(
                .getFeed(page: 0, pageSize: 50)
            )
            var tagCounts: [String: Int] = [:]
            for highlight in recent {
                for tag in highlight.tags {
                    tagCounts[tag, default: 0] += 1
                }
            }
            trendingTags = tagCounts
                .sorted { $0.value > $1.value }
                .prefix(12)
                .map(\.key)
        } catch {
            trendingTags = ["volleyball", "rally", "beach", "spike", "dig", "serve"]
        }
    }

    // MARK: - Helpers

    func selectTrendingTag(_ tag: String) {
        searchText = tag
        searchScope = .posts
        searchTextChanged()
    }

    // MARK: - Follow State

    func isFollowing(_ userId: String) -> Bool {
        followedUserIds.contains(userId)
    }

    func checkFollowStatus(for userIds: [String]) async {
        guard !userIds.isEmpty else { return }
        do {
            let rows: [FollowRow] = try await apiClient.request(
                .checkFollowStatusBatch(userIds: userIds)
            )
            for row in rows {
                followedUserIds.insert(row.followingId)
            }
        } catch {
            // Auth failure — no follow state available
        }
    }

    func toggleFollow(for userId: String) async {
        let wasFollowing = followedUserIds.contains(userId)

        // Optimistic update
        if wasFollowing {
            followedUserIds.remove(userId)
        } else {
            followedUserIds.insert(userId)
        }

        do {
            if wasFollowing {
                let _: EmptyResponse = try await apiClient.request(.unfollow(userId: userId))
            } else {
                let _: EmptyResponse = try await apiClient.request(.follow(userId: userId))
            }
        } catch {
            // Revert
            if wasFollowing {
                followedUserIds.insert(userId)
            } else {
                followedUserIds.remove(userId)
            }
        }
    }
}
