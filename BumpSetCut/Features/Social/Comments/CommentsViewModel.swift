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
    private let apiClient: any APIClient
    private var currentPage = 0

    init(highlightId: String, apiClient: (any APIClient)? = nil) {
        self.highlightId = highlightId
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
}
