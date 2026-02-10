import Foundation
import Observation

// MARK: - Rally Action Manager

/// Manages rally save/remove actions, undo history, and action feedback state.
/// Persists selections to disk via MetadataStore so they survive dismiss/reopen.
@MainActor
@Observable
final class RallyActionManager {
    // MARK: - State

    private(set) var savedRallies: Set<Int> = []
    private(set) var removedRallies: Set<Int> = []
    private(set) var actionHistory: [RallyActionResult] = []

    // MARK: - Persistence

    private var videoId: UUID?
    private var metadataStore: MetadataStore?

    // MARK: - Feedback State

    private(set) var actionFeedback: RallyActionFeedback?
    private(set) var showActionFeedback: Bool = false
    private(set) var isPerformingAction: Bool = false

    // MARK: - Computed Properties

    var canUndo: Bool { !actionHistory.isEmpty }
    var savedRalliesArray: [Int] { Array(savedRallies).sorted() }

    func isSaved(at index: Int) -> Bool {
        savedRallies.contains(index)
    }

    func isRemoved(at index: Int) -> Bool {
        removedRallies.contains(index)
    }

    // MARK: - Persistence Lifecycle

    func loadSavedSelections(videoId: UUID, metadataStore: MetadataStore) {
        self.videoId = videoId
        self.metadataStore = metadataStore
        let selections = metadataStore.loadReviewSelections(for: videoId)
        savedRallies = selections.saved
        removedRallies = selections.removed
    }

    private func persistSelections() {
        guard let videoId, let metadataStore else { return }
        let selections = RallyReviewSelections(saved: savedRallies, removed: removedRallies)
        try? metadataStore.saveReviewSelections(selections, for: videoId)
    }

    // MARK: - Action Registration

    /// Records a save/remove action and returns the appropriate feedback.
    func registerAction(_ action: RallySwipeAction, rallyIndex: Int, direction: RallySwipeDirection) -> RallyActionFeedback {
        switch action {
        case .save:
            savedRallies.insert(rallyIndex)
            removedRallies.remove(rallyIndex)
        case .remove:
            removedRallies.insert(rallyIndex)
            savedRallies.remove(rallyIndex)
        }

        actionHistory.append(RallyActionResult(action: action, rallyIndex: rallyIndex, direction: direction))
        persistSelections()

        let feedback: RallyActionFeedback
        switch action {
        case .save:
            feedback = RallyActionFeedback(type: .save, message: "Rally Saved")
        case .remove:
            feedback = RallyActionFeedback(type: .remove, message: "Rally Removed")
        }

        actionFeedback = feedback
        showActionFeedback = true
        return feedback
    }

    /// Pops the last action from history and reverses it.
    /// Returns the undone action so the VM can handle navigation, or nil if nothing to undo.
    func undoLast() -> RallyActionResult? {
        guard !isPerformingAction, let action = actionHistory.popLast() else { return nil }

        switch action.action {
        case .save:
            savedRallies.remove(action.rallyIndex)
        case .remove:
            removedRallies.remove(action.rallyIndex)
        }

        persistSelections()

        actionFeedback = RallyActionFeedback(type: .undo, message: "Action Undone")
        showActionFeedback = true
        return action
    }

    // MARK: - Bulk Actions

    /// Saves all rallies (marks every index as saved, clears removed).
    func saveAll(totalCount: Int) {
        savedRallies = Set(0..<totalCount)
        removedRallies = []
        persistSelections()
    }

    /// Clears all saved and removed selections.
    func deselectAll() {
        savedRallies = []
        removedRallies = []
        actionHistory = []
        persistSelections()
    }

    // MARK: - Feedback Control

    func dismissFeedback() {
        showActionFeedback = false
        actionFeedback = nil
    }

    func setPerformingAction(_ performing: Bool) {
        isPerformingAction = performing
    }
}
