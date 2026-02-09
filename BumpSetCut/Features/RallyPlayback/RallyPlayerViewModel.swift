import SwiftUI
import AVFoundation

// MARK: - Rally Player ViewModel

/// Coordinator that composes focused sub-services for rally playback.
/// Views consume this VM directly -- sub-services are internal implementation details.
@MainActor
@Observable
final class RallyPlayerViewModel {
    // MARK: - Input

    let videoMetadata: VideoMetadata

    // MARK: - Loading State

    private(set) var loadingState: RallyPlayerLoadingState = .loading
    private(set) var processingMetadata: ProcessingMetadata?
    private(set) var rallyVideoURLs: [URL] = []
    private(set) var actualVideoDuration: Double = 0
    private(set) var isBuffering: Bool = false

    // MARK: - Overview & Export State

    var showOverviewSheet: Bool = false
    var showExportOptions: Bool = false
    private(set) var isExporting: Bool = false
    private(set) var exportProgress: Double = 0.0

    // MARK: - Sub-Services

    private let navigation = RallyNavigationService()
    private let gesture = RallyGestureState()
    private let actions = RallyActionManager()
    let trim = RallyTrimManager()
    private let lifecycle = RallyPlayerLifecycle()

    // MARK: - External Services

    let playerCache = RallyPlayerCache()
    let thumbnailCache = RallyThumbnailCache()
    private let metadataStore = MetadataStore()

    // MARK: - Task Management

    private var activeTasks: [Task<Void, Never>] = []

    // MARK: - Navigation Forwarding

    var currentRallyIndex: Int { navigation.currentRallyIndex }
    var previousRallyIndex: Int? { navigation.previousRallyIndex }
    var visibleCardIndices: [Int] { navigation.visibleCardIndices }
    var isTransitioning: Bool { navigation.isTransitioning }
    var transitionDirection: NavigationDirection? { navigation.transitionDirection }
    var canGoNext: Bool { navigation.canGoNext(totalCount: rallyVideoURLs.count) }
    var canGoPrevious: Bool { navigation.canGoPrevious() }
    var totalRallies: Int { rallyVideoURLs.count }

    var currentRallyURL: URL? {
        guard currentRallyIndex < rallyVideoURLs.count else { return nil }
        return rallyVideoURLs[currentRallyIndex]
    }

    func stackPosition(for rallyIndex: Int) -> Int {
        navigation.stackPosition(for: rallyIndex)
    }

    func updateVisibleStack() {
        navigation.updateVisibleStack(totalCount: rallyVideoURLs.count)
    }

    // MARK: - Gesture Forwarding

    var dragOffset: CGSize {
        get { gesture.dragOffset }
        set { gesture.dragOffset = newValue }
    }
    var isDragging: Bool {
        get { gesture.isDragging }
        set { gesture.isDragging = newValue }
    }
    var zoomScale: CGFloat {
        get { gesture.zoomScale }
        set { gesture.zoomScale = newValue }
    }
    var zoomOffset: CGSize {
        get { gesture.zoomOffset }
        set { gesture.zoomOffset = newValue }
    }
    var baseZoomScale: CGFloat {
        get { gesture.baseZoomScale }
        set { gesture.baseZoomScale = newValue }
    }
    var baseZoomOffset: CGSize {
        get { gesture.baseZoomOffset }
        set { gesture.baseZoomOffset = newValue }
    }
    var isZoomed: Bool { gesture.isZoomed }
    var swipeOffset: CGFloat { gesture.swipeOffset }
    var swipeOffsetY: CGFloat { gesture.swipeOffsetY }
    var swipeRotation: Double { gesture.swipeRotation }
    var peekProgress: Double { gesture.peekProgress }
    var currentPeekDirection: RallyPeekDirection? { gesture.currentPeekDirection }
    var peekThumbnail: UIImage? { gesture.peekThumbnail }

    func resetZoom() { gesture.resetZoom() }

    func updatePeekProgress(translation: CGSize, geometry: GeometryProxy, isPortrait: Bool) {
        let dimension = isPortrait ? geometry.size.height : geometry.size.width
        gesture.updatePeekProgress(translation: translation, dimension: dimension, isPortrait: isPortrait)
        gesture.loadPeekThumbnail(currentIndex: currentRallyIndex, urls: rallyVideoURLs, thumbnailCache: thumbnailCache)
    }

    func resetPeekProgress() { gesture.resetPeekProgress() }

    // MARK: - Action Forwarding

    var savedRallies: Set<Int> { actions.savedRallies }
    var removedRallies: Set<Int> { actions.removedRallies }
    var actionHistory: [RallyActionResult] { actions.actionHistory }
    var currentRallyIsSaved: Bool { actions.isSaved(at: currentRallyIndex) }
    var currentRallyIsRemoved: Bool { actions.isRemoved(at: currentRallyIndex) }
    var savedRalliesArray: [Int] { actions.savedRalliesArray }
    var canUndo: Bool { actions.canUndo }
    var actionFeedback: RallyActionFeedback? { actions.actionFeedback }
    var showActionFeedback: Bool { actions.showActionFeedback }
    var isPerformingAction: Bool { actions.isPerformingAction }

    func dismissActionFeedback() { actions.dismissFeedback() }

    // MARK: - Trim Forwarding

    var isTrimmingMode: Bool { trim.isTrimmingMode }
    var trimAdjustments: [Int: RallyTrimAdjustment] {
        get { trim.trimAdjustments }
        set { trim.trimAdjustments = newValue }
    }
    var currentTrimBefore: Double {
        get { trim.currentTrimBefore }
        set { trim.currentTrimBefore = newValue }
    }
    var currentTrimAfter: Double {
        get { trim.currentTrimAfter }
        set { trim.currentTrimAfter = newValue }
    }

    // MARK: - Initialization

    init(videoMetadata: VideoMetadata) {
        self.videoMetadata = videoMetadata
    }

    // MARK: - Loading

    func loadRallies() async {
        loadingState = .loading

        do {
            let metadata = try metadataStore.loadMetadata(for: videoMetadata.id)
            processingMetadata = metadata

            trim.loadSavedAdjustments(videoId: videoMetadata.id, metadataStore: metadataStore)

            let asset = AVURLAsset(url: videoMetadata.originalURL)
            actualVideoDuration = try await CMTimeGetSeconds(asset.load(.duration))

            guard !metadata.rallySegments.isEmpty else {
                loadingState = .empty
                return
            }

            rallyVideoURLs = metadata.rallySegments.enumerated().map { index, _ in
                guard var components = URLComponents(url: videoMetadata.originalURL, resolvingAgainstBaseURL: false) else {
                    return videoMetadata.originalURL
                }
                components.fragment = "rally_\(index)"
                return components.url ?? videoMetadata.originalURL
            }

            thumbnailCache.setRallySegments(metadata.rallySegments)

            if !rallyVideoURLs.isEmpty, let url = currentRallyURL {
                updateVisibleStack()
                playerCache.setCurrentPlayer(for: url)
                seekToCurrentRallyStart()

                let windowIndices = navigation.playerWindowIndices(totalCount: rallyVideoURLs.count)
                await lifecycle.preloadWindowedVideos(
                    indices: windowIndices, urls: rallyVideoURLs,
                    segments: metadata.rallySegments, playerCache: playerCache,
                    thumbnailCache: thumbnailCache, allURLs: rallyVideoURLs
                )

                loadingState = .loaded
                setupRallyLooping()
                playerCache.play()
            } else {
                loadingState = .empty
            }
        } catch {
            loadingState = .error(error.localizedDescription)
        }
    }

    // MARK: - Effective Rally Times

    func effectiveStartTime(for rallyIndex: Int) -> Double {
        guard let metadata = processingMetadata else { return 0 }
        return trim.effectiveStartTime(for: rallyIndex, segments: metadata.rallySegments)
    }

    func effectiveEndTime(for rallyIndex: Int) -> Double {
        guard let metadata = processingMetadata else { return 0 }
        return trim.effectiveEndTime(for: rallyIndex, segments: metadata.rallySegments, videoDuration: actualVideoDuration)
    }

    // MARK: - Player Lifecycle Helpers

    private func seekToCurrentRallyStart() {
        guard let url = currentRallyURL else { return }
        let startTime = effectiveStartTime(for: currentRallyIndex)
        lifecycle.seekToRallyStart(url: url, startTime: startTime, playerCache: playerCache)
    }

    func setupRallyLooping() {
        guard let player = playerCache.currentPlayer else { return }
        let endTime = effectiveEndTime(for: currentRallyIndex)
        let startTime = effectiveStartTime(for: currentRallyIndex)
        lifecycle.setupLooping(
            player: player, startTime: startTime, endTime: endTime,
            isTrimmingMode: { [weak self] in self?.isTrimmingMode ?? false },
            playerCache: playerCache
        )
    }

    private func preloadAdjacent() async {
        guard let metadata = processingMetadata else { return }
        let windowIndices = navigation.playerWindowIndices(totalCount: rallyVideoURLs.count)
        let windowURLs = navigation.playerWindowURLs(urls: rallyVideoURLs)
        await lifecycle.preloadAdjacent(
            currentIndex: currentRallyIndex, indices: windowIndices,
            urls: rallyVideoURLs, segments: metadata.rallySegments,
            windowURLs: windowURLs, playerCache: playerCache,
            thumbnailCache: thumbnailCache, visibleCardIndices: visibleCardIndices
        )
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

    func jumpToRally(_ index: Int) {
        guard index != currentRallyIndex else { return }
        playerCache.pause()
        let direction: NavigationDirection = index < currentRallyIndex ? .up : .down
        navigateTo(index: index, direction: direction)
    }

    var savedRallyShareInfo: [Int: RallyShareInfo] {
        guard let metadata = processingMetadata else { return [:] }
        var dict: [Int: RallyShareInfo] = [:]
        for index in savedRalliesArray {
            guard index < metadata.rallySegments.count else { continue }
            let segment = metadata.rallySegments[index]
            dict[index] = RallyShareInfo(
                startTime: segment.startTime,
                endTime: segment.endTime,
                metadata: RallyHighlightMetadata(
                    duration: segment.duration,
                    confidence: segment.confidence,
                    quality: segment.quality,
                    detectionCount: segment.detectionCount
                )
            )
        }
        return dict
    }

    func navigateTo(index: Int, direction: NavigationDirection) {
        guard let targetOffset = navigation.beginTransition(to: index, totalCount: rallyVideoURLs.count, direction: direction) else { return }

        gesture.resetZoom()

        // Transfer drag position to swipe offset for seamless animation
        gesture.swipeOffsetY = gesture.dragOffset.height
        gesture.dragOffset = .zero

        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            gesture.swipeOffsetY = targetOffset
        }

        navigation.advanceIndex(to: index, totalCount: rallyVideoURLs.count)

        let url = rallyVideoURLs[index]
        playerCache.setCurrentPlayer(for: url)
        seekToCurrentRallyStart()
        setupRallyLooping()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
            playerCache.play()

            await preloadAdjacent()

            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s

            navigation.completeTransition()

            try? await Task.sleep(nanoseconds: 16_000_000)  // ~1 frame
            gesture.swipeOffsetY = 0
        }
    }

    // MARK: - Actions

    func performAction(_ action: RallySwipeAction, direction: RallySwipeDirection, fromDragOffset: CGFloat = 0) {
        actions.setPerformingAction(true)
        gesture.resetZoom()
        playerCache.pause()

        // Transfer drag position to swipe offset seamlessly
        gesture.swipeOffset = fromDragOffset
        gesture.swipeRotation = Double(fromDragOffset) / 30.0
        gesture.dragOffset = .zero
        gesture.peekProgress = 0.0
        gesture.currentPeekDirection = nil

        let slideDistance = UIScreen.main.bounds.width * 1.2
        let targetOffset = direction == .right ? slideDistance : -slideDistance
        let targetRotation = direction == .right ? 10.0 : -10.0

        withAnimation(.interpolatingSpring(stiffness: 200, damping: 28)) {
            gesture.swipeOffset = targetOffset
            gesture.swipeRotation = targetRotation
        }

        let _ = actions.registerAction(action, rallyIndex: currentRallyIndex, direction: direction)

        let dismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            actions.dismissFeedback()
        }
        activeTasks.append(dismissTask)

        let actionTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)

            gesture.swipeOffset = 0
            gesture.swipeOffsetY = 0
            gesture.swipeRotation = 0
            gesture.dragOffset = .zero

            if canGoNext {
                navigation.setIndex(currentRallyIndex + 1, totalCount: rallyVideoURLs.count)
                let url = rallyVideoURLs[currentRallyIndex]
                playerCache.setCurrentPlayer(for: url)
                seekToCurrentRallyStart()
                setupRallyLooping()
                playerCache.play()
                await preloadAdjacent()
            } else {
                playerCache.pause()
                showOverviewSheet = true
            }

            actions.setPerformingAction(false)
        }
        activeTasks.append(actionTask)
    }

    func undoLastAction() {
        guard let action = actions.undoLast() else { return }
        actions.setPerformingAction(true)

        let slideDistance = UIScreen.main.bounds.width * 1.2
        gesture.swipeOffset = action.direction == .right ? slideDistance : -slideDistance
        gesture.swipeRotation = action.direction == .right ? 10.0 : -10.0

        navigation.setIndex(action.rallyIndex, totalCount: rallyVideoURLs.count)

        if let url = currentRallyURL {
            playerCache.setCurrentPlayer(for: url)
            seekToCurrentRallyStart()
            setupRallyLooping()
            Task { await preloadAdjacent() }
            playerCache.play()
        }

        withAnimation(.interpolatingSpring(stiffness: 200, damping: 28)) {
            gesture.swipeOffset = 0
            gesture.swipeRotation = 0
        }

        let dismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            actions.dismissFeedback()
            actions.setPerformingAction(false)
        }
        activeTasks.append(dismissTask)
    }

    // MARK: - Trim Mode

    func enterTrimMode() {
        trim.enterTrimMode(rallyIndex: currentRallyIndex)
        playerCache.pause()
        seekToCurrentRallyStart()
    }

    func scrubTo(time: Double) {
        guard let url = currentRallyURL else { return }
        let cmTime = CMTimeMakeWithSeconds(time, preferredTimescale: 600)
        playerCache.seek(url: url, to: cmTime)
    }

    func confirmTrim() {
        trim.confirmTrim(rallyIndex: currentRallyIndex, videoId: videoMetadata.id, metadataStore: metadataStore)
        seekToCurrentRallyStart()
        setupRallyLooping()
        playerCache.play()
    }

    func cancelTrim() {
        trim.cancelTrim(rallyIndex: currentRallyIndex)
        seekToCurrentRallyStart()
        setupRallyLooping()
        playerCache.play()
    }

    // MARK: - Export

    func startExport(type: RallyExportType) {
        isExporting = true
        exportProgress = 0.0
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
        for task in activeTasks { task.cancel() }
        activeTasks.removeAll()
        lifecycle.removeLooping()
        playerCache.cleanup()
        thumbnailCache.cleanup()
    }
}
