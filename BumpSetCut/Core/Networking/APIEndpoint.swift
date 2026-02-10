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
    case signInWithApple(identityToken: String)
    case refreshToken(String)
    case signOut
    case deleteAccount

    // User
    case getProfile(userId: String)
    case updateProfile(UserProfileUpdate)
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
    case follow(userId: String)
    case unfollow(userId: String)
    case getFollowers(userId: String, page: Int)
    case getFollowing(userId: String, page: Int)
    case checkFollowStatus(userId: String)
    case checkFollowStatusBatch(userIds: [String])

    // Upload
    case createUploadURL

    var path: String {
        switch self {
        case .signInWithApple: return "/auth/apple"
        case .refreshToken: return "/auth/refresh"
        case .signOut: return "/auth/signout"
        case .deleteAccount: return "/auth/delete"
        case .getProfile(let userId): return "/profiles/\(userId)"
        case .updateProfile: return "/profiles/me"
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
        case .follow(let userId): return "/profiles/\(userId)/follow"
        case .unfollow(let userId): return "/profiles/\(userId)/follow"
        case .getFollowers(let userId, _): return "/profiles/\(userId)/followers"
        case .getFollowing(let userId, _): return "/profiles/\(userId)/following"
        case .checkFollowStatus(let userId): return "/profiles/\(userId)/follow/status"
        case .checkFollowStatusBatch: return "/profiles/follow/status/batch"
        case .createUploadURL: return "/uploads"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .signInWithApple, .createHighlight, .addComment, .likeHighlight,
             .follow, .createUploadURL, .checkFollowStatusBatch:
            return .post
        case .refreshToken:
            return .post
        case .signOut:
            return .post
        case .deleteAccount, .deleteHighlight, .deleteComment, .unlikeHighlight, .unfollow:
            return .delete
        case .updateProfile:
            return .patch
        default:
            return .get
        }
    }

    var requiresAuth: Bool {
        switch self {
        case .signInWithApple: return false
        case .refreshToken: return false
        case .getHighlight, .getComments, .getProfile, .getUserHighlights,
             .getFollowers, .getFollowing, .searchUsers, .searchHighlights:
            return false
        default:
            return true
        }
    }
}

// MARK: - Request Payload Types

struct UserProfileUpdate: Codable {
    var displayName: String?
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
}
