//
//  ProcessingCoordinator.swift
//  BumpSetCut
//
//  App-level coordinator for video processing that persists across navigation.
//  Owns the processing task so progress is visible from any screen.
//

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

    // MARK: - Processing Context (stored so VM can resume save flow)
    private(set) var videoURL: URL?
    private(set) var mediaStore: MediaStore?
    private(set) var volleyballType: VolleyballType = .beach
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
        volleyballType: VolleyballType,
        videoId: UUID,
        isDebugMode: Bool
    ) {
        // Cancel any existing processing
        cancelProcessing()

        // Store context
        self.videoURL = videoURL
        self.mediaStore = mediaStore
        self.volleyballType = volleyballType
        self.videoId = videoId

        // Reset state
        self.isProcessing = true
        self.progress = 0.0
        self.videoName = videoURL.deletingPathExtension().lastPathComponent
        self.noRalliesDetected = false
        self.errorMessage = nil
        self.pendingSaveURL = nil
        self.pendingIsDebugMode = isDebugMode
        self.pendingDebugData = nil
        self.didComplete = false
        self.showCompletionPill = false

        // Create fresh processor
        self.processor = VideoProcessor()
        self.processor.configure(for: volleyballType)

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
                    _ = try await processor.processVideo(videoURL, videoId: videoId)

                    // Mark video as processed
                    await MainActor.run {
                        if let match = mediaStore.getAllVideos().first(where: { $0.id == videoId }) {
                            if let metadataSize = match.getCurrentMetadataSize() {
                                let _ = mediaStore.markVideoAsProcessed(
                                    videoId: videoId,
                                    metadataFileSize: metadataSize,
                                    volleyballType: volleyballType
                                )
                                SubscriptionService.shared.recordVideoProcessing()
                            }
                        }
                    }

                    // Create hard link for save flow
                    let ext = videoURL.pathExtension.isEmpty ? "mp4" : videoURL.pathExtension
                    let linkURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Processed_\(UUID().uuidString).\(ext)")
                    try FileManager.default.linkItem(at: videoURL, to: linkURL)

                    await MainActor.run {
                        self.pendingSaveURL = linkURL
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
                    self.errorMessage = error.localizedDescription
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
