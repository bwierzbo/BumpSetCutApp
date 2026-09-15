import SwiftUI

// MARK: - Action Feedback

struct RallyActionFeedback {
    let type: ActionType
    let message: String
    /// The rally the feedback refers to. The player auto-advances shortly
    /// after a favorite, so the toast's "Choose Folder" action must remember
    /// which rally it was created for.
    var rallyIndex: Int? = nil

    enum ActionType {
        case save
        case remove
        case undo
        case favorite
        case trim

        var iconName: String {
            switch self {
            case .save: return "heart.fill"
            case .remove: return "trash.fill"
            case .undo: return "arrow.uturn.backward"
            case .favorite: return "star.fill"
            case .trim: return "scissors"
            }
        }

        var color: Color {
            switch self {
            case .save: return .bscSuccess
            case .remove: return .bscError
            case .undo: return .bscWarning
            case .favorite: return .bscPrimary
            case .trim: return .bscWarning
            }
        }
    }
}

// MARK: - Rally Action Result

struct RallyActionResult {
    let action: RallySwipeAction
    let rallyIndex: Int
    let direction: RallySwipeDirection
    let previousTrim: RallyTrimAdjustment?
    let isTrimAction: Bool
    // Pre-action membership snapshot so undo restores exactly the prior state
    // (each action mutates up to three sets, not just its primary one)
    let wasSaved: Bool
    let wasRemoved: Bool
    let wasFavorited: Bool
    let previousCollection: String?

    init(action: RallySwipeAction, rallyIndex: Int, direction: RallySwipeDirection,
         wasSaved: Bool = false, wasRemoved: Bool = false, wasFavorited: Bool = false,
         previousCollection: String? = nil) {
        self.action = action
        self.rallyIndex = rallyIndex
        self.direction = direction
        self.previousTrim = nil
        self.isTrimAction = false
        self.wasSaved = wasSaved
        self.wasRemoved = wasRemoved
        self.wasFavorited = wasFavorited
        self.previousCollection = previousCollection
    }

    init(trimRallyIndex: Int, previousTrim: RallyTrimAdjustment?) {
        self.action = .save
        self.rallyIndex = trimRallyIndex
        self.direction = .right
        self.previousTrim = previousTrim
        self.isTrimAction = true
        self.wasSaved = false
        self.wasRemoved = false
        self.wasFavorited = false
        self.previousCollection = nil
    }
}
