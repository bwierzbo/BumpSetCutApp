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

    // Links to local data (nil if not from this device)
    var localVideoId: UUID?
    var localRallyIndex: Int?

    /// HLS streaming URL constructed from Mux playback ID.
    var videoURL: URL {
        URL(string: "https://stream.mux.com/\(muxPlaybackId).m3u8")!
    }

    /// Thumbnail image URL from Mux at 2-second mark.
    var thumbnailImageURL: URL? {
        thumbnailURL ?? URL(string: "https://image.mux.com/\(muxPlaybackId)/thumbnail.jpg?time=2")
    }

    init(id: String, authorId: String, author: UserProfile? = nil, muxPlaybackId: String,
         thumbnailURL: URL? = nil, caption: String? = nil, tags: [String] = [],
         rallyMetadata: RallyHighlightMetadata, likesCount: Int = 0, commentsCount: Int = 0,
         isLikedByMe: Bool = false, createdAt: Date = Date(),
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
        localVideoId = try container.decodeIfPresent(UUID.self, forKey: .localVideoId)
        localRallyIndex = try container.decodeIfPresent(Int.self, forKey: .localRallyIndex)
    }

    private enum CodingKeys: String, CodingKey {
        case id, authorId, author, muxPlaybackId, thumbnailURL, caption, tags
        case rallyMetadata, likesCount, commentsCount, isLikedByMe, createdAt
        case localVideoId, localRallyIndex
    }
}
