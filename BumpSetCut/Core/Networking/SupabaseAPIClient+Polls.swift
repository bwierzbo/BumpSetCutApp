import Foundation
import Supabase

// MARK: - Polls

extension SupabaseAPIClient {

    nonisolated func createPoll<T: Decodable>(_ upload: PollUpload) async throws -> T {
        try await supabase
            .from("polls")
            .insert(upload)
            .select()
            .single()
            .execute()
            .value
    }

    nonisolated func createPollOptions<T: Decodable>(_ options: [PollOptionUpload]) async throws -> T {
        try await supabase
            .from("poll_options")
            .insert(options)
            .select()
            .execute()
            .value
    }

    nonisolated func votePoll<T>(_ vote: PollVoteUpload) async throws -> T {
        // Atomic vote change: conflict on (poll_id, user_id) updates the row
        // in place (delete-then-insert left no vote if the insert failed)
        try await supabase
            .from("poll_votes")
            .upsert(vote, onConflict: "poll_id,user_id")
            .execute()
        return try safeCast(EmptyResponse())
    }

    nonisolated func getMyPollVote<T>(pollId: String) async throws -> T {
        let userId = try await currentUserId()
        let rows: [PollVoteRow] = try await supabase
            .from("poll_votes")
            .select("option_id")
            .eq("poll_id", value: pollId)
            .eq("user_id", value: userId)
            .limit(1)
            .execute()
            .value
        return try safeCast(rows)
    }

    nonisolated func getMyPollVotes<T>(pollIds: [String]) async throws -> T {
        guard !pollIds.isEmpty else { return try safeCast([MyPollVoteRow]()) }
        let userId = try await currentUserId()
        let rows: [MyPollVoteRow] = try await supabase
            .from("poll_votes")
            .select("poll_id, option_id")
            .eq("user_id", value: userId)
            .in("poll_id", values: pollIds)
            .execute()
            .value
        return try safeCast(rows)
    }
}
