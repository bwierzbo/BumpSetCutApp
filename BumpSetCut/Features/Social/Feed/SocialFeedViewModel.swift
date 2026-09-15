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

    /// What the feed actually renders: loaded highlights minus anything the
    /// user has since blocked or reported. Computed so a block/report mid-
    /// session removes the card immediately (ModerationService is @Observable).
    var visibleHighlights: [Highlight] {
        let moderation = ModerationService.shared
        return highlights.filter { !moderation.isHighlightHidden(id: $0.id, authorId: $0.authorId) }
    }
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: Error?
    private(set) var hasMorePages = true
    private(set) var loadMoreFailed = false
    /// Transient message for a failed background action (e.g. a reverted
    /// optimistic like). The view consumes it into a toast and clears it.
    var actionError: String?
    var feedType: FeedType = .forYou

    private var currentPage = 0
    private let pageSize = 20
    // Supersedes in-flight loads on tab switch — a dropped-by-guard load left
    // the previous feed's content displayed under the new tab
    private var loadGeneration = 0
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
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        error = nil
        loadMoreFailed = false
        currentPage = 0

        // Blocks are per-account server state; make sure they're in before the
        // first filter so blocked users stay hidden across app relaunches.
        await ModerationService.shared.ensureBlocksLoaded()

        do {
            let endpoint: APIEndpoint = feedType == .following
                ? .getFollowingFeed(page: 0, pageSize: pageSize)
                : .getFeed(page: 0, pageSize: pageSize)
            let page: [Highlight] = try await apiClient.request(endpoint)
            guard gen == loadGeneration else { return }
            let moderation = ModerationService.shared
            highlights = page.filter { !moderation.isHighlightHidden(id: $0.id, authorId: $0.authorId) }
            hasMorePages = page.count >= pageSize
            currentPage = 1
            await enrichPollVotes()
        } catch {
            guard gen == loadGeneration else { return }
            self.error = error
            highlights = []
            hasMorePages = false
        }

        if gen == loadGeneration {
            isLoading = false
        }
    }

    func loadMoreIfNeeded(currentItem: Highlight) async {
        // Compare against the last VISIBLE item — if the stored last was
        // hidden by a block/report, pagination would otherwise never trigger.
        guard let lastItem = visibleHighlights.last,
              lastItem.id == currentItem.id,
              hasMorePages,
              !isLoadingMore else { return }

        isLoadingMore = true
        loadMoreFailed = false
        defer { isLoadingMore = false }

        let gen = loadGeneration
        do {
            let endpoint: APIEndpoint = feedType == .following
                ? .getFollowingFeed(page: currentPage, pageSize: pageSize)
                : .getFeed(page: currentPage, pageSize: pageSize)
            let page: [Highlight] = try await apiClient.request(endpoint)
            // A feed switch mid-request supersedes this page
            guard gen == loadGeneration else { return }
            let moderation = ModerationService.shared
            let filtered = page.filter { !moderation.isHighlightHidden(id: $0.id, authorId: $0.authorId) }
            highlights.append(contentsOf: filtered)
            hasMorePages = page.count >= pageSize
            currentPage += 1
            await enrichPollVotes()
        } catch {
            print("⚠️ [SocialFeedViewModel] loadMore page \(currentPage) failed: \(error)")
            if gen == loadGeneration {
                loadMoreFailed = true
            }
        }
    }

    func retryLoadMore() async {
        guard let lastItem = highlights.last else { return }
        await loadMoreIfNeeded(currentItem: lastItem)
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
            // Revert on failure — re-resolve by id; the pre-await index can be
            // stale (feed switched, post deleted/prepended) and would crash or
            // corrupt another post's like state
            if let idx = highlights.firstIndex(where: { $0.id == highlight.id }) {
                highlights[idx].isLikedByMe = wasLiked
                highlights[idx].likesCount += wasLiked ? 1 : -1
            }
            actionError = "Couldn't update like"
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

