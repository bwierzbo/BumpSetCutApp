import Foundation

// MARK: - Card Stack Item

/// Generic card item for swipeable card stack
/// Supports any content type with stable identifier-based tracking
struct CardStackItem: Identifiable {
    let id: UUID
    var content: String  // Placeholder for Phase 2 video URLs
    var action: CardStackAction?

    init(id: UUID = UUID(), content: String = "", action: CardStackAction? = nil) {
        self.id = id
        self.content = content
        self.action = action
    }
}
