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
    private(set) var favoritedRallies: Set<Int> = []
    /// Rally index → favorites collection folder NAME (absent = general Favorites)
    private(set) var favoriteCollections: [Int: String] = [:]
    /// Rallies already posted to the community feed.
    private(set) var postedRallies: Set<Int> = []
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

    func isFavorited(at index: Int) -> Bool {
        favoritedRallies.contains(index)
    }

    // MARK: - Persistence Lifecycle

    func loadSavedSelections(videoId: UUID, metadataStore: MetadataStore) {
        self.videoId = videoId
        self.metadataStore = metadataStore
        let selections = metadataStore.loadReviewSelections(for: videoId)
        savedRallies = selections.saved
        removedRallies = selections.removed
        favoritedRallies = selections.favorited
        favoriteCollections = selections.favoriteCollections
        postedRallies = selections.posted
    }

    private func persistSelections() {
        guard let videoId, let metadataStore else { return }
        let selections = RallyReviewSelections(saved: savedRallies, removed: removedRallies,
                                               favorited: favoritedRallies, favoriteCollections: favoriteCollections,
                                               posted: postedRallies)
        try? metadataStore.saveReviewSelections(selections, for: videoId)
    }

    /// Record rallies that just went up as a community post.
    func markPosted(_ indices: [Int]) {
        guard !indices.isEmpty else { return }
        postedRallies.formUnion(indices)
        persistSelections()
    }

    /// Files a favorited rally into a named collection (nil = general Favorites).
    /// Persists immediately — the favorite swipe may be seconds in the past.
    func setFavoriteCollection(_ name: String?, for index: Int) {
        if let name {
            favoriteCollections[index] = name
        } else {
            favoriteCollections.removeValue(forKey: index)
        }
        persistSelections()
    }

    // MARK: - Action Registration

    /// Records a save/remove action and returns the appropriate feedback.
    func registerAction(_ action: RallySwipeAction, rallyIndex: Int, direction: RallySwipeDirection) -> RallyActionFeedback {
        // Snapshot membership before mutating so undo can restore all three sets
        let result = RallyActionResult(
            action: action, rallyIndex: rallyIndex, direction: direction,
            wasSaved: savedRallies.contains(rallyIndex),
            wasRemoved: removedRallies.contains(rallyIndex),
            wasFavorited: favoritedRallies.contains(rallyIndex),
            previousCollection: favoriteCollections[rallyIndex]
        )

        switch action {
        case .save:
            savedRallies.insert(rallyIndex)
            removedRallies.remove(rallyIndex)
        case .remove:
            removedRallies.insert(rallyIndex)
            savedRallies.remove(rallyIndex)
            favoritedRallies.remove(rallyIndex)
            favoriteCollections.removeValue(forKey: rallyIndex)
        case .favorite:
            favoritedRallies.insert(rallyIndex)
            savedRallies.insert(rallyIndex)
            removedRallies.remove(rallyIndex)
        }

        actionHistory.append(result)
        persistSelections()

        let feedback: RallyActionFeedback
        switch action {
        case .save:
            feedback = RallyActionFeedback(type: .save, message: "Rally Saved")
        case .remove:
            feedback = RallyActionFeedback(type: .remove, message: "Rally Removed")
        case .favorite:
            feedback = RallyActionFeedback(type: .favorite, message: "Rally Favorited", rallyIndex: rallyIndex)
        }

        actionFeedback = feedback
        showActionFeedback = true
        return feedback
    }

    /// Records a trim action so it can be undone.
    func registerTrimAction(rallyIndex: Int, previousTrim: RallyTrimAdjustment?) {
        let result = RallyActionResult(trimRallyIndex: rallyIndex, previousTrim: previousTrim)
        actionHistory.append(result)

        actionFeedback = RallyActionFeedback(type: .trim, message: "Trim Applied")
        showActionFeedback = true
    }

    /// Pops the last action from history and reverses it.
    /// Returns the undone action so the VM can handle navigation, or nil if nothing to undo.
    func undoLast() -> RallyActionResult? {
        guard !isPerformingAction, let action = actionHistory.popLast() else { return nil }

        if action.isTrimAction {
            actionFeedback = RallyActionFeedback(type: .undo, message: "Trim Undone")
            showActionFeedback = true
            return action
        }

        // Restore the pre-action snapshot — reversing only the primary set would
        // lose whatever membership the action cleared from the other sets
        let index = action.rallyIndex
        if action.wasSaved { savedRallies.insert(index) } else { savedRallies.remove(index) }
        if action.wasRemoved { removedRallies.insert(index) } else { removedRallies.remove(index) }
        if action.wasFavorited { favoritedRallies.insert(index) } else { favoritedRallies.remove(index) }
        if let previous = action.previousCollection {
            favoriteCollections[index] = previous
        } else {
            favoriteCollections.removeValue(forKey: index)
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
        favoritedRallies = []
        favoriteCollections = [:]
        actionHistory = []
        // postedRallies is history, not a selection — clearing the review
        // doesn't un-post anything.
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
