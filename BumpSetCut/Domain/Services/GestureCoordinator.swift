//
//  GestureCoordinator.swift
//  BumpSetCut
//
//  Created for Rally Swiping Fixes Epic - Issue #49
//  Centralized gesture handling with performance optimization
//

import Foundation
import SwiftUI
import Combine

final class GestureCoordinator: ObservableObject {
    // MARK: - Configuration
    struct GestureConfiguration {
        // Navigation thresholds
        let navigationThreshold: CGFloat = 100  // Distance to trigger navigation
        let actionThreshold: CGFloat = 120      // Distance to trigger actions
        let velocityThreshold: CGFloat = 300    // Velocity to override distance checks

        // Resistance settings
        let resistanceThreshold: CGFloat = 100
        let baseResistance: CGFloat = 0.3

        // Performance settings
        let gestureUpdateInterval: TimeInterval = 0.016  // 60fps
        let debounceInterval: TimeInterval = 0.033       // ~30fps for heavy operations
    }

    // MARK: - State
    private let configuration = GestureConfiguration()
    private let navigationState: RallyNavigationState
    private var lastGestureUpdate: Date = Date()
    private var gestureTimer: Timer?

    // Performance tracking
    private var gestureStartTime: Date?
    private var lastPerformanceCheck: Date = Date()

    // Debouncing
    private var isProcessingGesture = false

    // MARK: - Initialization
    init(navigationState: RallyNavigationState) {
        self.navigationState = navigationState
    }

    deinit {
        gestureTimer?.invalidate()
    }

    // MARK: - Gesture Processing
    func processGesture(_ value: DragGesture.Value, isPortrait: Bool) {
        // Performance optimization: limit update frequency
        let now = Date()
        guard now.timeIntervalSince(lastGestureUpdate) >= configuration.gestureUpdateInterval else {
            return
        }
        lastGestureUpdate = now

        // Start timing if this is a new gesture
        if gestureStartTime == nil {
            gestureStartTime = now
        }

        // Update navigation state with debounced processing
        updateNavigationState(value.translation, isPortrait: isPortrait)
    }

    func endGesture(_ value: DragGesture.Value, isPortrait: Bool) {
        defer {
            gestureStartTime = nil
            isProcessingGesture = false
        }

        // Record gesture performance
        if let startTime = gestureStartTime {
            let responseTime = Date().timeIntervalSince(startTime) * 1000 // Convert to ms
            logGesturePerformance(responseTime: responseTime)
        }

        // Determine action based on gesture
        let action = determineGestureAction(
            translation: value.translation,
            velocity: value.velocity,
            isPortrait: isPortrait
        )

        // Execute action
        executeGestureAction(action, translation: value.translation, isPortrait: isPortrait)
    }

    // MARK: - Private Methods
    private func updateNavigationState(_ translation: CGSize, isPortrait: Bool) {
        guard !isProcessingGesture else { return }

        navigationState.updateDragOffset(translation, isPortrait: isPortrait)
    }

    private func determineGestureAction(translation: CGSize, velocity: CGSize, isPortrait: Bool) -> GestureAction {
        let distance: CGFloat
        let velocityMagnitude: CGFloat

        if isPortrait {
            distance = abs(translation.height)
            velocityMagnitude = abs(velocity.height)
        } else {
            distance = abs(translation.width)
            velocityMagnitude = abs(velocity.width)
        }

        // Check for high velocity override
        if velocityMagnitude > configuration.velocityThreshold {
            return determineNavigationDirection(translation: translation, isPortrait: isPortrait)
        }

        // Check distance thresholds
        if distance >= configuration.actionThreshold {
            return .action
        } else if distance >= configuration.navigationThreshold {
            return determineNavigationDirection(translation: translation, isPortrait: isPortrait)
        }

        return .bounce
    }

    private func determineNavigationDirection(translation: CGSize, isPortrait: Bool) -> GestureAction {
        if isPortrait {
            return translation.height < 0 ? .navigateNext : .navigatePrevious
        } else {
            return translation.width < 0 ? .navigateNext : .navigatePrevious
        }
    }

    private func executeGestureAction(_ action: GestureAction, translation: CGSize, isPortrait: Bool) {
        isProcessingGesture = true

        Task { @MainActor in
            switch action {
            case .navigateNext:
                navigationState.navigateToNext()
            case .navigatePrevious:
                navigationState.navigateToPrevious()
            case .action:
                // Trigger action (like/delete) - to be connected with ActionPersistenceManager
                break
            case .bounce:
                navigationState.endDrag(translation: translation, isPortrait: isPortrait)
            }
        }
    }

    private func logGesturePerformance(responseTime: TimeInterval) {
        #if DEBUG
        let threshold: TimeInterval = 50.0 // 50ms target
        let status = responseTime <= threshold ? "✓" : "⚠️"
        print("GestureCoordinator: \(String(format: "%.1f", responseTime))ms - \(status)")

        if responseTime > threshold {
            print("⚠️ Gesture response time exceeded target: \(String(format: "%.1f", responseTime))ms > \(String(format: "%.1f", threshold))ms")
        }
        #endif
    }
}

// MARK: - Supporting Types
enum GestureAction {
    case navigateNext
    case navigatePrevious
    case action
    case bounce
}

// MARK: - SwiftUI Integration
extension GestureCoordinator {
    func createDragGesture(isPortrait: Bool) -> some Gesture {
        DragGesture()
            .onChanged { value in
                self.processGesture(value, isPortrait: isPortrait)
            }
            .onEnded { value in
                self.endGesture(value, isPortrait: isPortrait)
            }
    }
}

// MARK: - Protocol for Rally Players
protocol RallyNavigationCapable {
    var gestureCoordinator: GestureCoordinator { get }
    var isPortrait: Bool { get }
}

extension RallyNavigationCapable {
    var rallyDragGesture: some Gesture {
        gestureCoordinator.createDragGesture(isPortrait: isPortrait)
    }
}