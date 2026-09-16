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
import UIKit
import UserNotifications

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
    /// Rally count of the last successful run — the completion pill's summary.
    private(set) var completedRallyCount = 0

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
    // Run generation: a cancelled run's late callbacks (its CancellationError can
    // land after a new run started) must not clobber the new run's state
    @ObservationIgnored private var runGeneration = 0

    // MARK: - Processing Context (stored so VM can resume save flow)
    private(set) var videoURL: URL?
    private(set) var mediaStore: MediaStore?
    private(set) var videoId: UUID?

    // MARK: - Private
    private var processor = VideoProcessor()
    private var currentTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "BumpSetCut", category: "ProcessingCoordinator")
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?

    private init() {}

    /// Keep the screen awake while processing runs foregrounded; a long job
    /// auto-locking the phone was the top way processing died before
    /// background continuation existed.
    private func setKeepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }

    /// While processing, a trip to the background asks the pipeline to write
    /// a resume checkpoint at its next rally-idle frame — the safety net for
    /// the pre-iOS-26 path and for continued-processing expiration.
    private func startBackgroundObserver() {
        stopBackgroundObserver()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.processor.requestCheckpoint()
            }
        }
    }

    private func stopBackgroundObserver() {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        backgroundObserver = nil
    }

    // MARK: - Start Processing

    func startProcessing(
        videoURL: URL,
        mediaStore: MediaStore,
        videoId: UUID,
        isDebugMode: Bool,
        config: ProcessorConfig = ProcessorConfig()
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
        self.completedRallyCount = 0

        // Create fresh processor
        self.processor = VideoProcessor()
        self.processor.config = config
        // Data flywheel: collect per-frame evidence only for opted-in users, so
        // borderline rallies can be staged for relabeling after processing.
        self.processor.collectFrameEvidence = AppSettings.shared.enableDataFlywheel

        runGeneration += 1
        let gen = runGeneration

        // Survive leaving the app: iOS 26+ continues the run under a system
        // progress UI; every version checkpoints on backgrounding and keeps
        // the screen awake while foregrounded.
        setKeepAwake(true)
        startBackgroundObserver()

        // First run: ask for real notification permission (alert + sound) so
        // the completion notification banners instead of landing silently in
        // Notification Center. iOS only ever prompts while notDetermined, so
        // this is a one-time, contextual ask.
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
        }
        let keeper = ProcessingBackgroundKeeper.processing
        keeper.onExpiration = { [weak self] in
            self?.processor.requestCheckpoint()
        }
        keeper.onSystemCancel = { [weak self] in
            self?.cancelProcessing()
        }
        keeper.begin(subtitle: videoName)

        currentTask = Task { [weak self] in
            guard let self else { return }

            // Poll progress from processor
            let progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                    guard let self else { break }
                    await MainActor.run {
                        self.progress = min(1.0, max(0.0, self.processor.progress))
                        ProcessingBackgroundKeeper.processing.updateProgress(self.progress, subtitle: self.videoName)
                    }
                }
            }

            defer { progressTask.cancel() }

            do {
                // Register background expiry cancellation. When a continued-
                // processing task is keeping us alive (iOS 26+), the legacy
                // 30s guard expiring must NOT kill the run — checkpoint and
                // keep going instead.
                let task = self.currentTask
                processor.setBackgroundCancellationHandler { [weak self] in
                    guard let self else { return }
                    if ProcessingBackgroundKeeper.processing.isActive {
                        self.processor.requestCheckpoint()
                        return
                    }
                    task?.cancel()
                    self.handleCancellation(gen: gen)
                }

                if isDebugMode {
                    let tempURL = try await processor.processVideoDebug(videoURL)
                    let debugData = processor.trajectoryDebugger
                    await MainActor.run {
                        guard gen == self.runGeneration else { return }
                        self.pendingSaveURL = tempURL
                        self.pendingDebugData = debugData
                        self.handleCompletion(gen: gen)
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
                        guard gen == self.runGeneration else { return }
                        self.completedRallyCount = metadata.rallyCount
                    }

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
                        // Mark as processed on success so the manifest's
                        // hasProcessingMetadata flag stays authoritative (UI relies on it
                        // instead of a per-render disk check). Always mark when the video
                        // exists; the size is best-effort storage tracking only.
                        if let match = mediaStore.getAllVideos().first(where: { $0.id == videoId }) {
                            let _ = mediaStore.markVideoAsProcessed(
                                videoId: videoId,
                                metadataFileSize: match.getCurrentMetadataSize() ?? 0
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
                        self.handleCompletion(gen: gen)
                    }
                }

            } catch is CancellationError {
                await MainActor.run { self.handleCancellation(gen: gen) }
            } catch ProcessingError.noRalliesDetected {
                // Data flywheel (opted-in users only): a video where the detector
                // found NO rallies is a hard negative worth relabeling. Persist the
                // full per-frame evidence, then stage whole-video frame groupings.
                let collectedEvidence = self.processor.frameEvidence
                await MainActor.run {
                    if gen == self.runGeneration {
                        self.noRalliesDetected = true
                        self.handleCompletion(gen: gen)
                    }
                    if AppSettings.shared.enableDataFlywheel, !collectedEvidence.isEmpty {
                        let stored = collectedEvidence.map(StoredFrameEvidence.init)
                        try? MetadataStore().saveFrameEvidence(stored, for: videoId)
                    }
                }
                await FlywheelCaptureService.shared.stageNoRallyContribution(
                    videoId: videoId, originalURL: videoURL
                )
            } catch {
                await MainActor.run {
                    guard gen == self.runGeneration else { return }
                    if StorageChecker.isStorageError(error) {
                        self.errorMessage = "Ran out of storage space during processing. Free up space and try again."
                    } else {
                        self.errorMessage = error.localizedDescription
                    }
                    self.handleCompletion(gen: gen)
                }
            }
        }
    }

    // MARK: - Cancel

    func cancelProcessing() {
        // Invalidate the run so its late callbacks become no-ops
        runGeneration += 1
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
        progress = 0.0
        showCompletionPill = false
        setKeepAwake(false)
        stopBackgroundObserver()
        ProcessingBackgroundKeeper.processing.finish(success: false)
        // The pipeline's resume checkpoint survives a cancel on purpose:
        // processing the same video again picks up where this run stopped.
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

    private func handleCompletion(gen: Int) {
        guard gen == runGeneration else { return }
        isProcessing = false
        progress = 1.0
        didComplete = true
        showCompletionPill = true
        currentTask = nil
        setKeepAwake(false)
        stopBackgroundObserver()
        ProcessingBackgroundKeeper.processing.finish(success: errorMessage == nil)
        logger.info("Processing completed for \(self.videoName)")

        if noRalliesDetected || errorMessage != nil {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else {
            UINotificationFeedbackGenerator.success()
        }

        // The user may have left mid-run (iOS 26 continues it in the
        // background) — tell them the outcome without making them check.
        // The pill above does the same for their return to the app.
        if noRalliesDetected {
            postLocalNotification(
                title: "No rallies detected",
                body: "\(videoName) finished processing but no rallies were found. Try Higher Sensitivity from the video."
            )
        } else if let errorMessage {
            postLocalNotification(title: "Processing failed", body: "\(videoName): \(errorMessage)")
        } else {
            let count = completedRallyCount
            postLocalNotification(
                title: "Your rallies are ready 🏐",
                body: count > 0
                    ? "Found \(count) \(count == 1 ? "rally" : "rallies") in \(videoName). Open BumpSetCut to watch them."
                    : "\(videoName) finished processing. Open BumpSetCut to watch your rallies."
            )
        }

        // Auto-hide the completion pill after ~6s of FOREGROUND time. The
        // countdown must not burn while the user is away (with background
        // continuation the app keeps running after they leave) — coming back
        // to a vanished summary meant hunting for the processed video.
        let gen = runGeneration
        Task {
            while UIApplication.shared.applicationState != .active {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await MainActor.run {
                if gen == self.runGeneration && self.showCompletionPill && self.didComplete {
                    self.showCompletionPill = false
                }
            }
        }
    }

    private func handleCancellation(gen: Int) {
        guard gen == runGeneration else { return }
        // User-initiated cancels bump runGeneration before cancelling the task, so a
        // matching generation here means the system cancelled us: background grace
        // time expired. Surface it — silently discarding minutes of processing looks
        // like a successful no-op. Guard on isProcessing because the expiry path
        // reaches here twice (background handler + the task's CancellationError).
        guard isProcessing else { return }
        isProcessing = false
        progress = 0.0
        currentTask = nil
        setKeepAwake(false)
        stopBackgroundObserver()
        ProcessingBackgroundKeeper.processing.finish(success: false)
        errorMessage = "Processing was paused — your progress is saved. Start it again to continue."
        didComplete = true
        showCompletionPill = true
        logger.warning("Processing interrupted by background expiry for \(self.videoName)")
        postLocalNotification(
            title: "Processing paused",
            body: "\(videoName) couldn't keep running in the background. Your progress is saved — open BumpSetCut and start it again to continue."
        )
    }

    /// Local notification (no server involved) for outcomes the user may miss
    /// while the app is backgrounded. No-op when the app is frontmost.
    private func postLocalNotification(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                // Provisional authorization is granted without a prompt, which is the
                // only kind that can be requested while backgrounded.
                guard (try? await center.requestAuthorization(options: [.alert, .sound, .provisional])) == true else { return }
            case .denied:
                return
            default:
                break
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: "processing-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}
