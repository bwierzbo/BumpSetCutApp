import Foundation

// MARK: - Loading State

enum RallyPlayerLoadingState: Equatable {
    case loading
    case loaded
    case error(String)
    case empty
}

// MARK: - Swipe Actions

enum RallySwipeAction {
    case save
    case remove
}

// MARK: - Swipe Direction

enum RallySwipeDirection {
    case left
    case right
}

// MARK: - Peek Direction

enum RallyPeekDirection: CustomStringConvertible {
    case next     // Vertical down (next rally) or horizontal left
    case previous // Vertical up (previous rally) or horizontal right

    var description: String {
        switch self {
        case .next: return "next"
        case .previous: return "previous"
        }
    }
}

// MARK: - Export Type

enum RallyExportType: Identifiable {
    case individual
    case stitched

    var id: String {
        switch self {
        case .individual: return "individual"
        case .stitched: return "stitched"
        }
    }

    var title: String {
        switch self {
        case .individual: return "Individual Clips"
        case .stitched: return "Stitched Video"
        }
    }

    var description: String {
        switch self {
        case .individual: return "Export each rally as a separate video file"
        case .stitched: return "Combine all selected rallies into one video"
        }
    }

    var iconName: String {
        switch self {
        case .individual: return "square.stack.3d.up"
        case .stitched: return "film.stack"
        }
    }
}
