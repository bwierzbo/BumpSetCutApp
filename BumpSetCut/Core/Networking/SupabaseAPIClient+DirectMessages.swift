import Foundation
import Supabase

// MARK: - Direct Messages & Device Tokens

extension SupabaseAPIClient {

    /// Messages plus the attached post (if any). Nil when it was deleted or
    /// the viewer may not see it.
    private static let messageSelect =
        "*, highlight:highlights!highlight_id(*, author:profiles(*), poll:polls(*, options:poll_options(*)))"
    private static let conversationPageSize = 30

    /// The messaging RPCs raise `DM_*`-prefixed errors. PostgREST surfaces
    /// those as a `PostgrestError`; re-wrap them as `APIError.serverError` so
    /// callers only ever pattern-match one error type (`DirectMessageError`).
    private nonisolated func mappingDMErrors<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as PostgrestError {
            throw APIError.serverError(statusCode: 400, message: error.message)
        }
    }

    /// `status` is the caller's membership status: "accepted" for the inbox,
    /// "pending" for message requests.
    nonisolated func getConversations<T>(page: Int, status: String) async throws -> T {
        let myId = try await currentUserId()
        let from = page * Self.conversationPageSize
        let to = from + Self.conversationPageSize - 1
        let rows: [ConversationSummary] = try await supabase
            .from("conversation_overview")
            .select()
            .eq("user_id", value: myId)
            .eq("my_status", value: status)
            .order("last_message_at", ascending: false)
            .range(from: from, to: to)
            .execute()
            .value
        return try safeCast(rows)
    }

    nonisolated func getConversation<T>(id: String) async throws -> T {
        // 406 here means "no messages yet" (the view hides empty shells),
        // "not a member", or blocked — all handled by the caller.
        let row: ConversationSummary = try await supabase
            .from("conversation_overview")
            .select()
            .eq("conversation_id", value: id)
            .single()
            .execute()
            .value
        return try safeCast(row)
    }

    nonisolated func getMessages<T>(conversationId: String, before: Date?, limit: Int) async throws -> T {
        var query = supabase
            .from("messages")
            .select(Self.messageSelect)
            .eq("conversation_id", value: conversationId)
        if let before {
            // Fractional seconds are required — ISO8601Format() truncates
            // them, which makes the cursor skip or repeat messages.
            query = query.lt("created_at", value: before.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        let messages: [DirectMessage] = try await query
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return try safeCast(messages)
    }

    nonisolated func sendMessage<T>(_ params: SendMessageParams) async throws -> T {
        // The RPC returns the bare row; re-read it with embeds so the
        // decode path matches getMessages.
        let inserted: DirectMessage = try await mappingDMErrors {
            try await supabase.rpc("send_message", params: params).single().execute().value
        }
        let full: DirectMessage = try await supabase
            .from("messages")
            .select(Self.messageSelect)
            .eq("id", value: inserted.id)
            .single()
            .execute()
            .value
        return try safeCast(full)
    }

    nonisolated func getOrCreateConversation<T>(otherUserId: String) async throws -> T {
        let id: String = try await mappingDMErrors {
            try await supabase
                .rpc("get_or_create_conversation", params: OtherUserParams(otherUserId: otherUserId))
                .execute()
                .value
        }
        return try safeCast(id)
    }

    /// Runs one of the conversation-scoped RPCs (`accept_conversation`,
    /// `leave_conversation`, `mark_conversation_read`).
    nonisolated func conversationRPC<T>(_ function: String, id: String) async throws -> T {
        try await mappingDMErrors {
            try await supabase.rpc(function, params: ConversationIdParams(conversationId: id)).execute()
        }
        return try safeCast(EmptyResponse())
    }

    /// Runs a parameterless RPC that returns a single count.
    nonisolated func countRPC<T>(_ function: String) async throws -> T {
        let count: Int = try await supabase.rpc(function).execute().value
        return try safeCast(count)
    }

    // MARK: Device Tokens

    nonisolated func registerDeviceToken<T>(_ registration: DeviceTokenRegistration) async throws -> T {
        try await supabase.rpc("register_device_token", params: registration).execute()
        return try safeCast(EmptyResponse())
    }

    nonisolated func deleteDeviceToken<T>(token: String) async throws -> T {
        let myId = try await currentUserId()
        try await supabase
            .from("device_tokens")
            .delete()
            .eq("token", value: token)
            .eq("user_id", value: myId)
            .execute()
        return try safeCast(EmptyResponse())
    }
}
