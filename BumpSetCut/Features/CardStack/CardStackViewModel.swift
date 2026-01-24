import SwiftUI

// MARK: - Card Stack View Model

@MainActor
@Observable
final class CardStackViewModel {
    // MARK: - State

    var cards: [CardStackItem]
    private(set) var currentIndex: Int = 0
    private(set) var visibleCardIndices: [Int] = []

    // MARK: - Gesture State

    var dragOffset: CGSize = .zero
    var dragRotation: Double = 0

    // MARK: - Stack Configuration

    private let forwardStackSize = 2   // Show 2 cards ahead
    private let backwardStackSize = 1  // Keep 1 card behind for undo

    // MARK: - Computed Properties

    var canGoNext: Bool { currentIndex < cards.count - 1 }
    var canGoPrevious: Bool { currentIndex > 0 }
    var totalCards: Int { cards.count }

    var currentCard: CardStackItem? {
        guard currentIndex < cards.count else { return nil }
        return cards[currentIndex]
    }

    // MARK: - Initialization

    init(cards: [CardStackItem]) {
        self.cards = cards
        updateVisibleStack()
    }

    // MARK: - Stack Management

    /// Updates the visible card indices for rendering
    /// Returns indices for current card + next 2 cards (+ 1 previous if exists)
    func updateVisibleStack() {
        var indices: [Int] = []

        // Add previous card if exists (for undo/reverse animation)
        if currentIndex > 0 {
            indices.append(currentIndex - 1)
        }

        // Add current and next cards
        for offset in 0...forwardStackSize {
            let index = currentIndex + offset
            if index < cards.count {
                indices.append(index)
            }
        }

        visibleCardIndices = indices
    }

    /// Get stack position relative to current card
    /// - Parameter cardIndex: The card's index in the cards array
    /// - Returns: Position relative to current (-1 = previous, 0 = current, 1+ = next)
    func stackPosition(for cardIndex: Int) -> Int {
        return cardIndex - currentIndex
    }

    /// Calculate explicit zIndex to prevent animation glitches
    /// - Parameter position: Stack position from stackPosition(for:)
    /// - Returns: Explicit zIndex value (100 for current, negative for others)
    func zIndexForPosition(_ position: Int) -> Double {
        switch position {
        case -1: return -1              // Previous card (behind)
        case 0: return 100              // Current card (top)
        default: return Double(-position)  // Next cards (stacked below)
        }
    }

    // MARK: - Actions

    /// Perform swipe action on current card and advance to next
    /// - Parameter action: The action to perform (save or remove)
    func performAction(_ action: CardStackAction) {
        guard currentIndex < cards.count else { return }

        // Record action on current card
        cards[currentIndex].action = action

        // Advance to next card
        withAnimation(.bscSwipe) {
            if canGoNext {
                currentIndex += 1
                updateVisibleStack()
            }
        }
    }
}
