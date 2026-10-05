//
//  HighlightLikeToggle.swift
//  BumpSetCut
//
//  The one optimistic like/unlike flow, shared by every surface that shows a
//  post (feed, profile grid viewer, single-post viewer).
//

import Foundation

extension Highlight {
    /// Set like state, keeping the count in step. Idempotent, so a revert
    /// after a failed request can't double-count.
    mutating func setLikedByMe(_ liked: Bool) {
        guard isLikedByMe != liked else { return }
        isLikedByMe = liked
        likesCount += liked ? 1 : -1
    }
}

@MainActor
enum HighlightLikeToggle {
    /// Flip the post's like state through `update` (which applies a mutation
    /// to the post with the given id wherever the caller stores it), persist
    /// it, and revert on failure. Returns false when the request failed.
    static func toggle(
        _ highlight: Highlight,
        apiClient: any APIClient,
        update: (String, (inout Highlight) -> Void) -> Void
    ) async -> Bool {
        let wasLiked = highlight.isLikedByMe
        update(highlight.id) { $0.setLikedByMe(!wasLiked) }
        do {
            let _: EmptyResponse = try await apiClient.request(
                wasLiked ? .unlikeHighlight(id: highlight.id) : .likeHighlight(id: highlight.id)
            )
            return true
        } catch {
            update(highlight.id) { $0.setLikedByMe(wasLiked) }
            return false
        }
    }
}
