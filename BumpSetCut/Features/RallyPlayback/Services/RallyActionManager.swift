import Foundation
import Observation

// MARK: - Rally Action Manager

/// Manages rally save/remove actions, undo history, and action feedback state.
/// Pure state manager with no AVFoundation or SwiftUI animation dependencies.
@MainActor
@Observable
final class RallyActionManager {
    // MARK: - State

    private(set) var savedRallies: Set<Int> = []
    private(set) var removedRallies: Set<Int> = []
    private(set) var actionHistory: [RallyActionResult] = []

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

        actionFeedback = RallyActionFeedback(type: .undo, message: "Action Undone")
        showActionFeedback = true
        return action
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
