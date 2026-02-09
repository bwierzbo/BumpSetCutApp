import Foundation

// MARK: - Rally Highlight Metadata

struct RallyHighlightMetadata: Codable, Hashable {
    let duration: Double
    let confidence: Double
    let quality: Double
    let detectionCount: Int
}

// MARK: - Highlight

struct Highlight: Codable, Identifiable, Hashable {
    let id: String
    let authorId: String
    let author: UserProfile?
    let muxPlaybackId: String
    let thumbnailURL: URL?
    var caption: String?
    var tags: [String]
    let rallyMetadata: RallyHighlightMetadata
    var likesCount: Int
    var commentsCount: Int
    var isLikedByMe: Bool
    let createdAt: Date
    var hideLikes: Bool
    var videoUrls: [String]?

    // Links to local data (nil if not from this device)
    var localVideoId: UUID?
    var localRallyIndex: Int?

    /// All video URLs for this highlight (supports multi-rally posts).
    var allVideoURLs: [URL] {
        if let urls = videoUrls, !urls.isEmpty {
            return urls.compactMap { URL(string: $0) }
        }
        if let url = URL(string: muxPlaybackId) {
            return [url]
        }
        return []
    }

    /// Primary video URL (first in list or single).
    var videoURL: URL {
        allVideoURLs.first ?? URL(string: "about:blank")!
    }

    /// Thumbnail image URL (falls back to nil if no dedicated thumbnail).
    var thumbnailImageURL: URL? {
        thumbnailURL
    }

    init(id: String, authorId: String, author: UserProfile? = nil, muxPlaybackId: String,
         thumbnailURL: URL? = nil, caption: String? = nil, tags: [String] = [],
         rallyMetadata: RallyHighlightMetadata, likesCount: Int = 0, commentsCount: Int = 0,
         isLikedByMe: Bool = false, createdAt: Date = Date(),
         hideLikes: Bool = false, videoUrls: [String]? = nil,
         localVideoId: UUID? = nil, localRallyIndex: Int? = nil) {
        self.id = id
        self.authorId = authorId
        self.author = author
        self.muxPlaybackId = muxPlaybackId
        self.thumbnailURL = thumbnailURL
        self.caption = caption
        self.tags = tags
        self.rallyMetadata = rallyMetadata
        self.likesCount = likesCount
        self.commentsCount = commentsCount
        self.isLikedByMe = isLikedByMe
        self.createdAt = createdAt
        self.hideLikes = hideLikes
        self.videoUrls = videoUrls
        self.localVideoId = localVideoId
        self.localRallyIndex = localRallyIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        authorId = try container.decode(String.self, forKey: .authorId)
        author = try container.decodeIfPresent(UserProfile.self, forKey: .author)
        muxPlaybackId = try container.decode(String.self, forKey: .muxPlaybackId)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        rallyMetadata = try container.decode(RallyHighlightMetadata.self, forKey: .rallyMetadata)
        likesCount = try container.decodeIfPresent(Int.self, forKey: .likesCount) ?? 0
        commentsCount = try container.decodeIfPresent(Int.self, forKey: .commentsCount) ?? 0
        isLikedByMe = try container.decodeIfPresent(Bool.self, forKey: .isLikedByMe) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        hideLikes = try container.decodeIfPresent(Bool.self, forKey: .hideLikes) ?? false
        videoUrls = try container.decodeIfPresent([String].self, forKey: .videoUrls)
        localVideoId = try container.decodeIfPresent(UUID.self, forKey: .localVideoId)
        localRallyIndex = try container.decodeIfPresent(Int.self, forKey: .localRallyIndex)
    }

    private enum CodingKeys: String, CodingKey {
        case id, authorId, author, muxPlaybackId, thumbnailURL, caption, tags
        case rallyMetadata, likesCount, commentsCount, isLikedByMe, createdAt
        case hideLikes, videoUrls, localVideoId, localRallyIndex
    }
}
