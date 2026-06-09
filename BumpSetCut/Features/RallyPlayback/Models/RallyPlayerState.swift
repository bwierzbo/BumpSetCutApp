import Foundation

// MARK: - Trim Adjustment

struct RallyTrimAdjustment: Codable {
    var before: Double    // seconds to add before rally (negative = trim into rally)
    var after: Double     // seconds to add after rally (negative = trim into rally)
    var rotation: Double  // degrees applied at playback (0 = no rotation)
    var zoom: Double      // playback zoom scale (1.0 = no zoom)
    var panX: Double      // focal pan X, normalized as a fraction of card width (0 = centered)
    var panY: Double      // focal pan Y, normalized as a fraction of card height (0 = centered)

    init(before: Double, after: Double, rotation: Double = 0, zoom: Double = 1.0, panX: Double = 0, panY: Double = 0) {
        self.before = before
        self.after = after
        self.rotation = rotation
        self.zoom = zoom
        self.panX = panX
        self.panY = panY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        before = try container.decode(Double.self, forKey: .before)
        after = try container.decode(Double.self, forKey: .after)
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1.0
        panX = try container.decodeIfPresent(Double.self, forKey: .panX) ?? 0
        panY = try container.decodeIfPresent(Double.self, forKey: .panY) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case before, after, rotation, zoom, panX, panY
    }
}

// MARK: - Review Selections

struct RallyReviewSelections: Codable {
    var saved: Set<Int>
    var removed: Set<Int>
    var favorited: Set<Int>

    init(saved: Set<Int> = [], removed: Set<Int> = [], favorited: Set<Int> = []) {
        self.saved = saved
        self.removed = removed
        self.favorited = favorited
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        saved = try container.decode(Set<Int>.self, forKey: .saved)
        removed = try container.decode(Set<Int>.self, forKey: .removed)
        favorited = try container.decodeIfPresent(Set<Int>.self, forKey: .favorited) ?? []
    }

    var isEmpty: Bool { saved.isEmpty && removed.isEmpty && favorited.isEmpty }
}

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
    case favorite
}

// MARK: - Swipe Direction

enum RallySwipeDirection {
    case left
    case right
    case up
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
