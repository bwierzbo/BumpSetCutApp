//
//  OrientationManager.swift
//  BumpSetCut
//
//  Created for Rally Swiping Fixes Epic - Issue #52
//  Unified orientation handling with native iOS-level smoothness
//

import Foundation
import SwiftUI
import UIKit
import Combine

final class OrientationManager: ObservableObject {
    // MARK: - Orientation State
    @Published var currentOrientation: UIDeviceOrientation = .portrait
    var isPortrait: Bool {
        currentOrientation == .portrait || currentOrientation == .portraitUpsideDown
    }
    var isLandscape: Bool {
        currentOrientation == .landscapeLeft || currentOrientation == .landscapeRight
    }

    // MARK: - Transition State
    @Published var isTransitioning: Bool = false
    @Published var transitionProgress: Double = 0.0

    // MARK: - Geometry Caching
    private var cachedGeometry: GeometryCache?
    private var geometryCacheTime: Date?
    private let cacheValidityDuration: TimeInterval = 0.1 // 100ms cache

    // MARK: - Configuration
    struct OrientationConfiguration {
        // Animation settings (native iOS-level)
        static let orientationAnimation = Animation.spring(
            response: 0.35,
            dampingFraction: 0.85,
            blendDuration: 0.0
        )

        static let gestureAnimation = Animation.spring(
            response: 0.3,
            dampingFraction: 0.75,
            blendDuration: 0.0
        )

        static let layoutAnimation = Animation.spring(
            response: 0.25,
            dampingFraction: 0.8,
            blendDuration: 0.0
        )

        // Gesture thresholds by orientation
        struct GestureThresholds {
            let navigation: CGFloat
            let action: CGFloat
            let peek: CGFloat
            let resistance: CGFloat
        }

        static let portraitThresholds = GestureThresholds(
            navigation: 100,
            action: 120,
            peek: 20,
            resistance: 100
        )

        static let landscapeThresholds = GestureThresholds(
            navigation: 120,
            action: 140,
            peek: 25,
            resistance: 120
        )

        // Debouncing
        static let orientationChangeDebounce: TimeInterval = 0.1
    }

    // MARK: - Private Properties
    private var orientationCancellable: AnyCancellable?
    private var lastOrientationChange: Date = Date()

    // MARK: - Initialization
    init() {
        // Start device orientation monitoring
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        // Set initial orientation with fallback for .unknown
        let deviceOrientation = UIDevice.current.orientation
        currentOrientation = (deviceOrientation == .unknown || deviceOrientation == .faceUp || deviceOrientation == .faceDown)
            ? .portrait
            : deviceOrientation

        setupOrientationMonitoring()
    }

    deinit {
        orientationCancellable?.cancel()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    // MARK: - Orientation Monitoring
    private func setupOrientationMonitoring() {
        orientationCancellable = NotificationCenter.default
            .publisher(for: UIDevice.orientationDidChangeNotification)
            .debounce(for: .seconds(OrientationConfiguration.orientationChangeDebounce), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleOrientationChange()
                }
            }
    }

    @MainActor
    private func handleOrientationChange() {
        let newOrientation = UIDevice.current.orientation

        // Ignore invalid orientations
        guard newOrientation != .unknown && newOrientation != .faceUp && newOrientation != .faceDown else {
            return
        }

        // Ignore rapid orientation changes
        let now = Date()
        guard now.timeIntervalSince(lastOrientationChange) >= OrientationConfiguration.orientationChangeDebounce else {
            return
        }
        lastOrientationChange = now

        // Only process if orientation actually changed
        guard newOrientation != currentOrientation else { return }

        let oldOrientation = currentOrientation
        currentOrientation = newOrientation

        // Clear geometry cache on orientation change
        invalidateGeometryCache()

        // Perform transition animation
        performOrientationTransition(from: oldOrientation, to: newOrientation)
    }

    @MainActor
    private func performOrientationTransition(from: UIDeviceOrientation, to: UIDeviceOrientation) {
        isTransitioning = true
        transitionProgress = 0.0

        withAnimation(OrientationConfiguration.orientationAnimation) {
            transitionProgress = 1.0
        }

        // End transition after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.isTransitioning = false
            self?.transitionProgress = 0.0
        }
    }

    // MARK: - Geometry Caching
    struct GeometryCache {
        let size: CGSize
        let safeAreaInsets: EdgeInsets
        let isPortrait: Bool
        let timestamp: Date
    }

    func cacheGeometry(_ geometry: GeometryProxy) {
        cachedGeometry = GeometryCache(
            size: geometry.size,
            safeAreaInsets: geometry.safeAreaInsets,
            isPortrait: isPortrait,
            timestamp: Date()
        )
        geometryCacheTime = Date()
    }

    func getCachedGeometry() -> GeometryCache? {
        guard let cache = cachedGeometry,
              let cacheTime = geometryCacheTime,
              Date().timeIntervalSince(cacheTime) < cacheValidityDuration else {
            return nil
        }
        return cache
    }

    private func invalidateGeometryCache() {
        cachedGeometry = nil
        geometryCacheTime = nil
    }

    // MARK: - Gesture Configuration
    func getGestureThresholds() -> OrientationConfiguration.GestureThresholds {
        return isPortrait ?
            OrientationConfiguration.portraitThresholds :
            OrientationConfiguration.landscapeThresholds
    }

    // MARK: - Animation Helpers
    func orientationAnimation<Value: VectorArithmetic>(_ value: Value) -> Animation {
        return OrientationConfiguration.orientationAnimation
    }

    func gestureAnimation<Value: VectorArithmetic>(_ value: Value) -> Animation {
        return OrientationConfiguration.gestureAnimation
    }

    func layoutAnimation<Value: VectorArithmetic>(_ value: Value) -> Animation {
        return OrientationConfiguration.layoutAnimation
    }

    // MARK: - Orientation Queries
    var orientationDescription: String {
        switch currentOrientation {
        case .portrait: return "Portrait"
        case .portraitUpsideDown: return "Portrait (Upside Down)"
        case .landscapeLeft: return "Landscape (Left)"
        case .landscapeRight: return "Landscape (Right)"
        default: return "Unknown"
        }
    }

    var shouldUseVerticalGestures: Bool {
        return isPortrait
    }

    var shouldUseHorizontalGestures: Bool {
        return isLandscape
    }
}

// MARK: - SwiftUI Integration
extension OrientationManager {
    func orientationModifier() -> some ViewModifier {
        OrientationViewModifier(manager: self)
    }
}

struct OrientationViewModifier: ViewModifier {
    let manager: OrientationManager

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Ensure orientation monitoring is active
            }
            .animation(manager.orientationAnimation(1.0), value: manager.currentOrientation)
    }
}

// MARK: - View Extensions
extension View {
    func rallyOrientation(_ manager: OrientationManager) -> some View {
        self.modifier(manager.orientationModifier())
    }

    func orientationAware<Portrait: View, Landscape: View>(
        _ manager: OrientationManager,
        @ViewBuilder portrait: () -> Portrait,
        @ViewBuilder landscape: () -> Landscape
    ) -> some View {
        Group {
            if manager.isPortrait {
                portrait()
            } else {
                landscape()
            }
        }
        .animation(manager.orientationAnimation(1.0), value: manager.isPortrait)
    }
}