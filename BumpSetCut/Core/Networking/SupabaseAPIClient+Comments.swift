import Foundation
import Supabase

// MARK: - Comments

extension SupabaseAPIClient {

    nonisolated func getComments<T>(highlightId: String, page: Int) async throws -> T {
        let pageSize = 20
        let from = page * pageSize
        let to = from + pageSize - 1
        var comments: [Comment] = try await supabase
            .from("comments")
            .select("*, author:profiles(*)")
            .eq("highlight_id", value: highlightId)
            .order("created_at", ascending: false)
            .range(from: from, to: to)
            .execute()
            .value

        // PostgREST embeds can't express a "liked by me" filter, so annotate
        // the current user's likes with one follow-up query. Best-effort (try?):
        // the heart fill reconciles on the next load, and a hiccup on the new
        // comment_likes table must not break comment loading itself. Skipped
        // when unauthenticated (comments are viewable without auth).
        if let myId = try? await currentUserId(), !comments.isEmpty,
           let likedRows: [CommentLikeRow] = try? await supabase
                .from("comment_likes")
                .select("comment_id")
                .eq("user_id", value: myId)
                .in("comment_id", values: comments.map(\.id))
                .execute()
                .value {
            let likedIds = Set(likedRows.map(\.commentId))
            for i in comments.indices where likedIds.contains(comments[i].id) {
                comments[i].isLikedByMe = true
            }
        }
        return try safeCast(comments)
    }

    nonisolated func addComment<T: Decodable>(highlightId: String, text: String) async throws -> T {
        let userId = try await currentUserId()
        return try await supabase
            .from("comments")
            .insert(["highlight_id": highlightId, "author_id": userId, "text": text])
            .select("*, author:profiles(*)")
            .single()
            .execute()
            .value
    }

    nonisolated func deleteComment<T>(id: String) async throws -> T {
        try await supabase
            .from("comments")
            .delete()
            .eq("id", value: id)
            .execute()
        return try safeCast(EmptyResponse())
    }

    nonisolated func likeComment<T>(id: String) async throws -> T {
        let userId = try await currentUserId()
        try await supabase
            .from("comment_likes")
            .insert(["comment_id": id, "user_id": userId])
            .execute()
        return try safeCast(EmptyResponse())
    }

    nonisolated func unlikeComment<T>(id: String) async throws -> T {
        let userId = try await currentUserId()
        try await supabase
            .from("comment_likes")
            .delete()
            .eq("comment_id", value: id)
            .eq("user_id", value: userId)
            .execute()
        return try safeCast(EmptyResponse())
    }
}
