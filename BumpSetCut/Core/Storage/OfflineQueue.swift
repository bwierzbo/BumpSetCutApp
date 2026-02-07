import Foundation
import Observation

// MARK: - Social Interaction

struct SocialInteraction: Codable, Identifiable {
    let id: UUID
    let type: InteractionType
    let targetId: String
    let payload: String?
    let timestamp: Date

    enum InteractionType: String, Codable {
        case like
        case unlike
        case comment
        case follow
        case unfollow
    }

    init(type: InteractionType, targetId: String, payload: String? = nil) {
        self.id = UUID()
        self.type = type
        self.targetId = targetId
        self.payload = payload
        self.timestamp = Date()
    }
}

// MARK: - Offline Queue

@MainActor
@Observable
final class OfflineQueue {

    private(set) var pendingCount: Int = 0
    private(set) var isDraining: Bool = false

    private var queue: [SocialInteraction] = []
    private let fileManager = FileManager.default
    private let queueURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let baseDirectory = StorageManager.getPersistentStorageDirectory()
        self.queueURL = baseDirectory.appendingPathComponent("offline_queue.json")

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        loadFromDisk()
    }

    // MARK: - Enqueue

    func enqueue(_ interaction: SocialInteraction) {
        queue.append(interaction)
        pendingCount = queue.count
        saveToDisk()
    }

    // MARK: - Drain

    func drain(using client: any APIClient) async {
        guard !isDraining, !queue.isEmpty else { return }
        isDraining = true

        var failedItems: [SocialInteraction] = []

        for interaction in queue {
            do {
                let endpoint = mapToEndpoint(interaction)
                let _: EmptyResponse = try await client.request(endpoint)
            } catch {
                // Keep failed items for retry
                failedItems.append(interaction)
            }
        }

        queue = failedItems
        pendingCount = queue.count
        isDraining = false
        saveToDisk()
    }

    // MARK: - Clear

    func clear() {
        queue.removeAll()
        pendingCount = 0
        saveToDisk()
    }

    // MARK: - Private

    private func mapToEndpoint(_ interaction: SocialInteraction) -> APIEndpoint {
        switch interaction.type {
        case .like:
            return .likeHighlight(id: interaction.targetId)
        case .unlike:
            return .unlikeHighlight(id: interaction.targetId)
        case .comment:
            return .addComment(highlightId: interaction.targetId, text: interaction.payload ?? "")
        case .follow:
            return .follow(userId: interaction.targetId)
        case .unfollow:
            return .unfollow(userId: interaction.targetId)
        }
    }

    private func saveToDisk() {
        do {
            let data = try encoder.encode(queue)
            try data.write(to: queueURL, options: .atomic)
        } catch {
            print("OfflineQueue: Failed to save: \(error)")
        }
    }

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: queueURL.path),
              let data = try? Data(contentsOf: queueURL),
              let loaded = try? decoder.decode([SocialInteraction].self, from: data) else {
            return
        }
        queue = loaded
        pendingCount = queue.count
    }
}

// MARK: - Empty Response

struct EmptyResponse: Codable {}
