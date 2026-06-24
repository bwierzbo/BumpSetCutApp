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
    let mediaStore: MediaStore

    // MARK: - Loading State

    private(set) var loadingState: RallyPlayerLoadingState = .loading
    private(set) var processingMetadata: ProcessingMetadata?
    private(set) var rallyVideoURLs: [URL] = []
    private(set) var actualVideoDuration: Double = 0
    /// Upright display size of the source video (post-preferredTransform).
    /// All rallies share one source, so this is computed once at load and used
    /// to letterbox correctly (instead of inferring aspect from the thumbnail).
    private(set) var videoDisplaySize: CGSize?
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

    /// Remove completed or cancelled tasks from activeTasks to prevent unbounded growth.
    private func pruneCompletedTasks() {
        activeTasks.removeAll { $0.isCancelled }
    }

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

    // MARK: - Quick Share

    /// Exported temp clip ready to hand to the system share sheet.
    var shareURL: URL?
    /// True while the current rally is being exported for sharing.
    var isPreparingShare = false
    var shareErrorMessage: String?

    /// Export the current rally segment (trim-aware) to a temp clip and surface it
    /// for the native share sheet. Rallies are time-ranges in the original video, so
    /// a quick per-rally export is required before sharing.
    func shareCurrentRally() {
        guard !isPreparingShare else { return }
        let index = currentRallyIndex
        guard index < rallyVideoURLs.count else { return }
        let start = effectiveStartTime(for: index)
        let end = effectiveEndTime(for: index)
        guard end > start else { return }
        let originalURL = videoMetadata.originalURL
        let addWatermark = SubscriptionService.shared.shouldAddWatermark

        isPreparingShare = true
        let shareTask = Task {
            do {
                let asset = AVURLAsset(url: originalURL)
                let range = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600)
                )
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("rally_\(index + 1)_\(UUID().uuidString.prefix(6)).mp4")
                let url = try await VideoExporter().exportClip(
                    asset: asset, timeRange: range, to: temp, addWatermark: addWatermark
                )
                isPreparingShare = false
                shareURL = url
            } catch {
                isPreparingShare = false
                shareErrorMessage = error.localizedDescription
            }
        }
        // Track so a mid-export dismiss cancels the work via cleanup() instead of
        // leaving an export running with a strong self capture.
        activeTasks.append(shareTask)
        pruneCompletedTasks()
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
    var actionSwipeOffsetY: CGFloat { gesture.actionSwipeOffsetY }
    var dragAxis: RallyGestureState.DragAxis? {
        get { gesture.dragAxis }
        set { gesture.dragAxis = newValue }
    }
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
    var favoritedRallies: Set<Int> { actions.favoritedRallies }
    var actionHistory: [RallyActionResult] { actions.actionHistory }
    var currentRallyIsSaved: Bool { actions.isSaved(at: currentRallyIndex) }
    var currentRallyIsRemoved: Bool { actions.isRemoved(at: currentRallyIndex) }
    var currentRallyIsFavorited: Bool { actions.isFavorited(at: currentRallyIndex) }
    var savedRalliesArray: [Int] { actions.savedRalliesArray }
    var canUndo: Bool { actions.canUndo }
    var actionFeedback: RallyActionFeedback? { actions.actionFeedback }
    var showActionFeedback: Bool { actions.showActionFeedback }
    var isPerformingAction: Bool { actions.isPerformingAction }

    func dismissActionFeedback() { actions.dismissFeedback() }

    func saveAllRallies() { actions.saveAll(totalCount: rallyVideoURLs.count) }
    func deselectAllRallies() { actions.deselectAll() }

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
    var currentTrimRotation: Double {
        get { trim.currentTrimRotation }
        set { trim.currentTrimRotation = newValue }
    }
    var currentTrimZoom: Double {
        get { trim.currentTrimZoom }
        set { trim.currentTrimZoom = newValue }
    }
    var pendingPropagation: PendingPropagation? {
        get { trim.pendingPropagation }
        set { trim.pendingPropagation = newValue }
    }

    /// Last known rally-card size, kept fresh by the view's GeometryReader.
    /// Used to denormalize persisted pan (stored as a fraction of card size).
    private(set) var cardSize: CGSize = .zero
    func updateCardSize(_ size: CGSize) { cardSize = size }

    /// Rotation (in degrees) to apply at playback for the given rally.
    /// During trim mode for the current rally, reflects the live edit value.
    func rotationDegrees(for rallyIndex: Int) -> Double {
        if isTrimmingMode, rallyIndex == currentRallyIndex {
            return currentTrimRotation
        }
        return trim.rotation(for: rallyIndex)
    }

    /// Persisted zoom for a rally (used for non-current cards). The current card
    /// reads live zoom from the gesture state instead.
    func zoom(for rallyIndex: Int) -> CGFloat {
        CGFloat(trim.zoom(for: rallyIndex))
    }

    /// Persisted pan offset (in points) for a rally, denormalized by card size.
    func panOffset(for rallyIndex: Int) -> CGSize {
        let pan = trim.pan(for: rallyIndex)
        return CGSize(width: pan.width * cardSize.width, height: pan.height * cardSize.height)
    }

    /// Seed the transient gesture zoom from the current rally's persisted
    /// adjustment, so each rally rests at its saved framing.
    func seedZoomForCurrentRally() {
        let scale = zoom(for: currentRallyIndex)
        let offset = panOffset(for: currentRallyIndex)
        gesture.seedZoom(scale: scale, offset: offset)
    }

    /// True while the propagation prompt is showing (video stays paused/dimmed).
    var isAwaitingPropagationChoice: Bool {
        trim.pendingPropagation != nil
    }

    /// Resolve the propagation prompt. When `applyToRest` is true the confirmed
    /// rotation + zoom + pan are written to this rally and every following one.
    /// Either way the prompt is dismissed and playback resumes.
    func resolvePropagation(applyToRest: Bool) {
        if applyToRest {
            let i = currentRallyIndex
            let pan = trim.pan(for: i)
            let metadataVideoId = videoMetadata.originalVideoId ?? videoMetadata.id
            trim.applyAdjustmentForward(
                rotation: trim.rotation(for: i),
                zoom: trim.zoom(for: i),
                panX: pan.width,
                panY: pan.height,
                fromIndex: i,
                totalRallies: rallyVideoURLs.count,
                videoId: metadataVideoId,
                metadataStore: metadataStore
            )
        }
        trim.clearPendingPropagation()

        // Resume playback now that the user has answered the prompt.
        seekToCurrentRallyStart()
        setupRallyLooping()
        playerCache.play()
    }

    // MARK: - Initialization

    init(videoMetadata: VideoMetadata, mediaStore: MediaStore) {
        self.videoMetadata = videoMetadata
        self.mediaStore = mediaStore
    }

    // MARK: - Loading

    func loadRallies() async {
        // Idempotent: already loaded once for this video — keep current playback state.
        // Rotation and other view re-eval cycles must not seek back to the start.
        if processingMetadata != nil, case .loaded = loadingState {
            return
        }

        loadingState = .loading

        do {
            let metadataVideoId = videoMetadata.originalVideoId ?? videoMetadata.id
            let metadata = try metadataStore.loadMetadata(for: metadataVideoId)
            processingMetadata = metadata

            trim.loadSavedAdjustments(videoId: metadataVideoId, metadataStore: metadataStore)
            actions.loadSavedSelections(videoId: metadataVideoId, metadataStore: metadataStore)

            let asset = AVURLAsset(url: videoMetadata.originalURL)
            actualVideoDuration = try await CMTimeGetSeconds(asset.load(.duration))

            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize),
               let preferred = try? await track.load(.preferredTransform) {
                videoDisplaySize = RotationGeometry.uprightSize(naturalSize: natural, preferredTransform: preferred)
            }

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
                seedZoomForCurrentRally()
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

        // Transfer drag position to swipe offset for seamless animation
        gesture.swipeOffsetY = gesture.dragOffset.height
        gesture.dragOffset = .zero

        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            gesture.swipeOffsetY = targetOffset
        }

        navigation.advanceIndex(to: index, totalCount: rallyVideoURLs.count)

        // Rest at the destination rally's saved zoom/pan framing.
        seedZoomForCurrentRally()

        let url = rallyVideoURLs[index]
        playerCache.setCurrentPlayer(for: url)
        seekToCurrentRallyStart()
        setupRallyLooping()

        let navTask = Task { @MainActor in
            // Wait for the new player to be buffered before playing (replaces fixed 100ms sleep)
            let ready = await playerCache.waitForPlayerReady(for: url, timeout: 2.0)
            if !ready {
                // Fallback: brief delay to let the seek settle
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            playerCache.play()

            await preloadAdjacent()

            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            // Bail if cleanup() cancelled us during the sleep — `try?` swallows the
            // CancellationError, so without this check a cancelled transition still
            // mutates navigation/gesture state after the view is gone.
            if Task.isCancelled { return }
            navigation.completeTransition()

            try? await Task.sleep(nanoseconds: 16_000_000)  // ~1 frame
            if Task.isCancelled { return }
            gesture.swipeOffsetY = 0
        }
        activeTasks.append(navTask)
        pruneCompletedTasks()
    }

    // MARK: - Data Flywheel

    /// True when the user has opted into contributing training data — gates the
    /// "report a mistake" affordance in the rally UI.
    var isFlywheelEnabled: Bool { AppSettings.shared.enableDataFlywheel }

    /// Whether the user has reported any rally in this video — drives the flag
    /// indicator, which stays lit across the whole video once reported.
    var currentVideoIsReported: Bool {
        FlywheelCaptureService.shared.reportedCount(
            videoId: videoMetadata.originalVideoId ?? videoMetadata.id
        ) > 0
    }

    /// Report the current rally as a model mistake (explicit opt-in contribution).
    func reportCurrentRallyMistake(reason: String?) {
        let videoId = videoMetadata.originalVideoId ?? videoMetadata.id
        // Mark immediately so the indicator flips on sheet dismiss.
        FlywheelCaptureService.shared.markRallyReported(videoId: videoId, rallyIndex: currentRallyIndex)
        stageFlywheelCorrection(rallyIndex: currentRallyIndex, trigger: .reported, reason: reason)
    }

    /// Stage a flywheel contribution for a corrected/reported rally. No-op unless
    /// opted in or the rally has no backing segment.
    private func stageFlywheelCorrection(rallyIndex: Int, trigger: FlywheelTrigger, reason: String? = nil) {
        guard AppSettings.shared.enableDataFlywheel else { return }
        guard let segments = processingMetadata?.rallySegments,
              rallyIndex >= 0, rallyIndex < segments.count else { return }
        let segment = segments[rallyIndex]
        let videoId = videoMetadata.originalVideoId ?? videoMetadata.id
        let originalURL = videoMetadata.originalURL
        let task = Task {
            await FlywheelCaptureService.shared.stageCorrection(
                videoId: videoId, rallyIndex: rallyIndex, segment: segment,
                trigger: trigger, reason: reason, originalURL: originalURL
            )
        }
        activeTasks.append(task)
        pruneCompletedTasks()
    }

    // MARK: - Actions

    func performAction(_ action: RallySwipeAction, direction: RallySwipeDirection, fromDragOffset: CGFloat = 0) {
        actions.setPerformingAction(true)
        playerCache.pause()

        gesture.peekProgress = 0.0
        gesture.currentPeekDirection = nil
        gesture.dragOffset = .zero

        if direction == .up {
            // Vertical slide-out for favorite
            gesture.actionSwipeOffsetY = fromDragOffset
            gesture.swipeOffset = 0
            gesture.swipeRotation = 0

            let slideDistance = UIScreen.main.bounds.height * 1.2
            withAnimation(.interpolatingSpring(stiffness: 200, damping: 28)) {
                gesture.actionSwipeOffsetY = -slideDistance
            }
        } else {
            // Horizontal slide-out for save/remove
            gesture.swipeOffset = fromDragOffset
            gesture.swipeRotation = Double(fromDragOffset) / 30.0

            let slideDistance = UIScreen.main.bounds.width * 1.2
            let targetOffset = direction == .right ? slideDistance : -slideDistance
            let targetRotation = direction == .right ? 10.0 : -10.0

            withAnimation(.interpolatingSpring(stiffness: 200, damping: 28)) {
                gesture.swipeOffset = targetOffset
                gesture.swipeRotation = targetRotation
            }
        }

        let _ = actions.registerAction(action, rallyIndex: currentRallyIndex, direction: direction)

        // Data flywheel: a removed rally is a strong "model got it wrong" signal.
        if action == .remove {
            stageFlywheelCorrection(rallyIndex: currentRallyIndex, trigger: .userRemoved)
        }

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
            gesture.actionSwipeOffsetY = 0
            gesture.dragOffset = .zero

            if canGoNext {
                navigation.setIndex(currentRallyIndex + 1, totalCount: rallyVideoURLs.count)
                seedZoomForCurrentRally()
                let url = rallyVideoURLs[currentRallyIndex]
                playerCache.setCurrentPlayer(for: url)
                seekToCurrentRallyStart()
                setupRallyLooping()

                // Wait for buffer readiness before playing (eliminates stutter)
                let ready = await playerCache.waitForPlayerReady(for: url, timeout: 2.0)
                if !ready {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                playerCache.play()
                await preloadAdjacent()
            } else {
                playerCache.pause()
                showOverviewSheet = true
            }

            actions.setPerformingAction(false)
        }
        activeTasks.append(actionTask)
        pruneCompletedTasks()
    }

    func undoLastAction() {
        guard let action = actions.undoLast() else { return }

        if action.isTrimAction {
            let metadataVideoId = videoMetadata.originalVideoId ?? videoMetadata.id
            trim.restoreTrimAdjustment(action.previousTrim, for: action.rallyIndex, videoId: metadataVideoId, metadataStore: metadataStore)

            if currentRallyIndex != action.rallyIndex {
                navigation.setIndex(action.rallyIndex, totalCount: rallyVideoURLs.count)
                if let url = currentRallyURL {
                    playerCache.setCurrentPlayer(for: url)
                }
            }
            // Re-seed zoom from the restored adjustment.
            seedZoomForCurrentRally()
            seekToCurrentRallyStart()
            setupRallyLooping()
            playerCache.play()

            let dismissTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                actions.dismissFeedback()
            }
            activeTasks.append(dismissTask)
            pruneCompletedTasks()
            return
        }

        actions.setPerformingAction(true)

        if action.direction == .up {
            // Undo favorite: slide back from top
            let slideDistance = UIScreen.main.bounds.height * 1.2
            gesture.actionSwipeOffsetY = -slideDistance
        } else {
            let slideDistance = UIScreen.main.bounds.width * 1.2
            gesture.swipeOffset = action.direction == .right ? slideDistance : -slideDistance
            gesture.swipeRotation = action.direction == .right ? 10.0 : -10.0
        }

        navigation.setIndex(action.rallyIndex, totalCount: rallyVideoURLs.count)
        seedZoomForCurrentRally()

        if let url = currentRallyURL {
            playerCache.setCurrentPlayer(for: url)
            seekToCurrentRallyStart()
            setupRallyLooping()
            let preloadTask = Task { await preloadAdjacent() }
            activeTasks.append(preloadTask)
            pruneCompletedTasks()
            playerCache.play()
        }

        withAnimation(.interpolatingSpring(stiffness: 200, damping: 28)) {
            gesture.swipeOffset = 0
            gesture.swipeRotation = 0
            gesture.actionSwipeOffsetY = 0
        }

        let dismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            actions.dismissFeedback()
            actions.setPerformingAction(false)
        }
        activeTasks.append(dismissTask)
        pruneCompletedTasks()
    }

    // MARK: - Trim Mode

    func enterTrimMode() {
        trim.enterTrimMode(rallyIndex: currentRallyIndex)
        // Seed the gesture zoom from the saved framing so pinch/pan starts there.
        seedZoomForCurrentRally()
        playerCache.pause()
        seekToCurrentRallyStart()
    }

    func scrubTo(time: Double) {
        guard let url = currentRallyURL else { return }
        let cmTime = CMTimeMakeWithSeconds(time, preferredTimescale: 600)
        playerCache.seek(url: url, to: cmTime)
    }

    func confirmTrim() {
        // Capture the live pinch/pan from the gesture state into the trim values
        // (zoom is size-independent; pan is normalized to card size).
        trim.currentTrimZoom = Double(gesture.zoomScale)
        if cardSize.width > 0, cardSize.height > 0 {
            trim.currentTrimPanX = Double(gesture.zoomOffset.width / cardSize.width)
            trim.currentTrimPanY = Double(gesture.zoomOffset.height / cardSize.height)
        }

        let metadataVideoId = videoMetadata.originalVideoId ?? videoMetadata.id
        let previousTrim = trim.confirmTrim(rallyIndex: currentRallyIndex, videoId: metadataVideoId, metadataStore: metadataStore)

        actions.registerTrimAction(rallyIndex: currentRallyIndex, previousTrim: previousTrim)

        // Data flywheel: a trim corrects the model's rally boundaries.
        stageFlywheelCorrection(rallyIndex: currentRallyIndex, trigger: .userTrimmed)

        seekToCurrentRallyStart()
        setupRallyLooping()

        // If rotation/zoom changed, stay paused on the current frame and let the
        // propagation prompt drive playback resumption. Otherwise resume now.
        if trim.pendingPropagation == nil {
            playerCache.play()
        }

        let dismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            actions.dismissFeedback()
        }
        activeTasks.append(dismissTask)
        pruneCompletedTasks()
    }

    func cancelTrim() {
        trim.cancelTrim(rallyIndex: currentRallyIndex)
        // Restore the gesture zoom to the saved (pre-edit) framing.
        seedZoomForCurrentRally()
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

    // MARK: - Copy Favorites to Library

    func copyFavoritesToLibrary() async {
        guard !favoritedRallies.isEmpty,
              let metadata = processingMetadata else { return }

        let asset = AVURLAsset(url: videoMetadata.originalURL)
        let exporter = VideoExporter()
        let fileManager = FileManager.default
        let baseDir = StorageManager.getPersistentStorageDirectory()
        let favoritesDir = baseDir.appendingPathComponent(LibraryType.favorites.rootPath, isDirectory: true)
        try? fileManager.createDirectory(at: favoritesDir, withIntermediateDirectories: true)

        for index in favoritedRallies.sorted() {
            guard index < metadata.rallySegments.count else { continue }
            let segment = metadata.rallySegments[index]
            do {
                let startTime = CMTime(seconds: segment.startTime, preferredTimescale: 600)
                let endTime = CMTime(seconds: segment.endTime, preferredTimescale: 600)
                let timeRange = CMTimeRange(start: startTime, end: endTime)

                // Export to temp
                let tempURL = fileManager.temporaryDirectory
                    .appendingPathComponent("fav_rally_\(index)_\(UUID().uuidString).mp4")
                let exportedURL = try await exporter.exportClip(asset: asset, timeRange: timeRange, to: tempURL)

                // Move to persistent storage
                let destFileName = UUID().uuidString + ".mp4"
                let destURL = favoritesDir.appendingPathComponent(destFileName)
                try fileManager.moveItem(at: exportedURL, to: destURL)

                // Register in MediaStore with source backlink for sync
                let _ = mediaStore.addVideo(
                    at: destURL,
                    toFolder: LibraryType.favorites.rootPath,
                    customName: "\(videoMetadata.displayName) - Rally \(index + 1)",
                    sourceVideoId: videoMetadata.id,
                    sourceRallyIndex: index
                )
            } catch {
                print("Failed to export favorite rally \(index): \(error)")
            }
        }
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
