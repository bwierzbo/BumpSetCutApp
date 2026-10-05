import Foundation
import Supabase

// MARK: - Lifetime Stats & Tester Flag

extension SupabaseAPIClient {

    nonisolated func getMyStats<T>() async throws -> T {
        let myId = try await currentUserId()
        return try safeCast(await myStatsRow(userId: myId))
    }

    nonisolated func addMyStats<T>(rallies: Int, timeCutSeconds: Double, batchId: UUID) async throws -> T {
        // The RPC increments atomically server-side; re-reading the row
        // afterwards keeps the decode path identical to getMyStats.
        try await supabase
            .rpc("add_user_stats", params: AddUserStatsParams(rallies: rallies, timeCutSeconds: timeCutSeconds, batchId: batchId))
            .execute()
        let myId = try await currentUserId()
        return try safeCast(await myStatsRow(userId: myId))
    }

    nonisolated func amITester<T>() async throws -> T {
        let myId = try await currentUserId()
        let rows: [AppTesterRow] = try await supabase
            .from("app_testers")
            .select("user_id")
            .eq("user_id", value: myId)
            .limit(1)
            .execute()
            .value
        return try safeCast(!rows.isEmpty)
    }

    private nonisolated func myStatsRow(userId: String) async throws -> UserStats {
        let rows: [UserStats] = try await supabase
            .from("user_stats")
            .select()
            .eq("user_id", value: userId)
            .limit(1)
            .execute()
            .value
        return rows.first ?? UserStats.empty(userId: userId)
    }
}
