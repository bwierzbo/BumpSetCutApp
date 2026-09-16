//
//  SocialNotificationService.swift
//  BumpSetCut
//
//  Tracks the unread social-notification badge and listens on Supabase
//  Realtime so new likes/follows/comments land while the app is running.
//  A new follow "pops": an in-app toast when the app is active, a local
//  notification banner when it's in the background. True closed-app pushes
//  need APNs and are tracked on the backlog.
//

import Foundation
import Observation
import Supabase
import UIKit
import UserNotifications

@MainActor
@Observable
final class SocialNotificationService {

    static let shared = SocialNotificationService()

    // MARK: - State

    private(set) var unreadCount = 0
    /// Set when a follow arrives while the app is active; HomeView shows it
    /// as a toast and clears it.
    var followToast: String?

    private let apiClient: SupabaseAPIClient
    private let supabase = SupabaseConfig.client
    private var channel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?

    private init(apiClient: SupabaseAPIClient = .shared) {
        self.apiClient = apiClient
    }

    // MARK: - Lifecycle (driven by AuthenticationService)

    func start(userId: String) {
        stop()
        Task { await refreshUnreadCount() }

        let channel = supabase.channel("notifications-\(userId)")
        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "notifications",
            filter: .eq("recipient_id", value: userId)
        )
        self.channel = channel
        listenTask = Task { [weak self] in
            await channel.subscribe()
            for await insert in inserts {
                await self?.handle(insert)
            }
        }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        if let channel {
            let client = supabase
            Task { await client.removeChannel(channel) }
        }
        channel = nil
        unreadCount = 0
        followToast = nil
    }

    // MARK: - Badge

    func refreshUnreadCount() async {
        guard let count: Int = try? await apiClient.request(.getUnreadNotificationCount) else { return }
        unreadCount = count
    }

    /// Called when the notification center has been opened and marked all read.
    func clearBadge() {
        unreadCount = 0
    }

    // MARK: - Live events

    /// Only the columns the pop needs; realtime records are raw snake_case,
    /// untouched by the API client's decoder.
    private struct InsertedRow: Decodable {
        let type: String
        let actorId: String
        enum CodingKeys: String, CodingKey {
            case type
            case actorId = "actor_id"
        }
    }

    private func handle(_ insert: InsertAction) async {
        unreadCount += 1

        guard let row = try? insert.decodeRecord(as: InsertedRow.self, decoder: JSONDecoder()),
              row.type == SocialNotification.Kind.follow.rawValue else { return }

        // Name the follower if we can; the pop still fires without it.
        let actor: UserProfile? = try? await apiClient.request(.getProfile(userId: row.actorId))
        let message = actor.map { "\($0.username) started following you" } ?? "You have a new follower"

        if UIApplication.shared.applicationState == .active {
            followToast = message
        } else {
            postLocalNotification(body: message)
        }
    }

    private func postLocalNotification(body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                // Provisional is the only kind requestable without a prompt.
                guard (try? await center.requestAuthorization(options: [.alert, .sound, .provisional])) == true else { return }
            case .denied:
                return
            default:
                break
            }
            let content = UNMutableNotificationContent()
            content.title = "New follower"
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "social-follow-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}
