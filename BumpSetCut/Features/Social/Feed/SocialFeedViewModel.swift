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
            if feedType == .forYou {
                highlights = Self.stubHighlights
            }
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
            // Silently fail pagination — user can retry by scrolling
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

    func votePoll(highlightId: String, pollId: String, optionId: String) async {
        guard let highlightIndex = highlights.firstIndex(where: { $0.id == highlightId }),
              var poll = highlights[highlightIndex].poll else { return }

        // Optimistic update
        if let optIndex = poll.options.firstIndex(where: { $0.id == optionId }) {
            poll.options[optIndex].voteCount += 1
            poll.totalVotes += 1
            poll.myVoteOptionId = optionId
            highlights[highlightIndex].poll = poll
        }

        do {
            let userId = try await SupabaseConfig.client.auth.session.user.id.uuidString.lowercased()
            let vote = PollVoteUpload(pollId: pollId, optionId: optionId, userId: userId)
            let _: EmptyResponse = try await apiClient.request(.votePoll(vote))
        } catch {
            // Revert on failure
            if var revertPoll = highlights[highlightIndex].poll,
               let optIndex = revertPoll.options.firstIndex(where: { $0.id == optionId }) {
                revertPoll.options[optIndex].voteCount -= 1
                revertPoll.totalVotes -= 1
                revertPoll.myVoteOptionId = nil
                highlights[highlightIndex].poll = revertPoll
            }
        }
    }

    func enrichPollVotes() async {
        // Only enrich if user is authenticated
        guard (try? await SupabaseConfig.client.auth.session) != nil else { return }
        for i in highlights.indices {
            guard let poll = highlights[i].poll,
                  poll.myVoteOptionId == nil else { continue }
            do {
                let rows: [PollVoteRow] = try await apiClient.request(.getMyPollVote(pollId: poll.id))
                if let row = rows.first {
                    highlights[i].poll?.myVoteOptionId = row.optionId
                }
            } catch {
                // Non-critical — user just won't see their vote highlighted
            }
        }
    }

    // MARK: - Stub Data

    static let stubHighlights: [Highlight] = {
        let authors = [
            UserProfile(id: "1", username: "sarahspikes"),
            UserProfile(id: "2", username: "miketorres"),
            UserProfile(id: "3", username: "jadew"),
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
                createdAt: Date().addingTimeInterval(TimeInterval(-i * 3600)),
                hideLikes: i == 2
            )
        }
    }()
}

