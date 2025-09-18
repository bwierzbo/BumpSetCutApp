//
//  TikTokRallyPlayerView.swift
//  BumpSetCut
//
//  TikTok-style rally player with individual video files and seamless swiping
//

import SwiftUI
import AVKit
import AVFoundation

extension Notification.Name {
    static let pauseAllVideos = Notification.Name("pauseAllVideos")
}

struct TikTokRallyPlayerView: View {
    // MARK: - Properties

    let videoMetadata: VideoMetadata
    let onPeekProgress: ((Double, PeekDirection?) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var appSettings: AppSettings
    @StateObject private var metadataStore = MetadataStore()

    // Rally video state
    @State private var processingMetadata: ProcessingMetadata?
    @State private var rallyVideoURLs: [URL] = []
    @State private var currentRallyIndex = 0
    @State private var isLoading = true
    @State private var isExportingRallies = false
    @State private var hasError = false
    @State private var errorMessage = ""

    // Rally management state
    @State private var savedRallies: Set<Int> = []
    @State private var removedRallies: Set<Int> = []
    @State private var lastAction: (action: SwipeAction, rallyIndex: Int)?

    // Video players state
    @State private var players: [AVPlayer] = []
    @State private var playerLayers: [AVPlayerLayer] = []
    @State private var notificationObservers: [NSObjectProtocol] = []

    // Gesture state
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var bounceOffset: CGFloat = 0.0

    // Peek state
    @State private var peekProgress: Double = 0.0
    @State private var currentPeekDirection: PeekDirection? = nil
    @State private var peekFrameImage: UIImage? = nil
    @State private var isLoadingPeekFrame = false
    @State private var peekFrameTask: Task<Void, Never>? = nil

    // Videos are now stacked and managed automatically

    // Transition state
    @State private var isTransitioning = false
    @State private var transitionOpacity = 1.0
    @State private var videoScale: CGFloat = 1.0

    // Action feedback state
    @State private var actionFeedback: ActionFeedback?
    @State private var showActionFeedback = false

    // Tinder-style swipe animation state
    @State private var swipeOffset: CGFloat = 0.0
    @State private var swipeRotation: Double = 0.0
    @State private var isPerformingAction = false
    @State private var currentAction: SwipeAction?

    // Export state
    @State private var showExportOptions = false
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    private var canGoNext: Bool {
        currentRallyIndex < rallyVideoURLs.count - 1
    }

    private var canGoPrevious: Bool {
        currentRallyIndex > 0
    }

    // MARK: - Initializer

    init(videoMetadata: VideoMetadata, onPeekProgress: ((Double, PeekDirection?) -> Void)? = nil) {
        self.videoMetadata = videoMetadata
        self.onPeekProgress = onPeekProgress
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // Stacked videos handle peek effect automatically

                if isLoading {
                    loadingView
                } else if hasError {
                    errorView
                } else if rallyVideoURLs.isEmpty {
                    noRalliesView
                } else {
                    rallyPlayerStack(geometry: geometry)
                        .clipped() // Ensure no video content bleeds outside
                }

                // Navigation overlay
                if !isLoading && !hasError && !rallyVideoURLs.isEmpty {
                    navigationOverlay
                }

                // Tinder-style action buttons
                if !isLoading && !hasError && !rallyVideoURLs.isEmpty {
                    actionButtonsOverlay
                }

                // Action feedback overlay
                if showActionFeedback, let feedback = actionFeedback {
                    actionFeedbackOverlay(feedback: feedback)
                }
            }
            .clipped() // Additional clipping at the top level
            .sheet(isPresented: $showExportOptions) {
                ExportOptionsView(
                    savedRallies: Array(savedRallies).sorted(),
                    totalRallies: rallyVideoURLs.count,
                    processingMetadata: processingMetadata,
                    videoMetadata: videoMetadata,
                    isExporting: $isExporting,
                    exportProgress: $exportProgress
                ) {
                    // Dismiss callback
                    showExportOptions = false
                }
            }
        }
        .onAppear {
            Task {
                await loadRallyVideos()
                // Videos are now automatically stacked and managed
            }
        }
        .onDisappear {
            cleanupPlayers()
            cleanupPeekFrame()
        }
    }

    // MARK: - Video Player Stack

    private func rallyPlayerStack(geometry: GeometryProxy) -> some View {
        ZStack {
            ForEach(Array(rallyVideoURLs.enumerated()), id: \.offset) { index, url in
                let shouldShow = shouldShowVideo(index: index)

                if shouldShow {
                    TikTokVideoPlayer(
                        url: url,
                        isActive: index == currentRallyIndex,
                        size: geometry.size
                    )
                    .offset(
                        x: calculateDeckOffsetX(for: index, geometry: geometry),
                        y: calculateDeckOffsetY(for: index)
                    )
                    .rotationEffect(.degrees(calculateDeckRotation(for: index)))
                    .scaleEffect(calculateDeckScale(for: index))
                    .opacity(calculateDeckOpacity(for: index))
                    .zIndex(calculateDeckZIndex(for: index)) // Proper layering for bidirectional navigation
                    .animation(.spring(response: 0.4, dampingFraction: 0.8, blendDuration: 0.1), value: currentRallyIndex)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: swipeOffset)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: swipeRotation)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: transitionOpacity)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: videoScale)
                    .allowsHitTesting(index == currentRallyIndex) // Only allow interaction with current video
                }
            }
        }
        .clipped() // Prevent videos from showing outside bounds
        .gesture(swipeGesture(geometry: geometry))
    }


    // MARK: - Video Peek Helper Functions

    private func shouldShowVideo(index: Int) -> Bool {
        // Show current video and adjacent videos for bidirectional navigation
        // This creates a stack where current video is on top, with next/previous accessible
        let distance = abs(index - currentRallyIndex)
        return distance <= 1 // Show current, previous, and next
    }

    // MARK: - Video Stacking Functions

    private func getAdjacentVideoIndex() -> Int? {
        // Show next rally video underneath for peek effect
        let nextIndex = currentRallyIndex + 1
        if nextIndex < rallyVideoURLs.count {
            return nextIndex
        }
        return nil
    }

    // MARK: - Peek Frame Animation Calculations

    // MARK: - Deck Stacking Calculation Functions

    private func calculateDeckOffsetX(for index: Int, geometry: GeometryProxy) -> CGFloat {
        let indexFromCurrent = index - currentRallyIndex

        if index == currentRallyIndex {
            // Current video: follows horizontal drag for action feedback (left/right like/delete)
            return dragOffset.width
        } else {
            // Stacked videos: slight horizontal offset to show depth
            return CGFloat(indexFromCurrent) * 3.0 // 3px offset per layer
        }
    }

    private func calculateDeckOffsetY(for index: Int) -> CGFloat {
        let indexFromCurrent = index - currentRallyIndex

        if index == currentRallyIndex {
            // Current video: follows vertical drag for navigation (up to next rally)
            return dragOffset.height
        } else {
            // Stacked videos: slight vertical offset to show depth
            return CGFloat(indexFromCurrent) * 2.0 // 2px offset per layer
        }
    }

    private func calculateDeckScale(for index: Int) -> CGFloat {
        let indexFromCurrent = index - currentRallyIndex

        if index == currentRallyIndex {
            // Current video: normal scale, slight shrink during drag
            let dragProgress = abs(dragOffset.width) / 300.0 // Scale based on drag distance
            return 1.0 - (dragProgress * 0.05) // Slight shrink when being dragged off
        } else {
            // Stacked videos: slightly smaller to show they're underneath
            return 1.0 - (CGFloat(indexFromCurrent) * 0.02) // 2% smaller per layer
        }
    }

    private func calculateDeckRotation(for index: Int) -> Double {
        let indexFromCurrent = index - currentRallyIndex

        if index == currentRallyIndex {
            // Current video: rotates based on horizontal drag (like/delete feedback)
            return Double(dragOffset.width) * 0.05 // Subtle rotation during horizontal swipe
        } else {
            // Stacked videos: slight random rotation to show they're separate cards
            return Double(indexFromCurrent) * 0.5 // 0.5° rotation per layer
        }
    }

    private func calculateDeckOpacity(for index: Int) -> Double {
        let indexFromCurrent = index - currentRallyIndex

        if index == currentRallyIndex {
            // Current video: full opacity, fades slightly when being swiped
            let horizontalDragProgress = abs(dragOffset.width) / 300.0
            let verticalDragProgress = abs(dragOffset.height) / 300.0
            // Fade for navigation feedback
            return 1.0 - (horizontalDragProgress * 0.2) - (verticalDragProgress * 0.1)
        } else if abs(indexFromCurrent) == 1 {
            // Adjacent videos (next/previous): high opacity to show they're ready
            return 0.95
        } else {
            // Other videos: more transparent
            return max(0.3, 1.0 - (Double(abs(indexFromCurrent)) * 0.2))
        }
    }

    private func calculateDeckZIndex(for index: Int) -> Double {
        let indexFromCurrent = index - currentRallyIndex

        if index == currentRallyIndex {
            // Current video: highest z-index
            return 100.0
        } else if indexFromCurrent > 0 {
            // Next videos: lower z-index as they go further
            return 50.0 - Double(indexFromCurrent)
        } else {
            // Previous videos: even lower z-index
            return 25.0 + Double(indexFromCurrent) // indexFromCurrent is negative, so this decreases
        }
    }


    private func calculateHorizontalOffset(for index: Int, geometry: GeometryProxy) -> CGFloat {
        if index == currentRallyIndex {
            // Current video moves with swipe and animation
            return swipeOffset + dragOffset.width
        }

        return 0
    }

    private func calculateScale(for index: Int, geometry: GeometryProxy) -> CGFloat {
        if index == currentRallyIndex {
            return videoScale
        }

        return 0.95
    }

    private func calculateOpacity(for index: Int, geometry: GeometryProxy) -> CGFloat {
        if index == currentRallyIndex {
            return transitionOpacity
        }

        return 0.0
    }

    // MARK: - Swipe Gesture

    private func swipeGesture(geometry: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation

                // Calculate peek progress and direction
                updatePeekProgress(translation: value.translation, geometry: geometry)

                // Smooth feedback for both horizontal and vertical gestures
                let horizontalProgress = abs(dragOffset.width) / geometry.size.width
                let verticalProgress = abs(dragOffset.height) / geometry.size.height

                // Rotation follows horizontal movement with smooth interpolation
                swipeRotation = Double(dragOffset.width / geometry.size.width) * 15 // Reduced from 20 for smoother feel

                // Scale feedback based on gesture strength
                if abs(dragOffset.width) > 30 || abs(dragOffset.height) > 30 {
                    let combinedProgress = max(horizontalProgress, verticalProgress)
                    let scaleFactor = min(1.0, combinedProgress * 1.5)
                    videoScale = max(0.96, 1.0 - scaleFactor * 0.04) // Smoother scaling
                } else {
                    // Minimal feedback for small movements
                    videoScale = max(0.99, 1.0 - (horizontalProgress + verticalProgress) * 0.01)
                }

                // Resistance at navigation boundaries
                if !canGoNext && (dragOffset.height < -50 || abs(dragOffset.width) > 50) {
                    dragOffset.height *= 0.5 // Resistance when trying to swipe up on last card
                    dragOffset.width *= 0.5 // Resistance when trying to swipe left/right on last card
                }
                if !canGoPrevious && dragOffset.height > 50 {
                    dragOffset.height *= 0.5 // Resistance when trying to swipe down on first card
                }
            }
            .onEnded { value in
                isDragging = false

                let threshold: CGFloat = 100
                let actionThreshold: CGFloat = 120

                // Unified gesture handling for both orientations
                let verticalVelocity = value.velocity.height
                let verticalOffset = dragOffset.height
                let horizontalVelocity = value.velocity.width
                let horizontalOffset = dragOffset.width

                print("🎯 Gesture Debug:")
                print("   Vertical: velocity=\(verticalVelocity), offset=\(verticalOffset)")
                print("   Horizontal: velocity=\(horizontalVelocity), offset=\(horizontalOffset)")
                print("   Thresholds: nav=\(threshold), action=\(actionThreshold)")
                print("   CanGoNext: \(canGoNext), CanGoPrevious: \(canGoPrevious)")
                print("   Portrait: \(isPortrait)")

                // Analyze gesture direction and take appropriate action
                print("🧭 Gesture Analysis:")
                print("   Horizontal: velocity=\(horizontalVelocity), offset=\(horizontalOffset)")
                print("   Vertical: velocity=\(verticalVelocity), offset=\(verticalOffset)")

                // Determine the dominant direction with smoother transitions
                let horizontalMagnitude = max(abs(horizontalVelocity) / 10, abs(horizontalOffset))
                let verticalMagnitude = max(abs(verticalVelocity) / 10, abs(verticalOffset))
                let isHorizontalDominant = horizontalMagnitude > verticalMagnitude * 1.2 // Give horizontal slight preference

                // Check for horizontal swipes (left/right = peel off to next rally)
                if isHorizontalDominant && (abs(horizontalVelocity) > 250 || abs(horizontalOffset) > actionThreshold) {
                    print("🃏 Horizontal navigation detected")
                    if (horizontalOffset < -actionThreshold || horizontalOffset > actionThreshold) && canGoNext {
                        print("👈👉 Swipe LEFT/RIGHT - Peel off card to next rally")
                        navigateToNext()
                    } else if !canGoNext && currentRallyIndex == rallyVideoURLs.count - 1 {
                        print("🏁 Reached end of deck - showing export options")
                        showExportOptions = true
                    } else {
                        print("❌ Horizontal gesture blocked - no more cards in deck")
                    }
                }
                // Check for vertical swipes (up = next, down = previous) with better sensitivity
                else if abs(verticalVelocity) > 300 || abs(verticalOffset) > threshold {
                    print("📱 Vertical navigation detected")
                    if verticalOffset < -threshold && canGoNext {
                        print("⬆️ Swipe UP - Next rally")
                        navigateToNext()
                    } else if verticalOffset > threshold && canGoPrevious {
                        print("⬇️ Swipe DOWN - Previous rally")
                        navigateToPrevious()
                    } else if verticalOffset < -threshold && !canGoNext && currentRallyIndex == rallyVideoURLs.count - 1 {
                        print("🏁 Reached end of deck - showing export options")
                        showExportOptions = true
                    } else {
                        print("❌ Vertical gesture blocked - at boundary")
                    }
                } else {
                    print("❌ Gesture too weak for any action")
                }

                // Coordinate all animation resets with snappier spring timing
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0.05)) {
                    dragOffset = .zero
                    swipeRotation = 0.0 // Reset rotation when drag ends
                    videoScale = 1.0 // Reset scale when drag ends
                    peekProgress = 0.0 // Reset peek progress with same timing
                    currentPeekDirection = nil
                }

                // Cancel any ongoing frame loading
                cleanupPeekFrame()

                // Emit reset callback
                onPeekProgress?(0.0, nil)
            }
    }

    // MARK: - Peek Progress Handling

    private func updatePeekProgress(translation: CGSize, geometry: GeometryProxy) {
        // Define peek thresholds (start peeking after minimal movement)
        let peekStartThreshold: CGFloat = 20
        let actionThreshold: CGFloat = 120 // Existing action threshold

        // Calculate absolute distances
        let horizontalDistance = abs(translation.width)
        let verticalDistance = abs(translation.height)

        // Determine dominant direction
        let isVerticalDominant = verticalDistance > horizontalDistance

        var newPeekProgress: Double = 0.0
        var newPeekDirection: PeekDirection? = nil

        if isVerticalDominant && verticalDistance > peekStartThreshold {
            // Vertical gesture - rally navigation
            if translation.height > 0 && canGoPrevious {
                // Swipe down -> previous rally
                newPeekDirection = .previous
                let progressRange = actionThreshold - peekStartThreshold
                newPeekProgress = min(1.0, max(0.0, (verticalDistance - peekStartThreshold) / progressRange))
            } else if translation.height < 0 && canGoNext {
                // Swipe up -> next rally
                newPeekDirection = .next
                let progressRange = actionThreshold - peekStartThreshold
                newPeekProgress = min(1.0, max(0.0, (verticalDistance - peekStartThreshold) / progressRange))
            }
        } else if !isVerticalDominant && horizontalDistance > peekStartThreshold {
            // Horizontal gesture - actions
            if translation.width < 0 {
                // Swipe left -> remove action
                newPeekDirection = .next // "next" action (remove)
                let progressRange = actionThreshold - peekStartThreshold
                newPeekProgress = min(1.0, max(0.0, (horizontalDistance - peekStartThreshold) / progressRange))
            } else if translation.width > 0 {
                // Swipe right -> save action
                newPeekDirection = .previous // "previous" action (save)
                let progressRange = actionThreshold - peekStartThreshold
                newPeekProgress = min(1.0, max(0.0, (horizontalDistance - peekStartThreshold) / progressRange))
            }
        }

        // Update state if changed
        if newPeekProgress != peekProgress || newPeekDirection != currentPeekDirection {
            peekProgress = newPeekProgress
            currentPeekDirection = newPeekDirection

            // Load peek frame when direction changes or progress starts
            if newPeekDirection != nil && newPeekProgress > 0.0 {
                loadPeekFrameForDirection(newPeekDirection!)
            }

            // Emit callback if provided
            onPeekProgress?(peekProgress, currentPeekDirection)
        }
    }

    private func resetPeekProgress() {
        if peekProgress != 0.0 || currentPeekDirection != nil {
            // Animate peek progress reset with spring timing to match current video animations
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                peekProgress = 0.0
                currentPeekDirection = nil
            }

            // Cancel any ongoing frame loading
            cleanupPeekFrame()

            // Emit reset callback
            onPeekProgress?(0.0, nil)
        }
    }

    // MARK: - Peek Frame Loading

    private func loadPeekFrameForDirection(_ direction: PeekDirection) {
        // Cancel previous loading task
        peekFrameTask?.cancel()

        // Determine target rally index
        let targetIndex: Int
        switch direction {
        case .previous:
            targetIndex = currentRallyIndex - 1
        case .next:
            targetIndex = currentRallyIndex + 1
        }

        // Check if target index is valid
        guard targetIndex >= 0 && targetIndex < rallyVideoURLs.count else {
            // No adjacent rally available
            peekFrameImage = nil
            isLoadingPeekFrame = false
            return
        }

        let targetURL = rallyVideoURLs[targetIndex]

        // Check if we already have the frame for this URL
        if let cachedFrame = getCachedFrame(for: targetURL) {
            peekFrameImage = cachedFrame
            isLoadingPeekFrame = false
            return
        }

        // Start loading frame
        isLoadingPeekFrame = true
        peekFrameImage = nil

        peekFrameTask = Task { @MainActor in
            do {
                // Use high priority for peek frames to ensure responsiveness
                let frame = try await FrameExtractor.shared.extractFrame(from: targetURL, priority: .high)

                // Check if task was cancelled
                guard !Task.isCancelled else { return }

                // Update UI with loaded frame
                peekFrameImage = frame
                isLoadingPeekFrame = false

                print("🖼️ Loaded peek frame for rally \(targetIndex + 1)")

            } catch {
                // Check if task was cancelled
                guard !Task.isCancelled else { return }

                if case FrameExtractionError.memoryPressure = error {
                    print("📱 Peek frame loading cancelled due to memory pressure")
                } else {
                    print("⚠️ Failed to load peek frame for rally \(targetIndex + 1): \(error)")
                }
                peekFrameImage = nil
                isLoadingPeekFrame = false
            }
        }
    }

    private func getCachedFrame(for url: URL) -> UIImage? {
        // Since FrameExtractor has its own LRU cache, we can try to check if frame is already cached
        // For now, we'll let FrameExtractor handle all caching
        return nil
    }

    private func cleanupPeekFrame() {
        peekFrameTask?.cancel()
        peekFrameTask = nil
        peekFrameImage = nil
        isLoadingPeekFrame = false
    }


    // MARK: - Navigation

    private func navigateToNext() {
        guard canGoNext else { return }
        print("🔄 Navigating to NEXT rally: \(currentRallyIndex) -> \(currentRallyIndex + 1)")

        // Stop current video audio immediately
        pauseCurrentVideo()

        // Coordinate peek progress reset with navigation transition
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            peekProgress = 0.0
            currentPeekDirection = nil
            videoScale = 0.98
        }

        // Cancel any ongoing frame loading immediately
        cleanupPeekFrame()

        withAnimation(.spring(response: 0.5, dampingFraction: 0.75, blendDuration: 0.1)) {
            currentRallyIndex += 1
            dragOffset = .zero
        }

        // Return to normal scale with coordinated timing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                videoScale = 1.0
            }
        }

        // Emit final callback after navigation
        onPeekProgress?(0.0, nil)
    }

    private func navigateToPrevious() {
        guard canGoPrevious else { return }
        print("🔄 Navigating to PREVIOUS rally: \(currentRallyIndex) -> \(currentRallyIndex - 1)")

        // Stop current video audio immediately
        pauseCurrentVideo()

        // Coordinate peek progress reset with navigation transition
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            peekProgress = 0.0
            currentPeekDirection = nil
            videoScale = 0.98
        }

        // Cancel any ongoing frame loading immediately
        cleanupPeekFrame()

        withAnimation(.spring(response: 0.5, dampingFraction: 0.75, blendDuration: 0.1)) {
            currentRallyIndex -= 1
            dragOffset = .zero
        }

        // Return to normal scale with coordinated timing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                videoScale = 1.0
            }
        }

        // Emit final callback after navigation
        onPeekProgress?(0.0, nil)
    }

    // MARK: - Rally Actions

    private func performRemoveAction() {
        let rallyIndex = currentRallyIndex

        // Store the action for undo functionality (only if not already removed)
        if !removedRallies.contains(rallyIndex) {
            lastAction = (action: .remove, rallyIndex: rallyIndex)
        }

        withAnimation(.easeInOut(duration: 0.5)) {
            removedRallies.insert(rallyIndex)
            actionFeedback = ActionFeedback(type: .remove, message: "Rally Removed")
            showActionFeedback = true
        }

        // Auto-hide feedback after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                showActionFeedback = false
            }
        }

        // Navigate away from removed rally
        if canGoNext {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                navigateToNext()
            }
        } else if canGoPrevious {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                navigateToPrevious()
            }
        }

        print("🗑️ Rally \(rallyIndex + 1) marked for removal")
    }

    private func performSaveAction() {
        let rallyIndex = currentRallyIndex

        // Store the action for undo functionality (only if not already saved)
        if !savedRallies.contains(rallyIndex) {
            lastAction = (action: .save, rallyIndex: rallyIndex)
        }

        withAnimation(.easeInOut(duration: 0.5)) {
            savedRallies.insert(rallyIndex)
            removedRallies.remove(rallyIndex) // Remove from removed set if it was there
            actionFeedback = ActionFeedback(type: .save, message: "Rally Saved")
            showActionFeedback = true
        }

        // Auto-hide feedback after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                showActionFeedback = false
            }
        }

        print("💾 Rally \(rallyIndex + 1) marked as saved")
    }

    private func performTinderStyleAction(_ action: SwipeAction, direction: SwipeDirection) {
        let rallyIndex = currentRallyIndex
        currentAction = action
        isPerformingAction = true

        // Immediately reset peek progress with coordinated animation timing
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            peekProgress = 0.0
            currentPeekDirection = nil
        }

        // Calculate slide-off direction and rotation
        let slideDistance: CGFloat = UIScreen.main.bounds.width * 1.5
        let targetOffset = direction == .right ? slideDistance : -slideDistance
        let targetRotation = direction == .right ? 30.0 : -30.0

        // Animate video sliding off screen with Tinder-style rotation
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.1)) {
            swipeOffset = targetOffset
            swipeRotation = targetRotation
            transitionOpacity = 0.0
        }

        // Perform the actual action after animation starts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            switch action {
            case .save:
                savedRallies.insert(rallyIndex)
                removedRallies.remove(rallyIndex)
                actionFeedback = ActionFeedback(type: .save, message: "Rally Saved")
                print("💾 Rally \(rallyIndex + 1) marked as saved with Tinder animation")
            case .remove:
                removedRallies.insert(rallyIndex)
                actionFeedback = ActionFeedback(type: .remove, message: "Rally Removed")
                print("🗑️ Rally \(rallyIndex + 1) marked for removal with Tinder animation")
            }

            showActionFeedback = true
        }

        // Reset animation state and navigate to next rally with coordinated timing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // Use spring animation that matches our peek frame animations
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75, blendDuration: 0.1)) {
                swipeOffset = 0.0
                swipeRotation = 0.0
                transitionOpacity = 1.0
                isPerformingAction = false
                currentAction = nil
                showActionFeedback = false
            }

            // Cancel any ongoing frame loading
            cleanupPeekFrame()

            // Emit final reset callback
            onPeekProgress?(0.0, nil)

            // Navigate to next available rally
            if canGoNext {
                navigateToNext()
            } else if canGoPrevious {
                navigateToPrevious()
            }
        }
    }

    // MARK: - Rally Management

    /// Get the indices of rallies that should be kept (not removed)
    var activeRallyIndices: [Int] {
        Array(0..<rallyVideoURLs.count).filter { !removedRallies.contains($0) }
    }

    /// Get the indices of saved rallies
    var savedRallyIndices: [Int] {
        Array(savedRallies).sorted()
    }

    /// Export saved rallies as individual video files or stitched together
    func exportSavedRallies(asSingleVideo: Bool = false) async {
        guard !savedRallies.isEmpty else {
            print("⚠️ No rallies saved for export")
            return
        }

        print("📼 Exporting \(savedRallies.count) saved rallies (single video: \(asSingleVideo))")
        // TODO: Implement export functionality
        // This would involve:
        // 1. Getting the rally segments from processingMetadata
        // 2. Using VideoExporter to create individual files or stitch together
        // 3. Saving to user's photo library or Documents folder
    }

    /// Clear all rally management state
    func clearRallySelections() {
        withAnimation(.easeInOut(duration: 0.3)) {
            savedRallies.removeAll()
            removedRallies.removeAll()
        }
        print("🔄 Cleared all rally selections")
    }

    // MARK: - Navigation Overlay

    private var navigationOverlay: some View {
        VStack {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Circle())
                }
                .padding(.leading, 16)

                Spacer()

                // Rally counter with status
                HStack(spacing: 8) {
                    // Rally status indicator
                    if savedRallies.contains(currentRallyIndex) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.green)
                    } else if removedRallies.contains(currentRallyIndex) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.red)
                    }

                    Text("\(currentRallyIndex + 1) / \(rallyVideoURLs.count)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.4))
                .clipShape(Capsule())
                .padding(.trailing, 16)
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Action Buttons Overlay

    private var actionButtonsOverlay: some View {
        VStack {
            Spacer()

            HStack(spacing: 40) {
                // Remove button (trash icon)
                Button(action: {
                    performButtonAction(.remove)
                }) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .fill(Color.red)
                                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        )
                }
                .scaleEffect(removedRallies.contains(currentRallyIndex) ? 1.2 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: removedRallies.contains(currentRallyIndex))

                // Undo button
                Button(action: {
                    performUndoAction()
                }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .fill(Color.gray)
                                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        )
                }
                .opacity(lastAction != nil ? 1.0 : 0.4)
                .disabled(lastAction == nil)
                .animation(.easeInOut(duration: 0.2), value: lastAction != nil)

                // Save button (heart icon)
                Button(action: {
                    performButtonAction(.save)
                }) {
                    Image(systemName: savedRallies.contains(currentRallyIndex) ? "heart.fill" : "heart")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .fill(savedRallies.contains(currentRallyIndex) ? Color.pink : Color.green)
                                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        )
                }
                .scaleEffect(savedRallies.contains(currentRallyIndex) ? 1.2 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: savedRallies.contains(currentRallyIndex))
            }
            .padding(.bottom, isPortrait ? 100 : 20) // Lower position in landscape mode
            .animation(.easeInOut(duration: 0.3), value: isPortrait)
        }
    }

    // MARK: - Action Button Methods

    private func performButtonAction(_ action: SwipeAction) {
        let rallyIndex = currentRallyIndex

        // Store the action for undo functionality
        lastAction = (action: action, rallyIndex: rallyIndex)

        switch action {
        case .save:
            performSaveAction()
        case .remove:
            performRemoveAction()
        }
    }

    private func performUndoAction() {
        guard let lastActionData = lastAction else { return }

        let rallyIndex = lastActionData.rallyIndex

        withAnimation(.easeInOut(duration: 0.3)) {
            switch lastActionData.action {
            case .save:
                savedRallies.remove(rallyIndex)
                actionFeedback = ActionFeedback(type: .undo, message: "Save Undone")
            case .remove:
                removedRallies.remove(rallyIndex)
                actionFeedback = ActionFeedback(type: .undo, message: "Remove Undone")
            }

            showActionFeedback = true
        }

        // Clear the last action
        lastAction = nil

        // Auto-hide feedback after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                showActionFeedback = false
            }
        }

        print("↩️ Undid action: \(lastActionData.action) for rally \(rallyIndex + 1)")
    }

    // MARK: - Loading States

    private var loadingView: some View {
        VStack(spacing: 16) {
            if isExportingRallies {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Creating rally videos...")
                    .font(.headline)
                    .foregroundColor(.white)
            } else {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Loading rallies...")
                    .font(.headline)
                    .foregroundColor(.white)
            }
        }
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.red)

            Text("Error Loading Rallies")
                .font(.headline)
                .foregroundColor(.white)

            Text(errorMessage)
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                Task {
                    await loadRallyVideos()
                }
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var noRalliesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("No Rallies Found")
                .font(.headline)
                .foregroundColor(.white)

            Text("No rally segments were detected in this video.")
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    // MARK: - Data Loading

    private func loadRallyVideos() async {
        // Show loading state immediately
        await MainActor.run {
            isLoading = true
            hasError = false
        }

        guard let metadata = await loadProcessingMetadata() else { return }

        if metadata.rallySegments.isEmpty {
            await MainActor.run {
                hasError = false
                isLoading = false
            }
            return
        }

        // Move heavy operations to background queue to prevent UI blocking
        await Task.detached(priority: .userInitiated) {
            do {
                let asset = AVURLAsset(url: videoMetadata.originalURL)
                let exporter = VideoExporter()

                // Clean up old cache files before creating new ones
                exporter.cleanupRallyCache()

                // Log cache info for debugging
                let cacheInfo = exporter.getCacheInfo()
                print("📊 Rally cache: \(cacheInfo.count) files, \(cacheInfo.totalSize / 1024 / 1024) MB")

                await MainActor.run {
                    isExportingRallies = true
                }

                let urls = try await exporter.exportRallySegments(asset: asset, rallies: metadata.rallySegments)

                await MainActor.run {
                    self.rallyVideoURLs = urls
                    self.processingMetadata = metadata
                    self.isLoading = false
                    self.isExportingRallies = false
                    self.hasError = false
                }

            } catch {
                await MainActor.run {
                    self.hasError = true
                    self.isLoading = false
                    self.isExportingRallies = false
                    self.errorMessage = "Failed to create rally videos: \(error.localizedDescription)"
                }
            }
        }.value
    }

    private func loadProcessingMetadata() async -> ProcessingMetadata? {
        do {
            let metadata = try metadataStore.loadMetadata(for: videoMetadata.id)
            return metadata
        } catch {
            await MainActor.run {
                self.hasError = true
                self.isLoading = false
                self.errorMessage = "Failed to load video metadata: \(error.localizedDescription)"
            }
            return nil
        }
    }

    // MARK: - Visual Feedback

    private func actionFeedbackOverlay(feedback: ActionFeedback) -> some View {
        VStack {
            Spacer()

            HStack {
                Image(systemName: feedback.type.iconName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(feedback.type.color)

                Text(feedback.message)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(feedback.type.color, lineWidth: 2)
                    )
            )
            .scaleEffect(showActionFeedback ? 1.0 : 0.8)
            .opacity(showActionFeedback ? 1.0 : 0.0)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showActionFeedback)

            Spacer()
                .frame(height: 120) // Space above bottom for rally counter
        }
    }

    // MARK: - Cleanup

    private func pauseCurrentVideo() {
        // Force immediate pause of all audio to prevent overlap
        // This ensures clean audio transition between rallies
        print("🔇 Pausing current video audio for navigation")

        // Post notification to pause all active video players
        NotificationCenter.default.post(name: .pauseAllVideos, object: nil)
    }

    private func cleanupPlayers() {
        // Cleanup will be handled by TikTokVideoPlayer components
    }
}

// MARK: - TikTok Video Player Component

struct TikTokVideoPlayer: View {
    let url: URL
    let isActive: Bool
    let size: CGSize

    @StateObject private var playerManager = VideoPlayerManager()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    var body: some View {
        ZStack {
            Color.black

            if let player = playerManager.player {
                VideoPlayer(player: player)
                    .aspectRatio(contentMode: .fit)
                    .disabled(true) // Remove all video player controls
                    .clipped() // Clip video content to bounds
                    .animation(.easeInOut(duration: 0.3), value: verticalSizeClass)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped() // Double clipping to ensure no overflow
        .contentShape(Rectangle()) // Ensure tap gesture area is constrained
        .onTapGesture {
            playerManager.togglePlayPause()
        }
        .onAppear {
            playerManager.setupPlayer(url: url)
            if isActive {
                playerManager.playFromBeginning()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                playerManager.playFromBeginning()
            } else {
                playerManager.pause()
            }
        }
        .onDisappear {
            playerManager.cleanup()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pauseAllVideos)) { _ in
            // Immediately pause this player to prevent audio overlap
            playerManager.pause()
        }
    }
}

// MARK: - Video Player Manager

@MainActor
class VideoPlayerManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying: Bool = false
    private var notificationObserver: NSObjectProtocol?

    func setupPlayer(url: URL) {
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        // Auto-loop
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.player?.seek(to: .zero)
                self?.player?.play()
            }
        }
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func playFromBeginning() {
        player?.seek(to: .zero)
        player?.play()
        isPlaying = true
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func cleanup() {
        player?.pause()
        player = nil
        isPlaying = false

        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
    }
}

// MARK: - Action Feedback Types

struct ActionFeedback {
    let type: ActionType
    let message: String

    enum ActionType {
        case save
        case remove
        case undo

        var iconName: String {
            switch self {
            case .save:
                return "heart.fill"
            case .remove:
                return "trash.fill"
            case .undo:
                return "arrow.uturn.backward"
            }
        }

        var color: Color {
            switch self {
            case .save:
                return .green
            case .remove:
                return .red
            case .undo:
                return .orange
            }
        }
    }
}

// MARK: - Export Options View

struct ExportOptionsView: View {
    let savedRallies: [Int]
    let totalRallies: Int
    let processingMetadata: ProcessingMetadata?
    let videoMetadata: VideoMetadata
    @Binding var isExporting: Bool
    @Binding var exportProgress: Double
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var exportType: ExportType?

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                headerView

                if savedRallies.isEmpty {
                    noSavedRalliesView
                } else {
                    exportOptionsView
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle("Export Rallies")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                        onDismiss()
                    }
                }
            }
        }
        .sheet(item: $exportType) { type in
            ExportProgressView(
                exportType: type,
                savedRallies: savedRallies,
                processingMetadata: processingMetadata,
                videoMetadata: videoMetadata,
                isExporting: $isExporting,
                exportProgress: $exportProgress
            )
        }
    }

    private var headerView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Rally Review Complete!")
                .font(.title2)
                .fontWeight(.bold)

            Text("You've reviewed all \(totalRallies) rallies")
                .font(.body)
                .foregroundColor(.secondary)

            if !savedRallies.isEmpty {
                Text("💾 \(savedRallies.count) rallies saved")
                    .font(.headline)
                    .foregroundColor(.green)
                    .padding(.top, 8)
            }
        }
    }

    private var noSavedRalliesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.slash")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("No Rallies Saved")
                .font(.headline)
                .foregroundColor(.primary)

            Text("You didn't save any rallies to export. Go back and swipe right on rallies you want to keep!")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical, 32)
    }

    private var exportOptionsView: some View {
        VStack(spacing: 20) {
            Text("Choose Export Option")
                .font(.headline)
                .padding(.bottom, 8)

            // Individual Export Option
            ExportOptionCard(
                title: "Export Individual Videos",
                subtitle: "Save each rally as a separate video",
                icon: "square.stack.3d.up",
                color: .blue
            ) {
                exportType = .individual
            }

            // Stitched Export Option
            ExportOptionCard(
                title: "Export Combined Video",
                subtitle: "Stitch all saved rallies into one video",
                icon: "film.stack",
                color: .purple
            ) {
                exportType = .stitched
            }
        }
    }
}

// MARK: - Export Option Card

struct ExportOptionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(color)
                    .frame(width: 50, height: 50)
                    .background(color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(Color(UIColor.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(UIColor.separator), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Export Progress View

struct ExportProgressView: View {
    let exportType: ExportType
    let savedRallies: [Int]
    let processingMetadata: ProcessingMetadata?
    let videoMetadata: VideoMetadata
    @Binding var isExporting: Bool
    @Binding var exportProgress: Double

    @Environment(\.dismiss) private var dismiss
    @State private var exportStatus: ExportStatus = .preparing
    @State private var exportedCount = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                Spacer()

                progressIndicator

                statusText

                if exportStatus == .completed {
                    successView
                }

                Spacer()

                if exportStatus != .completed {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.headline)
                    .foregroundColor(.red)
                }
            }
            .padding(24)
            .navigationTitle(exportType.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            startExport()
        }
    }

    private var progressIndicator: some View {
        VStack(spacing: 16) {
            if exportStatus == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
            } else {
                ProgressView(value: exportProgress)
                    .progressViewStyle(CircularProgressViewStyle(tint: exportType.color))
                    .scaleEffect(2.0)
            }
        }
    }

    private var statusText: some View {
        VStack(spacing: 8) {
            Text(exportStatus.message)
                .font(.headline)
                .multilineTextAlignment(.center)

            if exportStatus == .exporting {
                Text("\(exportedCount) of \(savedRallies.count) rallies")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Text("Export completed successfully!")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.green)

            Button("Done") {
                dismiss()
            }
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .background(Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func startExport() {
        Task {
            await performExport()
        }
    }

    private func performExport() async {
        guard let metadata = processingMetadata else { return }

        await MainActor.run {
            isExporting = true
            exportStatus = .preparing
            exportProgress = 0.0
        }

        do {
            await MainActor.run {
                exportStatus = .exporting
            }

            let asset = AVURLAsset(url: videoMetadata.originalURL)
            let exporter = VideoExporter()
            let selectedSegments = savedRallies.compactMap { index in
                index < metadata.rallySegments.count ? metadata.rallySegments[index] : nil
            }

            if exportType == .individual {
                // Export individual videos
                for (index, segment) in selectedSegments.enumerated() {
                    let progress = Double(index) / Double(selectedSegments.count)
                    await MainActor.run {
                        exportProgress = progress
                        exportedCount = index
                    }

                    try await exporter.exportRallyToPhotoLibrary(asset: asset, rally: segment, index: index)
                }
            } else {
                // Export stitched video
                try await exporter.exportStitchedRalliesToPhotoLibrary(asset: asset, rallies: selectedSegments)
            }

            await MainActor.run {
                exportProgress = 1.0
                exportStatus = .completed
                isExporting = false
            }

        } catch {
            await MainActor.run {
                exportStatus = .failed(error.localizedDescription)
                isExporting = false
            }
        }
    }
}

// MARK: - Export Types and States

enum ExportType: Identifiable, CaseIterable {
    case individual
    case stitched

    var id: String { title }

    var title: String {
        switch self {
        case .individual: return "Individual Videos"
        case .stitched: return "Combined Video"
        }
    }

    var color: Color {
        switch self {
        case .individual: return .blue
        case .stitched: return .purple
        }
    }
}

enum ExportStatus: Equatable {
    case preparing
    case exporting
    case completed
    case failed(String)

    var message: String {
        switch self {
        case .preparing:
            return "Preparing export..."
        case .exporting:
            return "Exporting rallies..."
        case .completed:
            return "Export complete!"
        case .failed(let error):
            return "Export failed: \(error)"
        }
    }
}

// MARK: - Tinder-Style Animation Types

enum SwipeAction {
    case save
    case remove
}

enum SwipeDirection {
    case left
    case right
}

enum PeekDirection {
    case next     // Vertical down (next rally) or horizontal left (next action)
    case previous // Vertical up (previous rally) or horizontal right (previous action)
}

extension PeekDirection: CustomStringConvertible {
    var description: String {
        switch self {
        case .next: return "next"
        case .previous: return "previous"
        }
    }
}

