import SwiftUI

// MARK: - Action Feedback

struct RallyActionFeedback {
    let type: ActionType
    let message: String

    enum ActionType {
        case save
        case remove
        case undo

        var iconName: String {
            switch self {
            case .save: return "heart.fill"
            case .remove: return "trash.fill"
            case .undo: return "arrow.uturn.backward"
            }
        }

        var color: Color {
            switch self {
            case .save: return .green
            case .remove: return .red
            case .undo: return .orange
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
