//
//  ProcessingCoordinator.swift
//  BumpSetCut
//
//  App-level coordinator for video processing that persists across navigation.
//  Owns the processing task so progress is visible from any screen.
//

import AVFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
final class ProcessingCoordinator {

    // MARK: - Singleton
    static let shared = ProcessingCoordinator()

    // MARK: - Public State
    private(set) var isProcessing = false
    private(set) var progress: Double = 0.0
    private(set) var videoName: String = ""
    private(set) var noRalliesDetected = false
    private(set) var errorMessage: String?

    // Completion results — consumed by ProcessVideoViewModel when user returns
    private(set) var pendingSaveURL: URL?
    private(set) var pendingIsDebugMode = false
    private(set) var pendingDebugData: TrajectoryDebugger?
    private(set) var didComplete = false
    private(set) var showCompletionPill = false

    var progressPercent: Int { Int(min(1.0, max(0.0, progress)) * 100) }
    var hasResult: Bool { pendingSaveURL != nil || noRalliesDetected || errorMessage != nil }

    /// Live estimate of seconds remaining, derived from actual progress rate.
    /// `nil` until there's enough progress to extrapolate reliably.
    var estimatedSecondsRemaining: TimeInterval? {
        guard isProcessing, let start = processingStartDate, progress > 0.03 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        return max(0, elapsed / progress * (1 - progress))
    }

    @ObservationIgnored private var processingStartDate: Date?

    // MARK: - Processing Context (stored so VM can resume save flow)
    private(set) var videoURL: URL?
    private(set) var mediaStore: MediaStore?
    private(set) var videoId: UUID?

    // MARK: - Private
    private var processor = VideoProcessor()
    private var currentTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "BumpSetCut", category: "ProcessingCoordinator")

    private init() {}

    // MARK: - Start Processing

    func startProcessing(
        videoURL: URL,
        mediaStore: MediaStore,
        videoId: UUID,
        isDebugMode: Bool
    ) {
        // Cancel any existing processing
        cancelProcessing()

        // Store context
        self.videoURL = videoURL
        self.mediaStore = mediaStore
        self.videoId = videoId

        // Reset state
        self.isProcessing = true
        self.progress = 0.0
        self.processingStartDate = Date()
        // Use custom display name if available, otherwise fall back to file name
        let fileName = videoURL.lastPathComponent
        if let match = mediaStore.getAllVideos().first(where: { $0.fileName == fileName }) {
            self.videoName = match.displayName
        } else {
            self.videoName = videoURL.deletingPathExtension().lastPathComponent
        }
        self.noRalliesDetected = false
        self.errorMessage = nil
        self.pendingSaveURL = nil
        self.pendingIsDebugMode = isDebugMode
        self.pendingDebugData = nil
        self.didComplete = false
        self.showCompletionPill = false

        // Create fresh processor
        self.processor = VideoProcessor()
        // Data flywheel: collect per-frame evidence only for opted-in users, so
        // borderline rallies can be staged for relabeling after processing.
        self.processor.collectFrameEvidence = AppSettings.shared.enableDataFlywheel

        currentTask = Task { [weak self] in
            guard let self else { return }

            // Poll progress from processor
            let progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                    guard let self else { break }
                    await MainActor.run {
                        self.progress = min(1.0, max(0.0, self.processor.progress))
                    }
                }
            }

            defer { progressTask.cancel() }

            do {
                // Register background expiry cancellation
                let task = self.currentTask
                processor.setBackgroundCancellationHandler { [weak self] in
                    task?.cancel()
                    Task { @MainActor in
                        self?.handleCancellation()
                    }
                }

                if isDebugMode {
                    let tempURL = try await processor.processVideoDebug(videoURL)
                    let debugData = processor.trajectoryDebugger
                    await MainActor.run {
                        self.pendingSaveURL = tempURL
                        self.pendingDebugData = debugData
                        self.handleCompletion()
                    }
                } else {
                    let metadata = try await processor.processVideo(videoURL, videoId: videoId)

                    let sourceSeconds = (try? await AVURLAsset(url: videoURL).load(.duration))
                        .map(CMTimeGetSeconds) ?? 0

                    // Calibrate the time estimator from this run's actual wall-clock time
                    // vs. the source video duration (excludes the slower debug path).
                    if let start = self.processingStartDate {
                        ProcessingTimeEstimator.record(
                            videoDuration: sourceSeconds,
                            elapsed: Date().timeIntervalSince(start)
                        )
                    }

                    // Meter weekly usage by exported rally length (what the user actually gets),
                    // not source video length.
                    let exportedSeconds = metadata.totalRallyDuration

                    await MainActor.run {
                        // Lifetime stats: accumulate dead time removed + rallies for this
                        // video. Idempotent per videoId, and persists across deletions.
                        let cut = max(0, sourceSeconds - exportedSeconds)
                        LifetimeStatsStore.shared.record(
                            videoId: videoId,
                            timeCutSeconds: cut,
                            rallyCount: metadata.rallyCount
                        )
                    }

                    await MainActor.run {
                        // Mark as processed when the metadata sidecar is available (storage tracking).
                        if let match = mediaStore.getAllVideos().first(where: { $0.id == videoId }),
                           let metadataSize = match.getCurrentMetadataSize() {
                            let _ = mediaStore.markVideoAsProcessed(
                                videoId: videoId,
                                metadataFileSize: metadataSize
                            )
                        }
                        // Always record usage on a successful process, independent of the
                        // metadata-size lookup above.
                        SubscriptionService.shared.recordVideoProcessing(durationSeconds: exportedSeconds)
                    }

                    // Data flywheel (opted-in users only): persist the detector's
                    // per-frame evidence scoped to rally windows, then stage the
                    // borderline-confidence rallies for relabeling.
                    let collectedEvidence = self.processor.frameEvidence
                    await MainActor.run {
                        guard AppSettings.shared.enableDataFlywheel else { return }
                        let stored = FlywheelCaptureService.scopedEvidence(
                            collectedEvidence, segments: metadata.rallySegments
                        )
                        if !stored.isEmpty {
                            try? MetadataStore().saveFrameEvidence(stored, for: videoId)
                        }
                    }
                    await FlywheelCaptureService.shared.stagePassiveContributions(
                        videoId: videoId, metadata: metadata, originalURL: videoURL
                    )

                    // Normal processing annotates the original video with rally
                    // metadata in place — it does not produce a separate output file.
                    // (Debug mode is the only path that exports a distinct annotated
                    // video; see the isDebugMode branch above.) So there's nothing to
                    // save here: the original now carries its rallies.
                    await MainActor.run {
                        self.handleCompletion()
                    }
                }

            } catch is CancellationError {
                await MainActor.run { self.handleCancellation() }
            } catch ProcessingError.noRalliesDetected {
                await MainActor.run {
                    self.noRalliesDetected = true
                    self.handleCompletion()
                }
            } catch {
                await MainActor.run {
                    if StorageChecker.isStorageError(error) {
                        self.errorMessage = "Ran out of storage space during processing. Free up space and try again."
                    } else {
                        self.errorMessage = error.localizedDescription
                    }
                    self.handleCompletion()
                }
            }
        }
    }

    // MARK: - Cancel

    func cancelProcessing() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
        progress = 0.0
        showCompletionPill = false
    }

    // MARK: - Consume Results (called by ProcessVideoViewModel)

    func consumeResults() -> (saveURL: URL?, isDebugMode: Bool, debugData: TrajectoryDebugger?, noRallies: Bool, error: String?) {
        let result = (pendingSaveURL, pendingIsDebugMode, pendingDebugData, noRalliesDetected, errorMessage)
        // Reset after consuming
        pendingSaveURL = nil
        pendingDebugData = nil
        noRalliesDetected = false
        errorMessage = nil
        didComplete = false
        showCompletionPill = false
        return result
    }

    /// Reset coordinator fully (after save flow completes or user dismisses)
    func reset() {
        cancelProcessing()
        videoURL = nil
        mediaStore = nil
        videoId = nil
        pendingSaveURL = nil
        pendingDebugData = nil
        noRalliesDetected = false
        errorMessage = nil
        didComplete = false
        showCompletionPill = false
    }

    // MARK: - Private

    private func handleCompletion() {
        isProcessing = false
        progress = 1.0
        didComplete = true
        showCompletionPill = true
        currentTask = nil
        logger.info("Processing completed for \(self.videoName)")

        // Auto-hide completion pill after 5 seconds if not consumed
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if self.showCompletionPill && self.didComplete {
                    self.showCompletionPill = false
                }
            }
        }
    }

    private func handleCancellation() {
        isProcessing = false
        progress = 0.0
        currentTask = nil
        showCompletionPill = false
    }
}
