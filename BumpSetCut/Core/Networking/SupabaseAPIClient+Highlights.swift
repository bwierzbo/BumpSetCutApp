import Foundation
import Supabase

// MARK: - Feed, Highlights & Likes

extension SupabaseAPIClient {

    private static let highlightSelect = "*, author:profiles(*), poll:polls(*, options:poll_options(*))"

    nonisolated func getFeed<T>(page: Int, pageSize: Int) async throws -> T {
        let from = page * pageSize
        let to = from + pageSize - 1
        let highlights: [Highlight] = try await supabase
            .from("highlights")
            .select(Self.highlightSelect)
            .order("created_at", ascending: false)
            .range(from: from, to: to)
            .execute()
            .value
        return try safeCast(await annotatedWithMyLikes(highlights))
    }

    nonisolated func getFollowingFeed<T>(page: Int, pageSize: Int) async throws -> T {
        let myId = try await currentUserId()
        let from = page * pageSize
        let to = from + pageSize - 1

        // Get IDs of users the current user follows
        let follows: [FollowRow] = try await supabase
            .from("follows")
            .select("following_id")
            .eq("follower_id", value: myId)
            .execute()
            .value
        let followedIds = follows.map(\.followingId)

        guard !followedIds.isEmpty else {
            // Safe empty array cast — T is always [Highlight] for feed endpoints
            guard let empty = [Highlight]() as? T else {
                throw URLError(.cannotDecodeContentData)
            }
            return empty
        }

        let highlights: [Highlight] = try await supabase
            .from("highlights")
            .select(Self.highlightSelect)
            .in("author_id", values: followedIds)
            .order("created_at", ascending: false)
            .range(from: from, to: to)
            .execute()
            .value
        return try safeCast(await annotatedWithMyLikes(highlights))
    }

    nonisolated func getUserHighlights<T>(userId: String, page: Int) async throws -> T {
        let pageSize = 20
        let from = page * pageSize
        let to = from + pageSize - 1
        let highlights: [Highlight] = try await supabase
            .from("highlights")
            .select(Self.highlightSelect)
            .eq("author_id", value: userId)
            .order("created_at", ascending: false)
            .range(from: from, to: to)
            .execute()
            .value
        return try safeCast(await annotatedWithMyLikes(highlights))
    }

    nonisolated func getHighlight<T>(id: String) async throws -> T {
        let highlight: Highlight = try await supabase
            .from("highlights")
            .select(Self.highlightSelect)
            .eq("id", value: id)
            .single()
            .execute()
            .value
        return try safeCast(await annotatedWithMyLikes([highlight]).first ?? highlight)
    }

    nonisolated func createHighlight<T: Decodable>(_ upload: HighlightUpload) async throws -> T {
        try await supabase
            .from("highlights")
            .insert(upload)
            .select(Self.highlightSelect)
            .single()
            .execute()
            .value
    }

    nonisolated func searchHighlights<T>(query: String, page: Int) async throws -> T {
        let pageSize = 20
        let from = page * pageSize
        let to = from + pageSize - 1
        // Strip PostgREST filter metacharacters before interpolating into `.or(...)`.
        // Characters like , ( ) { } " \ have structural meaning in a filter string
        // and would otherwise let a crafted query break out and rewrite the WHERE
        // clause (PostgREST filter injection). `searchUsers` uses the parameterized
        // `.ilike(pattern:)` API and needs no escaping; this `.or(...)` does.
        let safeQuery = query.components(separatedBy: CharacterSet(charactersIn: ",(){}\"\\")).joined()
        let highlights: [Highlight] = try await supabase
            .from("highlights")
            .select(Self.highlightSelect)
            .or("caption.ilike.%\(safeQuery)%,tags.cs.{\(safeQuery)},location_name.ilike.%\(safeQuery)%")
            .order("created_at", ascending: false)
            .range(from: from, to: to)
            .execute()
            .value
        return try safeCast(await annotatedWithMyLikes(highlights))
    }

    nonisolated func deleteHighlight<T>(id: String) async throws -> T {
        try await supabase
            .from("highlights")
            .delete()
            .eq("id", value: id)
            .execute()
        return try safeCast(EmptyResponse())
    }

    // MARK: Likes

    nonisolated func likeHighlight<T>(id: String) async throws -> T {
        let userId = try await currentUserId()
        try await supabase
            .from("likes")
            .insert(["highlight_id": id, "user_id": userId])
            .execute()
        return try safeCast(EmptyResponse())
    }

    nonisolated func unlikeHighlight<T>(id: String) async throws -> T {
        let userId = try await currentUserId()
        try await supabase
            .from("likes")
            .delete()
            .eq("highlight_id", value: id)
            .eq("user_id", value: userId)
            .execute()
        return try safeCast(EmptyResponse())
    }

    /// Set `isLikedByMe` on each highlight by looking up the current user's likes.
    /// PostgREST embeds can't express a "liked by me" flag, so do one follow-up
    /// query. No-ops when unauthenticated or the input is empty.
    private func annotatedWithMyLikes(_ highlights: [Highlight]) async -> [Highlight] {
        guard !highlights.isEmpty, let myId = try? await currentUserId() else { return highlights }
        guard let rows: [HighlightLikeRow] = try? await supabase
            .from("likes")
            .select("highlight_id")
            .eq("user_id", value: myId)
            .in("highlight_id", values: highlights.map(\.id))
            .execute()
            .value
        else { return highlights }

        let likedIds = Set(rows.map(\.highlightId))
        return highlights.map { highlight in
            guard likedIds.contains(highlight.id) else { return highlight }
            var liked = highlight
            liked.isLikedByMe = true
            return liked
        }
    }
}
