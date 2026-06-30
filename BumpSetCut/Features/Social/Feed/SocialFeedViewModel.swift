//
//  SocialFeedViewModel.swift
//  BumpSetCut
//
//  Manages social feed data: loading, pagination, like/unlike.
//

import Foundation
import Observation

enum FeedType {
    case forYou
    case following
}

@MainActor
@Observable
final class SocialFeedViewModel {
    private(set) var highlights: [Highlight] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: Error?
    private(set) var hasMorePages = true
    var feedType: FeedType = .forYou

    private var currentPage = 0
    private let pageSize = 20
    private let apiClient: any APIClient

    init(apiClient: (any APIClient)? = nil) {
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    // MARK: - Feed Switching

    func switchFeed(_ type: FeedType) {
        guard feedType != type else { return }
        feedType = type
        highlights = []
        Task { await loadFeed() }
    }

    // MARK: - Loading

    func loadFeed() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        currentPage = 0

        do {
            let endpoint: APIEndpoint = feedType == .following
                ? .getFollowingFeed(page: 0, pageSize: pageSize)
                : .getFeed(page: 0, pageSize: pageSize)
            let page: [Highlight] = try await apiClient.request(endpoint)
            let blocked = ModerationService.shared.blockedUserIds
            highlights = page.filter { highlight in
                guard let authorUUID = UUID(uuidString: highlight.authorId) else { return true }
                return !blocked.contains(authorUUID)
            }
            hasMorePages = page.count >= pageSize
            currentPage = 1
            await enrichPollVotes()
        } catch {
            self.error = error
            highlights = []
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
            let endpoint: APIEndpoint = feedType == .following
                ? .getFollowingFeed(page: currentPage, pageSize: pageSize)
                : .getFeed(page: currentPage, pageSize: pageSize)
            let page: [Highlight] = try await apiClient.request(endpoint)
            let blocked = ModerationService.shared.blockedUserIds
            let filtered = page.filter { highlight in
                guard let authorUUID = UUID(uuidString: highlight.authorId) else { return true }
                return !blocked.contains(authorUUID)
            }
            highlights.append(contentsOf: filtered)
            hasMorePages = page.count >= pageSize
            currentPage += 1
            await enrichPollVotes()
        } catch {
            print("⚠️ [SocialFeedViewModel] loadMore page \(currentPage) failed: \(error)")
        }
    }

    // MARK: - Insert

    func prependHighlight(_ highlight: Highlight) {
        highlights.insert(highlight, at: 0)
    }

    // MARK: - Delete

    func deleteHighlight(_ highlight: Highlight) async -> Bool {
        do {
            let _: EmptyResponse = try await apiClient.request(.deleteHighlight(id: highlight.id))
            highlights.removeAll { $0.id == highlight.id }
            return true
        } catch {
            print("⚠️ [SocialFeedViewModel] deleteHighlight(\(highlight.id)) failed: \(error)")
            return false
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

    // MARK: - Poll Voting

    func enrichPollVotes() async {
        // Only enrich if user is authenticated
        guard (try? await SupabaseConfig.client.auth.session) != nil else { return }

        // Collect the polls still missing the user's vote, then fetch them all in
        // one query instead of one round-trip per poll (was N+1 on the feed).
        let pollIds = highlights.compactMap { highlight -> String? in
            guard let poll = highlight.poll, poll.myVoteOptionId == nil else { return nil }
            return poll.id
        }
        guard !pollIds.isEmpty,
              let rows: [MyPollVoteRow] = try? await apiClient.request(.getMyPollVotes(pollIds: pollIds))
        else { return }

        let voteByPoll = Dictionary(rows.map { ($0.pollId, $0.optionId) }, uniquingKeysWith: { first, _ in first })
        for i in highlights.indices {
            if let pollId = highlights[i].poll?.id, let optionId = voteByPoll[pollId] {
                highlights[i].poll?.myVoteOptionId = optionId
            }
        }
    }
}

