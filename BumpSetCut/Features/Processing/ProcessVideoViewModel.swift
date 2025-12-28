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
    let onShowPlayer: (() -> Void)?

    // MARK: - State
    var processor = VideoProcessor()
    var currentTask: Task<Void, Never>? = nil
    var currentVideoMetadata: VideoMetadata? = nil
    var showError: Bool = false
    var errorMessage: String = ""

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
    init(videoURL: URL, mediaStore: MediaStore, folderPath: String, onComplete: @escaping () -> Void, onShowPlayer: (() -> Void)?) {
        self.videoURL = videoURL
        self.mediaStore = mediaStore
        self.folderPath = folderPath
        self.onComplete = onComplete
        self.onShowPlayer = onShowPlayer
    }

    // MARK: - Actions
    func loadCurrentVideoMetadata() {
        let fileName = videoURL.lastPathComponent
        let videosInFolder = mediaStore.getVideos(in: folderPath)

        // First check the current folder
        if let matchingVideo = videosInFolder.first(where: { $0.fileName == fileName }) {
            currentVideoMetadata = matchingVideo
            return
        }

        // Check other folders
        let allFolders = mediaStore.getFolders(in: "")
        for folder in allFolders {
            let videosInOtherFolder = mediaStore.getVideos(in: folder.path)
            if let matchingVideo = videosInOtherFolder.first(where: { $0.fileName == fileName }) {
                currentVideoMetadata = matchingVideo
                return
            }
        }

        // Check root folder
        let rootVideos = mediaStore.getVideos(in: "")
        if let matchingVideo = rootVideos.first(where: { $0.fileName == fileName }) {
            currentVideoMetadata = matchingVideo
            return
        }

        currentVideoMetadata = nil
    }

    func cancelProcessing() {
        currentTask?.cancel()
    }

    func startProcessing(isDebugMode: Bool) {
        currentTask?.cancel()

        currentTask = Task {
            do {
                let tempProcessedURL: URL?
                let debugData: TrajectoryDebugger?

                if isDebugMode {
                    tempProcessedURL = try await processor.processVideoDebug(videoURL)
                    debugData = processor.trajectoryDebugger
                } else {
                    _ = try await processor.processVideo(videoURL, videoId: currentVideoMetadata?.id ?? UUID())
                    tempProcessedURL = nil
                    debugData = nil
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

                // Move and save processed video
                try await saveProcessedVideo(tempProcessedURL: tempProcessedURL, isDebugMode: isDebugMode, debugData: debugData)

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

    private func saveProcessedVideo(tempProcessedURL: URL, isDebugMode: Bool, debugData: TrajectoryDebugger?) async throws {
        let originalDisplayName = getVideoDisplayName()
        let prefix = isDebugMode ? "Debug" : "Processed"
        let processedName = getNextProcessedVideoName(originalDisplayName: originalDisplayName, prefix: prefix)
        let processedFileName = "\(processedName).mp4"

        let mediaStoreBase = mediaStore.baseDirectory
        let targetDirectory = folderPath.isEmpty ? mediaStoreBase : mediaStoreBase.appendingPathComponent(folderPath)
        let finalURL = targetDirectory.appendingPathComponent(processedFileName)

        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true, attributes: nil)

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempProcessedURL, to: finalURL)

        let originalVideoId = currentVideoMetadata?.id ?? UUID()
        let success = mediaStore.addProcessedVideo(at: finalURL, toFolder: folderPath, customName: processedName, originalVideoId: originalVideoId)

        if isDebugMode, success, let debugger = debugData {
            if let addedVideo = mediaStore.getVideos(in: folderPath).first(where: { $0.displayName == processedName }) {
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

    private func getNextProcessedVideoName(originalDisplayName: String, prefix: String) -> String {
        let videosInFolder = mediaStore.getVideos(in: folderPath)

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
