import UIKit
import Observation

// MARK: - Rally Navigation Service

/// Manages rally index navigation, visible card stack, and transition state.
/// Pure index/state math with no AVFoundation or SwiftUI animation dependencies.
@MainActor
@Observable
final class RallyNavigationService {
    // MARK: - Navigation State

    private(set) var currentRallyIndex: Int = 0
    private(set) var previousRallyIndex: Int? = nil

    // MARK: - Stack State

    private(set) var visibleCardIndices: [Int] = []
    private let forwardStackSize = 2
    private let backwardStackSize = 1

    // MARK: - Transition State

    private(set) var isTransitioning: Bool = false
    private(set) var transitionDirection: NavigationDirection? = nil

    // MARK: - Navigation Queries

    func canGoNext(totalCount: Int) -> Bool {
        currentRallyIndex < totalCount - 1
    }

    func canGoPrevious() -> Bool {
        currentRallyIndex > 0
    }

    // MARK: - Stack Management

    func updateVisibleStack(totalCount: Int) {
        var indices: [Int] = []

        if currentRallyIndex > 0 {
            indices.append(currentRallyIndex - 1)
        }

        for offset in 0...forwardStackSize {
            let index = currentRallyIndex + offset
            if index < totalCount {
                indices.append(index)
            }
        }
        visibleCardIndices = indices
    }

    func stackPosition(for rallyIndex: Int) -> Int {
        rallyIndex - currentRallyIndex
    }

    // MARK: - Transition Lifecycle

    /// Begins a transition to a new index. Returns the screen-height-based target offset
    /// for the slide-out animation, or nil if the transition cannot proceed.
    func beginTransition(to index: Int, totalCount: Int, direction: NavigationDirection) -> CGFloat? {
        guard index >= 0 && index < totalCount else { return nil }
        guard !isTransitioning else { return nil }

        previousRallyIndex = currentRallyIndex
        isTransitioning = true
        transitionDirection = direction

        let screenHeight = UIScreen.main.bounds.height
        return direction == .down ? -screenHeight : screenHeight
    }

    /// Updates the current index after beginning a transition.
    func advanceIndex(to index: Int, totalCount: Int) {
        currentRallyIndex = index
        updateVisibleStack(totalCount: totalCount)
    }

    /// Completes the transition, clearing previous rally and transition flags.
    func completeTransition() {
        previousRallyIndex = nil
        transitionDirection = nil
        isTransitioning = false
    }

    /// Sets the current index directly (for undo or jump navigation).
    func setIndex(_ index: Int, totalCount: Int) {
        currentRallyIndex = index
        updateVisibleStack(totalCount: totalCount)
    }

    // MARK: - Player Window

    private let windowRadius = 2

    func playerWindowIndices(totalCount: Int) -> [Int] {
        let lo = max(0, currentRallyIndex - windowRadius)
        let hi = min(totalCount - 1, currentRallyIndex + windowRadius)
        guard lo <= hi else { return [] }
        return Array(lo...hi)
    }

    func playerWindowURLs(urls: [URL]) -> Set<URL> {
        var result = Set(playerWindowIndices(totalCount: urls.count).map { urls[$0] })
        if let prev = previousRallyIndex, prev < urls.count {
            result.insert(urls[prev])
        }
        return result
    }
}

// MARK: - Navigation Direction

enum NavigationDirection {
    case up, down
}
