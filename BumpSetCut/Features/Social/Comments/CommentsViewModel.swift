//
//  CommentsViewModel.swift
//  BumpSetCut
//
//  Manages comments for a single highlight.
//

import Foundation
import Observation

@MainActor
@Observable
final class CommentsViewModel {
    private(set) var comments: [Comment] = []
    private(set) var isLoading = false
    private(set) var loadError: Error?
    private(set) var sendError: Error?
    var newCommentText: String = ""
    private(set) var isSending = false

    let highlightId: String
    private(set) var poll: Poll?
    private let apiClient: any APIClient
    private var currentPage = 0

    init(highlight: Highlight, apiClient: (any APIClient)? = nil) {
        self.highlightId = highlight.id
        self.poll = highlight.poll
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    func loadComments() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil

        do {
            let page: [Comment] = try await apiClient.request(.getComments(highlightId: highlightId, page: 0))
            let blocked = ModerationService.shared.blockedUserIds
            comments = page.filter { comment in
                guard let authorUUID = UUID(uuidString: comment.authorId) else { return true }
                return !blocked.contains(authorUUID)
            }
            currentPage = 1
        } catch is CancellationError {
            // View went away / reloaded — not a real failure, don't surface it.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // In-flight request was cancelled (e.g. sheet dismissed) — ignore.
        } catch {
            loadError = error
            comments = []
        }

        isLoading = false
    }

    func sendComment() async {
        let text = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        sendError = nil

        do {
            let comment: Comment = try await apiClient.request(.addComment(highlightId: highlightId, text: text))
            comments.insert(comment, at: 0)
            newCommentText = ""
        } catch {
            sendError = error
        }

        isSending = false
    }

    func toggleCommentLike(_ comment: Comment) async {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        let wasLiked = comments[index].isLikedByMe
        comments[index].isLikedByMe = !wasLiked
        comments[index].likesCount += wasLiked ? -1 : 1
    }

    @ObservationIgnored private var isSyncingVote = false

    /// Fetch the user's existing vote so the UI reflects it and changing works.
    func loadMyPollVote() async {
        guard let pollId = poll?.id, poll?.myVoteOptionId == nil else { return }
        if let rows: [PollVoteRow] = try? await apiClient.request(.getMyPollVote(pollId: pollId)),
           let optionId = rows.first?.optionId {
            poll?.myVoteOptionId = optionId
        }
    }

    /// Cast a vote, or change an existing one. Updates the UI immediately and syncs
    /// the latest selection to the server (coalescing rapid taps), idempotently.
    func votePoll(optionId: String) async {
        guard var current = poll,
              current.myVoteOptionId != optionId,
              current.options.contains(where: { $0.id == optionId }) else { return }

        // Optimistic UI — instant, on every tap.
        let previous = current.myVoteOptionId
        if let previous, let prevIndex = current.options.firstIndex(where: { $0.id == previous }) {
            current.options[prevIndex].voteCount = max(0, current.options[prevIndex].voteCount - 1)
        } else {
            current.totalVotes += 1
        }
        if let newIndex = current.options.firstIndex(where: { $0.id == optionId }) {
            current.options[newIndex].voteCount += 1
        }
        current.myVoteOptionId = optionId
        poll = current

        await syncVoteToServer()
    }

    /// One server sync at a time; loops until the server matches the latest selection.
    private func syncVoteToServer() async {
        guard !isSyncingVote else { return }
        isSyncingVote = true
        defer { isSyncingVote = false }

        var synced: String?
        while let pollId = poll?.id, let target = poll?.myVoteOptionId, target != synced {
            do {
                let userId = try await SupabaseConfig.client.auth.session.user.id.uuidString.lowercased()
                // Idempotent: clear any existing vote first, then insert the current choice.
                let _: EmptyResponse = try await apiClient.request(.deletePollVote(pollId: pollId))
                let vote = PollVoteUpload(pollId: pollId, optionId: target, userId: userId)
                let _: EmptyResponse = try await apiClient.request(.votePoll(vote))
                synced = target
            } catch {
                // Keep the optimistic UI; it reconciles on next feed/poll load.
                return
            }
        }
    }
}
