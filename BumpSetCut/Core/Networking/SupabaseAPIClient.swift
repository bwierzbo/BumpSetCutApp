import Foundation
import Supabase

// MARK: - Supabase API Client

final class SupabaseAPIClient: APIClient, @unchecked Sendable {

    static let shared = SupabaseAPIClient()

    private let supabase = SupabaseConfig.client

    private init() {}

    // MARK: - APIClient

    nonisolated func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        switch endpoint {

        // MARK: Feed & Highlights

        case .getFeed(let page, let pageSize):
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("highlights")
                .select("*, author:profiles(*)")
                .order("created_at", ascending: false)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .getUserHighlights(let userId, let page):
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("highlights")
                .select("*, author:profiles(*)")
                .eq("author_id", value: userId)
                .order("created_at", ascending: false)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .getHighlight(let id):
            let response: T = try await supabase
                .from("highlights")
                .select("*, author:profiles(*)")
                .eq("id", value: id)
                .single()
                .execute()
                .value
            return response

        case .createHighlight(let upload):
            let response: T = try await supabase
                .from("highlights")
                .insert(upload)
                .select("*, author:profiles(*)")
                .single()
                .execute()
                .value
            return response

        case .deleteHighlight(let id):
            try await supabase
                .from("highlights")
                .delete()
                .eq("id", value: id)
                .execute()
            return EmptyResponse() as! T

        // MARK: Likes

        case .likeHighlight(let id):
            let userId = try await currentUserId()
            try await supabase
                .from("likes")
                .insert(["highlight_id": id, "user_id": userId])
                .execute()
            return EmptyResponse() as! T

        case .unlikeHighlight(let id):
            let userId = try await currentUserId()
            try await supabase
                .from("likes")
                .delete()
                .eq("highlight_id", value: id)
                .eq("user_id", value: userId)
                .execute()
            return EmptyResponse() as! T

        // MARK: Comments

        case .getComments(let highlightId, let page):
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("comments")
                .select("*, author:profiles(*)")
                .eq("highlight_id", value: highlightId)
                .order("created_at", ascending: false)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .addComment(let highlightId, let text):
            let userId = try await currentUserId()
            let response: T = try await supabase
                .from("comments")
                .insert(["highlight_id": highlightId, "author_id": userId, "text": text])
                .select("*, author:profiles(*)")
                .single()
                .execute()
                .value
            return response

        case .deleteComment(let id):
            try await supabase
                .from("comments")
                .delete()
                .eq("id", value: id)
                .execute()
            return EmptyResponse() as! T

        // MARK: Profiles

        case .getProfile(let userId):
            let response: T = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            return response

        case .updateProfile(let update):
            let userId = try await currentUserId()
            let response: T = try await supabase
                .from("profiles")
                .update(update)
                .eq("id", value: userId)
                .select()
                .single()
                .execute()
                .value
            return response

        case .searchUsers(let query, let page):
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("profiles")
                .select()
                .or("display_name.ilike.%\(query)%,username.ilike.%\(query)%")
                .range(from: from, to: to)
                .execute()
                .value
            return response

        // MARK: Follows

        case .follow(let userId):
            let myId = try await currentUserId()
            try await supabase
                .from("follows")
                .insert(["follower_id": myId, "following_id": userId])
                .execute()
            return EmptyResponse() as! T

        case .unfollow(let userId):
            let myId = try await currentUserId()
            try await supabase
                .from("follows")
                .delete()
                .eq("follower_id", value: myId)
                .eq("following_id", value: userId)
                .execute()
            return EmptyResponse() as! T

        case .getFollowers(let userId, let page):
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("follows")
                .select("follower:profiles!follower_id(*)")
                .eq("following_id", value: userId)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        case .getFollowing(let userId, let page):
            let pageSize = 20
            let from = page * pageSize
            let to = from + pageSize - 1
            let response: T = try await supabase
                .from("follows")
                .select("following:profiles!following_id(*)")
                .eq("follower_id", value: userId)
                .range(from: from, to: to)
                .execute()
                .value
            return response

        // MARK: Auth (handled via Supabase Auth, not DB)

        case .signInWithApple, .refreshToken, .signOut, .deleteAccount:
            throw APIError.invalidRequest("Auth endpoints are handled by AuthenticationService, not APIClient")

        // MARK: Upload URL

        case .createUploadURL:
            throw APIError.invalidRequest("Use upload(fileURL:to:progress:) for file uploads")
        }
    }

    // MARK: - Upload

    nonisolated func upload(fileURL: URL, to endpoint: APIEndpoint, progress: @Sendable (Double) -> Void) async throws -> URL {
        let userId = try await currentUserId()
        let fileName = "\(userId)/\(UUID().uuidString).mp4"

        let bucket = supabase.storage.from("videos")
        let fileData = try Data(contentsOf: fileURL)
        try await bucket.upload(
            fileName,
            data: fileData,
            options: .init(contentType: "video/mp4")
        )

        progress(1.0)

        let publicURL = try bucket.getPublicURL(path: fileName)
        return publicURL
    }

    // MARK: - Private

    private func currentUserId() async throws -> String {
        guard let user = try? await SupabaseConfig.client.auth.session.user else {
            throw APIError.unauthorized
        }
        return user.id.uuidString
    }
}
