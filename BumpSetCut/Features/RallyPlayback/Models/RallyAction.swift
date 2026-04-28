import SwiftUI

// MARK: - Action Feedback

struct RallyActionFeedback {
    let type: ActionType
    let message: String

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

    init(action: RallySwipeAction, rallyIndex: Int, direction: RallySwipeDirection) {
        self.action = action
        self.rallyIndex = rallyIndex
        self.direction = direction
        self.previousTrim = nil
        self.isTrimAction = false
    }

    init(trimRallyIndex: Int, previousTrim: RallyTrimAdjustment?) {
        self.action = .save
        self.rallyIndex = trimRallyIndex
        self.direction = .right
        self.previousTrim = previousTrim
        self.isTrimAction = true
    }
}
