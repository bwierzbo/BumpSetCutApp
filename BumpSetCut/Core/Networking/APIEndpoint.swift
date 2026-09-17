import Foundation

// MARK: - HTTP Method

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
}

// MARK: - API Endpoint

enum APIEndpoint {
    // Auth
    case refreshToken(String)
    case signOut

    // User
    case getProfile(userId: String)
    case updateProfile(UserProfileUpdate)
    case updateProfileDetails(PlayerInfoUpdate)
    case searchUsers(query: String, page: Int)

    // Highlights
    case getFeed(page: Int, pageSize: Int)
    case getFollowingFeed(page: Int, pageSize: Int)
    case getUserHighlights(userId: String, page: Int)
    case getHighlight(id: String)
    case createHighlight(HighlightUpload)
    case deleteHighlight(id: String)
    case searchHighlights(query: String, page: Int)

    // Social
    case likeHighlight(id: String)
    case unlikeHighlight(id: String)
    case addComment(highlightId: String, text: String)
    case deleteComment(id: String)
    case getComments(highlightId: String, page: Int)
    case likeComment(id: String)
    case unlikeComment(id: String)
    case follow(userId: String)
    case unfollow(userId: String)
    case getFollowers(userId: String, page: Int)
    case getFollowing(userId: String, page: Int)
    case checkFollowStatus(userId: String)
    case checkFollowStatusBatch(userIds: [String])

    // Username
    case checkUsernameAvailability(username: String)

    // Content Moderation
    case createReport(CreateReportRequest)
    case getMyReports(page: Int)
    case blockUser(userId: String, reason: String?)
    case unblockUser(userId: String)
    case getBlockedUsers
    case isUserBlocked(userId: String)

    // Polls
    case createPoll(PollUpload)
    case createPollOptions(pollId: String, options: [PollOptionUpload])
    case votePoll(PollVoteUpload)
    case getMyPollVote(pollId: String)
    case getMyPollVotes(pollIds: [String])

    // Notifications
    case getNotifications(page: Int)
    case getUnreadNotificationCount
    case markAllNotificationsRead

    // Direct Messages
    case getConversations(page: Int)
    case getConversationRequests(page: Int)
    case getConversation(id: String)
    case getMessages(conversationId: String, before: Date?, limit: Int)
    case sendMessage(SendMessageParams)
    case getOrCreateConversation(otherUserId: String)
    case acceptConversation(id: String)
    case leaveConversation(id: String)
    case markConversationRead(id: String)
    case unreadMessageCount
    case pendingRequestCount
    case registerDeviceToken(DeviceTokenRegistration)
    case deleteDeviceToken(token: String)

    // Lifetime Stats (account-linked)
    case getMyStats
    case addMyStats(rallies: Int, timeCutSeconds: Double)

    // Upload
    case createUploadURL

    var path: String {
        switch self {
        case .refreshToken: return "/auth/refresh"
        case .signOut: return "/auth/signout"
        case .getProfile(let userId): return "/profiles/\(userId)"
        case .updateProfile: return "/profiles/me"
        case .updateProfileDetails: return "/profiles/me/details"
        case .searchUsers: return "/profiles/search"
        case .getFeed: return "/highlights/feed"
        case .getFollowingFeed: return "/highlights/following"
        case .getUserHighlights(let userId, _): return "/profiles/\(userId)/highlights"
        case .getHighlight(let id): return "/highlights/\(id)"
        case .createHighlight: return "/highlights"
        case .deleteHighlight(let id): return "/highlights/\(id)"
        case .searchHighlights: return "/highlights/search"
        case .likeHighlight(let id): return "/highlights/\(id)/like"
        case .unlikeHighlight(let id): return "/highlights/\(id)/like"
        case .addComment(let highlightId, _): return "/highlights/\(highlightId)/comments"
        case .deleteComment(let id): return "/comments/\(id)"
        case .getComments(let highlightId, _): return "/highlights/\(highlightId)/comments"
        case .likeComment(let id): return "/comments/\(id)/like"
        case .unlikeComment(let id): return "/comments/\(id)/like"
        case .follow(let userId): return "/profiles/\(userId)/follow"
        case .unfollow(let userId): return "/profiles/\(userId)/follow"
        case .getFollowers(let userId, _): return "/profiles/\(userId)/followers"
        case .getFollowing(let userId, _): return "/profiles/\(userId)/following"
        case .checkFollowStatus(let userId): return "/profiles/\(userId)/follow/status"
        case .checkFollowStatusBatch: return "/profiles/follow/status/batch"
        case .checkUsernameAvailability: return "/profiles/username-check"
        case .createReport: return "/moderation/reports"
        case .getMyReports: return "/moderation/reports/me"
        case .blockUser(let userId, _): return "/moderation/blocks/\(userId)"
        case .unblockUser(let userId): return "/moderation/blocks/\(userId)"
        case .getBlockedUsers: return "/moderation/blocks"
        case .isUserBlocked(let userId): return "/moderation/blocks/\(userId)/status"
        case .createPoll: return "/polls"
        case .createPollOptions(let pollId, _): return "/polls/\(pollId)/options"
        case .votePoll: return "/poll_votes"
        case .getMyPollVote(let pollId): return "/polls/\(pollId)/my-vote"
        case .getMyPollVotes: return "/poll_votes/mine"
        case .getNotifications: return "/notifications"
        case .getUnreadNotificationCount: return "/notifications/unread-count"
        case .markAllNotificationsRead: return "/notifications/read-all"
        case .getConversations: return "/conversations"
        case .getConversationRequests: return "/conversations/requests"
        case .getConversation(let id): return "/conversations/\(id)"
        case .getMessages(let conversationId, _, _): return "/conversations/\(conversationId)/messages"
        case .sendMessage: return "/messages"
        case .getOrCreateConversation(let otherUserId): return "/conversations/with/\(otherUserId)"
        case .acceptConversation(let id): return "/conversations/\(id)/accept"
        case .leaveConversation(let id): return "/conversations/\(id)/leave"
        case .markConversationRead(let id): return "/conversations/\(id)/read"
        case .unreadMessageCount: return "/messages/unread-count"
        case .pendingRequestCount: return "/conversations/requests/count"
        case .registerDeviceToken: return "/device-tokens"
        case .deleteDeviceToken(let token): return "/device-tokens/\(token)"
        case .getMyStats: return "/stats/me"
        case .addMyStats: return "/stats/me/add"
        case .createUploadURL: return "/uploads"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .createHighlight, .addComment, .likeHighlight, .likeComment,
             .follow, .createUploadURL, .checkFollowStatusBatch, .createReport, .blockUser,
             .createPoll, .createPollOptions, .votePoll, .addMyStats,
             .sendMessage, .getOrCreateConversation, .acceptConversation, .registerDeviceToken:
            return .post
        case .refreshToken:
            return .post
        case .signOut:
            return .post
        case .deleteHighlight, .deleteComment, .unlikeHighlight, .unlikeComment, .unfollow, .unblockUser,
             .leaveConversation, .deleteDeviceToken:
            return .delete
        case .updateProfile, .markAllNotificationsRead, .markConversationRead:
            return .patch
        case .updateProfileDetails:
            return .put
        default:
            return .get
        }
    }

    var requiresAuth: Bool {
        switch self {
        case .refreshToken: return false
        case .checkUsernameAvailability: return false
        case .getHighlight, .getComments, .getProfile, .getUserHighlights,
             .getFollowers, .getFollowing, .searchUsers, .searchHighlights:
            return false
        default:
            return true
        }
    }
}

// MARK: - Request Payload Types

/// Full-row upsert for `profile_details`. Unlike `UserProfileUpdate`, this
/// encodes EVERY key — nil becomes JSON null — so clearing a field actually
/// clears it instead of being omitted from the payload and left untouched.
struct PlayerInfoUpdate: Encodable {
    let userId: String
    var playTypes: [PlayType]
    var heightCm: Int?
    var level: PlayLevel?
    var handedness: Handedness?
    var indoorPosition: IndoorPosition?
    var instagramHandle: String?

    init(userId: String, info: PlayerInfo) {
        self.userId = userId
        self.playTypes = info.playTypes
        self.heightCm = info.heightCm
        self.level = info.level
        self.handedness = info.handedness
        self.indoorPosition = info.indoorPosition
        self.instagramHandle = info.instagramHandle
    }

    enum CodingKeys: String, CodingKey {
        case userId, playTypes, heightCm, level, handedness, indoorPosition, instagramHandle
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encode(playTypes, forKey: .playTypes)
        // `encode`, not `encodeIfPresent`: nil must reach the row as null.
        try container.encode(heightCm, forKey: .heightCm)
        try container.encode(level, forKey: .level)
        try container.encode(handedness, forKey: .handedness)
        try container.encode(indoorPosition, forKey: .indoorPosition)
        try container.encode(instagramHandle, forKey: .instagramHandle)
    }
}

struct UserProfileUpdate: Codable {
    var username: String?
    var bio: String?
    var teamName: String?
    var privacyLevel: PrivacyLevel?
    var avatarURL: String?
}

struct HighlightUpload: Codable {
    let authorId: String
    let muxPlaybackId: String
    var caption: String?
    var tags: [String]
    var hideLikes: Bool
    var videoUrls: [String]?
    var localVideoId: UUID?
    var localRallyIndex: Int?
    let rallyMetadata: RallyHighlightMetadata
    var locationName: String?
    var latitude: Double?
    var longitude: Double?
}
