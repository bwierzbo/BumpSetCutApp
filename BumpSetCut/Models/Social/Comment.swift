import Foundation

// MARK: - Comment

struct Comment: Codable, Identifiable, Hashable {
    let id: String
    let highlightId: String
    let authorId: String
    let author: UserProfile?
    var text: String
    var likesCount: Int
    var isLikedByMe: Bool
    let createdAt: Date

    init(id: String, highlightId: String, authorId: String, author: UserProfile? = nil,
         text: String, likesCount: Int = 0, isLikedByMe: Bool = false,
         createdAt: Date = Date()) {
        self.id = id
        self.highlightId = highlightId
        self.authorId = authorId
        self.author = author
        self.text = text
        self.likesCount = likesCount
        self.isLikedByMe = isLikedByMe
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        highlightId = try container.decode(String.self, forKey: .highlightId)
        authorId = try container.decode(String.self, forKey: .authorId)
        author = try container.decodeIfPresent(UserProfile.self, forKey: .author)
        text = try container.decode(String.self, forKey: .text)
        likesCount = try container.decodeIfPresent(Int.self, forKey: .likesCount) ?? 0
        isLikedByMe = try container.decodeIfPresent(Bool.self, forKey: .isLikedByMe) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, highlightId, authorId, author, text, likesCount, isLikedByMe, createdAt
    }
}
