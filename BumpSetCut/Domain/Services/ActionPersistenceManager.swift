//
//  ActionPersistenceManager.swift
//  BumpSetCut
//
//  Created for Rally Swiping Fixes Epic - Issue #54
//  Action persistence and undo functionality with native iOS feel
//

import Foundation
import SwiftUI

final class ActionPersistenceManager: ObservableObject {
    // MARK: - Action Types
    enum RallyActionType: String, CaseIterable, Codable {
        case like = "like"
        case delete = "delete"
        case bookmark = "bookmark"
        case share = "share"

        var displayName: String {
            switch self {
            case .like: return "Like"
            case .delete: return "Delete"
            case .bookmark: return "Bookmark"
            case .share: return "Share"
            }
        }

        var systemImage: String {
            switch self {
            case .like: return "heart.fill"
            case .delete: return "trash.fill"
            case .bookmark: return "bookmark.fill"
            case .share: return "square.and.arrow.up"
            }
        }
    }

    // MARK: - Action Data Models
    struct RallyAction: Codable, Identifiable {
        let id: UUID
        let type: RallyActionType
        let rallyIndex: Int
        let timestamp: Date
        let videoId: UUID
        let isUndoable: Bool

        init(type: RallyActionType, rallyIndex: Int, videoId: UUID) {
            self.id = UUID()
            self.type = type
            self.rallyIndex = rallyIndex
            self.timestamp = Date()
            self.videoId = videoId
            self.isUndoable = true
        }
    }

    struct VideoActionState: Codable {
        var likedRallies: Set<Int> = []
        var deletedRallies: Set<Int> = []
        var bookmarkedRallies: Set<Int> = []
        var sharedRallies: Set<Int> = []
        var undoStack: [RallyAction] = []
        var lastModified: Date = Date()

        mutating func applyAction(_ action: RallyAction) {
            switch action.type {
            case .like:
                likedRallies.insert(action.rallyIndex)
            case .delete:
                deletedRallies.insert(action.rallyIndex)
            case .bookmark:
                bookmarkedRallies.insert(action.rallyIndex)
            case .share:
                sharedRallies.insert(action.rallyIndex)
            }

            // Add to undo stack
            undoStack.append(action)

            // Limit undo stack size
            if undoStack.count > 10 {
                undoStack.removeFirst()
            }

            lastModified = Date()
        }

        mutating func undoAction(_ action: RallyAction) -> Bool {
            guard let index = undoStack.firstIndex(where: { $0.id == action.id }) else {
                return false
            }

            // Remove action effect
            switch action.type {
            case .like:
                likedRallies.remove(action.rallyIndex)
            case .delete:
                deletedRallies.remove(action.rallyIndex)
            case .bookmark:
                bookmarkedRallies.remove(action.rallyIndex)
            case .share:
                sharedRallies.remove(action.rallyIndex)
            }

            // Remove from undo stack
            undoStack.remove(at: index)
            lastModified = Date()

            return true
        }
    }

    // MARK: - State
    private var currentSession: UUID?
    private var actionStates: [UUID: VideoActionState] = [:]
    private var persistenceTimer: Timer?

    // Undo configuration
    private let undoTimeWindow: TimeInterval = 300 // 5 minutes
    private let maxUndoStackSize: Int = 10

    // File persistence
    private let persistenceDebounceInterval: TimeInterval = 1.0
    private var needsSave = false

    // MARK: - Current Session State
    var currentVideoActionState: VideoActionState? {
        guard let sessionId = currentSession else { return nil }
        return actionStates[sessionId]
    }

    // MARK: - Initialization
    init() {
        setupPersistenceTimer()
    }

    deinit {
        persistenceTimer?.invalidate()
        // Note: Cannot call async saveAllStates() from deinit
        // Data will be saved on next app launch if needed
    }

    // MARK: - Session Management
    @MainActor
    func startSession(for videoId: UUID) async {
        currentSession = videoId

        // Load existing state or create new
        if actionStates[videoId] == nil {
            do {
                actionStates[videoId] = try await loadVideoActionState(videoId: videoId)
            } catch {
                print("Failed to load action state for \(videoId): \(error)")
                actionStates[videoId] = VideoActionState()
            }
        }
    }

    @MainActor
    func endSession() async {
        guard let sessionId = currentSession else { return }

        // Save current state
        do {
            try await saveVideoActionState(videoId: sessionId)
        } catch {
            print("Failed to save action state for \(sessionId): \(error)")
        }

        currentSession = nil
    }

    // MARK: - Action Management
    @MainActor
    func performAction(_ type: RallyActionType, on rallyIndex: Int) async -> RallyAction? {
        guard let sessionId = currentSession else { return nil }

        let action = RallyAction(type: type, rallyIndex: rallyIndex, videoId: sessionId)

        // Apply action to state
        if actionStates[sessionId] == nil {
            actionStates[sessionId] = VideoActionState()
        }
        actionStates[sessionId]?.applyAction(action)

        // Schedule save
        scheduleSave()

        return action
    }

    @MainActor
    func undoAction(_ action: RallyAction) async -> Bool {
        guard let sessionId = currentSession,
              let _ = actionStates[sessionId] else {
            return false
        }

        // Check if action is still undoable (within time window)
        let timeElapsed = Date().timeIntervalSince(action.timestamp)
        guard timeElapsed <= undoTimeWindow else {
            return false
        }

        let success = actionStates[sessionId]?.undoAction(action) ?? false

        if success {
            scheduleSave()
        }

        return success
    }

    func getUndoableActions() -> [RallyAction] {
        guard let sessionId = currentSession,
              let state = actionStates[sessionId] else {
            return []
        }

        let cutoffTime = Date().addingTimeInterval(-undoTimeWindow)
        return state.undoStack.filter { $0.timestamp >= cutoffTime }
    }

    // MARK: - Action Queries
    func isRallyLiked(_ rallyIndex: Int) -> Bool {
        return currentVideoActionState?.likedRallies.contains(rallyIndex) ?? false
    }

    func isRallyDeleted(_ rallyIndex: Int) -> Bool {
        return currentVideoActionState?.deletedRallies.contains(rallyIndex) ?? false
    }

    func isRallyBookmarked(_ rallyIndex: Int) -> Bool {
        return currentVideoActionState?.bookmarkedRallies.contains(rallyIndex) ?? false
    }

    func isRallyShared(_ rallyIndex: Int) -> Bool {
        return currentVideoActionState?.sharedRallies.contains(rallyIndex) ?? false
    }

    // MARK: - Persistence
    private func setupPersistenceTimer() {
        persistenceTimer = Timer.scheduledTimer(withTimeInterval: persistenceDebounceInterval, repeats: true) { _ in
            Task {
                await self.saveIfNeeded()
            }
        }
    }

    private func scheduleSave() {
        needsSave = true
    }

    @MainActor
    private func saveIfNeeded() async {
        guard needsSave else { return }

        await saveAllStates()
        needsSave = false
    }

    @MainActor
    private func saveAllStates() async {
        for (videoId, _) in actionStates {
            do {
                try await saveVideoActionState(videoId: videoId)
            } catch {
                print("Failed to save action state for \(videoId): \(error)")
            }
        }
    }

    private func getActionStateURL(for videoId: UUID) -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let actionsDirectory = documentsPath.appendingPathComponent("RallyActions")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: actionsDirectory, withIntermediateDirectories: true)

        return actionsDirectory.appendingPathComponent("\(videoId.uuidString).json")
    }

    private func loadVideoActionState(videoId: UUID) async throws -> VideoActionState {
        let url = getActionStateURL(for: videoId)

        guard FileManager.default.fileExists(atPath: url.path) else {
            return VideoActionState()
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VideoActionState.self, from: data)
    }

    private func saveVideoActionState(videoId: UUID) async throws {
        guard let state = actionStates[videoId] else { return }

        let url = getActionStateURL(for: videoId)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url)
    }

    // MARK: - Cleanup
    func cleanupOldActions() async {
        let cutoffDate = Date().addingTimeInterval(-30 * 24 * 60 * 60) // 30 days ago

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let actionsDirectory = documentsPath.appendingPathComponent("RallyActions")

        do {
            let files = try FileManager.default.contentsOfDirectory(at: actionsDirectory, includingPropertiesForKeys: [.creationDateKey])

            for file in files {
                if let creationDate = try file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   creationDate < cutoffDate {
                    try FileManager.default.removeItem(at: file)

                    // Remove from memory cache if present
                    if let fileName = file.lastPathComponent.components(separatedBy: ".").first,
                       let uuid = UUID(uuidString: fileName) {
                        actionStates.removeValue(forKey: uuid)
                    }
                }
            }
        } catch {
            print("Failed to cleanup old action files: \(error)")
        }
    }
}

// MARK: - Action Feedback UI Components
extension ActionPersistenceManager {
    struct EnhancedActionFeedback: Identifiable {
        let id = UUID()
        let action: RallyAction
        let remainingTime: TimeInterval
        let progress: Double

        init(action: RallyAction, undoTimeWindow: TimeInterval = 300) {
            self.action = action
            let elapsed = Date().timeIntervalSince(action.timestamp)
            self.remainingTime = max(0, undoTimeWindow - elapsed)
            self.progress = min(1.0, elapsed / undoTimeWindow)
        }
    }
}