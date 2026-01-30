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

    // MARK: - Navigation State

    private(set) var currentRallyIndex: Int = 0

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

    // MARK: - Transition State

    private(set) var isTransitioning: Bool = false
    private(set) var swipeOffset: CGFloat = 0.0
    private(set) var swipeRotation: Double = 0.0
    private(set) var isPerformingAction: Bool = false

    // MARK: - Action Feedback

    private(set) var actionFeedback: RallyActionFeedback?
    private(set) var showActionFeedback: Bool = false

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

            loadingState = .loaded

            // Setup initial player and stack (non-blocking for fast load)
            if !rallyVideoURLs.isEmpty, let url = currentRallyURL {
                updateVisibleStack()
                playerCache.setCurrentPlayer(for: url)
                seekToCurrentRallyStart()  // Seek initial video to rally start

                // Start playing immediately (might buffer briefly)
                playerCache.play()

                // Preload adjacent videos in background (non-blocking)
                Task {
                    await preloadAdjacent()
                }
            }

        } catch {
            loadingState = .error(error.localizedDescription)
        }
    }

    private func seekToCurrentRallyStart() {
        guard let metadata = processingMetadata,
              let url = currentRallyURL,
              currentRallyIndex < metadata.rallySegments.count else { return }
        let segment = metadata.rallySegments[currentRallyIndex]
        playerCache.seek(url: url, to: segment.startCMTime)
    }

    // MARK: - Navigation

    func navigateToNext() {
        guard canGoNext else { return }
        navigateTo(index: currentRallyIndex + 1)
    }

    func navigateToPrevious() {
        guard canGoPrevious else { return }
        navigateTo(index: currentRallyIndex - 1)
    }

    func navigateTo(index: Int) {
        guard index >= 0 && index < rallyVideoURLs.count else { return }
        guard !isTransitioning else { return }  // Prevent rapid navigation

        isTransitioning = true

        // Update state
        currentRallyIndex = index
        let url = rallyVideoURLs[index]

        updateVisibleStack()

        // Setup player (should already exist from preload and be seeked to correct position)
        playerCache.setCurrentPlayer(for: url)

        // Start playback (thumbnail visible until video actually plays)
        Task { @MainActor in
            // Give player brief moment to check buffer, but don't wait long
            // Thumbnail will stay visible until video.rate > 0
            let _ = await playerCache.waitForPlayerReady(for: url, timeout: 0.5)

            // Start playing - custom player keeps thumbnail until actually playing
            playerCache.play()

            // Preload next batch in background AFTER starting playback
            await preloadAdjacent()

            isTransitioning = false
        }
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

    func performAction(_ action: RallySwipeAction, direction: RallySwipeDirection) {
        let rallyIndex = currentRallyIndex
        isPerformingAction = true

        // Pause player immediately to prevent audio bleeding
        playerCache.pause()

        // Reset peek
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            peekProgress = 0.0
            currentPeekDirection = nil
        }

        // Animate swipe off
        let slideDistance = UIScreen.main.bounds.width * 1.5
        let targetOffset = direction == .right ? slideDistance : -slideDistance
        let targetRotation = direction == .right ? 30.0 : -30.0

        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            swipeOffset = targetOffset
            swipeRotation = targetRotation
        }

        // Perform action after animation starts
        let actionTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)

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

            // Navigate to next after animation
            try? await Task.sleep(nanoseconds: 600_000_000)
            resetSwipeState()

            if canGoNext {
                navigateToNext()
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

        // Animate reverse swipe (from opposite direction)
        let slideDistance = UIScreen.main.bounds.width * 1.5
        let startOffset = action.direction == .right ? -slideDistance : slideDistance  // Opposite direction
        let startRotation = action.direction == .right ? -30.0 : 30.0

        // Set initial position off-screen (opposite side)
        swipeOffset = startOffset
        swipeRotation = startRotation

        // Navigate back to the undone rally
        currentRallyIndex = action.rallyIndex
        updateVisibleStack()

        if let url = currentRallyURL {
            playerCache.setCurrentPlayer(for: url)
            seekToCurrentRallyStart()

            // Preload adjacent in background
            Task {
                await preloadAdjacent()
            }

            playerCache.play()
        }

        // Animate card sliding back in
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
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

    private func resetSwipeState() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            swipeOffset = 0
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

        playerCache.cleanup()
        thumbnailCache.cleanup()
    }
}
