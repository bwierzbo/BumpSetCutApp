import SwiftUI
import AVFoundation
import Observation

// MARK: - ProcessVideoViewModel
@MainActor
@Observable
final class ProcessVideoViewModel {
    // MARK: - Dependencies
    var videoURL: URL
    let mediaStore: MediaStore
    let onComplete: () -> Void

    // MARK: - State
    var currentVideoMetadata: VideoMetadata? = nil
    var showError: Bool = false
    var errorMessage: String = ""
    var showStorageWarning: Bool = false
    var storageWarningMessage: String = ""

    // Weekly processing limit (free tier) — surfaced with an upgrade path
    var showProcessingLimit: Bool = false
    var processingLimitMessage: String = ""
    var showPaywall: Bool = false

    // Review navigation
    var showRallyPlayer: Bool = false

    // Pre-trim state
    var showPreTrim: Bool = false
    var pendingDebugModeForTrim: Bool = false

    // Pending save state - holds temp URL while the processed video is auto-saved
    var pendingSaveURL: URL? = nil
    var pendingIsDebugMode: Bool = false
    var pendingDebugData: TrajectoryDebugger? = nil

    // No rallies detected flag
    var noRalliesDetected: Bool = false
    /// Whether the permissive retry has already been used for this video.
    private(set) var didTrySensitiveReprocess = false

    // MARK: - Coordinator Reference
    private var coordinator: ProcessingCoordinator { ProcessingCoordinator.shared }

    // MARK: - Computed Properties (read from coordinator when processing)
    var isProcessing: Bool {
        coordinator.isProcessing && coordinator.videoURL == videoURL
    }

    var progress: Double {
        coordinator.progress
    }

    var progressPercent: Int {
        coordinator.progressPercent
    }

    var isComplete: Bool {
        coordinator.didComplete && !coordinator.noRalliesDetected && coordinator.errorMessage == nil
    }

    var hasMetadata: Bool {
        currentVideoMetadata?.hasMetadata ?? false
    }

    /// Rally totals of the current video's metadata, read once per metadata
    /// load instead of decoding the JSON on every body evaluation.
    private(set) var rallySummary: (rallyCount: Int, totalRallyDuration: Double)?

    var detectedRallyCount: Int {
        rallySummary?.rallyCount ?? 0
    }

    /// Cached original video duration (loaded async since metadata may not store it).
    var cachedOriginalDuration: Double?

    /// Seconds of dead time removed (original duration minus rallies), if known.
    private var timeCutSeconds: (cut: Double, original: Double)? {
        guard let originalDuration = cachedOriginalDuration ?? currentVideoMetadata?.duration,
              originalDuration > 0,
              let summary = rallySummary else { return nil }
        let cut = originalDuration - summary.totalRallyDuration
        return cut > 0 ? (cut, originalDuration) : nil
    }

    /// Time cut = original video duration minus total rally duration.
    var timeCutFormatted: String? {
        timeCutSeconds?.cut.formattedClock()
    }

    /// Share of the original video that was cut, as display text ("42%").
    var timeCutPercentFormatted: String? {
        guard let (cut, original) = timeCutSeconds else { return nil }
        return (cut / original).formattedPercent()
    }

    var canBeProcessed: Bool {
        currentVideoMetadata?.canBeProcessed ?? true
    }

    /// Another video is currently being processed (not this one)
    var isAnotherVideoProcessing: Bool {
        coordinator.isProcessing && coordinator.videoURL != videoURL
    }

    var videoDisplayName: String {
        getVideoDisplayName()
    }

    // MARK: - Processing Status
    var processingState: ProcessingState {
        if isProcessing {
            return .processing
        } else if pendingSaveURL != nil {
            return .pendingSave
        } else if noRalliesDetected {
            return .noRallies
        } else if isComplete {
            return .complete
        } else if hasMetadata {
            return .hasMetadata
        } else if !canBeProcessed {
            return .alreadyProcessed
        } else {
            return .ready
        }
    }

    enum ProcessingState {
        case ready
        case processing
        case pendingSave  // Processing done, waiting for user to select folder
        case complete
        case noRallies    // Processing finished but no rallies found
        case hasMetadata
        case alreadyProcessed
    }

    // MARK: - Status Info
    var statusInfo: StatusInfo {
        guard let metadata = currentVideoMetadata else {
            return StatusInfo(
                icon: "video.slash",
                color: .bscTextSecondary,
                title: "Cannot Process",
                description: "This video cannot be processed.",
                detail: nil
            )
        }

        if metadata.isProcessed {
            return StatusInfo(
                icon: "checkmark.seal.fill",
                color: .bscPrimary,
                title: "Processed Video",
                description: "This video is the result of AI processing and cannot be processed again. Only original videos can be processed.",
                detail: "Result of AI processing"
            )
        } else {
            let count = metadata.processedVideoIds.count
            return StatusInfo(
                icon: "arrow.branch",
                color: .bscBlue,
                title: "Already Has Versions",
                description: "This original video already has \(count) processed versions. To avoid duplicates, videos can only be processed once.",
                detail: "\(count) processed versions exist"
            )
        }
    }

    struct StatusInfo {
        let icon: String
        let color: Color
        let title: LocalizedStringResource
        let description: LocalizedStringResource
        let detail: LocalizedStringResource?
    }

    // MARK: - Initialization
    init(videoURL: URL, mediaStore: MediaStore, onComplete: @escaping () -> Void) {
        self.videoURL = videoURL
        self.mediaStore = mediaStore
        self.onComplete = onComplete
    }

    // MARK: - Actions
    func loadCurrentVideoMetadata() {
        let fileName = videoURL.lastPathComponent

        // Search all videos in the manifest by filename (covers all folders including nested subfolders)
        if let match = mediaStore.getAllVideos().first(where: { $0.fileName == fileName }) {
            currentVideoMetadata = match
            rallySummary = (try? mediaStore.metadataStore.loadMetadata(for: match.id))
                .map { ($0.rallyCount, $0.totalRallyDuration) }
            // Load duration from AVAsset if metadata doesn't have it
            if match.duration == nil || match.duration == 0 {
                loadVideoDuration()
            }
            return
        }

        currentVideoMetadata = nil
        rallySummary = nil
    }

    /// Load video duration from AVAsset (async) for stats computation.
    private func loadVideoDuration() {
        Task {
            let asset = AVURLAsset(url: videoURL)
            if let duration = try? await CMTimeGetSeconds(asset.load(.duration)), duration > 0 {
                await MainActor.run {
                    self.cachedOriginalDuration = duration
                }
            }
        }
    }

    /// Check if the coordinator has pending results for this video and pick them up.
    func checkForPendingResults() {
        guard coordinator.didComplete,
              coordinator.videoURL == videoURL else { return }

        let results = coordinator.consumeResults()

        if let error = results.error {
            errorMessage = error
            showError = true
        } else if results.noRallies {
            noRalliesDetected = true
        } else if let saveURL = results.saveURL {
            // Debug mode exports a distinct annotated video — save it alongside the
            // original, into the original video's folder (no destination prompt).
            pendingSaveURL = saveURL
            pendingIsDebugMode = results.isDebugMode
            pendingDebugData = results.debugData
            loadCurrentVideoMetadata()
            saveProcessedVideoToOriginalFolder()
        } else {
            // Normal processing: rally metadata was written onto the original video
            // in place. There is no separate file to save — just refresh so the
            // original surfaces its rallies, then clear the coordinator.
            loadCurrentVideoMetadata()
            coordinator.reset()
            onComplete()
        }
    }

    func cancelProcessing() {
        coordinator.cancelProcessing()
    }

    /// Reprocess flow (dev tool): drop the index-keyed sidecars (trims,
    /// selections, scoring — they'd point at the old rallies) and run
    /// detection again on the full source video. The current rally metadata
    /// stays until the new run replaces it, so manual rallies carry over and a
    /// cancelled run loses nothing. Lifetime stats are idempotent per videoId,
    /// so this run won't double-count. Favorites already exported to the
    /// library are separate files and stay.
    func reprocess() {
        guard let videoId = currentVideoMetadata?.id else { return }
        mediaStore.prepareForReprocess(videoId: videoId)
        noRalliesDetected = false
        loadCurrentVideoMetadata()
        startProcessing(isDebugMode: false)
    }

    /// Re-run detection with the permissive preset after a zero-rally result.
    /// One shot per session — the button hides once tried so users don't loop.
    func reprocessHighSensitivity() {
        guard let videoId = currentVideoMetadata?.id else { return }
        didTrySensitiveReprocess = true
        mediaStore.prepareForReprocess(videoId: videoId)
        noRalliesDetected = false
        loadCurrentVideoMetadata()
        startProcessing(isDebugMode: false, config: .highSensitivity)
    }

    func startProcessing(isDebugMode: Bool, config: ProcessorConfig = ProcessorConfig()) {
        // Block concurrent processing — only one video at a time
        if coordinator.isProcessing, coordinator.videoURL != videoURL {
            errorMessage = String(localized: "Another video is already being processed. Please wait for it to finish or cancel it first.")
            showError = true
            return
        }

        // Check weekly processing duration limit for free users
        let videoDuration = cachedOriginalDuration ?? currentVideoMetadata?.duration ?? 0
        let processingCheck = SubscriptionService.shared.canProcessVideo(durationSeconds: videoDuration)
        if !processingCheck.allowed {
            processingLimitMessage = processingCheck.message ?? String(localized: "Processing limit reached")
            showProcessingLimit = true
            return
        }

        // Check network requirement for free users
        let isPro = SubscriptionService.shared.isPro
        let networkCheck = NetworkMonitor.shared.canProcessVideo(isPro: isPro)

        if !networkCheck.allowed {
            errorMessage = networkCheck.reason ?? String(localized: "Network connection required")
            showError = true
            return
        }

        // Check storage space before starting
        let videoSize = StorageChecker.getFileSize(at: videoURL)
        let requiredSpace = Int64(Double(videoSize) * 1.5)
        let storageCheck = StorageChecker.checkAvailableSpace(requiredBytes: requiredSpace)

        if !storageCheck.isSufficient {
            storageWarningMessage = storageCheck.errorMessage ?? String(localized: "Not enough storage space to process this video")
            showStorageWarning = true
            return
        }

        // Delegate to coordinator — processing survives view dismissal
        coordinator.startProcessing(
            videoURL: videoURL,
            mediaStore: mediaStore,
            videoId: currentVideoMetadata?.id ?? UUID(),
            isDebugMode: isDebugMode,
            config: config
        )
    }

    /// Auto-save the processed video into the original video's folder. A processed video
    /// always lives alongside its source — there is no destination prompt.
    private func saveProcessedVideoToOriginalFolder() {
        guard let tempURL = pendingSaveURL else {
            print("⚠️ saveProcessedVideoToOriginalFolder: no pendingSaveURL")
            return
        }

        let destinationFolder = currentVideoMetadata?.folderPath ?? ""
        print("📁 saveProcessedVideoToOriginalFolder: saving to '\(destinationFolder)'")
        Task {
            do {
                try await saveProcessedVideo(
                    tempProcessedURL: tempURL,
                    isDebugMode: pendingIsDebugMode,
                    debugData: pendingDebugData,
                    destinationFolder: destinationFolder
                )
                print("✅ saveProcessedVideoToOriginalFolder: save succeeded")

                await MainActor.run {
                    pendingSaveURL = nil
                    pendingDebugData = nil
                    loadCurrentVideoMetadata()
                    coordinator.reset()
                }
            } catch {
                print("❌ saveProcessedVideoToOriginalFolder: error: \(error)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    /// Save a distinct annotated export (debug mode only). Normal processing has no
    /// separate file to save — it annotates the original in place.
    private func saveProcessedVideo(tempProcessedURL: URL, isDebugMode: Bool, debugData: TrajectoryDebugger?, destinationFolder: String) async throws {
        let originalDisplayName = getVideoDisplayName()
        let processedName = getNextProcessedVideoName(originalDisplayName: originalDisplayName, prefix: "Debug", inFolder: destinationFolder)
        let ext = videoURL.pathExtension.isEmpty ? "mp4" : videoURL.pathExtension
        // Unique on disk and in the manifest (which is keyed by file name) —
        // a display-name-based file name overwrote earlier exports and
        // collided across folders. The display name lives in customName.
        let processedFileName = "\(UUID().uuidString).\(ext)"

        let targetDirectory = mediaStore.baseDirectory.appendingPathComponent(destinationFolder)
        let finalURL = targetDirectory.appendingPathComponent(processedFileName)

        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.moveItem(at: tempProcessedURL, to: finalURL)

        let originalVideoId = currentVideoMetadata?.id ?? UUID()
        guard let addedVideo = mediaStore.addProcessedVideo(at: finalURL, toFolder: destinationFolder, customName: processedName, originalVideoId: originalVideoId) else {
            // Not recorded — don't leave an untracked file behind.
            try? FileManager.default.removeItem(at: finalURL)
            throw MediaStore.ImportError.registrationFailed
        }

        if isDebugMode, let debugger = debugData, let jsonData = debugger.exportToJSON() {
            try mediaStore.saveDebugData(for: addedVideo.id, debugData: jsonData, sessionId: UUID())
        }

        await MainActor.run {
            onComplete()
        }
    }

    // MARK: - Helpers
    private func getVideoDisplayName() -> String {
        let fileName = videoURL.lastPathComponent

        if let match = mediaStore.getAllVideos().first(where: { $0.fileName == fileName }) {
            return match.displayName
        }

        return videoURL.deletingPathExtension().lastPathComponent
    }

    private func getNextProcessedVideoName(originalDisplayName: String, prefix: String, inFolder destinationFolder: String) -> String {
        let videosInFolder = mediaStore.getVideos(in: destinationFolder)

        let existingNumbers = videosInFolder.compactMap { video -> Int? in
            let displayName = video.displayName
            if displayName.hasPrefix("\(prefix)") && displayName.hasSuffix(" \(originalDisplayName)") {
                let afterPrefix = String(displayName.dropFirst(prefix.count))
                let beforeOriginalName = String(afterPrefix.dropLast(" \(originalDisplayName)".count))
                return Int(beforeOriginalName)
            }
            return nil
        }

        let nextNumber = (existingNumbers.max() ?? 0) + 1
        let sanitizedDisplayName = sanitizeFilename(originalDisplayName)
        return String(format: "%@%02d %@", prefix, nextNumber, sanitizedDisplayName)
    }

    private func sanitizeFilename(_ filename: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = filename.components(separatedBy: invalidChars).joined(separator: "-")
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return trimmed.isEmpty ? "Video" : trimmed
    }
}
