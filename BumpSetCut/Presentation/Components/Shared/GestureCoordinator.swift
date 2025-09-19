//
//  GestureCoordinator.swift
//  BumpSetCut
//
//  Created for Issue #61 Stream B - Gesture Integration & Polish
//  Unified gesture handling with elastic bounce effects and performance optimization
//

import SwiftUI
import UIKit

/// Unified gesture coordination system with elastic bounce effects and performance optimization
@Observable
final class GestureCoordinator {
    // MARK: - Configuration

    struct GestureConfiguration {
        // Performance optimization
        static let debounceInterval: TimeInterval = 0.016 // ~60fps debouncing
        static let maxGestureFrequency: TimeInterval = 0.033 // ~30fps max processing

        // Elastic bounce parameters
        static let elasticResistance: CGFloat = 0.3 // Resistance factor for overscroll
        static let bounceBackAnimationDuration: TimeInterval = 0.4
        static let bounceBackSpringResponse: Double = 0.6
        static let bounceBackSpringDamping: Double = 0.8

        // Haptic feedback
        static let boundaryHapticIntensity: Float = 0.7
        static let actionHapticIntensity: Float = 1.0
    }

    // MARK: - State Management

    /// Current gesture state
    enum GestureState {
        case idle
        case dragging
        case overscrolling(direction: OverscrollDirection)
        case bouncing
        case completing(action: GestureAction)
    }

    /// Overscroll direction for elastic bounds
    enum OverscrollDirection {
        case start // Before first item
        case end   // After last item
    }

    /// Gesture actions that can be triggered
    enum GestureAction {
        case navigationPrevious
        case navigationNext
        case actionLike
        case actionDelete
        case peek(direction: PeekDirection)
        case cancel
    }

    enum PeekDirection {
        case previous
        case next
        case like
        case delete
    }

    // MARK: - Properties

    private let orientationManager: OrientationManager
    private var stackBounds: StackBounds

    /// Current gesture state
    private(set) var gestureState: GestureState = .idle

    /// Current drag translation with elastic bounds applied
    private(set) var currentTranslation: CGSize = .zero

    /// Raw translation before elastic calculations
    private(set) var rawTranslation: CGSize = .zero

    /// Resistance factor applied to current gesture
    private(set) var resistanceFactor: CGFloat = 1.0

    /// Current peek state for visual feedback
    private(set) var peekState: PeekDirection?

    /// Performance tracking
    private var lastGestureProcessTime: Date = .distantPast
    private var gestureStartTime: Date?

    /// Haptic feedback generators
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    /// Stack bounds for elastic behavior
    struct StackBounds {
        let currentIndex: Int
        let totalCount: Int
        let canGoPrevious: Bool
        let canGoNext: Bool
    }

    // MARK: - Callbacks

    var onGestureAction: ((GestureAction) -> Void)?
    var onPeekStateChanged: ((PeekDirection?) -> Void)?
    var onElasticBounce: ((OverscrollDirection) -> Void)?

    // MARK: - Initialization

    init(orientationManager: OrientationManager, stackBounds: StackBounds) {
        self.orientationManager = orientationManager
        self.stackBounds = stackBounds

        // Prepare haptic feedback generators
        impactFeedback.prepare()
        selectionFeedback.prepare()
    }

    // MARK: - Public Interface

    /// Update stack bounds (call when navigation state changes)
    func updateStackBounds(_ bounds: StackBounds) {
        let oldBounds = stackBounds
        self.stackBounds = bounds

        // Reset state if bounds changed significantly
        if oldBounds.currentIndex != bounds.currentIndex {
            resetGestureState()
        }
    }

    /// Create the drag gesture for SwiftUI views
    func createDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                self.handleGestureChanged(value)
            }
            .onEnded { value in
                self.handleGestureEnded(value)
            }
    }

    /// Reset gesture state to idle
    func resetGestureState() {
        gestureState = .idle
        currentTranslation = .zero
        rawTranslation = .zero
        resistanceFactor = 1.0
        peekState = nil
        gestureStartTime = nil

        onPeekStateChanged?(nil)
    }

    // MARK: - Gesture Processing

    private func handleGestureChanged(_ value: DragGesture.Value) {
        let now = Date()

        // Debouncing: Skip processing if too frequent
        guard now.timeIntervalSince(lastGestureProcessTime) >= GestureConfiguration.debounceInterval else {
            return
        }
        lastGestureProcessTime = now

        // Track gesture start time
        if gestureStartTime == nil {
            gestureStartTime = now
            gestureState = .dragging
        }

        rawTranslation = value.translation

        // Get device-optimized thresholds
        let thresholds = orientationManager.getGestureThresholds()

        // Process gesture based on orientation
        if orientationManager.isPortrait {
            processVerticalGesture(translation: rawTranslation, thresholds: thresholds)
        } else {
            processHorizontalGesture(translation: rawTranslation, thresholds: thresholds)
        }
    }

    private func handleGestureEnded(_ value: DragGesture.Value) {
        defer { resetGestureState() }

        guard let startTime = gestureStartTime else { return }

        let duration = Date().timeIntervalSince(startTime)
        let velocity = calculateVelocity(translation: value.translation, duration: duration)
        let thresholds = orientationManager.getGestureThresholds()

        // Determine final action based on translation and velocity
        let action = determineGestureAction(
            translation: rawTranslation,
            velocity: velocity,
            thresholds: thresholds
        )

        if action != .cancel {
            gestureState = .completing(action: action)
            triggerHapticFeedback(for: action)
            onGestureAction?(action)
        }
    }

    // MARK: - Gesture Processing Logic

    private func processVerticalGesture(translation: CGSize, thresholds: OrientationManager.GestureThresholds) {
        let verticalTranslation = translation.height
        let absTranslation = abs(verticalTranslation)

        // Determine gesture direction and apply elastic bounds
        if verticalTranslation < 0 {
            // Swipe up - next rally
            processNavigationGesture(
                translation: absTranslation,
                direction: .next,
                thresholds: thresholds
            )
        } else {
            // Swipe down - previous rally
            processNavigationGesture(
                translation: absTranslation,
                direction: .previous,
                thresholds: thresholds
            )
        }

        // Update current translation with elastic effect
        currentTranslation = CGSize(width: 0, height: verticalTranslation * resistanceFactor)
    }

    private func processHorizontalGesture(translation: CGSize, thresholds: OrientationManager.GestureThresholds) {
        let horizontalTranslation = translation.width
        let absTranslation = abs(horizontalTranslation)

        // Determine gesture type based on translation magnitude
        if absTranslation > thresholds.action {
            // Action gestures (like/delete)
            if horizontalTranslation > 0 {
                processActionGesture(translation: absTranslation, action: .like, thresholds: thresholds)
            } else {
                processActionGesture(translation: absTranslation, action: .delete, thresholds: thresholds)
            }
        } else if absTranslation > thresholds.peek {
            // Peek gestures for visual feedback
            let peekDirection: PeekDirection = horizontalTranslation > 0 ? .like : .delete
            processPeekGesture(direction: peekDirection)
        }

        // Update current translation with elastic effect
        currentTranslation = CGSize(width: horizontalTranslation * resistanceFactor, height: 0)
    }

    private func processNavigationGesture(
        translation: CGFloat,
        direction: NavigationDirection,
        thresholds: OrientationManager.GestureThresholds
    ) {
        enum NavigationDirection {
            case previous
            case next
        }

        let canNavigate = (direction == .previous) ? stackBounds.canGoPrevious : stackBounds.canGoNext

        if !canNavigate && translation > thresholds.navigation {
            // Hit boundary - apply elastic resistance
            let overscrollDirection: OverscrollDirection = (direction == .previous) ? .start : .end
            applyElasticResistance(translation: translation, thresholds: thresholds)

            if gestureState != .overscrolling(direction: overscrollDirection) {
                gestureState = .overscrolling(direction: overscrollDirection)
                triggerBoundaryHapticFeedback()
                onElasticBounce?(overscrollDirection)
            }
        } else if translation > thresholds.peek {
            // Normal navigation peek
            let peekDirection: PeekDirection = (direction == .previous) ? .previous : .next
            processPeekGesture(direction: peekDirection)
            resistanceFactor = 1.0
        } else {
            // Below peek threshold
            resistanceFactor = 1.0
            updatePeekState(nil)
        }
    }

    private func processActionGesture(
        translation: CGFloat,
        action: ActionType,
        thresholds: OrientationManager.GestureThresholds
    ) {
        enum ActionType {
            case like
            case delete
        }

        // Actions are always available, no boundary checks needed
        resistanceFactor = 1.0

        let peekDirection: PeekDirection = (action == .like) ? .like : .delete
        processPeekGesture(direction: peekDirection)
    }

    private func processPeekGesture(direction: PeekDirection) {
        if peekState != direction {
            updatePeekState(direction)
            triggerSelectionHapticFeedback()
        }
    }

    // MARK: - Elastic Bounce Effects

    private func applyElasticResistance(translation: CGFloat, thresholds: OrientationManager.GestureThresholds) {
        let overscroll = translation - thresholds.navigation
        let maxOverscroll = thresholds.resistance

        // Apply elastic resistance curve
        let normalizedOverscroll = min(overscroll / maxOverscroll, 1.0)
        let elasticFactor = 1.0 - (normalizedOverscroll * GestureConfiguration.elasticResistance)

        resistanceFactor = max(0.1, elasticFactor) // Minimum resistance to maintain responsiveness
    }

    // MARK: - Action Determination

    private func determineGestureAction(
        translation: CGSize,
        velocity: CGSize,
        thresholds: OrientationManager.GestureThresholds
    ) -> GestureAction {
        let isHighVelocity = (abs(velocity.width) > thresholds.velocity) || (abs(velocity.height) > thresholds.velocity)

        if orientationManager.isPortrait {
            // Vertical gestures for navigation
            let verticalTranslation = translation.height
            let absTranslation = abs(verticalTranslation)

            if absTranslation > thresholds.navigation || isHighVelocity {
                if verticalTranslation < 0 {
                    return stackBounds.canGoNext ? .navigationNext : .cancel
                } else {
                    return stackBounds.canGoPrevious ? .navigationPrevious : .cancel
                }
            }
        } else {
            // Horizontal gestures for actions
            let horizontalTranslation = translation.width
            let absTranslation = abs(horizontalTranslation)

            if absTranslation > thresholds.action || isHighVelocity {
                return horizontalTranslation > 0 ? .actionLike : .actionDelete
            }
        }

        return .cancel
    }

    // MARK: - Utility Functions

    private func calculateVelocity(translation: CGSize, duration: TimeInterval) -> CGSize {
        guard duration > 0 else { return .zero }

        return CGSize(
            width: translation.width / duration,
            height: translation.height / duration
        )
    }

    private func updatePeekState(_ newState: PeekDirection?) {
        guard peekState != newState else { return }

        peekState = newState
        onPeekStateChanged?(newState)
    }

    // MARK: - Haptic Feedback

    private func triggerHapticFeedback(for action: GestureAction) {
        switch action {
        case .navigationPrevious, .navigationNext:
            impactFeedback.impactOccurred(intensity: GestureConfiguration.actionHapticIntensity)
        case .actionLike, .actionDelete:
            impactFeedback.impactOccurred(intensity: GestureConfiguration.actionHapticIntensity)
        case .peek:
            selectionFeedback.selectionChanged()
        case .cancel:
            break // No haptic for cancel
        }
    }

    private func triggerBoundaryHapticFeedback() {
        impactFeedback.impactOccurred(intensity: GestureConfiguration.boundaryHapticIntensity)
    }

    private func triggerSelectionHapticFeedback() {
        selectionFeedback.selectionChanged()
    }
}

// MARK: - SwiftUI Integration

extension GestureCoordinator {
    /// Create a view modifier that applies the gesture coordinator
    func gestureModifier() -> some ViewModifier {
        GestureCoordinatorModifier(coordinator: self)
    }
}

struct GestureCoordinatorModifier: ViewModifier {
    let coordinator: GestureCoordinator

    func body(content: Content) -> some View {
        content
            .gesture(coordinator.createDragGesture())
            .animation(
                .spring(
                    response: GestureCoordinator.GestureConfiguration.bounceBackSpringResponse,
                    dampingFraction: GestureCoordinator.GestureConfiguration.bounceBackSpringDamping
                ),
                value: coordinator.currentTranslation
            )
    }
}

// MARK: - View Extensions

extension View {
    /// Apply gesture coordination to a view
    func gestureCoordinated(_ coordinator: GestureCoordinator) -> some View {
        self.modifier(coordinator.gestureModifier())
    }
}