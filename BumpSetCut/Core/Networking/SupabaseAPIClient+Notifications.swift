import Foundation
import Supabase

// MARK: - Notifications

extension SupabaseAPIClient {

    nonisolated func getNotifications<T>(page: Int) async throws -> T {
        let myId = try await currentUserId()
        let pageSize = 30
        let from = page * pageSize
        let to = from + pageSize - 1
        let notifications: [SocialNotification] = try await supabase
            .from("notifications")
            .select("*, actor:profiles!actor_id(*)")
            .eq("recipient_id", value: myId)
            .order("created_at", ascending: false)
            .range(from: from, to: to)
            .execute()
            .value
        return try safeCast(notifications)
    }

    nonisolated func getUnreadNotificationCount<T>() async throws -> T {
        let myId = try await currentUserId()
        let count = try await supabase
            .from("notifications")
            .select("id", head: true, count: .exact)
            .eq("recipient_id", value: myId)
            .is("read_at", value: nil)
            .execute()
            .count ?? 0
        return try safeCast(count)
    }

    nonisolated func markAllNotificationsRead<T>() async throws -> T {
        let myId = try await currentUserId()
        try await supabase
            .from("notifications")
            .update(["read_at": Date().ISO8601Format()])
            .eq("recipient_id", value: myId)
            .is("read_at", value: nil)
            .execute()
        return try safeCast(EmptyResponse())
    }
}
