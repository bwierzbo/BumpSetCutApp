import Foundation

// MARK: - Privacy Level

enum PrivacyLevel: String, Codable, CaseIterable {
    case `public` = "public"
    case followersOnly = "followers_only"
    case `private` = "private"

    var displayName: String {
        switch self {
        case .public: return "Public"
        case .followersOnly: return "Followers Only"
        case .private: return "Private"
        }
    }
}

// MARK: - User Profile

struct UserProfile: Codable, Identifiable, Hashable {
    let id: String
    var username: String
    var avatarURL: URL?
    var bio: String?
    var teamName: String?
    var followersCount: Int
    var followingCount: Int
    var highlightsCount: Int
    var privacyLevel: PrivacyLevel
    let createdAt: Date

    init(id: String, username: String, avatarURL: URL? = nil,
         bio: String? = nil, teamName: String? = nil, followersCount: Int = 0,
         followingCount: Int = 0, highlightsCount: Int = 0,
         privacyLevel: PrivacyLevel = .public, createdAt: Date = Date()) {
        self.id = id
        self.username = username
        self.avatarURL = avatarURL
        self.bio = bio
        self.teamName = teamName
        self.followersCount = followersCount
        self.followingCount = followingCount
        self.highlightsCount = highlightsCount
        self.privacyLevel = privacyLevel
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL)
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        teamName = try container.decodeIfPresent(String.self, forKey: .teamName)
        followersCount = try container.decodeIfPresent(Int.self, forKey: .followersCount) ?? 0
        followingCount = try container.decodeIfPresent(Int.self, forKey: .followingCount) ?? 0
        highlightsCount = try container.decodeIfPresent(Int.self, forKey: .highlightsCount) ?? 0
        privacyLevel = try container.decodeIfPresent(PrivacyLevel.self, forKey: .privacyLevel) ?? .public
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, username, avatarURL, bio, teamName
        case followersCount, followingCount, highlightsCount, privacyLevel, createdAt
    }
}
