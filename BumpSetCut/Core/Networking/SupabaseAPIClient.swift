import Foundation
import Supabase

// MARK: - Supabase API Client
//
// `request<T>` is a thin dispatcher; each area's queries live in an extension:
// +Highlights (feed, highlights, likes), +Comments, +Profiles (profiles,
// follows), +Moderation, +Polls, +Notifications, +DirectMessages (incl. device
// tokens), +Stats. Streaming uploads are in SupabaseStorageUploader.swift and
// the row/RPC DTOs in SupabaseAPIRows.swift.

final class SupabaseAPIClient: APIClient, MessageMediaClient, @unchecked Sendable {

    static let shared = SupabaseAPIClient()

    let supabase = SupabaseConfig.client

    /// Profiles plus their volleyball details. RLS on `profile_details` hides
    /// the embed (null) from viewers who shouldn't see a private player's info.
    /// Every profile read must carry the player-info embed. A bare `select()`
    /// yields a UserProfile whose `details` is nil, which is indistinguishable
    /// from "this user has set none" — and the editor then saves that emptiness
    /// back over real data.
    static let profileSelect = "*, details:profile_details(*)"

    private init() {}

    // MARK: - APIClient

    nonisolated func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        switch endpoint {

        // MARK: Feed, Highlights & Likes
        case .getFeed(let page, let pageSize): return try await getFeed(page: page, pageSize: pageSize)
        case .getFollowingFeed(let page, let pageSize): return try await getFollowingFeed(page: page, pageSize: pageSize)
        case .getUserHighlights(let userId, let page): return try await getUserHighlights(userId: userId, page: page)
        case .getHighlight(let id): return try await getHighlight(id: id)
        case .createHighlight(let upload): return try await createHighlight(upload)
        case .searchHighlights(let query, let page): return try await searchHighlights(query: query, page: page)
        case .deleteHighlight(let id): return try await deleteHighlight(id: id)
        case .likeHighlight(let id): return try await likeHighlight(id: id)
        case .unlikeHighlight(let id): return try await unlikeHighlight(id: id)

        // MARK: Comments
        case .getComments(let highlightId, let page): return try await getComments(highlightId: highlightId, page: page)
        case .addComment(let highlightId, let text): return try await addComment(highlightId: highlightId, text: text)
        case .deleteComment(let id): return try await deleteComment(id: id)
        case .likeComment(let id): return try await likeComment(id: id)
        case .unlikeComment(let id): return try await unlikeComment(id: id)

        // MARK: Profiles & Follows
        case .getProfile(let userId): return try await getProfile(userId: userId)
        case .updateProfile(let update): return try await updateProfile(update)
        case .updateProfileDetails(let update): return try await updateProfileDetails(update)
        case .searchUsers(let query, let page): return try await searchUsers(query: query, page: page)
        case .checkUsernameAvailability(let username): return try await checkUsernameAvailability(username: username)
        case .follow(let userId): return try await follow(userId: userId)
        case .unfollow(let userId): return try await unfollow(userId: userId)
        case .getFollowers(let userId, let page): return try await getFollowers(userId: userId, page: page)
        case .getFollowing(let userId, let page): return try await getFollowing(userId: userId, page: page)
        case .checkFollowStatus(let userId): return try await checkFollowStatus(userId: userId)
        case .checkFollowStatusBatch(let userIds): return try await checkFollowStatusBatch(userIds: userIds)

        // MARK: Moderation
        case .createReport(let report): return try await createReport(report)
        case .getMyReports(let page): return try await getMyReports(page: page)
        case .blockUser(let userId, let reason): return try await blockUser(userId: userId, reason: reason)
        case .unblockUser(let userId): return try await unblockUser(userId: userId)
        case .getBlockedUsers: return try await getBlockedUsers()

        // MARK: Polls
        case .createPoll(let upload): return try await createPoll(upload)
        case .createPollOptions(_, let options): return try await createPollOptions(options)
        case .votePoll(let vote): return try await votePoll(vote)
        case .getMyPollVote(let pollId): return try await getMyPollVote(pollId: pollId)
        case .getMyPollVotes(let pollIds): return try await getMyPollVotes(pollIds: pollIds)

        // MARK: Notifications
        case .getNotifications(let page): return try await getNotifications(page: page)
        case .getUnreadNotificationCount: return try await getUnreadNotificationCount()
        case .markAllNotificationsRead: return try await markAllNotificationsRead()

        // MARK: Direct Messages & Device Tokens
        case .getConversations(let page): return try await getConversations(page: page, status: "accepted")
        case .getConversationRequests(let page): return try await getConversations(page: page, status: "pending")
        case .getConversation(let id): return try await getConversation(id: id)
        case .getMessages(let conversationId, let before, let limit):
            return try await getMessages(conversationId: conversationId, before: before, limit: limit)
        case .sendMessage(let params): return try await sendMessage(params)
        case .getOrCreateConversation(let otherUserId): return try await getOrCreateConversation(otherUserId: otherUserId)
        case .acceptConversation(let id): return try await conversationRPC("accept_conversation", id: id)
        case .leaveConversation(let id): return try await conversationRPC("leave_conversation", id: id)
        case .markConversationRead(let id): return try await conversationRPC("mark_conversation_read", id: id)
        case .unreadMessageCount: return try await countRPC("unread_message_count")
        case .pendingRequestCount: return try await countRPC("pending_request_count")
        case .registerDeviceToken(let registration): return try await registerDeviceToken(registration)
        case .deleteDeviceToken(let token): return try await deleteDeviceToken(token: token)

        // MARK: Lifetime Stats
        case .getMyStats: return try await getMyStats()
        case .amITester: return try await amITester()
        case .addMyStats(let rallies, let timeCutSeconds, let batchId):
            return try await addMyStats(rallies: rallies, timeCutSeconds: timeCutSeconds, batchId: batchId)

        // MARK: Not served by this client
        case .refreshToken, .signOut:
            throw APIError.invalidRequest("Auth endpoints are handled by AuthenticationService, not APIClient")
        case .createUploadURL:
            throw APIError.invalidRequest("Use upload(fileURL:to:progress:) for file uploads")
        }
    }

    // MARK: - Upload

    nonisolated func upload(fileURL: URL, to endpoint: APIEndpoint, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fileName = try await streamUpload(fileURL: fileURL, bucket: "videos", progress: progress)
        return try supabase.storage.from("videos").getPublicURL(path: fileName)
    }

    // MARK: - Data Flywheel

    nonisolated func submitFlywheelContribution(_ contribution: FlywheelContribution, frameURLs: [URL], progress: @escaping @Sendable (Double) -> Void) async throws {
        let userId = try await currentUserId()
        // Upload each full-res still into the private bucket under the user's
        // folder: {userId}/{contributionId}/fNNN.jpg (the leading folder satisfies
        // the RLS owner check). Empty for a repeat flag whose frames already exist.
        var objectPaths: [String] = []
        let total = max(frameURLs.count, 1)
        for (i, url) in frameURLs.enumerated() {
            let data = try Data(contentsOf: url)
            // Keep the meaningful basename (rally_NN / random_NN), drop the local
            // contributionId prefix.
            let baseName = url.lastPathComponent
                .replacingOccurrences(of: "\(contribution.id.uuidString)_", with: "")
            let path = "\(userId)/\(contribution.id.uuidString)/\(baseName)"
            try await supabase.storage.from("training-data").upload(
                path, data: data, options: .init(contentType: "image/jpeg", upsert: true)
            )
            objectPaths.append(path)
            progress(Double(i + 1) / Double(total))
        }
        // Insert-or-increment: first flag for a video records frames + columns;
        // later flags just bump flag_count and append events server-side.
        let params = FlywheelFlagRPCParams(contribution: contribution, frameUrls: objectPaths)
        try await supabase.rpc("record_flywheel_flag", params: params).execute()
    }

    // MARK: - Avatar Upload

    /// Uploads a new avatar and returns its public URL.
    ///
    /// Every upload gets its own object name rather than overwriting a single
    /// `avatar.jpg`. That means a plain insert (no dependence on an UPDATE
    /// policy for the bucket) and a genuinely new URL, so no CDN or
    /// `AsyncImage` cache can serve the previous picture — the `?t=`
    /// cache-buster this used to rely on is no longer needed. Pass the
    /// profile's current avatar URL as `replacing` so the old object is
    /// cleaned up instead of accumulating.
    nonisolated func uploadAvatar(imageData: Data, replacing previous: URL? = nil) async throws -> URL {
        let userId = try await currentUserId()
        let fileName = "\(userId)/avatar_\(UUID().uuidString.lowercased()).jpg"

        try await supabase.storage.from("avatars").upload(
            fileName,
            data: imageData,
            options: .init(contentType: "image/jpeg", upsert: false)
        )

        // Best effort: a failure here just leaves one orphaned file behind,
        // which account deletion sweeps up anyway.
        if let previous,
           let stalePath = Self.avatarObjectPath(from: previous),
           stalePath != fileName {
            _ = try? await supabase.storage.from("avatars").remove(paths: [stalePath])
        }

        return try supabase.storage.from("avatars").getPublicURL(path: fileName)
    }

    /// `.../object/public/avatars/<userId>/<file>` → `<userId>/<file>`.
    nonisolated static func avatarObjectPath(from url: URL) -> String? {
        let components = url.pathComponents
        guard let bucketIndex = components.firstIndex(of: "avatars"),
              components.count > bucketIndex + 2 else { return nil }
        return components[(bucketIndex + 1)...].joined(separator: "/")
    }

    // MARK: - Message Media (private DM clips, playback only)

    nonisolated func signedURL(forMessageClip path: String) async throws -> URL {
        try await supabase.storage.from("message-media").createSignedURL(path: path, expiresIn: 3600)
    }

    // MARK: - Shared helpers (used by the per-area extensions)

    /// Safe cast helper — avoids force cast (`as! T`) crashes at runtime.
    nonisolated func safeCast<T>(_ value: Any) throws -> T {
        guard let result = value as? T else {
            throw URLError(.cannotDecodeContentData)
        }
        return result
    }

    func currentUserId() async throws -> String {
        guard let user = try? await SupabaseConfig.client.auth.session.user else {
            throw APIError.unauthorized
        }
        return user.id.uuidString.lowercased()
    }
}
