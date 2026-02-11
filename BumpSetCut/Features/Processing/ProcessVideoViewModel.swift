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
    var processor = VideoProcessor()
    var selectedVolleyballType: VolleyballType = .indoor
    var currentTask: Task<Void, Never>? = nil
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

    // MARK: - Computed Properties
    var isProcessing: Bool {
        processor.isProcessing
    }

    var progress: Double {
        min(1.0, max(0.0, processor.progress))
    }

    var progressPercent: Int {
        Int(progress * 100)
    }

    var isComplete: Bool {
        processor.processedURL != nil
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

    var canBeProcessed: Bool {
        currentVideoMetadata?.canBeProcessed ?? true
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
        let videosInFolder = mediaStore.getVideos(in: folderPath)

        // First check the current folder
        if let matchingVideo = videosInFolder.first(where: { $0.fileName == fileName }) {
            currentVideoMetadata = matchingVideo
            // Load detected volleyball type, default to beach if not detected
            selectedVolleyballType = matchingVideo.volleyballType ?? .beach
            return
        }

        // Check other folders
        let allFolders = mediaStore.getFolders(in: "")
        for folder in allFolders {
            let videosInOtherFolder = mediaStore.getVideos(in: folder.path)
            if let matchingVideo = videosInOtherFolder.first(where: { $0.fileName == fileName }) {
                currentVideoMetadata = matchingVideo
                selectedVolleyballType = matchingVideo.volleyballType ?? .beach
                return
            }
        }

        // Check root folder
        let rootVideos = mediaStore.getVideos(in: "")
        if let matchingVideo = rootVideos.first(where: { $0.fileName == fileName }) {
            currentVideoMetadata = matchingVideo
            selectedVolleyballType = matchingVideo.volleyballType ?? .beach
            return
        }

        currentVideoMetadata = nil
    }

    func cancelProcessing() {
        currentTask?.cancel()
    }

    func startProcessing(isDebugMode: Bool) {
        currentTask?.cancel()

        // Check network requirement for free users
        let isPro = SubscriptionService.shared.isPro
        let networkCheck = NetworkMonitor.shared.canProcessVideo(isPro: isPro)

        if !networkCheck.allowed {
            errorMessage = networkCheck.reason ?? "Network connection required"
            showError = true
            return
        }

        // Check storage space before starting
        // Estimate needing ~1.5x video size (original stays, processed output created)
        let videoSize = StorageChecker.getFileSize(at: videoURL)
        let requiredSpace = Int64(Double(videoSize) * 1.5)
        let storageCheck = StorageChecker.checkAvailableSpace(requiredBytes: requiredSpace)

        if !storageCheck.isSufficient {
            storageWarningMessage = storageCheck.errorMessage ?? "Not enough storage space to process this video"
            showStorageWarning = true
            return
        }

        currentTask = Task {
            do {
                // Configure processor for the selected volleyball type
                processor.configure(for: selectedVolleyballType)

                let tempProcessedURL: URL?
                let debugData: TrajectoryDebugger?

                if isDebugMode {
                    tempProcessedURL = try await processor.processVideoDebug(videoURL)
                    debugData = processor.trajectoryDebugger
                } else {
                    let videoId = currentVideoMetadata?.id ?? UUID()
                    _ = try await processor.processVideo(videoURL, videoId: videoId)
                    tempProcessedURL = nil
                    debugData = nil

                    // Mark the video as processed in the manifest
                    // Get metadata file size from the saved metadata
                    if let metadataSize = await MainActor.run(body: {
                        currentVideoMetadata?.getCurrentMetadataSize()
                    }) {
                        let selectedType = selectedVolleyballType
                        let success = await MainActor.run {
                            mediaStore.markVideoAsProcessed(videoId: videoId, metadataFileSize: metadataSize, volleyballType: selectedType)
                        }
                        print(success ? "✅ Video marked as processed in manifest" : "❌ Failed to mark video as processed")
                    }
                }

                await MainActor.run {
                    currentTask = nil
                }

                guard let tempProcessedURL = tempProcessedURL else {
                    await MainActor.run {
                        loadCurrentVideoMetadata()
                    }
                    return
                }

                // Store pending save info and show folder picker
                await MainActor.run {
                    pendingSaveURL = tempProcessedURL
                    pendingIsDebugMode = isDebugMode
                    pendingDebugData = debugData
                    showingFolderPicker = true
                }

            } catch is CancellationError {
                await MainActor.run {
                    currentTask = nil
                    processor.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    currentTask = nil
                    processor.isProcessing = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    /// Called after user selects a folder in the folder picker
    func confirmSaveToFolder(_ folderPath: String) {
        guard let tempURL = pendingSaveURL else { return }

        Task {
            do {
                try await saveProcessedVideo(
                    tempProcessedURL: tempURL,
                    isDebugMode: pendingIsDebugMode,
                    debugData: pendingDebugData,
                    destinationFolder: folderPath
                )

                await MainActor.run {
                    pendingSaveURL = nil
                    pendingDebugData = nil
                    showingFolderPicker = false
                }
            } catch {
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
        let processedFileName = "\(processedName).mp4"

        let mediaStoreBase = mediaStore.baseDirectory
        let targetDirectory = mediaStoreBase.appendingPathComponent(destinationFolder)
        let finalURL = targetDirectory.appendingPathComponent(processedFileName)

        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true, attributes: nil)

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempProcessedURL, to: finalURL)

        let originalVideoId = currentVideoMetadata?.id ?? UUID()
        let success = mediaStore.addProcessedVideo(at: finalURL, toFolder: destinationFolder, customName: processedName, originalVideoId: originalVideoId, volleyballType: selectedVolleyballType)

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

        let videosInFolder = mediaStore.getVideos(in: folderPath)
        if let matchingVideo = videosInFolder.first(where: { $0.fileName == fileName }) {
            return matchingVideo.displayName
        }

        let allFolders = mediaStore.getFolders(in: "")
        for folder in allFolders {
            let videosInOtherFolder = mediaStore.getVideos(in: folder.path)
            if let matchingVideo = videosInOtherFolder.first(where: { $0.fileName == fileName }) {
                return matchingVideo.displayName
            }
        }

        let rootVideos = mediaStore.getVideos(in: "")
        if let matchingVideo = rootVideos.first(where: { $0.fileName == fileName }) {
            return matchingVideo.displayName
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
