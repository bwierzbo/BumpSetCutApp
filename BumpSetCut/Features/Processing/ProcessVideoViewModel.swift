import SwiftUI
import Observation

// MARK: - ProcessVideoViewModel
@MainActor
@Observable
final class ProcessVideoViewModel {
    // MARK: - Dependencies
    let videoURL: URL
    let mediaStore: MediaStore
    let folderPath: String
    let onComplete: () -> Void

    // MARK: - State
    var selectedVolleyballType: VolleyballType = .beach
    var currentVideoMetadata: VideoMetadata? = nil
    var showError: Bool = false
    var errorMessage: String = ""
    var showStorageWarning: Bool = false
    var storageWarningMessage: String = ""

    // Rally player navigation
    var showRallyPlayer: Bool = false

    // Pending save state - holds temp URL until user selects destination folder
    var pendingSaveURL: URL? = nil
    var pendingIsDebugMode: Bool = false
    var pendingDebugData: TrajectoryDebugger? = nil
    var showingFolderPicker: Bool = false
    var selectedProcessedFolder: String = LibraryType.processed.rootPath

    // No rallies detected flag
    var noRalliesDetected: Bool = false

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

    var detectedRallyCount: Int {
        guard let videoId = currentVideoMetadata?.id,
              let metadata = try? MetadataStore().loadMetadata(for: videoId) else { return 0 }
        return metadata.rallyCount
    }

    var detectedRallyDurationFormatted: String {
        guard let videoId = currentVideoMetadata?.id,
              let metadata = try? MetadataStore().loadMetadata(for: videoId) else { return "0:00" }
        let total = metadata.totalRallyDuration
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Time cut = original video duration minus total rally duration.
    var timeCutFormatted: String? {
        guard let originalDuration = currentVideoMetadata?.duration,
              originalDuration > 0,
              let videoId = currentVideoMetadata?.id,
              let metadata = try? MetadataStore().loadMetadata(for: videoId) else { return nil }
        let cut = originalDuration - metadata.totalRallyDuration
        guard cut > 0 else { return nil }
        let minutes = Int(cut) / 60
        let seconds = Int(cut) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Percentage of original video that was cut.
    var timeCutPercent: Int? {
        guard let originalDuration = currentVideoMetadata?.duration,
              originalDuration > 0,
              let videoId = currentVideoMetadata?.id,
              let metadata = try? MetadataStore().loadMetadata(for: videoId) else { return nil }
        let cut = originalDuration - metadata.totalRallyDuration
        guard cut > 0 else { return nil }
        return Int((cut / originalDuration) * 100)
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
                color: .bscOrange,
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
                description: "This original video already has \(count) processed version\(count == 1 ? "" : "s"). To avoid duplicates, videos can only be processed once.",
                detail: "\(count) processed version\(count == 1 ? "" : "s") exist"
            )
        }
    }

    struct StatusInfo {
        let icon: String
        let color: Color
        let title: String
        let description: String
        let detail: String?
    }

    // MARK: - Initialization
    init(videoURL: URL, mediaStore: MediaStore, folderPath: String, onComplete: @escaping () -> Void) {
        self.videoURL = videoURL
        self.mediaStore = mediaStore
        self.folderPath = folderPath
        self.onComplete = onComplete
    }

    // MARK: - Actions
    func loadCurrentVideoMetadata() {
        let fileName = videoURL.lastPathComponent

        // Search all videos in the manifest by filename (covers all folders including nested subfolders)
        if let match = mediaStore.getAllVideos().first(where: { $0.fileName == fileName }) {
            currentVideoMetadata = match
            selectedVolleyballType = match.volleyballType ?? .beach
            return
        }

        currentVideoMetadata = nil
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
            pendingSaveURL = saveURL
            pendingIsDebugMode = results.isDebugMode
            pendingDebugData = results.debugData
            loadCurrentVideoMetadata()
            // Don't show folder picker yet — show summary first
        }
    }

    func cancelProcessing() {
        coordinator.cancelProcessing()
    }

    func startProcessing(isDebugMode: Bool) {
        // Block concurrent processing — only one video at a time
        if coordinator.isProcessing, coordinator.videoURL != videoURL {
            errorMessage = "Another video is already being processed. Please wait for it to finish or cancel it first."
            showError = true
            return
        }

        // Check weekly processing limit for free users
        let processingCheck = SubscriptionService.shared.canProcessVideo()
        if !processingCheck.allowed {
            errorMessage = processingCheck.message ?? "Processing limit reached"
            showError = true
            return
        }

        // Check network requirement for free users
        let isPro = SubscriptionService.shared.isPro
        let networkCheck = NetworkMonitor.shared.canProcessVideo(isPro: isPro)

        if !networkCheck.allowed {
            errorMessage = networkCheck.reason ?? "Network connection required"
            showError = true
            return
        }

        // Check storage space before starting
        let videoSize = StorageChecker.getFileSize(at: videoURL)
        let requiredSpace = Int64(Double(videoSize) * 1.5)
        let storageCheck = StorageChecker.checkAvailableSpace(requiredBytes: requiredSpace)

        if !storageCheck.isSufficient {
            storageWarningMessage = storageCheck.errorMessage ?? "Not enough storage space to process this video"
            showStorageWarning = true
            return
        }

        // Delegate to coordinator — processing survives view dismissal
        coordinator.startProcessing(
            videoURL: videoURL,
            mediaStore: mediaStore,
            volleyballType: selectedVolleyballType,
            videoId: currentVideoMetadata?.id ?? UUID(),
            isDebugMode: isDebugMode
        )
    }

    /// Called after user selects a folder in the folder picker
    func confirmSaveToFolder(_ folderPath: String) {
        guard let tempURL = pendingSaveURL else {
            print("⚠️ confirmSaveToFolder: no pendingSaveURL")
            return
        }

        print("📁 confirmSaveToFolder: saving to '\(folderPath)'")
        Task {
            do {
                try await saveProcessedVideo(
                    tempProcessedURL: tempURL,
                    isDebugMode: pendingIsDebugMode,
                    debugData: pendingDebugData,
                    destinationFolder: folderPath
                )
                print("✅ confirmSaveToFolder: save succeeded")

                await MainActor.run {
                    pendingSaveURL = nil
                    pendingDebugData = nil
                    showingFolderPicker = false
                    loadCurrentVideoMetadata()
                    coordinator.reset()
                }
                // Let SwiftUI settle before presenting rally viewer
                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run {
                    if currentVideoMetadata != nil {
                        showRallyPlayer = true
                    } else {
                        print("⚠️ confirmSaveToFolder: currentVideoMetadata is nil, can't show rally player")
                    }
                }
            } catch {
                print("❌ confirmSaveToFolder: error: \(error)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func saveProcessedVideo(tempProcessedURL: URL, isDebugMode: Bool, debugData: TrajectoryDebugger?, destinationFolder: String) async throws {
        let originalDisplayName = getVideoDisplayName()
        let prefix = isDebugMode ? "Debug" : "Processed"
        let processedName = getNextProcessedVideoName(originalDisplayName: originalDisplayName, prefix: prefix, inFolder: destinationFolder)
        let ext = videoURL.pathExtension.isEmpty ? "mp4" : videoURL.pathExtension
        let processedFileName = "\(processedName).\(ext)"

        let mediaStoreBase = mediaStore.baseDirectory
        let targetDirectory = mediaStoreBase.appendingPathComponent(destinationFolder)
        let finalURL = targetDirectory.appendingPathComponent(processedFileName)

        print("📁 saveProcessedVideo: moving \(tempProcessedURL.lastPathComponent) → \(finalURL.path)")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true, attributes: nil)

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempProcessedURL, to: finalURL)
        print("✅ saveProcessedVideo: file moved to \(processedFileName)")

        let originalVideoId = currentVideoMetadata?.id ?? UUID()
        let success = mediaStore.addProcessedVideo(at: finalURL, toFolder: destinationFolder, customName: processedName, originalVideoId: originalVideoId, volleyballType: selectedVolleyballType)
        print(success ? "✅ saveProcessedVideo: added to manifest" : "❌ saveProcessedVideo: addProcessedVideo returned false")

        if isDebugMode, success, let debugger = debugData {
            if let addedVideo = mediaStore.getVideos(in: destinationFolder).first(where: { $0.displayName == processedName }) {
                if let jsonData = debugger.exportToJSON() {
                    let sessionId = UUID()
                    _ = try mediaStore.saveDebugData(for: addedVideo.id, debugData: jsonData, sessionId: sessionId)
                }
            }
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
