//
//  AnimationCoordinator.swift
//  BumpSetCut
//
//  Created for Rally Swiping Fixes Epic - Issue #50
//  Unified animation system for 60fps performance
//

import Foundation
import SwiftUI

final class AnimationCoordinator: ObservableObject {
    // MARK: - Animation Configuration
    struct AnimationConfiguration {
        // Standard animation curves
        static let gestureAnimation = Animation.spring(response: 0.3, dampingFraction: 0.75, blendDuration: 0.0)
        static let transitionAnimation = Animation.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0.0)
        static let orientationAnimation = Animation.spring(response: 0.35, dampingFraction: 0.85, blendDuration: 0.0)

        // Stack coordination animations
        static let peelAnimation = Animation.spring(response: 0.35, dampingFraction: 0.6, blendDuration: 0.0)
        static let stackRevealAnimation = Animation.spring(response: 0.4, dampingFraction: 0.75, blendDuration: 0.1)
        static let cardRepositionAnimation = Animation.spring(response: 0.25, dampingFraction: 0.8, blendDuration: 0.0)

        // Performance settings
        static let targetFPS: Double = 60.0
        static let frameTimeTarget: Double = 1.0 / targetFPS // ~16.67ms per frame
    }

    // MARK: - Animation State
    private let navigationState: RallyNavigationState
    private var currentAnimations: Set<AnimationType> = []
    private var animationPhases: Set<AnimationPhase> = []

    // Performance tracking
    private var frameStartTime: Date?
    private var frameCount: Int = 0
    private var lastFPSCheck: Date = Date()

    // Stack animation coordination
    @Published var stackAnimationState: StackAnimationState = .idle
    @Published var peelProgress: Double = 0.0
    @Published var stackRevealProgress: Double = 0.0

    // MARK: - Initialization
    init(navigationState: RallyNavigationState) {
        self.navigationState = navigationState
    }

    // MARK: - Animation Management
    func startAnimation(_ type: AnimationType) {
        currentAnimations.insert(type)
        trackAnimationStart(type)
    }

    func endAnimation(_ type: AnimationType) {
        currentAnimations.remove(type)
        trackAnimationEnd(type)
    }

    // MARK: - Animation Helpers
    func gestureAnimation<Value: VectorArithmetic>(
        _ value: Value,
        target: Value,
        onComplete: (() -> Void)? = nil
    ) -> Animation {
        startAnimation(.gesture)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.endAnimation(.gesture)
            onComplete?()
        }

        return AnimationConfiguration.gestureAnimation
    }

    func transitionAnimation<Value: VectorArithmetic>(
        _ value: Value,
        target: Value,
        onComplete: (() -> Void)? = nil
    ) -> Animation {
        startAnimation(.transition)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.endAnimation(.transition)
            onComplete?()
        }

        return AnimationConfiguration.transitionAnimation
    }

    func orientationAnimation<Value: VectorArithmetic>(
        _ value: Value,
        target: Value,
        onComplete: (() -> Void)? = nil
    ) -> Animation {
        startAnimation(.orientation)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.endAnimation(.orientation)
            onComplete?()
        }

        return AnimationConfiguration.orientationAnimation
    }

    // MARK: - Performance Tracking
    private func trackAnimationStart(_ type: AnimationType) {
        frameStartTime = Date()
        frameCount = 0

        #if DEBUG
        print("AnimationCoordinator: Starting \(type) animation")
        #endif
    }

    private func trackAnimationEnd(_ type: AnimationType) {
        guard let startTime = frameStartTime else { return }

        let duration = Date().timeIntervalSince(startTime)
        let fps = duration > 0 ? Double(frameCount) / duration : 0

        #if DEBUG
        let fpsStatus = fps >= 55.0 ? "✓" : "⚠️"
        print("AnimationCoordinator: \(type) completed - \(String(format: "%.1f", fps)) FPS over \(String(format: "%.1f", duration * 1000))ms \(fpsStatus)")

        if fps < 55.0 {
            print("⚠️ Animation FPS below target: \(String(format: "%.1f", fps)) < 60.0")
        }
        #endif

        frameStartTime = nil
    }

    func recordFrame() {
        frameCount += 1

        // Check FPS periodically
        let now = Date()
        if now.timeIntervalSince(lastFPSCheck) >= 1.0 {
            let currentFPS = Double(frameCount)

            #if DEBUG
            if currentFPS < 55.0 {
                print("⚠️ FPS Warning: \(String(format: "%.1f", currentFPS)) FPS")
            }
            #endif

            lastFPSCheck = now
            frameCount = 0
        }
    }

    // MARK: - Coordinated Animation Interface
    func performCoordinatedPeelAnimation(
        direction: PeelDirection,
        gestureProgress: Double = 0.0,
        completion: @escaping () -> Void
    ) {
        guard stackAnimationState == .idle else {
            print("⚠️ Animation already in progress, skipping coordinated peel")
            return
        }

        startAnimationPhase(.peelStart)
        stackAnimationState = .peeling

        // Phase 1: Begin peel with coordinated stack positioning
        withAnimation(AnimationConfiguration.peelAnimation) {
            self.peelProgress = 0.3
            self.stackRevealProgress = 0.2
        }

        // Phase 2: Full peel with stack reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.startAnimationPhase(.stackRevealStart)
            self.stackAnimationState = .revealing

            withAnimation(AnimationConfiguration.stackRevealAnimation) {
                self.peelProgress = 1.0
                self.stackRevealProgress = 1.0
            }

            // Phase 3: Card repositioning after peel completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.startAnimationPhase(.repositionStart)
                self.stackAnimationState = .repositioning

                withAnimation(AnimationConfiguration.cardRepositionAnimation) {
                    self.peelProgress = 0.0
                    self.stackRevealProgress = 0.0
                }

                // Complete coordination
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.completeCoordinatedAnimation()
                    completion()
                }
            }
        }
    }

    func updateGestureBasedAnimation(
        translation: CGSize,
        velocity: CGSize,
        screenBounds: CGRect
    ) {
        guard stackAnimationState == .idle || stackAnimationState == .peeling else { return }

        // Calculate gesture progress (0.0 to 1.0)
        let horizontalProgress = min(1.0, abs(translation.width) / (screenBounds.width * 0.3))
        let verticalProgress = min(1.0, abs(translation.height) / (screenBounds.height * 0.3))
        let dominantProgress = max(horizontalProgress, verticalProgress)

        // Update animation state based on gesture
        if dominantProgress > 0.1 && stackAnimationState == .idle {
            stackAnimationState = .peeling
            startAnimationPhase(.peelInProgress)
        }

        // Smoothly update progress values
        let smoothedProgress = easeInOutQuad(dominantProgress)
        peelProgress = smoothedProgress * 0.6 // Partial peel during gesture
        stackRevealProgress = smoothedProgress * 0.4 // Subtle stack movement
    }

    func resetGestureAnimation() {
        guard stackAnimationState != .idle else { return }

        stackAnimationState = .repositioning
        startAnimationPhase(.repositionStart)

        withAnimation(AnimationConfiguration.cardRepositionAnimation) {
            peelProgress = 0.0
            stackRevealProgress = 0.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.completeCoordinatedAnimation()
        }
    }

    private func startAnimationPhase(_ phase: AnimationPhase) {
        animationPhases.insert(phase)

        #if DEBUG
        print("AnimationCoordinator: Starting phase \(phase)")
        #endif
    }

    private func completeCoordinatedAnimation() {
        stackAnimationState = .idle
        animationPhases.removeAll()
        currentAnimations.remove(.peel)
        currentAnimations.remove(.stackReveal)
        currentAnimations.remove(.cardReposition)

        #if DEBUG
        print("AnimationCoordinator: Coordinated animation complete")
        #endif
    }

    private func easeInOutQuad(_ t: Double) -> Double {
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    // MARK: - Animation Coordination State
    var isCoordinatedAnimationActive: Bool {
        stackAnimationState != .idle
    }

    var currentPhases: Set<AnimationPhase> {
        animationPhases
    }

    // MARK: - Unified Animation Interface
    func animateValue<Value: VectorArithmetic>(
        _ keyPath: WritableKeyPath<RallyNavigationState, Value>,
        to newValue: Value,
        type: AnimationType = .gesture
    ) {
        startAnimation(type)

        let animation: Animation = {
            switch type {
            case .gesture:
                return AnimationConfiguration.gestureAnimation
            case .transition:
                return AnimationConfiguration.transitionAnimation
            case .orientation:
                return AnimationConfiguration.orientationAnimation
            case .peel:
                return AnimationConfiguration.peelAnimation
            case .stackReveal:
                return AnimationConfiguration.stackRevealAnimation
            case .cardReposition:
                return AnimationConfiguration.cardRepositionAnimation
            }
        }()

        // Note: Direct keyPath assignment not supported with @Observable
        // This method would need to be customized for specific properties
        // withAnimation(animation) {
        //     navigationState[keyPath: keyPath] = newValue
        // }

        // Schedule animation end tracking
        let duration: TimeInterval
        switch type {
        case .gesture: duration = 0.3
        case .transition: duration = 0.4
        case .orientation: duration = 0.35
        case .peel: duration = 0.35
        case .stackReveal: duration = 0.4
        case .cardReposition: duration = 0.25
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.endAnimation(type)
        }
    }

    // MARK: - State Queries
    var isAnimating: Bool {
        !currentAnimations.isEmpty
    }

    var currentAnimationTypes: Set<AnimationType> {
        currentAnimations
    }
}

// MARK: - Supporting Types
enum AnimationType: Hashable, CustomStringConvertible {
    case gesture
    case transition
    case orientation
    case peel
    case stackReveal
    case cardReposition

    var description: String {
        switch self {
        case .gesture: return "gesture"
        case .transition: return "transition"
        case .orientation: return "orientation"
        case .peel: return "peel"
        case .stackReveal: return "stackReveal"
        case .cardReposition: return "cardReposition"
        }
    }
}

enum AnimationPhase: Hashable, CustomStringConvertible {
    case peelStart
    case peelInProgress
    case stackRevealStart
    case stackRevealInProgress
    case repositionStart
    case repositionInProgress
    case coordinatedComplete

    var description: String {
        switch self {
        case .peelStart: return "peelStart"
        case .peelInProgress: return "peelInProgress"
        case .stackRevealStart: return "stackRevealStart"
        case .stackRevealInProgress: return "stackRevealInProgress"
        case .repositionStart: return "repositionStart"
        case .repositionInProgress: return "repositionInProgress"
        case .coordinatedComplete: return "coordinatedComplete"
        }
    }
}

enum StackAnimationState: Hashable {
    case idle
    case peeling
    case revealing
    case repositioning
    case transitioning
}

// MARK: - SwiftUI Integration
extension AnimationCoordinator {
    func modifier(for type: AnimationType) -> some ViewModifier {
        AnimationModifier(coordinator: self, type: type)
    }
}

struct AnimationModifier: ViewModifier {
    let coordinator: AnimationCoordinator
    let type: AnimationType

    func body(content: Content) -> some View {
        content
            .onAppear {
                coordinator.recordFrame()
            }
    }
}

// MARK: - View Extensions
extension View {
    func rallyAnimation(_ coordinator: AnimationCoordinator, type: AnimationType) -> some View {
        self.modifier(coordinator.modifier(for: type))
    }
}
