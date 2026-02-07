import Foundation

// MARK: - Cache Entry

private struct CacheEntry<T: Codable>: Codable {
    let data: T
    let cachedAt: Date
    let ttl: TimeInterval

    var isExpired: Bool {
        Date().timeIntervalSince(cachedAt) > ttl
    }
}

// MARK: - Social Cache

@MainActor
final class SocialCache {

    // MARK: - TTL Constants

    static let feedTTL: TimeInterval = 300       // 5 minutes
    static let profileTTL: TimeInterval = 3600   // 1 hour
    static let commentsTTL: TimeInterval = 120   // 2 minutes

    // MARK: - Properties

    private let cacheDirectory: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Initialization

    init() {
        let baseDirectory = StorageManager.getPersistentStorageDirectory()
        self.cacheDirectory = baseDirectory.appendingPathComponent("SocialCache", isDirectory: true)

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Generic Cache Operations

    func cache<T: Codable>(_ value: T, key: String, ttl: TimeInterval) {
        let entry = CacheEntry(data: value, cachedAt: Date(), ttl: ttl)
        let url = fileURL(for: key)

        do {
            let data = try encoder.encode(entry)
            try data.write(to: url, options: .atomic)
        } catch {
            print("SocialCache: Failed to cache \(key): \(error)")
        }
    }

    func load<T: Codable>(key: String) -> T? {
        let url = fileURL(for: key)

        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let entry = try? decoder.decode(CacheEntry<T>.self, from: data) else {
            return nil
        }

        guard !entry.isExpired else {
            try? fileManager.removeItem(at: url)
            return nil
        }

        return entry.data
    }

    // MARK: - Typed Convenience Methods

    func cacheFeed(_ highlights: [Highlight], page: Int = 0) {
        cache(highlights, key: "feed_page_\(page)", ttl: Self.feedTTL)
    }

    func loadCachedFeed(page: Int = 0) -> [Highlight]? {
        load(key: "feed_page_\(page)")
    }

    func cacheProfile(_ profile: UserProfile) {
        cache(profile, key: "profile_\(profile.id)", ttl: Self.profileTTL)
    }

    func loadCachedProfile(userId: String) -> UserProfile? {
        load(key: "profile_\(userId)")
    }

    func cacheComments(_ comments: [Comment], highlightId: String, page: Int = 0) {
        cache(comments, key: "comments_\(highlightId)_\(page)", ttl: Self.commentsTTL)
    }

    func loadCachedComments(highlightId: String, page: Int = 0) -> [Comment]? {
        load(key: "comments_\(highlightId)_\(page)")
    }

    // MARK: - Cleanup

    func clearAll() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func clearExpired() {
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }

            // Decode just the metadata to check expiry
            struct MetadataOnly: Codable {
                let cachedAt: Date
                let ttl: TimeInterval
                var isExpired: Bool { Date().timeIntervalSince(cachedAt) > ttl }
            }

            if let meta = try? decoder.decode(MetadataOnly.self, from: data), meta.isExpired {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    // MARK: - Private

    private func fileURL(for key: String) -> URL {
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory.appendingPathComponent("\(safeKey).json")
    }
}
