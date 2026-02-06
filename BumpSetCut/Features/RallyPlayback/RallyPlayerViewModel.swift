import SwiftUI
import AVFoundation

// MARK: - Rally Player ViewModel

@MainActor
@Observable
final class RallyPlayerViewModel {
    // MARK: - Input

    let videoMetadata: VideoMetadata

    // MARK: - Loading State

    private(set) var loadingState: RallyPlayerLoadingState = .loading
    private(set) var processingMetadata: ProcessingMetadata?
    private(set) var rallyVideoURLs: [URL] = []

    // MARK: - Video Duration

    private(set) var actualVideoDuration: Double = 0

    // MARK: - Navigation State

    private(set) var currentRallyIndex: Int = 0
    private(set) var previousRallyIndex: Int? = nil  // Track previous rally during transitions

    // MARK: - Stack State (Tinder-style card stack)

    private(set) var visibleCardIndices: [Int] = []
    private let forwardStackSize = 2   // Show 2 cards ahead
    private let backwardStackSize = 1  // Keep 1 card behind for reverse animation

    // MARK: - Rally Management

    private(set) var savedRallies: Set<Int> = []
    private(set) var removedRallies: Set<Int> = []
    private(set) var lastAction: RallyActionResult?

    // MARK: - Peek State

    private(set) var peekProgress: Double = 0.0
    private(set) var currentPeekDirection: RallyPeekDirection?
    private(set) var peekThumbnail: UIImage?

    // MARK: - Gesture State

    var dragOffset: CGSize = .zero
    var isDragging: Bool = false
    private(set) var bounceOffset: CGFloat = 0.0

    // MARK: - Zoom State

    var zoomScale: CGFloat = 1.0
    var zoomOffset: CGSize = .zero
    var baseZoomScale: CGFloat = 1.0
    var baseZoomOffset: CGSize = .zero
    var isZoomed: Bool { zoomScale > 1.01 }

    // MARK: - Transition State

    private(set) var isTransitioning: Bool = false
    private(set) var transitionDirection: NavigationDirection? = nil
    private(set) var swipeOffset: CGFloat = 0.0  // Horizontal swipe (for actions)
    private(set) var swipeOffsetY: CGFloat = 0.0  // Vertical swipe (for navigation)
    private(set) var swipeRotation: Double = 0.0
    private(set) var isPerformingAction: Bool = false

    // MARK: - Buffering State

    private(set) var isBuffering: Bool = false

    // MARK: - Action Feedback

    private(set) var actionFeedback: RallyActionFeedback?
    private(set) var showActionFeedback: Bool = false

    // MARK: - Trim State

    private(set) var isTrimmingMode: Bool = false
    var trimAdjustments: [Int: RallyTrimAdjustment] = [:]  // rallyIndex → adjustment
    var currentTrimBefore: Double = 0.0  // temp working value during trim
    var currentTrimAfter: Double = 0.0   // temp working value during trim

    // MARK: - Export State

    var showExportOptions: Bool = false
    private(set) var isExporting: Bool = false
    private(set) var exportProgress: Double = 0.0

    // MARK: - Services

    let playerCache = RallyPlayerCache()
    let thumbnailCache = RallyThumbnailCache()
    private let metadataStore = MetadataStore()

    // MARK: - Task Management

    private var activeTasks: [Task<Void, Never>] = []

    // MARK: - Rally Looping

    private var timeObserver: Any?
    private weak var timeObserverPlayer: AVPlayer?

    // MARK: - Computed Properties

    var canGoNext: Bool { currentRallyIndex < rallyVideoURLs.count - 1 }
    var canGoPrevious: Bool { currentRallyIndex > 0 }
    var currentRallyIsSaved: Bool { savedRallies.contains(currentRallyIndex) }
    var currentRallyIsRemoved: Bool { removedRallies.contains(currentRallyIndex) }
    var totalRallies: Int { rallyVideoURLs.count }
    var savedRalliesArray: [Int] { Array(savedRallies).sorted() }

    var currentRallyURL: URL? {
        guard currentRallyIndex < rallyVideoURLs.count else { return nil }
        return rallyVideoURLs[currentRallyIndex]
    }

    // MARK: - Stack Helpers

    /// Updates the visible card indices for the stack
    func updateVisibleStack() {
        var indices: [Int] = []

        // Add previous card if exists (for backward swipe)
        if currentRallyIndex > 0 {
            indices.append(currentRallyIndex - 1)
        }

        // Add current and next cards
        for offset in 0...forwardStackSize {
            let index = currentRallyIndex + offset
            if index < rallyVideoURLs.count {
                indices.append(index)
            }
        }
        visibleCardIndices = indices
    }

    /// Get stack position relative to current (-1 = previous, 0 = current, 1+ = next)
    func stackPosition(for rallyIndex: Int) -> Int {
        return rallyIndex - currentRallyIndex
    }

    // MARK: - Initialization

    init(videoMetadata: VideoMetadata) {
        self.videoMetadata = videoMetadata
    }

    // MARK: - Loading

    func loadRallies() async {
        loadingState = .loading

        do {
            // Load processing metadata
            let metadata = try metadataStore.loadMetadata(for: videoMetadata.id)
            processingMetadata = metadata

            // Load actual video duration from the asset
            let asset = AVURLAsset(url: videoMetadata.originalURL)
            actualVideoDuration = try await CMTimeGetSeconds(asset.load(.duration))

            // Use original video URL - rally segments are time ranges within this video
            guard !metadata.rallySegments.isEmpty else {
                loadingState = .empty
                return
            }

            // For each rally segment, create unique URLs using fragment identifiers
            // This allows the thumbnail cache to distinguish between rallies
            rallyVideoURLs = metadata.rallySegments.enumerated().map { index, _ in
                guard var components = URLComponents(url: videoMetadata.originalURL, resolvingAgainstBaseURL: false) else {
                    return videoMetadata.originalURL
                }
                components.fragment = "rally_\(index)"
                return components.url ?? videoMetadata.originalURL
            }

            // Configure thumbnail cache BEFORE setting loaded state to prevent race
            thumbnailCache.setRallySegments(metadata.rallySegments)

            // Keep loading state while we preload all videos
            // This shows the buffering screen until everything is ready

            // Setup initial player and stack
            if !rallyVideoURLs.isEmpty, let url = currentRallyURL {
                updateVisibleStack()
                playerCache.setCurrentPlayer(for: url)
                seekToCurrentRallyStart()  // Seek initial video to rally start

                // Preload ALL videos upfront for seamless transitions
                await preloadAllVideos()

                // Now everything is ready - show the UI
                loadingState = .loaded

                // Start playing first video with looping
                setupRallyLooping()
                playerCache.play()
            } else {
                loadingState = .empty
            }

        } catch {
            loadingState = .error(error.localizedDescription)
        }
    }

    // MARK: - Effective Rally Times (original + trim adjustments)

    func effectiveStartTime(for rallyIndex: Int) -> Double {
        guard let metadata = processingMetadata,
              rallyIndex < metadata.rallySegments.count else { return 0 }
        let segment = metadata.rallySegments[rallyIndex]
        let adj = trimAdjustments[rallyIndex]
        return max(0, segment.startTime - (adj?.before ?? 0))
    }

    func effectiveEndTime(for rallyIndex: Int) -> Double {
        guard let metadata = processingMetadata,
              rallyIndex < metadata.rallySegments.count else { return 0 }
        let segment = metadata.rallySegments[rallyIndex]
        let adj = trimAdjustments[rallyIndex]
        let maxEnd = actualVideoDuration > 0 ? actualVideoDuration : segment.endTime
        return min(maxEnd, segment.endTime + (adj?.after ?? 0))
    }

    private func seekToCurrentRallyStart() {
        guard let url = currentRallyURL else { return }
        let startTime = effectiveStartTime(for: currentRallyIndex)
        let cmTime = CMTimeMakeWithSeconds(startTime, preferredTimescale: 600)
        playerCache.seek(url: url, to: cmTime)
    }

    func setupRallyLooping() {
        removeRallyLooping()
        guard let player = playerCache.currentPlayer else { return }

        let endTime = effectiveEndTime(for: currentRallyIndex)
        let startTime = effectiveStartTime(for: currentRallyIndex)
        let endCMTime = CMTimeMakeWithSeconds(endTime, preferredTimescale: 600)
        let startCMTime = CMTimeMakeWithSeconds(startTime, preferredTimescale: 600)

        let interval = CMTimeMakeWithSeconds(0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isTrimmingMode else { return }
                if CMTimeCompare(time, endCMTime) >= 0 {
                    self.playerCache.currentPlayer?.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
        timeObserverPlayer = player
    }

    private func removeRallyLooping() {
        if let observer = timeObserver, let player = timeObserverPlayer {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        timeObserverPlayer = nil
    }

    // MARK: - Navigation

    func navigateToNext() {
        guard canGoNext else { return }
        navigateTo(index: currentRallyIndex + 1, direction: .down)
    }

    func navigateToPrevious() {
        guard canGoPrevious else { return }
        navigateTo(index: currentRallyIndex - 1, direction: .up)
    }

    func navigateTo(index: Int, direction: NavigationDirection) {
        guard index >= 0 && index < rallyVideoURLs.count else { return }
        guard !isTransitioning else { return }  // Prevent rapid navigation

        resetZoom()
        isTransitioning = true
        transitionDirection = direction

        // Track previous rally to keep it visible during transition
        previousRallyIndex = currentRallyIndex

        // Continue from current drag position for seamless animation
        // The old card was being dragged via dragOffset; now it becomes isSlidingOut
        // which uses swipeOffsetY, so transfer the drag position
        swipeOffsetY = dragOffset.height
        dragOffset = .zero

        // Animate old card sliding out in the swipe direction
        // Next (swipe up) → old card continues UP (-screenHeight)
        // Previous (swipe down) → old card continues DOWN (+screenHeight)
        let screenHeight = UIScreen.main.bounds.height
        let targetOffset: CGFloat = direction == .down ? -screenHeight : screenHeight

        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            swipeOffsetY = targetOffset
        }

        // Update state
        currentRallyIndex = index
        let url = rallyVideoURLs[index]

        updateVisibleStack()

        // Setup player (already preloaded and seeked from initial load)
        playerCache.setCurrentPlayer(for: url)
        seekToCurrentRallyStart()
        setupRallyLooping()

        // Start playing immediately - video is already buffered
        Task { @MainActor in
            // Brief delay to let animation start, then play
            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s

            playerCache.play()

            // Wait for slide animation to complete (spring response 0.4 + settling)
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s more (0.6s total)

            // Clear roles first - old card becomes invisible (opacity 0 at position -1),
            // new card becomes isTopCard (offset 0). swipeOffsetY no longer affects any card.
            previousRallyIndex = nil
            transitionDirection = nil
            isTransitioning = false

            // Reset offset on next frame (no card uses it anymore, so invisible)
            try? await Task.sleep(nanoseconds: 16_000_000)  // ~1 frame
            swipeOffsetY = 0
        }
    }

    enum NavigationDirection {
        case up, down
    }

    private func preloadAllVideos() async {
        guard let metadata = processingMetadata else { return }

        // Preload ALL video players upfront
        playerCache.preloadPlayers(for: rallyVideoURLs)

        // Seek each player to its rally start time and wait for ready
        for (index, url) in rallyVideoURLs.enumerated() {
            guard index < metadata.rallySegments.count else { continue }
            let segment = metadata.rallySegments[index]

            // Seek and wait for completion
            await playerCache.seekAsync(url: url, to: segment.startCMTime)

            // Wait for player to buffer (with timeout)
            let _ = await playerCache.waitForPlayerReady(for: url, timeout: 5.0)
        }

        // Preload all thumbnails for background cards
        thumbnailCache.preloadThumbnails(for: rallyVideoURLs)
    }

    private func preloadAdjacent() async {
        // Preload video players for adjacent rallies (TikTok-style smooth transitions)
        playerCache.preloadAdjacentRallies(currentIndex: currentRallyIndex, urls: rallyVideoURLs)

        // Pre-seek adjacent players to their rally start times and WAIT for completion
        guard let metadata = processingMetadata else { return }

        // Seek next rally and wait
        if currentRallyIndex + 1 < rallyVideoURLs.count && currentRallyIndex + 1 < metadata.rallySegments.count {
            let nextURL = rallyVideoURLs[currentRallyIndex + 1]
            let nextSegment = metadata.rallySegments[currentRallyIndex + 1]
            await playerCache.seekAsync(url: nextURL, to: nextSegment.startCMTime)
        }

        // Seek previous rally and wait
        if currentRallyIndex > 0 && currentRallyIndex - 1 < metadata.rallySegments.count {
            let prevURL = rallyVideoURLs[currentRallyIndex - 1]
            let prevSegment = metadata.rallySegments[currentRallyIndex - 1]
            await playerCache.seekAsync(url: prevURL, to: prevSegment.startCMTime)
        }

        // Preload thumbnails for all visible stack cards (background cards use thumbnails)
        let urlsToPreload = visibleCardIndices
            .filter { $0 != currentRallyIndex }  // Exclude current (uses video player)
            .compactMap { index -> URL? in
                guard index < rallyVideoURLs.count else { return nil }
                return rallyVideoURLs[index]
            }
        thumbnailCache.preloadThumbnails(for: urlsToPreload)
    }

    // MARK: - Actions

    func performAction(_ action: RallySwipeAction, direction: RallySwipeDirection, fromDragOffset: CGFloat = 0) {
        let rallyIndex = currentRallyIndex
        isPerformingAction = true

        resetZoom()

        // Pause player immediately to prevent audio bleeding
        playerCache.pause()

        // Transfer drag position to swipe offset seamlessly (total visual offset unchanged)
        swipeOffset = fromDragOffset
        swipeRotation = Double(fromDragOffset) / 30.0
        dragOffset = .zero
        peekProgress = 0.0
        currentPeekDirection = nil

        // Animate from current position to off-screen
        let slideDistance = UIScreen.main.bounds.width * 1.2
        let targetOffset = direction == .right ? slideDistance : -slideDistance
        let targetRotation = direction == .right ? 10.0 : -10.0

        withAnimation(.interpolatingSpring(stiffness: 200, damping: 28)) {
            swipeOffset = targetOffset
            swipeRotation = targetRotation
        }

        // Register action immediately
        switch action {
        case .save:
            savedRallies.insert(rallyIndex)
            removedRallies.remove(rallyIndex)
            actionFeedback = RallyActionFeedback(type: .save, message: "Rally Saved")
        case .remove:
            removedRallies.insert(rallyIndex)
            savedRallies.remove(rallyIndex)
            actionFeedback = RallyActionFeedback(type: .remove, message: "Rally Removed")
        }

        lastAction = RallyActionResult(action: action, rallyIndex: rallyIndex, direction: direction)
        showActionFeedback = true

        // Auto-dismiss feedback after 2 seconds
        let dismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            dismissActionFeedback()
        }
        activeTasks.append(dismissTask)

        // After card slides off-screen, swap to next
        let actionTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)

            // Reset all offsets instantly (old card is off-screen)
            swipeOffset = 0
            swipeOffsetY = 0
            swipeRotation = 0
            dragOffset = .zero

            if canGoNext {
                currentRallyIndex += 1
                let url = rallyVideoURLs[currentRallyIndex]
                updateVisibleStack()
                playerCache.setCurrentPlayer(for: url)
                seekToCurrentRallyStart()
                setupRallyLooping()
                playerCache.play()
            }

            isPerformingAction = false
        }
        activeTasks.append(actionTask)
    }

    func undoLastAction() {
        guard let action = lastAction else { return }
        guard !isPerformingAction else { return }

        isPerformingAction = true

        // Clear the action state
        switch action.action {
        case .save:
            savedRallies.remove(action.rallyIndex)
        case .remove:
            removedRallies.remove(action.rallyIndex)
        }

        // Set initial position off-screen (same side it was swiped to)
        let slideDistance = UIScreen.main.bounds.width * 1.2
        swipeOffset = action.direction == .right ? slideDistance : -slideDistance
        swipeRotation = action.direction == .right ? 10.0 : -10.0

        // Navigate back to the undone rally
        currentRallyIndex = action.rallyIndex
        updateVisibleStack()

        if let url = currentRallyURL {
            playerCache.setCurrentPlayer(for: url)
            seekToCurrentRallyStart()
            setupRallyLooping()

            Task {
                await preloadAdjacent()
            }

            playerCache.play()
        }

        // Animate card sliding back in
        withAnimation(.interpolatingSpring(stiffness: 200, damping: 28)) {
            swipeOffset = 0
            swipeRotation = 0
        }

        // Show feedback
        actionFeedback = RallyActionFeedback(type: .undo, message: "Action Undone")
        showActionFeedback = true
        lastAction = nil

        // Auto-dismiss feedback and reset state
        let dismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            dismissActionFeedback()
            isPerformingAction = false
        }
        activeTasks.append(dismissTask)
    }

    func dismissActionFeedback() {
        showActionFeedback = false
        actionFeedback = nil
    }

    func resetZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            zoomScale = 1.0
            zoomOffset = .zero
        }
        baseZoomScale = 1.0
        baseZoomOffset = .zero
    }

    private func resetSwipeState() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            swipeOffset = 0
            swipeOffsetY = 0
            swipeRotation = 0
            dragOffset = .zero
        }
    }

    // MARK: - Peek Preview

    func updatePeekProgress(translation: CGSize, geometry: GeometryProxy, isPortrait: Bool) {
        let primaryTranslation = isPortrait ? -translation.height : translation.width
        let dimension = isPortrait ? geometry.size.height : geometry.size.width
        let threshold = dimension * 0.15

        let rawProgress = abs(primaryTranslation) / threshold
        peekProgress = min(1.0, rawProgress)

        // Determine direction
        if isPortrait {
            currentPeekDirection = translation.height < 0 ? .next : .previous
        } else {
            currentPeekDirection = translation.width > 0 ? .previous : .next
        }

        // Load thumbnail for peek direction
        loadPeekThumbnail()
    }

    func resetPeekProgress() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            peekProgress = 0.0
            currentPeekDirection = nil
            peekThumbnail = nil
        }
    }

    private func loadPeekThumbnail() {
        guard let direction = currentPeekDirection else { return }

        let targetIndex = direction == .next ? currentRallyIndex + 1 : currentRallyIndex - 1
        guard targetIndex >= 0 && targetIndex < rallyVideoURLs.count else { return }

        let url = rallyVideoURLs[targetIndex]
        peekThumbnail = thumbnailCache.getThumbnail(for: url)
    }

    // MARK: - Trim Mode

    func enterTrimMode() {
        let existing = trimAdjustments[currentRallyIndex]
        currentTrimBefore = existing?.before ?? 0.0
        currentTrimAfter = existing?.after ?? 0.0
        isTrimmingMode = true
        playerCache.pause()
        // Seek to rally start so the user sees the starting frame
        seekToCurrentRallyStart()
    }

    func scrubTo(time: Double) {
        guard let url = currentRallyURL else { return }
        let cmTime = CMTimeMakeWithSeconds(time, preferredTimescale: 600)
        playerCache.seek(url: url, to: cmTime)
    }

    func confirmTrim() {
        // Always save the adjustment so re-entering trim shows the same positions
        trimAdjustments[currentRallyIndex] = RallyTrimAdjustment(
            before: currentTrimBefore, after: currentTrimAfter
        )
        isTrimmingMode = false
        seekToCurrentRallyStart()
        setupRallyLooping()
        playerCache.play()
    }

    func cancelTrim() {
        // Restore the values from before entering trim mode
        let existing = trimAdjustments[currentRallyIndex]
        currentTrimBefore = existing?.before ?? 0.0
        currentTrimAfter = existing?.after ?? 0.0
        isTrimmingMode = false
        seekToCurrentRallyStart()
        setupRallyLooping()
        playerCache.play()
    }

    // MARK: - Export

    func startExport(type: RallyExportType) {
        isExporting = true
        exportProgress = 0.0
        // Export logic handled in view/sheet
    }

    func updateExportProgress(_ progress: Double) {
        exportProgress = progress
    }

    func finishExport() {
        isExporting = false
        exportProgress = 0.0
        showExportOptions = false
    }

    // MARK: - Cleanup

    func cleanup() {
        // Cancel all pending tasks
        for task in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()

        removeRallyLooping()
        playerCache.cleanup()
        thumbnailCache.cleanup()
    }
}
