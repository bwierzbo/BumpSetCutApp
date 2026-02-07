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

        do {
            let page: [Comment] = try await apiClient.request(.getComments(highlightId: highlightId, page: 0))
            comments = page
            currentPage = 1
        } catch {
            // Stub comments for development
            comments = Self.stubComments(for: highlightId)
        }

        isLoading = false
    }

    func sendComment() async {
        let text = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true

        do {
            let comment: Comment = try await apiClient.request(.addComment(highlightId: highlightId, text: text))
            comments.insert(comment, at: 0)
            newCommentText = ""
        } catch {
            // Optimistic: add stub comment locally
            let stub = Comment(
                id: UUID().uuidString,
                highlightId: highlightId,
                authorId: "me",
                author: UserProfile(id: "me", displayName: "You", username: "me"),
                text: text
            )
            comments.insert(stub, at: 0)
            newCommentText = ""
        }

        isSending = false
    }

    func toggleCommentLike(_ comment: Comment) async {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        let wasLiked = comments[index].isLikedByMe
        comments[index].isLikedByMe = !wasLiked
        comments[index].likesCount += wasLiked ? -1 : 1
    }

    // MARK: - Stubs

    static func stubComments(for highlightId: String) -> [Comment] {
        [
            Comment(id: "c1", highlightId: highlightId, authorId: "1",
                    author: UserProfile(id: "1", displayName: "Sarah Chen", username: "sarahspikes"),
                    text: "What a save! Great rally.", likesCount: 5),
            Comment(id: "c2", highlightId: highlightId, authorId: "2",
                    author: UserProfile(id: "2", displayName: "Mike Torres", username: "miketorres"),
                    text: "That dig was insane", likesCount: 3),
        ]
    }
}
