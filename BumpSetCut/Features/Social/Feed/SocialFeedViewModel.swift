//
//  SocialFeedViewModel.swift
//  BumpSetCut
//
//  Manages social feed data: loading, pagination, like/unlike.
//

import Foundation
import Observation

@MainActor
@Observable
final class SocialFeedViewModel {
    private(set) var highlights: [Highlight] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: Error?
    private(set) var hasMorePages = true

    private var currentPage = 0
    private let pageSize = 20
    private let apiClient: any APIClient

    init(apiClient: (any APIClient)? = nil) {
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    // MARK: - Loading

    func loadFeed() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        currentPage = 0

        do {
            let page: [Highlight] = try await apiClient.request(.getFeed(page: 0, pageSize: pageSize))
            highlights = page
            hasMorePages = page.count >= pageSize
            currentPage = 1
        } catch {
            self.error = error
            // Load stub data for development
            highlights = Self.stubHighlights
            hasMorePages = false
        }

        isLoading = false
    }

    func loadMoreIfNeeded(currentItem: Highlight) async {
        guard let lastItem = highlights.last,
              lastItem.id == currentItem.id,
              hasMorePages,
              !isLoadingMore else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page: [Highlight] = try await apiClient.request(.getFeed(page: currentPage, pageSize: pageSize))
            highlights.append(contentsOf: page)
            hasMorePages = page.count >= pageSize
            currentPage += 1
        } catch {
            // Silently fail pagination — user can retry by scrolling
        }
    }

    // MARK: - Interactions

    func toggleLike(for highlight: Highlight) async {
        guard let index = highlights.firstIndex(where: { $0.id == highlight.id }) else { return }

        // Optimistic update
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
            // Revert on failure
            highlights[index].isLikedByMe = wasLiked
            highlights[index].likesCount += wasLiked ? 1 : -1
        }
    }

    // MARK: - Stub Data

    static let stubHighlights: [Highlight] = {
        let authors = [
            UserProfile(id: "1", displayName: "Sarah Chen", username: "sarahspikes"),
            UserProfile(id: "2", displayName: "Mike Torres", username: "miketorres"),
            UserProfile(id: "3", displayName: "Jade Williams", username: "jadew"),
        ]
        return (0..<6).map { i in
            Highlight(
                id: "stub-\(i)",
                authorId: authors[i % 3].id,
                author: authors[i % 3],
                muxPlaybackId: "stub-playback-\(i)",
                caption: ["Huge rally!", "Beach volleyball finals", "What a save!", "Perfect set to spike", "Amazing dig", "Match point"][i],
                tags: ["volleyball", "rally"],
                rallyMetadata: RallyHighlightMetadata(duration: Double.random(in: 5...20), confidence: 0.92, quality: 0.88, detectionCount: Int.random(in: 30...120)),
                likesCount: Int.random(in: 0...200),
                commentsCount: Int.random(in: 0...50),
                createdAt: Date().addingTimeInterval(TimeInterval(-i * 3600))
            )
        }
    }()
}

