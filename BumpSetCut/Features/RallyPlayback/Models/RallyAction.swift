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

        var iconName: String {
            switch self {
            case .save: return "heart.fill"
            case .remove: return "trash.fill"
            case .undo: return "arrow.uturn.backward"
            case .favorite: return "star.fill"
            }
        }

        var color: Color {
            switch self {
            case .save: return .bscSuccess
            case .remove: return .bscError
            case .undo: return .bscWarning
            case .favorite: return .bscPrimary
            }
        }
    }
}

// MARK: - Rally Action Result

struct RallyActionResult {
    let action: RallySwipeAction
    let rallyIndex: Int
    let direction: RallySwipeDirection
}
