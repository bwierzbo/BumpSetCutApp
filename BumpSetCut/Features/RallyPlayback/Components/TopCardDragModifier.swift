//
//  TopCardDragModifier.swift
//  BumpSetCut
//

import SwiftUI

// MARK: - Top Card Drag Modifier

/// Applies drag/transition transforms for vertical scroll navigation.
/// During transitions, old and new cards move together (connected edge-to-edge) like a continuous scroll.
///
/// IMPORTANT: Uses a single modifier chain (offset + rotation) for ALL states to preserve
/// SwiftUI structural identity. Using if/else branches causes view tree destruction/recreation,
/// which tears down AVPlayerLayer and causes black flash artifacts.
struct TopCardDragModifier: ViewModifier {
    let isTopCard: Bool        // Current card during normal drag (not during transition)
    let isSlidingOut: Bool     // Previous card sliding off-screen during transition
    let isSlidingIn: Bool      // New current card sliding in from off-screen during transition
    let dragOffset: CGSize
    let swipeOffset: CGFloat       // Horizontal swipe (actions)
    let swipeOffsetY: CGFloat      // Vertical swipe (navigation)
    let swipeRotation: Double
    let slideInOffset: CGFloat     // Card height offset for sliding-in card (+height or -height)
    var actionSwipeOffsetY: CGFloat = 0  // Vertical swipe for favorite action

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: computedOffsetX, y: computedOffsetY)
            .rotationEffect(.degrees(computedRotation))
    }

    private var computedOffsetX: CGFloat {
        if isTopCard {
            return swipeOffset + dragOffset.width
        }
        return 0
    }

    private var computedOffsetY: CGFloat {
        if isTopCard {
            return dragOffset.height + actionSwipeOffsetY
        } else if isSlidingOut {
            return swipeOffsetY
        } else if isSlidingIn {
            return swipeOffsetY + slideInOffset
        }
        return 0
    }

    private var computedRotation: Double {
        if isTopCard {
            return swipeRotation + dragRotation
        }
        return 0
    }

    private var dragRotation: Double {
        // Reduce Motion: the card follows the finger without tilting.
        guard !reduceMotion else { return 0 }
        let rotation = Double(dragOffset.width) / 30.0
        return max(-10, min(10, rotation))
    }
}
