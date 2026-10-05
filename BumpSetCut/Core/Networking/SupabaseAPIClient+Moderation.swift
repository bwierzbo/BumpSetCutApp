import Foundation
import Supabase

// MARK: - Moderation (reports & blocks)

extension SupabaseAPIClient {

    nonisolated func createReport<T: Decodable>(_ report: CreateReportRequest) async throws -> T {
        try await supabase
            .from("content_reports")
            .insert(report)
            .select()
            .single()
            .execute()
            .value
    }

    nonisolated func getMyReports<T: Decodable>(page: Int) async throws -> T {
        let myId = try await currentUserId()
        let pageSize = 20
        let from = page * pageSize
        let to = from + pageSize - 1
        return try await supabase
            .from("content_reports")
            .select()
            .eq("reporter_id", value: myId)
            .order("created_at", ascending: false)
            .range(from: from, to: to)
            .execute()
            .value
    }

    nonisolated func blockUser<T: Decodable>(userId: String, reason: String?) async throws -> T {
        let myId = try await currentUserId()
        let blockData: [String: String] = [
            "blocker_id": myId,
            "blocked_id": userId,
        ].merging(reason.map { ["reason": $0] } ?? [:]) { _, new in new }
        return try await supabase
            .from("user_blocks")
            .insert(blockData)
            .select()
            .single()
            .execute()
            .value
    }

    nonisolated func unblockUser<T>(userId: String) async throws -> T {
        let myId = try await currentUserId()
        try await supabase
            .from("user_blocks")
            .delete()
            .eq("blocker_id", value: myId)
            .eq("blocked_id", value: userId)
            .execute()
        return try safeCast(EmptyResponse())
    }

    nonisolated func getBlockedUsers<T: Decodable>() async throws -> T {
        let myId = try await currentUserId()
        return try await supabase
            .from("user_blocks")
            .select()
            .eq("blocker_id", value: myId)
            .execute()
            .value
    }
}
