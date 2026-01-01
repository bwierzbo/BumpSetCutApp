//
//  UploadCoordinator.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import Foundation
import SwiftUI
import PhotosUI
import MijickPopups
import Combine
import UniformTypeIdentifiers
import os

// MARK: - Video Transferable (for efficient large file transfer)

/// Transferable wrapper for video files - avoids loading entire video into memory
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            // Copy to temp location
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("import_\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return Self(url: tempURL)
        }
    }
}

// MARK: - Enhanced Upload Coordinator

@MainActor
class UploadCoordinator: ObservableObject {
    private let mediaStore: MediaStore
    let uploadManager: UploadManager
    private let logger = Logger(subsystem: "BumpSetCut", category: "UploadCoordinator")
    
    @Published var isUploadInProgress = false
    @Published var showingUploadProgress = false
    @Published var showCompleted = false
    @Published var uploadProgressText = ""
    @Published var currentItemIndex = 0
    @Published var totalItemCount = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var estimatedTimeRemaining: TimeInterval?
    @Published var currentFileSize: String = ""

    // Track import speed for estimates
    private var importStartTime: Date?
    private var lastImportDuration: TimeInterval?
    private var lastImportSize: Int64?
    private var elapsedTimer: Timer?
    
    // Publisher for notifying when upload is completed
    private let uploadCompletedSubject = PassthroughSubject<Void, Never>()
    var uploadCompletedPublisher: AnyPublisher<Void, Never> {
        uploadCompletedSubject.eraseToAnyPublisher()
    }
    
    // Upload flow state
    private var pendingUploads: [PhotosPickerItem] = []
    private var currentUploadIndex = 0
    private var currentFolderPath: String = ""

    // Track recently uploaded videos for post-upload naming
    private var recentlyUploadedFileNames: [String] = []
    
    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
        self.uploadManager = UploadManager(mediaStore: mediaStore)
    }
    
    // MARK: - Public Interface
    
    func startUploadFlow(from items: [PhotosPickerItem], destinationFolder: String = "") {
        guard !items.isEmpty else { return }
        
        pendingUploads = items
        currentUploadIndex = 0
        currentFolderPath = destinationFolder
        isUploadInProgress = true
        
        logger.info("Starting upload flow with \(items.count) items")
        
        // Reset upload manager
        uploadManager.reset()
        
        // Process all items to create upload items
        Task {
            await processAllItems()
        }
    }
    
    func startSingleUpload(from item: PhotosPickerItem, destinationFolder: String = "") {
        startUploadFlow(from: [item], destinationFolder: destinationFolder)
    }
    
    func cancelUploadFlow() {
        uploadManager.cancelAllUploads()
        isUploadInProgress = false
        showCompleted = false
        resetUploadFlow()
    }
    
    var uploadProgress: UploadManager {
        return uploadManager
    }
    
    // MARK: - Upload Processing
    
    private func processAllItems() async {
        for (index, item) in pendingUploads.enumerated() {
            // Use file-based transfer - never load entire video into memory
            guard let movie = try? await item.loadTransferable(type: VideoTransferable.self) else {
                logger.warning("Failed to load video for item \(index)")
                continue
            }

            let fileName = "VID_\(Date().timeIntervalSince1970).mp4"
            await uploadManager.addUpload(
                url: movie.url,
                fileName: fileName,
                destinationFolderPath: currentFolderPath
            )
        }

        // Show progress popup
        showingUploadProgress = true
        await UploadProgressPopup(uploadManager: uploadManager).present()

        // Start processing each upload item with naming and folder selection
        await processUploadQueue()
    }
    
    private func processUploadQueue() async {
        for uploadItem in uploadManager.uploadItems {
            guard case .pending = uploadItem.status else { continue }
            
            // Step 1: Video Naming
            await handleVideoNaming(for: uploadItem)
            
            // Step 2: Folder Selection (if not already set)
            if uploadItem.destinationFolderPath.isEmpty {
                await handleFolderSelection(for: uploadItem)
            }
            
            // Step 3: Start actual upload
            uploadManager.startUpload(item: uploadItem)
            
            // Wait for this upload to complete before processing next
            await waitForUploadCompletion(uploadItem)
        }
        
        // All uploads processed
        await finishUploadFlow()
    }
    
    private func handleVideoNaming(for uploadItem: UploadItem) async {
        await MainActor.run {
            uploadItem.status = .naming
        }

        logger.info("Starting video naming dialog for: \(uploadItem.originalFileName)")

        return await withCheckedContinuation { continuation in
            var hasResumed = false
            let resumeOnce: () -> Void = {
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume()
            }

            Task { @MainActor in
                logger.info("About to present VideoUploadNamingDialog")

                await VideoUploadNamingDialog(
                    uploadItem: uploadItem,
                    onName: { customName in
                        Task { @MainActor in
                            uploadItem.displayName = customName
                            uploadItem.finalName = customName
                            self.logger.info("Video named: \(customName)")
                            resumeOnce()
                        }
                    },
                    onSkip: {
                        Task { @MainActor in
                            self.logger.info("Video naming skipped")
                            resumeOnce()
                        }
                    },
                    onCancel: {
                        Task { @MainActor in
                            uploadItem.cancel()
                            self.logger.info("Video naming cancelled")
                            resumeOnce()
                        }
                    }
                ).present()

                self.logger.info("VideoUploadNamingDialog present() called")
            }
        }
    }
    
    private func handleFolderSelection(for uploadItem: UploadItem) async {
        await MainActor.run {
            uploadItem.status = .selectingFolder
        }

        return await withCheckedContinuation { continuation in
            var hasResumed = false
            let resumeOnce: () -> Void = {
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume()
            }

            Task {
                await FolderSelectionPopup(
                    mediaStore: mediaStore,
                    currentFolderPath: currentFolderPath,
                    onFolderSelected: { selectedPath in
                        Task {
                            uploadItem.destinationFolderPath = selectedPath
                            resumeOnce()
                        }
                    },
                    onCancel: {
                        Task {
                            uploadItem.cancel()
                            resumeOnce()
                        }
                    }
                ).present()
            }
        }
    }
    
    private func waitForUploadCompletion(_ uploadItem: UploadItem) async {
        let maxWaitTime: UInt64 = 5 * 60 * 1_000_000_000 // 5 minutes in nanoseconds
        let pollInterval: UInt64 = 100_000_000 // 100ms
        var elapsedTime: UInt64 = 0

        while elapsedTime < maxWaitTime {
            switch uploadItem.status {
            case .complete, .cancelled, .failed:
                return
            default:
                try? await Task.sleep(nanoseconds: pollInterval)
                elapsedTime += pollInterval
            }
        }

        // Timeout reached - mark as failed
        logger.warning("Upload timed out for: \(uploadItem.originalFileName)")
        uploadItem.status = .failed(error: "Upload timed out")
    }
    
    private func finishUploadFlow() async {
        logger.info("Upload flow completed")
        // Don't immediately reset - let checkAndResetUploadProgress handle the delayed reset
        // Just clear the upload queue but keep isUploadInProgress true for the completion display
        showingUploadProgress = false
        pendingUploads.removeAll()
        currentUploadIndex = 0
        currentFolderPath = ""
    }
    
    private func resetUploadFlow() {
        isUploadInProgress = false
        showingUploadProgress = false
        pendingUploads.removeAll()
        currentUploadIndex = 0
        currentFolderPath = ""
    }
}

// MARK: - Drag and Drop Support

struct DropViewDelegate: DropDelegate {
    let uploadCoordinator: UploadCoordinator
    let destinationFolder: String
    @Binding var isDropping: Bool
    
    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: ["public.movie"])
    }
    
    func dropEntered(info: DropInfo) {
        isDropping = true
    }
    
    func dropExited(info: DropInfo) {
        isDropping = false
    }
    
    func performDrop(info: DropInfo) -> Bool {
        isDropping = false
        
        let providers = info.itemProviders(for: ["public.movie"])
        
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    DispatchQueue.main.async {
                        if let url = url, error == nil {
                            Task {
                                await handleDroppedVideo(url: url)
                            }
                        }
                    }
                }
            }
        }
        
        return true
    }
    
    private func handleDroppedVideo(url: URL) async {
        // Copy to temp location instead of loading into memory
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop_\(UUID().uuidString).mp4")

        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
        } catch {
            print("❌ Failed to copy dropped video: \(error)")
            return
        }

        await MainActor.run {
            uploadCoordinator.isUploadInProgress = true
        }

        await uploadCoordinator.uploadManager.addUpload(
            url: tempURL,
            fileName: url.lastPathComponent,
            destinationFolderPath: destinationFolder
        )

        // Start upload immediately for dropped files
        if let uploadItem = uploadCoordinator.uploadManager.uploadItems.last {
            uploadCoordinator.uploadManager.startUpload(item: uploadItem)
        }
    }
}

// MARK: - Upload Queue Management

extension UploadCoordinator {
    func pauseAllUploads() {
        // Implementation for pausing uploads
        // This would require additional state management in UploadItem
        logger.info("Pause functionality not yet implemented")
    }
    
    func resumeAllUploads() {
        // Implementation for resuming uploads
        logger.info("Resume functionality not yet implemented")
    }
    
    func retryFailedUploads() {
        let failedItems = uploadManager.uploadItems.filter {
            if case .failed = $0.status { return true }
            return false
        }
        
        for item in failedItems {
            item.status = .pending
            uploadManager.startUpload(item: item)
        }
        
        logger.info("Retrying \(failedItems.count) failed uploads")
    }
    
    func clearCompletedUploads() {
        uploadManager.clearCompleted()
    }
}

// MARK: - Multiple File Upload Support

extension UploadCoordinator {
    func handleMultiplePhotosPickerItems(_ items: [PhotosPickerItem], destinationFolder: String = "") {
        logger.info("Handling \(items.count) photos picker items")
        
        // Simple direct upload without naming dialog
        print("🚀 UploadCoordinator: Starting direct upload, set isUploadInProgress = true")
        
        // Force UI update on main thread
        Task { @MainActor in
            isUploadInProgress = true
            objectWillChange.send()
            print("📱 UI Update: isUploadInProgress = true sent to UI")
        }
        
        Task {
            // Longer delay to ensure UI has time to show the progress bar
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            await processItemsDirectly(items, destinationFolder: destinationFolder)
        }
    }
    
    private func processItemsDirectly(_ items: [PhotosPickerItem], destinationFolder: String) async {
        print("🔄 Processing \(items.count) items directly")

        await MainActor.run {
            totalItemCount = items.count
            currentItemIndex = 0
            elapsedTime = 0
            estimatedTimeRemaining = nil
            recentlyUploadedFileNames.removeAll()
            startElapsedTimer()
        }

        for (index, item) in items.enumerated() {
            let itemStartTime = Date()

            await MainActor.run {
                currentItemIndex = index + 1
                currentFileSize = ""
                uploadProgressText = "Preparing video \(index + 1) of \(items.count)..."

                // Calculate estimate based on previous imports
                if let lastDuration = lastImportDuration, items.count > 1 {
                    let remainingItems = items.count - index
                    estimatedTimeRemaining = lastDuration * Double(remainingItems)
                }
            }

            // Use file-based transfer for large videos (avoids loading entire video into memory)
            do {
                await MainActor.run {
                    uploadProgressText = "Importing from Photos..."
                }

                guard let videoURL = try await loadVideoToTempFile(from: item, index: index) else {
                    logger.warning("Failed to load video for item \(index)")
                    continue
                }

                // Get file size for display
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int64) ?? 0
                let fileSizeString = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)

                await MainActor.run {
                    currentFileSize = fileSizeString
                    uploadProgressText = "Saving \(fileSizeString) video..."
                }

                print("✅ Loaded video \(index) to temp file: \(videoURL.lastPathComponent) (\(fileSizeString))")

                // Copy to final destination
                await saveVideoFromURL(videoURL, destinationFolder: destinationFolder)

                // Track timing for estimates
                let importDuration = Date().timeIntervalSince(itemStartTime)
                await MainActor.run {
                    lastImportDuration = importDuration
                    lastImportSize = fileSize
                }

                // Clean up temp file
                try? FileManager.default.removeItem(at: videoURL)

            } catch {
                logger.error("Failed to process item \(index): \(error.localizedDescription)")
                await MainActor.run {
                    uploadProgressText = "Failed to import video \(index + 1)"
                }
            }
        }

        await MainActor.run {
            stopElapsedTimer()
        }

        print("✨ Finished processing all items")
        await handleUploadCompletion()
    }

    // MARK: - Timer Management

    private func startElapsedTimer() {
        elapsedTime = 0
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedTime += 1
                // Update remaining estimate
                if let remaining = self?.estimatedTimeRemaining, remaining > 1 {
                    self?.estimatedTimeRemaining = remaining - 1
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// Load video from PhotosPickerItem to a temp file (memory efficient for large videos)
    private func loadVideoToTempFile(from item: PhotosPickerItem, index: Int) async throws -> URL? {
        // Use file-based transfer only - never load entire video into memory
        if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
            return movie.url
        }

        // If VideoTransferable fails, log and return nil (don't fall back to Data loading)
        logger.warning("VideoTransferable failed for item \(index) - skipping to avoid memory issues")
        return nil
    }

    /// Save video from URL to final destination
    private func saveVideoFromURL(_ sourceURL: URL, destinationFolder: String) async {
        do {
            let fileName = "Video_\(DateFormatter.yyyyMMdd_HHmmss.string(from: Date()))_\(UUID().uuidString.prefix(4)).mp4"
            let baseURL = StorageManager.getPersistentStorageDirectory()
            let destinationURL = baseURL
                .appendingPathComponent(destinationFolder)
                .appendingPathComponent(fileName)

            // Ensure directory exists
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )

            // Copy file (more efficient than loading into memory)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            print("✅ Copied video to: \(destinationURL.path)")

            // Get file size for display
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
            print("📦 File size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")

            // Create auto-generated name
            let uploadDate = DateFormatter.shortDate.string(from: Date())
            let autoName = "Uploaded video \(uploadDate)"

            // Add to MediaStore
            let success = mediaStore.addVideo(
                at: destinationURL,
                toFolder: destinationFolder,
                customName: autoName
            )

            if success {
                print("✅ Video added to MediaStore: \(autoName)")
                logger.info("Video upload completed: \(fileName)")
                // Track for post-upload naming
                await MainActor.run {
                    recentlyUploadedFileNames.append(fileName)
                }
            } else {
                print("❌ Failed to add video to MediaStore")
                logger.error("Failed to add video to MediaStore: \(fileName)")
            }

        } catch {
            logger.error("Failed to save video: \(error.localizedDescription)")
            print("❌ Save error: \(error)")
        }
    }
    
    private func handleUploadCompletion() async {
        print("🎉 All uploads completed, showing naming dialog")

        // Show naming dialog for each uploaded video
        for fileName in recentlyUploadedFileNames {
            await showPostUploadNamingDialog(for: fileName)
        }

        print("🎉 Naming complete, showing completion state")

        await MainActor.run {
            showCompleted = true
            recentlyUploadedFileNames.removeAll()

            // Notify LibraryView to refresh its contents
            print("📢 Sending upload completion notification")
            uploadCompletedSubject.send()
        }

        // Auto-dismiss after 2 seconds to keep it simple
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        await MainActor.run {
            print("⏰ Auto-dismissing upload completion")
            isUploadInProgress = false
            showCompleted = false
        }
    }

    private func showPostUploadNamingDialog(for fileName: String) async {
        // Get current name from MediaStore
        let videos = mediaStore.getAllVideos()
        guard let video = videos.first(where: { $0.fileName == fileName }) else {
            logger.warning("Could not find video for naming: \(fileName)")
            return
        }

        let currentName = video.displayName
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM/yyyy"
        let defaultName = "Uploaded video \(dateFormatter.string(from: Date()))"

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var hasResumed = false
            let resumeOnce: () -> Void = {
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume()
            }

            Task { @MainActor in
                await PostUploadNamingDialog(
                    currentName: currentName.isEmpty ? defaultName : currentName,
                    onSave: { newName in
                        Task { @MainActor in
                            if newName != currentName && !newName.isEmpty {
                                let success = self.mediaStore.renameVideo(fileName: fileName, to: newName)
                                if success {
                                    self.logger.info("Video renamed to: \(newName)")
                                } else {
                                    self.logger.warning("Failed to rename video: \(fileName)")
                                }
                            }
                            resumeOnce()
                        }
                    },
                    onSkip: {
                        Task { @MainActor in
                            self.logger.info("Video naming skipped for: \(fileName)")
                            resumeOnce()
                        }
                    }
                ).present()
            }
        }
    }
    
    func completeUploadFlow() {
        print("🔚 UploadCoordinator.completeUploadFlow() called")
        print("🔚 Setting isUploadInProgress = false, showCompleted = false")
        
        // Update UI state immediately for responsiveness
        isUploadInProgress = false
        showCompleted = false
        
        // Move the cleanup to a background task
        Task {
            uploadManager.clearCompleted()
            await MainActor.run {
                print("🔚 Upload flow completion finished")
                self.logger.info("Upload flow completed by user action")
            }
        }
    }
    
    
    func getUploadSummary() -> UploadSummary {
        return UploadSummary(
            totalItems: uploadManager.totalItems,
            completedItems: uploadManager.completedItems,
            failedItems: uploadManager.uploadItems.filter { 
                if case .failed = $0.status { return true }
                return false 
            }.count,
            overallProgress: uploadManager.overallProgress,
            isActive: uploadManager.isActive
        )
    }
}

// MARK: - Upload Summary Model

struct UploadSummary {
    let totalItems: Int
    let completedItems: Int
    let failedItems: Int
    let overallProgress: Double
    let isActive: Bool
    
    var successRate: Double {
        guard totalItems > 0 else { return 0 }
        return Double(completedItems) / Double(totalItems)
    }
    
    var statusText: String {
        if isActive {
            return "Uploading \(completedItems)/\(totalItems)"
        } else if failedItems > 0 {
            return "Completed with \(failedItems) failures"
        } else {
            return "All uploads completed"
        }
    }
}