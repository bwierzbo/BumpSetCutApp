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

        // Performance settings
        static let targetFPS: Double = 60.0
        static let frameTimeTarget: Double = 1.0 / targetFPS // ~16.67ms per frame
    }

    // MARK: - Animation State
    private let navigationState: RallyNavigationState
    private var currentAnimations: Set<AnimationType> = []

    // Performance tracking
    private var frameStartTime: Date?
    private var frameCount: Int = 0
    private var lastFPSCheck: Date = Date()

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

    // MARK: - Unified Animation Interface
    func animateValue<Value: VectorArithmetic>(
        _ keyPath: WritableKeyPath<RallyNavigationState, Value>,
        to newValue: Value,
        type: AnimationType = .gesture
    ) {
        startAnimation(type)

        let _animation: Animation = {
            switch type {
            case .gesture:
                return AnimationConfiguration.gestureAnimation
            case .transition:
                return AnimationConfiguration.transitionAnimation
            case .orientation:
                return AnimationConfiguration.orientationAnimation
            }
        }()

        // Note: Direct keyPath assignment not supported with @Observable
        // This method would need to be customized for specific properties
        // withAnimation(_animation) {
        //     navigationState[keyPath: keyPath] = newValue
        // }

        // Schedule animation end tracking
        let duration: TimeInterval
        switch type {
        case .gesture: duration = 0.3
        case .transition: duration = 0.4
        case .orientation: duration = 0.35
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

    var description: String {
        switch self {
        case .gesture: return "gesture"
        case .transition: return "transition"
        case .orientation: return "orientation"
        }
    }
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
