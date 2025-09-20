//
//  RallyPlayerView.swift
//  BumpSetCut
//
//  Modern swipeable rally player with Tinder-style gestures
//

import SwiftUI
import AVKit
import AVFoundation

extension Notification.Name {
    static let pauseAllVideos = Notification.Name("pauseAllVideos")
}

enum PeelDirection {
    case left
    case right
    case up
}

enum PeekDirection {
    case next
    case previous
}

enum SwipeDirection {
    case left
    case right
    case up
}

// MARK: - Tinder-Style Action System
struct RallyActionRecord {
    let actionType: ActionPersistenceManager.RallyActionType
    let rallyIndex: Int
    let timestamp: Date

    init(_ actionType: ActionPersistenceManager.RallyActionType, on rallyIndex: Int) {
        self.actionType = actionType
        self.rallyIndex = rallyIndex
        self.timestamp = Date()
    }
}

struct RallyPlayerView: View {
    // MARK: - Properties
    let videoMetadata: VideoMetadata
    let onPeekProgress: ((Double, PeekDirection?) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var appSettings: AppSettings

    // MARK: - Unified Coordinator System
    @StateObject private var navigationState: RallyNavigationState
    @StateObject internal var gestureCoordinator: GestureCoordinator
    @StateObject private var animationCoordinator: AnimationCoordinator
    @StateObject private var orientationManager = OrientationManager()
    @StateObject private var actionPersistence = ActionPersistenceManager()
    @StateObject private var metricsCollector = MetricsCollector(config: .default)
    @StateObject private var cacheManager = RallyCacheManager()

    // MARK: - Remaining State (Minimized)
    @State private var rallyVideoURLs: [URL] = []
    @State private var players: [AVPlayer] = []
    @State private var playerLayers: [AVPlayerLayer] = []
    @State private var notificationObservers: [NSObjectProtocol] = []


    // Tinder-style state
    @State private var lastRallyAction: RallyActionRecord?
    @State private var isPlaying = true
    @State private var peelOffset: CGSize = .zero
    @State private var peelRotation: Double = 0.0
    @State private var peelOpacity: Double = 1.0

    // Action icon states
    @State private var showHeartIcon: Bool = false
    @State private var showTrashIcon: Bool = false
    @State private var heartScale: CGFloat = 0.8
    @State private var trashScale: CGFloat = 0.8
    @State private var dragDirection: SwipeDirection? = nil
    @State private var currentDragOffset: CGSize = .zero

    // Thumbnail state for card stack
    @State private var thumbnails: [Int: UIImage] = [:]  // Rally index to thumbnail
    @State private var isLoadingThumbnails = false

    // MARK: - Computed Properties
    internal var isPortrait: Bool {
        orientationManager.isPortrait
    }

    private var currentRally: RallySegment? {
        navigationState.currentRally
    }

    // MARK: - Enhanced Shadow System (Performance Optimized)
    private func calculateShadowOpacity(stackIndex: Int) -> Double {
        guard stackIndex > 0 else { return 0.0 } // No shadow for top card

        // Cache base values for performance
        let baseOpacity = 0.15 + (Double(stackIndex - 1) * 0.1)

        // Only calculate animation influence if animations are active
        guard animationCoordinator.isCoordinatedAnimationActive else {
            return min(0.4, baseOpacity)
        }

        // Coordinate with animation system for smooth transitions
        let animationMultiplier = 1.0 + (animationCoordinator.stackRevealProgress * 0.3)
        let peelInfluence = animationCoordinator.peelProgress * 0.2

        return min(0.4, baseOpacity * animationMultiplier + peelInfluence)
    }

    private func calculateShadowRadius(stackIndex: Int) -> CGFloat {
        guard stackIndex > 0 else { return 0.0 } // No shadow for top card

        // Cache base values for performance
        let baseRadius: CGFloat = 4 + (CGFloat(stackIndex - 1) * 3)

        // Only calculate animation influence if animations are active
        guard animationCoordinator.isCoordinatedAnimationActive else {
            return min(15, baseRadius)
        }

        // Coordinate with animation system for depth enhancement
        let animationMultiplier: CGFloat = 1.0 + (animationCoordinator.stackRevealProgress * 0.5)
        let peelInfluence: CGFloat = animationCoordinator.peelProgress * 2.0

        return min(15, baseRadius * animationMultiplier + peelInfluence)
    }

    private func calculateShadowOffset(stackIndex: Int) -> CGSize {
        guard stackIndex > 0 else { return .zero } // No shadow for top card

        // Cache base values for performance
        let baseY: CGFloat = 3 + (CGFloat(stackIndex - 1) * 2)

        // Only calculate animation influence if animations are active
        guard animationCoordinator.isCoordinatedAnimationActive else {
            return CGSize(x: 0, y: min(10, baseY))
        }

        // Coordinate with animation system for dynamic shadow positioning
        let animationMultiplier: CGFloat = 1.0 + (animationCoordinator.stackRevealProgress * 0.4)
        let peelInfluence: CGFloat = animationCoordinator.peelProgress * 3.0

        return CGSize(
            x: 0,
            y: min(10, baseY * animationMultiplier + peelInfluence)
        )
    }

    private func calculateCardScale(stackIndex: Int, isTopCard: Bool) -> CGFloat {
        // Enhanced depth-based scaling with stronger perspective
        let baseScale: CGFloat = 1.0 - (CGFloat(stackIndex) * 0.06) // 1.0, 0.94, 0.88 for stronger depth

        guard !isTopCard else { return baseScale }

        // Background cards get additional depth enhancement during animations
        let stackRevealMultiplier = 1.0 + (animationCoordinator.stackRevealProgress * 0.5)
        let depthEnhancement = animationCoordinator.stackRevealProgress * 0.02 // Additional scale reduction during reveal

        return max(0.8, (baseScale - depthEnhancement) * stackRevealMultiplier)
    }

    private func calculateCardOffsets(stackIndex: Int, isTopCard: Bool) -> (vertical: CGFloat, horizontal: CGFloat) {
        // Enhanced offset calculation with perspective depth
        let baseVerticalOffset: CGFloat = CGFloat(stackIndex) * 10 // Increased from 8 for stronger depth
        let baseHorizontalOffset: CGFloat = CGFloat(stackIndex) * 5 // Increased from 4 for perspective

        guard !isTopCard else {
            // Top card uses gesture-based offsets
            let peelInfluence = animationCoordinator.peelProgress
            return (
                vertical: -peelInfluence * 20,
                horizontal: 0
            )
        }

        // Background cards use coordinated animation offsets
        let stackRevealMultiplier = 1.0 + (animationCoordinator.stackRevealProgress * 0.6)
        let perspectiveEnhancement = animationCoordinator.stackRevealProgress * CGFloat(stackIndex) * 3

        return (
            vertical: baseVerticalOffset * stackRevealMultiplier + perspectiveEnhancement,
            horizontal: baseHorizontalOffset * stackRevealMultiplier
        )
    }

    private func calculateCardOpacity(stackIndex: Int, isTopCard: Bool) -> Double {
        if isTopCard {
            // Top card uses peel opacity for gesture feedback
            return peelOpacity
        }

        // Enhanced opacity gradient for background cards based on depth
        let baseOpacity = 0.85 - (Double(stackIndex - 1) * 0.15) // 0.85, 0.7, 0.55...

        // Coordinate with animation system for smooth depth transitions
        let stackRevealBoost = animationCoordinator.stackRevealProgress * 0.2
        let peelInteraction = animationCoordinator.peelProgress * 0.1

        // Dynamic opacity that enhances during interactions
        let dynamicOpacity = baseOpacity + stackRevealBoost + peelInteraction

        return max(0.3, min(0.9, dynamicOpacity))
    }

    // MARK: - Initialization
    init(videoMetadata: VideoMetadata, onPeekProgress: ((Double, PeekDirection?) -> Void)? = nil) {
        self.videoMetadata = videoMetadata
        self.onPeekProgress = onPeekProgress

        // Initialize coordinators with dependencies
        let navState = RallyNavigationState(videoMetadata: videoMetadata)
        self._navigationState = StateObject(wrappedValue: navState)
        self._gestureCoordinator = StateObject(wrappedValue: GestureCoordinator(navigationState: navState))
        self._animationCoordinator = StateObject(wrappedValue: AnimationCoordinator(navigationState: navState))
    }

    // MARK: - Body
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black.ignoresSafeArea()

                // Main content based on state
                if navigationState.isLoading {
                    loadingView
                } else if navigationState.hasError {
                    errorView
                } else {
                    rallyPlayerContent(geometry: geometry)
                }

                // Video buffering overlay
                BufferingView.forVideoLoading(
                    isBuffering: navigationState.isVideoBuffering,
                    progress: navigationState.videoLoadingProgress
                )

                // Timeout overlay if buffering times out
                if navigationState.bufferingTimeout {
                    BufferingView.forVideoTimeout(isBuffering: true)
                }

            }
        }
        .rallyOrientation(orientationManager)
        .onAppear {
            setupRallyPlayer()
        }
        .onDisappear {
            cleanupRallyPlayer()
        }
        .gesture(tinderStyleGesture)
        .animation(AnimationCoordinator.AnimationConfiguration.peelAnimation, value: peelOffset)
        .animation(AnimationCoordinator.AnimationConfiguration.peelAnimation, value: peelRotation)
        .animation(AnimationCoordinator.AnimationConfiguration.peelAnimation, value: peelOpacity)
        .animation(AnimationCoordinator.AnimationConfiguration.stackRevealAnimation, value: animationCoordinator.stackRevealProgress)
        .animation(AnimationCoordinator.AnimationConfiguration.cardRepositionAnimation, value: currentDragOffset)
    }

    // MARK: - Content Views
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)

            Text("Loading rallies...")
                .foregroundColor(.white)
                .font(.headline)
        }
    }

    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Error")
                .font(.headline)
                .foregroundColor(.white)

            Text(navigationState.errorMessage)
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding(.horizontal)

            Button("Dismiss") {
                dismiss()
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
    }

    private func rallyPlayerContent(geometry: GeometryProxy) -> some View {
        ZStack {
            // Cache geometry for performance
            Color.clear
                .onAppear {
                    orientationManager.cacheGeometry(geometry)
                }
                .onChange(of: geometry.size) { _, _ in
                    orientationManager.cacheGeometry(geometry)
                }

            // Stack visualization: Show 2-3 videos stacked with depth effect
            if !rallyVideoURLs.isEmpty && navigationState.currentRallyIndex < players.count && navigationState.playersReady {
                // Background cards (show next 2 videos if available)
                ForEach(0..<min(3, players.count - navigationState.currentRallyIndex), id: \.self) { stackIndex in
                    let playerIndex = navigationState.currentRallyIndex + stackIndex
                    let isTopCard = stackIndex == 0

                    // Calculate coordinated depth-based transforms
                    let cardScale = calculateCardScale(stackIndex: stackIndex, isTopCard: isTopCard)
                    let offsets = calculateCardOffsets(stackIndex: stackIndex, isTopCard: isTopCard)
                    let verticalOffset = offsets.vertical
                    let horizontalOffset = offsets.horizontal

                    Group {
                        if isTopCard {
                            // Top card: Full video player
                            RallyVideoPlayerView(
                                player: players[playerIndex],
                                geometry: geometry,
                                orientationManager: orientationManager
                            )
                            .id("rally-\(playerIndex)-stack-\(stackIndex)")
                        } else {
                            // Background cards: Show thumbnail for performance
                            if let thumbnail = thumbnails[playerIndex] {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .aspectRatio(contentMode: orientationManager.isLandscape ? .fill : .fit)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color.black)
                                    .clipped()
                                    .id("rally-thumbnail-\(playerIndex)-stack-\(stackIndex)")
                            } else {
                                // Placeholder while loading thumbnail
                                Rectangle()
                                    .fill(Color.black.opacity(0.3))
                                    .overlay(
                                        ProgressView()
                                            .tint(.white)
                                            .scaleEffect(0.8)
                                    )
                                    .id("rally-placeholder-\(playerIndex)-stack-\(stackIndex)")
                            }
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .if(orientationManager.isLandscape) { view in
                        view.ignoresSafeArea(.all)
                    }
                    // Apply coordinated stack transforms
                    .scaleEffect(cardScale)
                    .offset(
                        x: isTopCard ? (peelOffset.width + currentDragOffset.width) : horizontalOffset,
                        y: isTopCard ? (peelOffset.height + currentDragOffset.height) : verticalOffset
                    )
                    .rotationEffect(.degrees(isTopCard ? peelRotation : 0))
                    .opacity(calculateCardOpacity(stackIndex: stackIndex, isTopCard: isTopCard))
                    .zIndex(Double(3 - stackIndex)) // Ensure proper layering (top card has highest z-index)
                    .shadow(
                        color: Color.black.opacity(calculateShadowOpacity(stackIndex: stackIndex)),
                        radius: calculateShadowRadius(stackIndex: stackIndex),
                        x: calculateShadowOffset(stackIndex: stackIndex).x,
                        y: calculateShadowOffset(stackIndex: stackIndex).y
                    )
                    .animation(AnimationCoordinator.AnimationConfiguration.stackRevealAnimation, value: animationCoordinator.stackRevealProgress)
                    .animation(AnimationCoordinator.AnimationConfiguration.peelAnimation, value: animationCoordinator.peelProgress)
                    .allowsHitTesting(isTopCard) // Only top card responds to touches
                    .onTapGesture {
                        if isTopCard {
                            togglePlayPause()
                        }
                    }
                }
            } else {
                // Debug: Show what's missing
                Text("Debug: URLs=\(rallyVideoURLs.count), Players=\(players.count), Index=\(navigationState.currentRallyIndex), Ready=\(navigationState.playersReady)")
                    .foregroundColor(.white)
                    .padding()
            }

            // Back button (top left)
            backButton

            // Rally counter indicator (top center)
            progressIndicatorView

            // Stack depth visual cues (left side)
            stackDepthIndicator

            // Bottom action bar with orientation-aware layout
            bottomActionBar
        }
    }

    // MARK: - Minimal UI: Single Undo Button
    private var undoButton: some View {
        VStack {
            Spacer()

            if let lastAction = lastRallyAction {
                Button(action: { undoLastAction() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Undo \(lastAction.actionType.displayName)")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25))
                }
                .padding(.bottom, 50)
            }
        }
    }

    // MARK: - Adaptive Bottom Action Bar
    private var bottomActionBar: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()

                HStack {
                    Spacer()

                    // Trash Icon (Left) - Close to undo button
                    trashIconButton

                    Spacer()
                        .frame(maxWidth: 60) // Fixed spacing to keep icons close to center

                    // Undo Button (Center)
                    undoButtonCompact

                    Spacer()
                        .frame(maxWidth: 60) // Fixed spacing to keep icons close to center

                    // Heart Icon (Right) - Close to undo button
                    heartIconButton

                    Spacer()
                }
                .padding(.horizontal, 20) // Minimal edge padding
                .padding(.bottom, isPortrait ? 50 : 30)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isPortrait)
            }
        }
    }

    // MARK: - Action Icon Components
    private var trashIconButton: some View {
        Button(action: {
            // Manual delete action
            performPeelAnimation(.left) {
                deleteCurrentRally()
            }
        }) {
            Image(systemName: "trash.fill")
                .font(.title) // Bigger size
                .foregroundColor(showTrashIcon ? .red : .white.opacity(0.8)) // Higher opacity when inactive
                .scaleEffect(trashScale)
                .opacity(showTrashIcon ? 1.0 : 0.8) // Higher base opacity
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showTrashIcon)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: trashScale)
    }

    private var heartIconButton: some View {
        Button(action: {
            // Manual like action
            performPeelAnimation(.right) {
                likeCurrentRally()
            }
        }) {
            Image(systemName: "heart.fill")
                .font(.title) // Bigger size
                .foregroundColor(showHeartIcon ? .red : .white.opacity(0.8)) // Higher opacity when inactive
                .scaleEffect(heartScale)
                .opacity(showHeartIcon ? 1.0 : 0.8) // Higher base opacity
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showHeartIcon)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: heartScale)
    }

    private var undoButtonCompact: some View {
        Group {
            if lastRallyAction != nil {
                Button(action: { undoLastAction() }) {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.title3)
                        Text("Undo")
                            .font(.caption2)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        }
    }

    // MARK: - Back Button (Top Left)
    private var backButton: some View {
        VStack {
            HStack {
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "arrow.left")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.top, 50) // Safe area padding
                .padding(.leading, 20)

                Spacer()
            }

            Spacer()
        }
    }

    // MARK: - Progress Indicator UI (Top Center)
    private var progressIndicatorView: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()

                if let metadata = navigationState.processingMetadata {
                    VStack(spacing: 6) {
                        // Main progress indicator with rally count
                        HStack(spacing: 12) {
                            // Current rally number
                            Text("\(navigationState.currentRallyIndex + 1)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .frame(minWidth: 24)

                            // Progress bar
                            progressBarView(current: navigationState.currentRallyIndex + 1,
                                          total: metadata.rallySegments.count)

                            // Total rally count
                            Text("\(metadata.rallySegments.count)")
                                .font(.title2)
                                .fontWeight(.medium)
                                .foregroundColor(.white.opacity(0.8))
                                .frame(minWidth: 24)
                        }

                        // Remaining rallies indicator
                        let remaining = metadata.rallySegments.count - (navigationState.currentRallyIndex + 1)
                        if remaining > 0 {
                            Text("\(remaining) remaining")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.white.opacity(0.7))
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .animation(.easeInOut(duration: 0.4), value: navigationState.currentRallyIndex)
                }

                Spacer()
            }
            .padding(.top, 50) // Same safe area padding as back button

            Spacer()
        }
    }

    // MARK: - Progress Bar Component
    private func progressBarView(current: Int, total: Int) -> some View {
        GeometryReader { geometry in
            let progress = Double(current) / Double(total)
            let barWidth = isPortrait ? 120.0 : 80.0 // Adaptive width for orientation

            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.3))
                    .frame(width: barWidth, height: 6)

                // Progress fill
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white)
                    .frame(width: barWidth * progress, height: 6)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress)

                // Stack depth indicators (dots)
                HStack(spacing: max(2, (barWidth - 20) / Double(total - 1))) {
                    ForEach(0..<total, id: \.self) { index in
                        Circle()
                            .fill(index <= current - 1 ? .white : .white.opacity(0.4))
                            .frame(width: index == current - 1 ? 8 : 6,
                                   height: index == current - 1 ? 8 : 6)
                            .scaleEffect(index == current - 1 ? 1.2 : 1.0)
                            .animation(.spring(response: 0.4, dampingFraction: 0.7),
                                     value: current)
                    }
                }
                .frame(width: barWidth, height: 6)
            }
        }
        .frame(height: 6)
    }

    // MARK: - Stack Depth Visual Cues
    private var stackDepthIndicator: some View {
        VStack {
            Spacer()

            HStack {
                // Left side stack depth indicator
                if let metadata = navigationState.processingMetadata {
                    let totalRallies = metadata.rallySegments.count
                    let currentIndex = navigationState.currentRallyIndex
                    let stackSize = min(3, totalRallies - currentIndex) // Show up to 3 cards in stack

                    VStack(spacing: 4) {
                        ForEach(0..<stackSize, id: \.self) { index in
                            let isTopCard = index == 0
                            let cardOpacity = isTopCard ? 1.0 : max(0.3, 1.0 - Double(index) * 0.3)
                            let cardWidth: CGFloat = isTopCard ? 4 : 3

                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white.opacity(cardOpacity))
                                .frame(width: cardWidth, height: 20)
                                .scaleEffect(isTopCard ? 1.0 : 0.9 - Double(index) * 0.1)
                                .animation(.spring(response: 0.5, dampingFraction: 0.8),
                                         value: currentIndex)
                        }

                        // Remaining count dot indicator for many rallies
                        if totalRallies - currentIndex > 3 {
                            Text("•••")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.4))
                                .padding(.top, 2)
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.vertical, 20)
                    .background(.ultraThinMaterial.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    .opacity(navigationState.canInteract ? 1.0 : 0.0) // Hide during loading
                    .animation(.easeInOut(duration: 0.3), value: navigationState.canInteract)
                }

                Spacer()
            }

            Spacer()
        }
    }

    // MARK: - Tinder-Style Gesture System
    private var tinderStyleGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                // Only process gestures when video is ready, we can interact, and not transitioning orientation
                guard navigationState.canInteract && !orientationManager.isTransitioning else { return }

                let translation = value.translation

                // Get device-optimized thresholds for resistance calculation
                let thresholds = orientationManager.getGestureThresholds()

                // Apply drag offset with device-optimized resistance
                let baseResistance: CGFloat = 0.5
                let resistanceThreshold = thresholds.resistance

                // Calculate dynamic resistance based on distance
                let distance = sqrt(translation.width * translation.width + translation.height * translation.height)
                let resistanceFactor = distance > resistanceThreshold ?
                    baseResistance * (resistanceThreshold / distance) : baseResistance

                currentDragOffset = CGSize(
                    width: translation.width * resistanceFactor,
                    height: translation.height * resistanceFactor
                )

                updateIconsBasedOnDrag(translation: translation, velocity: value.velocity)
            }
            .onEnded { value in
                // Only process gestures when video is ready, we can interact, and not transitioning orientation
                guard navigationState.canInteract && !orientationManager.isTransitioning else {
                    resetAllGestureStates()
                    withAnimation(AnimationCoordinator.AnimationConfiguration.cardRepositionAnimation) {
                        currentDragOffset = .zero
                    }
                    return
                }

                let translation = value.translation
                let velocity = value.velocity

                // Reset icons
                resetIconStates()

                // Get device-optimized thresholds from OrientationManager
                let thresholds = orientationManager.getGestureThresholds()

                // Calculate dominant axis using both distance and velocity
                let horizontalMagnitude = abs(translation.width)
                let verticalMagnitude = abs(translation.height)
                let horizontalVelocity = abs(velocity.width)
                let verticalVelocity = abs(velocity.height)

                let threshold = thresholds.navigation
                let velocityThreshold = thresholds.velocity

                // Determine if gesture meets minimum thresholds
                let horizontalExceedsThreshold = horizontalMagnitude > threshold || horizontalVelocity > velocityThreshold
                let verticalExceedsThreshold = verticalMagnitude > threshold || verticalVelocity > velocityThreshold

                // Prioritize the dominant axis when both exceed thresholds
                if verticalExceedsThreshold && (verticalMagnitude > horizontalMagnitude || !horizontalExceedsThreshold) {
                    // Vertical gesture dominates
                    if translation.height < 0 {
                        // Up swipe = Next rally
                        performPeelAnimation(.up) {
                            nextRally()
                        }
                    } else {
                        // Down swipe = Previous rally
                        performPeelAnimation(.up) { // Use same animation for consistency
                            previousRally()
                        }
                    }
                }
                else if horizontalExceedsThreshold {
                    // Horizontal gesture dominates
                    if translation.width > 0 {
                        // Right swipe = Like
                        triggerIconFlare(.right)
                        performPeelAnimation(.right) {
                            likeCurrentRally()
                        }
                    } else {
                        // Left swipe = Delete
                        triggerIconFlare(.left)
                        performPeelAnimation(.left) {
                            deleteCurrentRally()
                        }
                    }
                } else {
                    // Sub-threshold gesture - use coordinated reset animation
                    animationCoordinator.resetGestureAnimation()
                    withAnimation(AnimationCoordinator.AnimationConfiguration.cardRepositionAnimation) {
                        peelOffset = .zero
                        peelRotation = 0
                        peelOpacity = 1
                    }
                    resetIconStates()
                }

                // Always reset drag offset on gesture end using coordinated animation
                withAnimation(AnimationCoordinator.AnimationConfiguration.cardRepositionAnimation) {
                    currentDragOffset = .zero
                }
            }
    }

    // MARK: - Enhanced Icon Feedback System with Animation Coordination
    private func updateIconsBasedOnDrag(translation: CGSize, velocity: CGSize = .zero) {
        // Use device-optimized peek threshold for feedback
        let thresholds = orientationManager.getGestureThresholds()
        let feedbackThreshold = thresholds.peek

        // Update coordinated animation progress
        let screenSize = UIScreen.main.bounds.size
        let bounds = CGRect(origin: .zero, size: screenSize)
        animationCoordinator.updateGestureBasedAnimation(
            translation: translation,
            velocity: velocity,
            screenBounds: bounds
        )

        // Calculate dominant axis to provide appropriate feedback
        let horizontalMagnitude = abs(translation.width)
        let verticalMagnitude = abs(translation.height)

        // Only show horizontal feedback if horizontal is dominant or significant
        if horizontalMagnitude > feedbackThreshold && horizontalMagnitude >= verticalMagnitude {
            if translation.width > 0 {
                // Dragging right - show heart with coordinated scaling
                dragDirection = .right
                showHeartIcon = true
                showTrashIcon = false

                let progress = min(horizontalMagnitude / 100, 1.0)
                let animationProgress = animationCoordinator.peelProgress
                heartScale = 0.8 + (0.4 * progress) + (0.2 * animationProgress) // Enhanced scaling
            } else {
                // Dragging left - show trash with coordinated scaling
                dragDirection = .left
                showTrashIcon = true
                showHeartIcon = false

                let progress = min(horizontalMagnitude / 100, 1.0)
                let animationProgress = animationCoordinator.peelProgress
                trashScale = 0.8 + (0.4 * progress) + (0.2 * animationProgress) // Enhanced scaling
            }
        } else if verticalMagnitude > feedbackThreshold && verticalMagnitude > horizontalMagnitude {
            // Vertical gesture dominant - don't show left/right icons, prepare for up/down swipe
            if translation.height < 0 {
                dragDirection = .up // Up swipe for next
            } else {
                dragDirection = .up // Down swipe for previous (use same direction enum)
            }
            showHeartIcon = false
            showTrashIcon = false
            heartScale = 0.8
            trashScale = 0.8
        } else {
            // Reset when not exceeding threshold or unclear direction
            resetIconStates()
        }
    }

    private func resetIconStates() {
        dragDirection = nil
        showHeartIcon = false
        showTrashIcon = false
        heartScale = 0.8
        trashScale = 0.8
    }

    private func resetAllGestureStates() {
        resetIconStates()
        resetPeelAnimation()
    }

    private func triggerIconFlare(_ direction: SwipeDirection) {
        switch direction {
        case .right:
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                heartScale = 1.3
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeOut(duration: 0.2)) {
                    self.heartScale = 0.8
                    self.showHeartIcon = false
                }
            }
        case .left:
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                trashScale = 1.3
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeOut(duration: 0.2)) {
                    self.trashScale = 0.8
                    self.showTrashIcon = false
                }
            }
        case .up:
            break // No icon for up swipe
        }
    }

    // MARK: - Coordinated Peel Animations
    private func performPeelAnimation(_ direction: PeelDirection, completion: @escaping () -> Void) {
        // Use coordinated animation system for smooth stack coordination
        animationCoordinator.performCoordinatedPeelAnimation(direction: direction) {
            completion()
            self.resetPeelAnimation()
        }
    }

    private func resetPeelAnimation() {
        animationCoordinator.resetGestureAnimation()

        withAnimation(AnimationCoordinator.AnimationConfiguration.cardRepositionAnimation) {
            peelOffset = .zero
            peelRotation = 0
            peelOpacity = 1
        }
    }

    // MARK: - Rally Actions
    private func likeCurrentRally() {
        let currentIndex = navigationState.currentRallyIndex
        lastRallyAction = RallyActionRecord(.like, on: currentIndex)

        Task {
            let _ = await actionPersistence.performAction(.like, on: currentIndex)
            await navigateToNextRally()
        }
    }

    private func deleteCurrentRally() {
        let currentIndex = navigationState.currentRallyIndex
        lastRallyAction = RallyActionRecord(.delete, on: currentIndex)

        Task {
            let _ = await actionPersistence.performAction(.delete, on: currentIndex)
            await navigateToNextRally()
        }
    }

    private func nextRally() {
        Task {
            await navigateToNextRally()
        }
    }

    private func previousRally() {
        Task {
            await navigateToPreviousRally()
        }
    }

    private func navigateToNextRally() async {
        guard navigationState.canGoNext else { return }

        await MainActor.run {
            // Pause current player
            if navigationState.currentRallyIndex < players.count {
                players[navigationState.currentRallyIndex].pause()
            }

            // Move to next rally
            navigationState.currentRallyIndex += 1

            // Play new rally
            if navigationState.currentRallyIndex < players.count && isPlaying {
                players[navigationState.currentRallyIndex].play()
                print("🎬 Playing rally \(navigationState.currentRallyIndex)")
            }

            // Prefetch upcoming thumbnails
            Task {
                await self.prefetchUpcomingThumbnails()
            }
        }
    }

    private func navigateToPreviousRally() async {
        guard navigationState.canGoPrevious else { return }

        await MainActor.run {
            // Pause current player
            if navigationState.currentRallyIndex < players.count {
                players[navigationState.currentRallyIndex].pause()
            }

            // Move to previous rally
            navigationState.currentRallyIndex -= 1

            // Play new rally
            if navigationState.currentRallyIndex >= 0 && navigationState.currentRallyIndex < players.count && isPlaying {
                players[navigationState.currentRallyIndex].play()
                print("🎬 Playing rally \(navigationState.currentRallyIndex)")
            }
        }
    }

    // MARK: - Playback Controls
    private func togglePlayPause() {
        let currentIndex = navigationState.currentRallyIndex
        guard currentIndex < players.count else { return }

        let player = players[currentIndex]

        if isPlaying {
            player.pause()
        } else {
            player.play()
        }

        isPlaying.toggle()
    }

    // MARK: - Undo System
    private func undoLastAction() {
        guard let lastAction = lastRallyAction else { return }

        Task {
            // Revert the action in persistence
            switch lastAction.actionType {
            case .like:
                let _ = await actionPersistence.performAction(.like, on: lastAction.rallyIndex) // Toggle off
            case .delete:
                let _ = await actionPersistence.performAction(.delete, on: lastAction.rallyIndex) // Toggle off
            default:
                break
            }

            // Navigate back to the previous rally
            await MainActor.run {
                if navigationState.currentRallyIndex > lastAction.rallyIndex {
                    // Pause current player
                    if navigationState.currentRallyIndex < players.count {
                        players[navigationState.currentRallyIndex].pause()
                    }

                    // Return to previous rally
                    navigationState.currentRallyIndex = lastAction.rallyIndex

                    // Restart the restored rally from the beginning
                    if navigationState.currentRallyIndex < players.count && isPlaying {
                        let player = players[navigationState.currentRallyIndex]
                        player.seek(to: .zero) // Restart from beginning
                        player.play()
                        print("🔄 Restarted rally \(navigationState.currentRallyIndex) from beginning")
                    }
                }

                // Clear the last action
                self.lastRallyAction = nil
            }
        }
    }

    // MARK: - Thumbnail Management
    private func loadThumbnailsForStack() async {
        guard !rallyVideoURLs.isEmpty else { return }

        await MainActor.run {
            isLoadingThumbnails = true
        }

        // Load thumbnails for current and next 2 rallies
        let startIndex = navigationState.currentRallyIndex
        let endIndex = min(startIndex + 3, rallyVideoURLs.count)

        for index in startIndex..<endIndex {
            await loadThumbnail(for: index)
        }

        await MainActor.run {
            isLoadingThumbnails = false
        }
    }

    private func loadThumbnail(for rallyIndex: Int) async {
        guard rallyIndex < rallyVideoURLs.count else { return }

        let videoURL = rallyVideoURLs[rallyIndex]
        let timestamp = 0.5  // Get thumbnail from 0.5 seconds into the rally

        // Check disk cache first
        if let cachedData = await cacheManager.getCachedThumbnail(for: videoMetadata.id, at: Double(rallyIndex) + timestamp),
           let image = UIImage(data: cachedData) {
            await MainActor.run {
                self.thumbnails[rallyIndex] = image
            }
            return
        }

        // Generate thumbnail using FrameExtractor
        do {
            let cmTime = CMTime(seconds: timestamp, preferredTimescale: 600)
            let thumbnail = try await FrameExtractor.shared.generateThumbnail(from: videoURL, at: cmTime)

            await MainActor.run {
                self.thumbnails[rallyIndex] = thumbnail
            }

            // Cache to disk for future use
            if let jpegData = thumbnail.jpegData(compressionQuality: 0.7) {
                await cacheManager.storeThumbnail(jpegData, for: videoMetadata.id, at: Double(rallyIndex) + timestamp)
            }
        } catch {
            print("❌ Failed to generate thumbnail for rally \(rallyIndex): \(error)")
        }
    }

    private func prefetchUpcomingThumbnails() async {
        // Prefetch thumbnails for the next 3 rallies beyond current view
        let startIndex = navigationState.currentRallyIndex + 3
        let endIndex = min(startIndex + 3, rallyVideoURLs.count)

        guard startIndex < endIndex else { return }

        // Use low priority prefetching
        var requests: [(URL, CMTime)] = []
        for index in startIndex..<endIndex {
            if thumbnails[index] == nil {
                let url = rallyVideoURLs[index]
                let time = CMTime(seconds: 0.5, preferredTimescale: 600)
                requests.append((url, time))
            }
        }

        if !requests.isEmpty {
            FrameExtractor.shared.prefetchThumbnails(for: requests, priority: .low)
        }
    }

    // MARK: - Lifecycle
    private func setupRallyPlayer() {
        Task {
            let initTimer = metricsCollector.startInitializationTimer(component: "rally_player")

            // Initialize navigation state
            await navigationState.initialize()

            // Start action persistence session
            await actionPersistence.startSession(for: videoMetadata.id)

            // Load rally videos (this will also setup players when complete)
            await loadRallyVideos()

            metricsCollector.recordInitializationComplete(timer: initTimer)
        }
    }

    private func cleanupRallyPlayer() {
        Task {
            await actionPersistence.endSession()
        }

        // Cleanup video players
        cleanupVideoPlayers()
    }

    private func loadRallyVideos() async {
        guard let metadata = await loadProcessingMetadata() else { return }

        if metadata.rallySegments.isEmpty {
            await MainActor.run {
                navigationState.hasError = false
                navigationState.isLoading = false
            }
            return
        }

        // Check cache first for instant loading
        if let cachedURLs = await cacheManager.getCachedRallyURLs(for: videoMetadata.id) {
            await MainActor.run {
                self.rallyVideoURLs = cachedURLs
                self.navigationState.processingMetadata = metadata
                self.navigationState.isLoading = false
                self.navigationState.hasError = false

                // Setup video players with cached URLs
                self.setupVideoPlayers()

                // Load thumbnails for card stack preview
                Task {
                    await self.loadThumbnailsForStack()
                }
            }
            print("⚡ Loaded \(cachedURLs.count) rallies from cache instantly!")
            return
        }

        // Cache miss - need to export rally segments
        print("📊 Cache miss - exporting rally segments...")
        await Task.detached(priority: .userInitiated) {
            do {
                let asset = AVURLAsset(url: videoMetadata.originalURL)
                let exporter = VideoExporter()

                // Note: No longer calling cleanupRallyCache() here to preserve cache
                let urls = try await exporter.exportRallySegments(asset: asset, rallies: metadata.rallySegments)

                // Store in cache for future launches
                await self.cacheManager.storeCachedRallies(videoMetadata.id, urls)

                await MainActor.run {
                    self.rallyVideoURLs = urls
                    self.navigationState.processingMetadata = metadata
                    self.navigationState.isLoading = false
                    self.navigationState.hasError = false

                    // Setup video players once URLs are loaded
                    self.setupVideoPlayers()

                    // Load thumbnails for card stack preview
                    Task {
                        await self.loadThumbnailsForStack()
                    }
                }

            } catch {
                await MainActor.run {
                    self.navigationState.hasError = true
                    self.navigationState.isLoading = false
                    self.navigationState.errorMessage = "Failed to create rally videos: \(error.localizedDescription)"
                }
                print("❌ Rally loading error: \(error)")
            }
        }.value
    }

    private func loadProcessingMetadata() async -> ProcessingMetadata? {
        do {
            // Get metadataStore from navigationState (since it's created there now)
            guard let metadataStore = navigationState.metadataStore else {
                throw NSError(domain: "RallyPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "MetadataStore not available"])
            }
            let metadata = try metadataStore.loadMetadata(for: videoMetadata.id)
            return metadata
        } catch {
            await MainActor.run {
                self.navigationState.hasError = true
                self.navigationState.isLoading = false
                self.navigationState.errorMessage = "Failed to load video metadata: \(error.localizedDescription)"
            }
            print("❌ Metadata loading error: \(error)")
            return nil
        }
    }

    private func setupVideoPlayers() {
        // Clear existing players
        cleanupVideoPlayers()

        // Start video buffering state
        navigationState.startVideoBuffering()

        // Create players for each rally video with looping
        players = rallyVideoURLs.map { url in
            let player = AVPlayer(url: url)
            player.isMuted = false

            // Optimize for immediate visual readiness
            player.automaticallyWaitsToMinimizeStalling = false
            player.preventsDisplaySleepDuringVideoPlayback = true

            // Setup looping for rally videos
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                if self.isPlaying {
                    player.play()
                }
            }

            return player
        }

        // Setup status monitoring for the first player (critical for preventing black screen)
        if !players.isEmpty {
            observePlayerReadiness(player: players[0], isFirstPlayer: true)
        }

        print("🎬 Setup \(players.count) video players for rallies")
    }

    private func observePlayerReadiness(player: AVPlayer, isFirstPlayer: Bool) {
        guard let playerItem = player.currentItem else {
            navigationState.completeVideoBuffering(success: false)
            return
        }

        // Add player item status observer
        let observer = playerItem.observe(\.status, options: [.new, .initial]) { item, _ in
            DispatchQueue.main.async {

                switch item.status {
                case .readyToPlay:
                    // Only start playback when video is truly ready
                    if isFirstPlayer && isPlaying {
                        player.play()
                        print("🎬 Started playing rally 0 - video frames ready")
                    }

                    // Complete buffering on first player readiness
                    if isFirstPlayer {
                        navigationState.completeVideoBuffering(success: true)
                    }

                case .failed:
                    if let error = item.error {
                        print("❌ Player item failed: \(error.localizedDescription)")
                    }
                    if isFirstPlayer {
                        navigationState.completeVideoBuffering(success: false)
                    }

                case .unknown:
                    // Update loading progress for better UX
                    if isFirstPlayer {
                        navigationState.updateVideoLoadingProgress(0.3)
                    }

                @unknown default:
                    break
                }
            }
        }

        // Store observer to clean up later
        notificationObservers.append(observer)

        // Also observe loaded time ranges for progress indication
        let timeRangeObserver = playerItem.observe(\.loadedTimeRanges, options: [.new]) { item, _ in
            DispatchQueue.main.async {
                guard isFirstPlayer else { return }

                if let timeRange = item.loadedTimeRanges.first?.timeRangeValue {
                    let duration = item.duration.seconds
                    let loadedDuration = timeRange.duration.seconds

                    if duration > 0 && !duration.isNaN {
                        let progress = min(1.0, loadedDuration / duration)
                        navigationState.updateVideoLoadingProgress(progress * 0.7 + 0.3) // Start from 30%
                    }
                }
            }
        }

        notificationObservers.append(timeRangeObserver)
    }

    private func cleanupVideoPlayers() {
        // Pause and release all players
        for player in players {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        players.removeAll()

        // Remove notification observers
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()

        print("🧹 Cleaned up video players")
    }
}


// MARK: - Clean Fullscreen Video Player (No Overlay Controls)
private struct RallyVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let geometry: GeometryProxy
    let orientationManager: OrientationManager

    private var isLandscape: Bool {
        orientationManager.isLandscape
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.clipsToBounds = true

        let playerLayer = AVPlayerLayer(player: player)

        // Disable implicit animations for initial layout
        playerLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "transform": NSNull()
        ]

        let initialFrame = CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.size.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Use resizeAspect (fit) in portrait, resizeAspectFill (fill) in landscape
        playerLayer.videoGravity = isLandscape ? .resizeAspectFill : .resizeAspect
        playerLayer.frame = CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.size.height)
        playerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        playerLayer.position = CGPoint(x: initialFrame.midX, y: initialFrame.midY)
        CATransaction.commit()

        // Ensure the layer is ready for display
        playerLayer.needsDisplayOnBoundsChange = true
        playerLayer.masksToBounds = true

        view.layer.addSublayer(playerLayer)

        // Store reference for updates
        context.coordinator.playerLayer = playerLayer

        print("🎬 Created player layer with frame: \(playerLayer.frame)")

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let playerLayer = context.coordinator.playerLayer {
            let bounds = uiView.bounds
            guard bounds.width > 0 && bounds.height > 0 else { return }

            // Determine layout mode from actual bounds to avoid timing issues during rotation
            let computedLandscape = bounds.width > bounds.height

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Use resizeAspect (fit) in portrait, resizeAspectFill (fill) in landscape
            playerLayer.videoGravity = computedLandscape ? .resizeAspectFill : .resizeAspect
            playerLayer.frame = bounds
            playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()

            // Update coordinator state
            let coordinator = context.coordinator
            coordinator.lastFrameUpdate = Date()
            coordinator.lastKnownLandscape = computedLandscape

            print("🎬 Updated player frame: \(bounds), landscape(fromBounds): \(computedLandscape)")
        }
    }

    // Helper functions inside struct:
    /// Compute video rect fitting contentSize inside bounds.
    /// isLandscape is computed from bounds dimensions (not external orientation state).
    private func computeVideoRect(for bounds: CGRect, isLandscape: Bool, asset: AVAsset?) -> CGRect {
        guard let asset = asset, let track = asset.tracks(withMediaType: .video).first else {
            return bounds
        }
        let natural = normalizedSize(for: track)
        if natural.width <= 0 || natural.height <= 0 {
            return bounds
        }

        // Aspect Fit in portrait, Stretch to fill in landscape
        if isLandscape {
            // Stretch to fill entire screen in landscape
            return bounds
        } else {
            return AVMakeRect(aspectRatio: natural, insideRect: bounds) // aspect fit
        }
    }

    private func normalizedSize(for track: AVAssetTrack) -> CGSize {
        // Apply preferredTransform to get the display-corrected size
        let transformed = CGSize(
            width: abs(track.naturalSize.applying(track.preferredTransform).width),
            height: abs(track.naturalSize.applying(track.preferredTransform).height)
        )
        if transformed.width > 0 && transformed.height > 0 {
            return transformed
        }
        return track.naturalSize
    }

    private func aspectFillRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        let scale = max(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let width = contentSize.width * scale
        let height = contentSize.height * scale
        let x = bounds.midX - width / 2
        let y = bounds.midY - height / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        var playerLayer: AVPlayerLayer?
        var lastFrameUpdate: Date = Date()
        var lastKnownLandscape: Bool = false
    }
}

// Helper extension for conditional modifiers
extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - RallyNavigationCapable Conformance
extension RallyPlayerView: RallyNavigationCapable {
    var integratedRallyDragGesture: some Gesture {
        gestureCoordinator.createDragGesture(isPortrait: isPortrait)
    }
}

