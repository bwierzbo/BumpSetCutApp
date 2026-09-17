//
//  DirectMessageService.swift
//  BumpSetCut
//
//  Live delivery for direct messages: one Realtime subscription per signed-in
//  user, fanned out to whoever is listening (the inbox list, the open thread),
//  plus the unread badge and APNs device-token registration.
//

import Foundation
import Observation
import Supabase
import UIKit
import UserNotifications

/// Raw `messages` row as Realtime delivers it. Realtime payloads never pass
/// through `SupabaseConfig.jsonDecoder`, so the keys are snake_case and the
/// timestamp carries microseconds plus an offset.
struct InsertedMessageRow: Decodable {
    let id: String
    let conversationId: String
    let senderId: String
    let recipientId: String
    let body: String?
    let attachmentType: String?
    let highlightId: String?
    let clipPath: String?
    let clipDuration: Double?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case senderId = "sender_id"
        case recipientId = "recipient_id"
        case body
        case attachmentType = "attachment_type"
        case highlightId = "highlight_id"
        case clipPath = "clip_path"
        case clipDuration = "clip_duration"
        case createdAt = "created_at"
    }

    func asMessage() -> DirectMessage {
        DirectMessage(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            recipientId: recipientId,
            body: body,
            attachmentType: attachmentType.flatMap(DirectMessage.AttachmentType.init(rawValue:)),
            highlightId: highlightId,
            clipPath: clipPath,
            clipDuration: clipDuration,
            createdAt: Self.parseDate(createdAt),
            // Realtime carries no embeds; the thread hydrates it.
            highlight: nil
        )
    }

    static func parseDate(_ value: String) -> Date {
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle()) { return date }
        return Date()
    }
}

@MainActor
@Observable
final class DirectMessageService {

    static let shared = DirectMessageService()

    struct IncomingToast: Equatable {
        let conversationId: String
        let text: String
    }

    // MARK: - State

    /// Unread messages across every conversation, requests included — this is
    /// the envelope badge and the app icon badge.
    private(set) var unreadCount = 0
    /// Conversations waiting to be accepted; labels the Requests segment.
    private(set) var pendingRequestCount = 0
    /// The thread currently on screen. Its messages never toast or bump the badge.
    var activeConversationId: String?
    /// Set when a message arrives for another conversation while the app is
    /// active. MainTabView shows it and clears it.
    var incomingToast: IncomingToast?
    /// Conversation to open from a push tap or a deep link. MainTabView copies
    /// it into AppNavigationState (AppDelegate can't reach that @State object).
    var pendingConversationId: String?

    private let apiClient: any APIClient
    private let supabase = SupabaseConfig.client

    @ObservationIgnored private var channel: RealtimeChannelV2?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var userId: String?
    /// Fresh stream per subscriber — the inbox and the open thread both listen.
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<DirectMessage>.Continuation] = [:]
    /// Survives sign-out so the next sign-in can re-register without waiting
    /// for APNs to hand us the token again.
    @ObservationIgnored private var deviceToken: String?

    init(apiClient: (any APIClient)? = nil) {
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    // MARK: - Lifecycle

    func start(userId: String) {
        stop()
        subscribeToInserts(for: userId)
        Task { await adopt(userId: userId) }
    }

    /// Take on a signed-in user: counts, badge, and this device's push token.
    /// Separate from the Realtime subscription so either half can run alone.
    func adopt(userId: String) async {
        self.userId = userId
        await refreshCounts()
        registerForPushIfAuthorized()
        if let deviceToken {
            await sendDeviceTokenRegistration(deviceToken)
        }
    }

    private func subscribeToInserts(for userId: String) {
        let channel = supabase.channel("messages-\(userId)")
        // Obtained before subscribe() — same ordering the notifications
        // service relies on.
        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "messages",
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
        userId = nil
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
        unreadCount = 0
        pendingRequestCount = 0
        incomingToast = nil
        activeConversationId = nil
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
    }

    // MARK: - Live message fan-out

    /// A new stream for each caller. Ends when the caller's task is cancelled
    /// or the service stops. Values are raw rows — `highlight` is always nil.
    func inserts() -> AsyncStream<DirectMessage> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers[id] = nil }
            }
        }
    }

    private func handle(_ insert: InsertAction) async {
        guard let row = try? insert.decodeRecord(as: InsertedMessageRow.self, decoder: JSONDecoder()) else { return }
        await handleIncoming(row.asMessage(), isAppActive: UIApplication.shared.applicationState == .active)
    }

    /// Broadcast first so an open thread appends immediately, then deal with
    /// badge and toast.
    func handleIncoming(_ message: DirectMessage, isAppActive: Bool) async {
        for continuation in subscribers.values { continuation.yield(message) }

        if message.conversationId == activeConversationId {
            // The thread is on screen; it marks itself read.
            return
        }

        await refreshCounts()

        guard isAppActive else {
            // Backgrounded: APNs is the real path, but a local notification
            // covers the case where the app is running and push is off.
            postLocalNotification(for: message)
            return
        }

        let summary: ConversationSummary? = try? await apiClient.request(
            .getConversation(id: message.conversationId)
        )
        // `??` takes an autoclosure, which can't carry the await — resolve the
        // fallback explicitly.
        var username = summary?.otherUsername
        if username == nil {
            let profile: UserProfile? = try? await apiClient.request(.getProfile(userId: message.senderId))
            username = profile?.username
        }
        let name = username ?? "New message"
        let text = summary?.myStatus == .pending
            ? "\(name) wants to message you"
            : "\(name): \(message.previewText)"
        incomingToast = IncomingToast(conversationId: message.conversationId, text: text)
    }

    private func postLocalNotification(for message: DirectMessage) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound, .provisional])) == true else { return }
            case .denied:
                return
            default:
                break
            }
            let content = UNMutableNotificationContent()
            content.title = "New message"
            content.body = message.previewText
            content.sound = .default
            content.userInfo = ["conversationId": message.conversationId]
            let request = UNNotificationRequest(
                identifier: "dm-\(message.id)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    // MARK: - Counts

    func refreshCounts() async {
        guard userId != nil else { return }
        async let unread: Int? = try? apiClient.request(.unreadMessageCount)
        async let pending: Int? = try? apiClient.request(.pendingRequestCount)
        let (unreadValue, pendingValue) = await (unread, pending)
        if let unreadValue { unreadCount = unreadValue }
        if let pendingValue { pendingRequestCount = pendingValue }
        try? await UNUserNotificationCenter.current().setBadgeCount(unreadCount)
    }

    /// Called by the thread on appear (and whenever a message lands while it's
    /// open) so the badge tracks what's actually been seen.
    func didOpenConversation(_ id: String) async {
        activeConversationId = id
        let _: EmptyResponse? = try? await apiClient.request(.markConversationRead(id: id))
        await refreshCounts()
    }

    func didCloseConversation(_ id: String) {
        if activeConversationId == id { activeConversationId = nil }
    }

    // MARK: - Push tokens

    /// TestFlight and App Store builds sign with the production APNs
    /// environment; anything run from Xcode gets the sandbox one.
    static var apnsEnvironment: DeviceTokenRegistration.Environment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    func registerForPushIfAuthorized() {
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional || status == .ephemeral else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func registerDeviceToken(_ data: Data) async {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        await sendDeviceTokenRegistration(hex)
    }

    private func sendDeviceTokenRegistration(_ token: String) async {
        guard userId != nil else { return }
        let registration = DeviceTokenRegistration(token: token, environment: Self.apnsEnvironment)
        let _: EmptyResponse? = try? await apiClient.request(.registerDeviceToken(registration))
    }

    /// Called before the auth session is torn down — deleting the row needs it.
    func unregisterDeviceToken() async {
        guard let deviceToken else { return }
        let _: EmptyResponse? = try? await apiClient.request(.deleteDeviceToken(token: deviceToken))
    }
}
