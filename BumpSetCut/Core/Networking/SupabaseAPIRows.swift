import Foundation

// MARK: - Supabase Row / RPC DTOs
//
// Decodable rows and Encodable RPC parameter wrappers used by SupabaseAPIClient.
// They live at file scope because Swift forbids nested types inside the
// generic `request<T>` function.

/// app_testers row — only its presence matters.
struct AppTesterRow: Decodable { let userId: String }

struct FollowRow: Decodable {
    // No custom CodingKeys: the decoder's `.convertFromSnakeCase` strategy maps
    // `following_id` → `followingId` automatically. Pinning the raw value to
    // "following_id" would never match the already-converted key and break decode.
    let followingId: String
}

struct FollowerWrapper: Decodable {
    let follower: UserProfile
}

struct FollowingWrapper: Decodable {
    let following: UserProfile
}

struct UsernameAvailability: Decodable {
    let isAvailable: Bool
}

struct PollVoteRow: Decodable {
    let optionId: String
}

struct MyPollVoteRow: Decodable {
    // `.convertFromSnakeCase` maps poll_id → pollId, option_id → optionId.
    let pollId: String
    let optionId: String
}

struct CommentLikeRow: Decodable {
    // `.convertFromSnakeCase` maps comment_id → commentId automatically.
    let commentId: String
}

struct HighlightLikeRow: Decodable {
    // `.convertFromSnakeCase` maps highlight_id → highlightId automatically.
    let highlightId: String
}

/// Single-argument RPC parameter wrappers.
struct OtherUserParams: Encodable {
    let otherUserId: String
    enum CodingKeys: String, CodingKey { case otherUserId = "p_other_user_id" }
}

struct ConversationIdParams: Encodable {
    let conversationId: String
    enum CodingKeys: String, CodingKey { case conversationId = "p_conversation_id" }
}

/// Parameters for the `add_user_stats` RPC — explicit keys so the encoder's
/// key strategy can't drift from the SQL parameter names.
struct AddUserStatsParams: Encodable {
    let rallies: Int
    let timeCutSeconds: Double
    let batchId: UUID

    enum CodingKeys: String, CodingKey {
        case rallies = "p_rallies"
        case timeCutSeconds = "p_time_cut_seconds"
        case batchId = "p_batch_id"
    }
}
