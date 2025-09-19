//
//  AnimationCoordinator.swift
//  BumpSetCut
//
//  Created for Issue #61 Stream C - Animation Enhancement & Coordination
//  Coordinates smooth animations between gesture system and UI feedback
//

import SwiftUI
import UIKit

/// Coordinates animations between gesture system and UI elements for smooth user experience
@Observable
final class AnimationCoordinator {
    // MARK: - Configuration

    struct AnimationConfiguration {
        // Core animation timings
        static let standardDuration: TimeInterval = 0.3
        static let quickDuration: TimeInterval = 0.2
        static let slowDuration: TimeInterval = 0.5

        // Spring parameters for different animation types
        static let gestureSpringResponse: Double = 0.4
        static let gestureSpringDamping: Double = 0.7
        static let cancelSpringResponse: Double = 0.5
        static let cancelSpringDamping: Double = 0.8
        static let bounceSpringResponse: Double = 0.3
        static let bounceSpringDamping: Double = 0.6

        // Visual feedback parameters
        static let iconScaleMin: CGFloat = 0.8
        static let iconScaleMax: CGFloat = 1.2
        static let resistanceScaleMin: CGFloat = 0.95
        static let backgroundOpacityMin: CGFloat = 0.0
        static let backgroundOpacityMax: CGFloat = 0.3

        // Animation thresholds
        static let peekThreshold: CGFloat = 30.0
        static let actionThreshold: CGFloat = 80.0
    }

    // MARK: - Animation State

    /// Current animation state for coordination
    enum AnimationState {
        case idle
        case gesture(type: GestureAnimationType)
        case transitioning
        case bouncing
        case cancelling
    }

    /// Different types of gesture animations
    enum GestureAnimationType {
        case navigation(direction: NavigationDirection)
        case action(type: ActionType)
        case peek(direction: PeekDirection)
    }

    enum NavigationDirection {
        case previous
        case next
    }

    enum ActionType {
        case like
        case delete
    }

    enum PeekDirection {
        case previous
        case next
        case like
        case delete
    }

    // MARK: - Properties

    /// Current animation state
    private(set) var animationState: AnimationState = .idle

    /// Current gesture translation for smooth animation
    private(set) var gestureTranslation: CGSize = .zero

    /// Resistance factor for elastic effects
    private(set) var resistanceFactor: CGFloat = 1.0

    /// Icon scales for visual feedback
    private(set) var likeIconScale: CGFloat = 1.0
    private(set) var deleteIconScale: CGFloat = 1.0
    private(set) var navigationIconScale: CGFloat = 1.0

    /// Background opacity for feedback overlays
    private(set) var backgroundOpacity: Double = 0.0

    /// Current peek direction for icon updates
    private(set) var currentPeekDirection: PeekDirection?

    /// Animation tracking
    private var animationStartTime: Date?
    private var lastUpdateTime: Date = .distantPast

    // MARK: - Callbacks

    var onAnimationStateChanged: ((AnimationState) -> Void)?
    var onHapticFeedback: ((HapticType) -> Void)?

    enum HapticType {
        case boundary
        case peek
        case action
        case cancel
    }

    // MARK: - Public Interface

    /// Update animations based on gesture state
    func updateGestureBasedAnimation(
        translation: CGSize,
        gestureType: GestureCoordinator.GestureAction?,
        resistance: CGFloat,
        peekDirection: GestureCoordinator.PeekDirection?
    ) {
        let now = Date()

        // Throttle updates for performance
        guard now.timeIntervalSince(lastUpdateTime) >= 0.016 else { return } // ~60fps
        lastUpdateTime = now

        // Update core gesture properties
        gestureTranslation = translation
        resistanceFactor = resistance

        // Convert peek direction
        let mappedPeekDirection = mapPeekDirection(peekDirection)

        // Update animation state based on gesture
        updateAnimationState(gestureType: gestureType, peekDirection: mappedPeekDirection)

        // Apply visual feedback
        updateIconsBasedOnDrag(translation: translation, peekDirection: mappedPeekDirection)
        updateBackgroundFeedback(translation: translation)

        // Trigger haptic feedback if needed
        checkForHapticTriggers(peekDirection: mappedPeekDirection)
    }

    /// Animate gesture completion
    func animateGestureCompletion(action: GestureCoordinator.GestureAction) {
        animationState = .transitioning
        animationStartTime = Date()

        withAnimation(.spring(
            response: AnimationConfiguration.gestureSpringResponse,
            dampingFraction: AnimationConfiguration.gestureSpringDamping
        )) {
            completeGestureAnimation(for: action)
        }

        // Reset to idle after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + AnimationConfiguration.standardDuration) {
            self.resetToIdle()
        }

        onHapticFeedback?(.action)
    }

    /// Animate gesture cancellation with smooth return to idle
    func animateGestureCancellation() {
        animationState = .cancelling

        withAnimation(.spring(
            response: AnimationConfiguration.cancelSpringResponse,
            dampingFraction: AnimationConfiguration.cancelSpringDamping
        )) {
            resetVisualFeedback()
        }

        // Reset to idle after cancel animation
        DispatchQueue.main.asyncAfter(deadline: .now() + AnimationConfiguration.quickDuration) {
            self.resetToIdle()
        }

        onHapticFeedback?(.cancel)
    }

    /// Animate elastic bounce when hitting boundaries
    func animateElasticBounce(direction: GestureCoordinator.OverscrollDirection) {
        animationState = .bouncing

        withAnimation(.spring(
            response: AnimationConfiguration.bounceSpringResponse,
            dampingFraction: AnimationConfiguration.bounceSpringDamping
        )) {
            // Slightly scale down and then back up for bounce effect
            resistanceFactor = AnimationConfiguration.resistanceScaleMin
        }

        // Return to normal after bounce
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(
                response: AnimationConfiguration.bounceSpringResponse,
                dampingFraction: AnimationConfiguration.bounceSpringDamping
            )) {
                self.resistanceFactor = 1.0
            }
        }

        onHapticFeedback?(.boundary)
    }

    /// Reset all animations to idle state
    func resetToIdle() {
        animationState = .idle
        currentPeekDirection = nil
        animationStartTime = nil
        resetVisualFeedback()
        onAnimationStateChanged?(.idle)
    }

    // MARK: - Private Animation Logic

    private func updateAnimationState(
        gestureType: GestureCoordinator.GestureAction?,
        peekDirection: PeekDirection?
    ) {
        let newState: AnimationState

        if let peek = peekDirection {
            newState = .gesture(type: .peek(direction: peek))
        } else if let gesture = gestureType {
            switch gesture {
            case .navigationPrevious:
                newState = .gesture(type: .navigation(direction: .previous))
            case .navigationNext:
                newState = .gesture(type: .navigation(direction: .next))
            case .actionLike:
                newState = .gesture(type: .action(type: .like))
            case .actionDelete:
                newState = .gesture(type: .action(type: .delete))
            case .peek, .cancel:
                newState = .idle
            }
        } else {
            newState = .idle
        }

        if case .gesture = animationState, case .gesture = newState {
            // Smooth transition between gesture types
            animationState = newState
        } else if animationState != newState {
            animationState = newState
            onAnimationStateChanged?(newState)
        }
    }

    private func updateIconsBasedOnDrag(translation: CGSize, peekDirection: PeekDirection?) {
        let absTranslationX = abs(translation.width)
        let absTranslationY = abs(translation.height)

        // Reset all scales first
        let baseScale: CGFloat = 1.0
        likeIconScale = baseScale
        deleteIconScale = baseScale
        navigationIconScale = baseScale

        // Apply scaling based on current peek direction
        if let peek = peekDirection {
            currentPeekDirection = peek

            let progress = min(max(absTranslationX, absTranslationY) / AnimationConfiguration.actionThreshold, 1.0)
            let scale = baseScale + (AnimationConfiguration.iconScaleMax - baseScale) * progress

            switch peek {
            case .like:
                likeIconScale = scale
            case .delete:
                deleteIconScale = scale
            case .previous, .next:
                navigationIconScale = scale
            }
        } else {
            currentPeekDirection = nil
        }
    }

    private func updateBackgroundFeedback(translation: CGSize) {
        let maxTranslation = max(abs(translation.width), abs(translation.height))
        let progress = min(maxTranslation / AnimationConfiguration.actionThreshold, 1.0)

        backgroundOpacity = AnimationConfiguration.backgroundOpacityMin +
                          (AnimationConfiguration.backgroundOpacityMax - AnimationConfiguration.backgroundOpacityMin) * progress
    }

    private func completeGestureAnimation(for action: GestureCoordinator.GestureAction) {
        // Animate completion based on action type
        switch action {
        case .actionLike:
            likeIconScale = AnimationConfiguration.iconScaleMax
        case .actionDelete:
            deleteIconScale = AnimationConfiguration.iconScaleMax
        case .navigationPrevious, .navigationNext:
            navigationIconScale = AnimationConfiguration.iconScaleMax
        case .peek, .cancel:
            break
        }

        // Reset translation
        gestureTranslation = .zero
    }

    private func resetVisualFeedback() {
        gestureTranslation = .zero
        resistanceFactor = 1.0
        likeIconScale = 1.0
        deleteIconScale = 1.0
        navigationIconScale = 1.0
        backgroundOpacity = AnimationConfiguration.backgroundOpacityMin
        currentPeekDirection = nil
    }

    private func checkForHapticTriggers(peekDirection: PeekDirection?) {
        // Trigger haptic feedback when entering peek state
        if let peek = peekDirection, currentPeekDirection != peek {
            onHapticFeedback?(.peek)
        }
    }

    private func mapPeekDirection(_ gestureDirection: GestureCoordinator.PeekDirection?) -> PeekDirection? {
        guard let gestureDirection = gestureDirection else { return nil }

        switch gestureDirection {
        case .previous:
            return .previous
        case .next:
            return .next
        case .like:
            return .like
        case .delete:
            return .delete
        }
    }
}

// MARK: - SwiftUI Integration

extension AnimationCoordinator {
    /// Create animation values for SwiftUI views
    var animationValues: AnimationValues {
        AnimationValues(
            translation: gestureTranslation,
            resistance: resistanceFactor,
            likeScale: likeIconScale,
            deleteScale: deleteIconScale,
            navigationScale: navigationIconScale,
            backgroundOpacity: backgroundOpacity
        )
    }

    struct AnimationValues {
        let translation: CGSize
        let resistance: CGFloat
        let likeScale: CGFloat
        let deleteScale: CGFloat
        let navigationScale: CGFloat
        let backgroundOpacity: Double
    }
}