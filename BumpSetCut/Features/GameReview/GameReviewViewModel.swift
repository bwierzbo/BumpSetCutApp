//
//  GameReviewViewModel.swift
//  BumpSetCut
//
//  Coordinator for Game Review mode: sequential rally playback with scoring.
//

import SwiftUI
import AVFoundation

@MainActor
@Observable
final class GameReviewViewModel {
    // MARK: - Input

    let videoMetadata: VideoMetadata

    // MARK: - Loading State

    private(set) var loadingState: RallyPlayerLoadingState = .loading
    private(set) var processingMetadata: ProcessingMetadata?
    /// The rally segments used for this game review (may be a subset of all segments).
    private(set) var activeSegments: [RallySegment] = []
    private(set) var rallyVideoURLs: [URL] = []
    private(set) var actualVideoDuration: Double = 0

    // MARK: - Scoring State

    private(set) var scoreEngine: GameScoreEngine
    private(set) var decisions: [RallyScoringDecision] = []
    private(set) var serveInferences: [ServeInference] = []
    private(set) var setup: GameSetup

    // MARK: - Correction State

    var showCorrectionSheet: Bool = false

    // MARK: - Summary State

    var showSummary: Bool = false

    // MARK: - Export State

    private(set) var isExporting: Bool = false
    private(set) var exportProgress: Double = 0.0
    var exportedURL: URL?
    var showShareSheet: Bool = false
    var exportError: String?

    // MARK: - Sub-Services (reused from RallyPlayback)

    private let navigation = RallyNavigationService()
    let trim = RallyTrimManager()
    private let lifecycle = RallyPlayerLifecycle()
    let playerCache = RallyPlayerCache()
    let thumbnailCache = RallyThumbnailCache()
    private let metadataStore = MetadataStore()

    // MARK: - Task Management

    private var activeTasks: [Task<Void, Never>] = []

    // MARK: - Navigation Forwarding

    var currentRallyIndex: Int { navigation.currentRallyIndex }
    var totalRallies: Int { rallyVideoURLs.count }
    var canGoNext: Bool { navigation.canGoNext(totalCount: rallyVideoURLs.count) }

    var currentRallyURL: URL? {
        guard currentRallyIndex < rallyVideoURLs.count else { return nil }
        return rallyVideoURLs[currentRallyIndex]
    }

    // MARK: - Scoring Convenience

    var currentScore: GameScore { scoreEngine.score }
    var currentServer: CourtSide { scoreEngine.currentServer }
    var nearMappedTo: CourtSide { scoreEngine.nearMappedTo }

    var currentServeInference: ServeInference? {
        serveInferences.first { $0.rallyIndex == currentRallyIndex }
    }

    var assumedWinner: CourtSide {
        // The winner of this rally serves the next one.
        // If we can infer who serves the next rally from ball size trend,
        // use that to work backwards and determine who won this rally.
        if currentRallyIndex + 1 < serveInferences.count {
            let nextInference = serveInferences[currentRallyIndex + 1]
            if nextInference.method == .bboxTrend, nextInference.confidence > 0.3 {
                return nextInference.inferredServer
            }
        }
        // Fallback for last rally or weak signal: assume server wins
        return currentServeInference?.inferredServer ?? setup.firstServer
    }

    // MARK: - Initialization

    init(videoMetadata: VideoMetadata, setup: GameSetup) {
        self.videoMetadata = videoMetadata
        self.setup = setup
        self.scoreEngine = GameScoreEngine(setup: setup)
    }

    /// Initialize from a saved state (resume)
    init(videoMetadata: VideoMetadata, state: GameReviewState) {
        self.videoMetadata = videoMetadata
        self.setup = state.setup
        self.decisions = state.decisions
        self.scoreEngine = GameScoreEngine.replay(decisions: state.decisions, setup: state.setup)
    }

    // MARK: - Loading

    func loadRallies() async {
        loadingState = .loading

        do {
            let metadataVideoId = videoMetadata.originalVideoId ?? videoMetadata.id
            let metadata = try metadataStore.loadMetadata(for: metadataVideoId)
            processingMetadata = metadata

            trim.loadSavedAdjustments(videoId: metadataVideoId, metadataStore: metadataStore)

            let asset = AVURLAsset(url: videoMetadata.originalURL)
            actualVideoDuration = try await CMTimeGetSeconds(asset.load(.duration))

            guard !metadata.rallySegments.isEmpty else {
                loadingState = .empty
                return
            }

            activeSegments = metadata.rallySegments

            rallyVideoURLs = activeSegments.indices.map { index in
                guard var components = URLComponents(url: videoMetadata.originalURL, resolvingAgainstBaseURL: false) else {
                    return videoMetadata.originalURL
                }
                components.fragment = "rally_\(index)"
                return components.url ?? videoMetadata.originalURL
            }

            // Compute serve inferences using filtered segments
            serveInferences = ServeInferenceService.inferServes(
                segments: activeSegments,
                setup: setup,
                decisions: decisions
            )

            thumbnailCache.setRallySegments(activeSegments)

            // If resuming, jump to saved rally index
            if !decisions.isEmpty {
                let resumeIndex = min(decisions.count, rallyVideoURLs.count - 1)
                navigation.setIndex(resumeIndex, totalCount: rallyVideoURLs.count)
            }

            if !rallyVideoURLs.isEmpty, let url = currentRallyURL {
                navigation.updateVisibleStack(totalCount: rallyVideoURLs.count)
                playerCache.setCurrentPlayer(for: url)
                seekToCurrentRallyStart()

                let windowIndices = navigation.playerWindowIndices(totalCount: rallyVideoURLs.count)
                await lifecycle.preloadWindowedVideos(
                    indices: windowIndices, urls: rallyVideoURLs,
                    segments: activeSegments, playerCache: playerCache,
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
        guard !activeSegments.isEmpty else { return 0 }
        return trim.effectiveStartTime(for: rallyIndex, segments: activeSegments)
    }

    func effectiveEndTime(for rallyIndex: Int) -> Double {
        guard !activeSegments.isEmpty else { return 0 }
        return trim.effectiveEndTime(for: rallyIndex, segments: activeSegments, videoDuration: actualVideoDuration)
    }

    // MARK: - Player Helpers

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
            isTrimmingMode: { [weak self] in self?.trim.isTrimmingMode ?? false },
            playerCache: playerCache
        )
    }

    private func preloadAdjacent() async {
        guard !activeSegments.isEmpty else { return }
        let windowIndices = navigation.playerWindowIndices(totalCount: rallyVideoURLs.count)
        let windowURLs = navigation.playerWindowURLs(urls: rallyVideoURLs)
        await lifecycle.preloadAdjacent(
            currentIndex: currentRallyIndex, indices: windowIndices,
            urls: rallyVideoURLs, segments: activeSegments,
            windowURLs: windowURLs, playerCache: playerCache,
            thumbnailCache: thumbnailCache, visibleCardIndices: navigation.visibleCardIndices
        )
    }

    // MARK: - Confirm Rally (Swipe Right)

    func confirmRally() {
        let server = currentServeInference?.inferredServer ?? setup.firstServer
        let winner = assumedWinner

        let newScore = scoreEngine.awardPoint(to: winner, server: server)

        let decision = RallyScoringDecision(
            rallyIndex: currentRallyIndex,
            pointWinner: winner,
            server: server,
            serveInference: currentServeInference ?? ServeInference(
                rallyIndex: currentRallyIndex,
                bboxSizeSlope: 0,
                sampleCount: 0,
                inferredServer: server,
                confidence: 0.5,
                method: .firstRallySetup
            ),
            isManuallyOverridden: false,
            scoreAfter: newScore
        )

        decisions.append(decision)
        persistState()
        advanceToNextRally()
    }

    // MARK: - Open Correction (Swipe Left)

    func openCorrection() {
        playerCache.pause()
        showCorrectionSheet = true
    }

    // MARK: - Apply Correction

    func applyCorrection(winner: CourtSide, server: CourtSide, applyToRest: Bool) {
        showCorrectionSheet = false

        let newScore = scoreEngine.awardPoint(to: winner, server: server)

        let decision = RallyScoringDecision(
            rallyIndex: currentRallyIndex,
            pointWinner: winner,
            server: server,
            serveInference: ServeInference(
                rallyIndex: currentRallyIndex,
                bboxSizeSlope: 0,
                sampleCount: 0,
                inferredServer: server,
                confidence: 1.0,
                method: .manualOverride
            ),
            isManuallyOverridden: true,
            scoreAfter: newScore
        )

        decisions.append(decision)

        // Recompute subsequent inferences if requested
        if applyToRest {
            serveInferences = ServeInferenceService.inferServes(
                segments: activeSegments,
                setup: setup,
                decisions: decisions
            )
        }

        persistState()
        advanceToNextRally()
    }

    // MARK: - Undo

    func undoLastDecision() {
        guard !decisions.isEmpty else { return }
        decisions.removeLast()

        // Replay engine from scratch
        scoreEngine = GameScoreEngine.replay(decisions: decisions, setup: setup)
        showSummary = false

        // Navigate back to the rally that was just undone
        let targetIndex = decisions.count
        if targetIndex < rallyVideoURLs.count {
            navigation.setIndex(targetIndex, totalCount: rallyVideoURLs.count)
            if let url = currentRallyURL {
                playerCache.setCurrentPlayer(for: url)
                seekToCurrentRallyStart()
                setupRallyLooping()
                playerCache.play()
            }
        }

        // Recompute inferences
        serveInferences = ServeInferenceService.inferServes(
            segments: activeSegments,
            setup: setup,
            decisions: decisions
        )

        persistState()
    }

    // MARK: - Advance

    private func advanceToNextRally() {
        guard canGoNext else {
            // Reached end of rallies — show summary
            showSummary = true
            return
        }

        let nextIndex = currentRallyIndex + 1
        navigation.setIndex(nextIndex, totalCount: rallyVideoURLs.count)

        if let url = currentRallyURL {
            playerCache.setCurrentPlayer(for: url)
            seekToCurrentRallyStart()
            setupRallyLooping()

            let advanceTask = Task { @MainActor in
                let ready = await playerCache.waitForPlayerReady(for: url, timeout: 2.0)
                if !ready {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                playerCache.play()
                await preloadAdjacent()
            }
            activeTasks.append(advanceTask)
        }
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
        let metadataVideoId = videoMetadata.originalVideoId ?? videoMetadata.id
        trim.confirmTrim(rallyIndex: currentRallyIndex, videoId: metadataVideoId, metadataStore: metadataStore)
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

    // MARK: - Persistence

    private func persistState() {
        let metadataVideoId = videoMetadata.originalVideoId ?? videoMetadata.id
        let state = GameReviewState(
            videoId: metadataVideoId,
            setup: setup,
            decisions: decisions,
            currentRallyIndex: currentRallyIndex,
            createdDate: Date(),
            lastModifiedDate: Date()
        )
        try? metadataStore.saveGameReview(state, for: metadataVideoId)
    }

    // MARK: - Export

    func exportGameVideo() {
        guard !isExporting else { return }
        isExporting = true
        exportProgress = 0.0
        exportError = nil
        exportedURL = nil

        let task = Task { @MainActor in
            do {
                let asset = AVURLAsset(url: videoMetadata.originalURL)
                guard !activeSegments.isEmpty else {
                    throw ProcessingError.exportSessionFailed("No rally segments available")
                }

                let service = GameExportService()
                let url = try await service.exportGameVideo(
                    asset: asset,
                    rallies: activeSegments,
                    decisions: decisions,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor in
                            self?.exportProgress = progress
                        }
                    }
                )

                try await service.saveToPhotoLibrary(url: url)
                exportedURL = url
                isExporting = false
            } catch {
                exportError = error.localizedDescription
                isExporting = false
            }
        }
        activeTasks.append(task)
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
