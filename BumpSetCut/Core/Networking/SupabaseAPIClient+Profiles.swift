import Foundation
import Supabase

// MARK: - Profiles & Follows

extension SupabaseAPIClient {

    nonisolated func getProfile<T: Decodable>(userId: String) async throws -> T {
        try await supabase
            .from("profiles")
            .select(Self.profileSelect)
            .eq("id", value: userId)
            .single()
            .execute()
            .value
    }

    nonisolated func updateProfile<T: Decodable>(_ update: UserProfileUpdate) async throws -> T {
        let userId = try await currentUserId()
        return try await supabase
            .from("profiles")
            .update(update)
            .eq("id", value: userId)
            // Return the details embed too, so the cached local profile
            // keeps them after a save.
            .select(Self.profileSelect)
            .single()
            .execute()
            .value
    }

    nonisolated func updateProfileDetails<T: Decodable>(_ update: PlayerInfoUpdate) async throws -> T {
        let userId = try await currentUserId()
        guard update.userId == userId else { throw APIError.unauthorized }
        return try await supabase
            .from("profile_details")
            .upsert(update, onConflict: "user_id")
            .select()
            .single()
            .execute()
            .value
    }

    nonisolated func searchUsers<T: Decodable>(query: String, page: Int) async throws -> T {
        let pageSize = 20
        let from = page * pageSize
        let to = from + pageSize - 1
        return try await supabase
            .from("profiles")
            .select(Self.profileSelect)
            .ilike("username", pattern: "%\(query)%")
            .range(from: from, to: to)
            .execute()
            .value
    }

    nonisolated func checkUsernameAvailability<T>(username: String) async throws -> T {
        let rows: [UserProfile] = try await supabase
            .from("profiles")
            .select()
            .eq("username", value: username)
            .limit(1)
            .execute()
            .value
        return try safeCast(UsernameAvailability(isAvailable: rows.isEmpty))
    }

    // MARK: Follows

    nonisolated func follow<T>(userId: String) async throws -> T {
        let myId = try await currentUserId()
        try await supabase
            .from("follows")
            .insert(["follower_id": myId, "following_id": userId])
            .execute()
        return try safeCast(EmptyResponse())
    }

    nonisolated func unfollow<T>(userId: String) async throws -> T {
        let myId = try await currentUserId()
        try await supabase
            .from("follows")
            .delete()
            .eq("follower_id", value: myId)
            .eq("following_id", value: userId)
            .execute()
        return try safeCast(EmptyResponse())
    }

    nonisolated func getFollowers<T: Decodable>(userId: String, page: Int) async throws -> T {
        let pageSize = 20
        let from = page * pageSize
        let to = from + pageSize - 1
        return try await supabase
            .from("follows")
            .select("follower:profiles!follower_id(*)")
            .eq("following_id", value: userId)
            .range(from: from, to: to)
            .execute()
            .value
    }

    nonisolated func getFollowing<T: Decodable>(userId: String, page: Int) async throws -> T {
        let pageSize = 20
        let from = page * pageSize
        let to = from + pageSize - 1
        return try await supabase
            .from("follows")
            .select("following:profiles!following_id(*)")
            .eq("follower_id", value: userId)
            .range(from: from, to: to)
            .execute()
            .value
    }

    nonisolated func checkFollowStatus<T: Decodable>(userId: String) async throws -> T {
        let myId = try await currentUserId()
        return try await supabase
            .from("follows")
            .select("following_id")
            .eq("follower_id", value: myId)
            .eq("following_id", value: userId)
            .execute()
            .value
    }

    nonisolated func checkFollowStatusBatch<T: Decodable>(userIds: [String]) async throws -> T {
        guard !userIds.isEmpty else {
            return try safeCast([FollowRow]())
        }
        let myId = try await currentUserId()
        return try await supabase
            .from("follows")
            .select("following_id")
            .eq("follower_id", value: myId)
            .in("following_id", values: userIds)
            .execute()
            .value
    }
}
