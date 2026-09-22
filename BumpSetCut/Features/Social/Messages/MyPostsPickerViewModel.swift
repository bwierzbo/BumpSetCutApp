//
//  MyPostsPickerViewModel.swift
//  BumpSetCut
//
//  Your own community posts, for attaching one to a message. Paged like the
//  profile grid; a post is attached by id, so nothing is exported or uploaded.
//

import Foundation
import Observation

@MainActor
@Observable
final class MyPostsPickerViewModel {
    private(set) var highlights: [Highlight] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = true
    private(set) var loadFailed = false

    let currentUserId: String
    private let apiClient: any APIClient
    private var nextPage = 0
    static let pageSize = 20

    init(currentUserId: String, apiClient: (any APIClient)? = nil) {
        self.currentUserId = currentUserId
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        loadFailed = false
        do {
            let page: [Highlight] = try await apiClient.request(.getUserHighlights(userId: currentUserId, page: 0))
            highlights = page
            hasMore = page.count >= Self.pageSize
            nextPage = 1
        } catch is CancellationError {
        } catch {
            loadFailed = true
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page: [Highlight] = try await apiClient.request(.getUserHighlights(userId: currentUserId, page: nextPage))
            let seen = Set(highlights.map(\.id))
            highlights.append(contentsOf: page.filter { !seen.contains($0.id) })
            hasMore = page.count >= Self.pageSize
            nextPage += 1
        } catch is CancellationError {
        } catch {
            // Keep what we have; the sentinel row reappears and can retry.
        }
    }
}
