//
//  UploadCoordinator.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import Foundation
import SwiftUI
import PhotosUI
import Combine
import UniformTypeIdentifiers
import Observation
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
@Observable
final class UploadCoordinator {
    private let mediaStore: MediaStore
    let uploadManager: UploadManager
    private let logger = Logger(subsystem: "BumpSetCut", category: "UploadCoordinator")

    var isUploadInProgress = false
    var showCompleted = false
    var uploadProgressText = ""
    var elapsedTime: TimeInterval = 0
    var currentFileSize: String = ""

    // Storage warning
    var showStorageWarning = false
    var storageWarningMessage = ""

    @ObservationIgnored private var elapsedTimer: Timer?

    // Publisher for notifying when upload is completed
    @ObservationIgnored private let uploadCompletedSubject = PassthroughSubject<Void, Never>()
    var uploadCompletedPublisher: AnyPublisher<Void, Never> {
        uploadCompletedSubject.eraseToAnyPublisher()
    }

    // Track recently uploaded videos for post-upload naming
    private var recentlyUploadedFileNames: [String] = []

    // Naming dialog state
    var showNamingDialog = false
    var namingDialogFileName = ""
    var namingDialogSuggestedName = ""
    @ObservationIgnored private var namingContinuation: CheckedContinuation<Void, Never>?
    
    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
        self.uploadManager = UploadManager(mediaStore: mediaStore)
    }
    
    // MARK: - Public Interface

    func cancelUploadFlow() {
        uploadManager.cancelAllUploads()
        isUploadInProgress = false
        showCompleted = false
    }

    var uploadProgress: UploadManager {
        return uploadManager
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

// MARK: - Single File Upload

extension UploadCoordinator {
    func handlePhotosPickerItem(_ item: PhotosPickerItem, destinationFolder: String = "") {
        logger.info("Handling photos picker item")

        Task { @MainActor in
            isUploadInProgress = true
        }

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms for UI to show overlay
            await processItem(item, destinationFolder: destinationFolder)
        }
    }

    private func processItem(_ item: PhotosPickerItem, destinationFolder: String) async {
        await MainActor.run {
            elapsedTime = 0
            recentlyUploadedFileNames.removeAll()
            startElapsedTimer()
            uploadProgressText = "Importing from Photos..."
        }

        guard let videoURL = try? await loadVideoToTempFile(from: item, index: 0) else {
            logger.warning("Failed to load video from Photos")
            await MainActor.run {
                stopElapsedTimer()
                isUploadInProgress = false
            }
            return
        }

        let fileSize = StorageChecker.getFileSize(at: videoURL)

        // Check storage space
        let storageCheck = StorageChecker.checkAvailableSpace(requiredBytes: fileSize)
        if !storageCheck.isSufficient {
            await MainActor.run {
                stopElapsedTimer()
                isUploadInProgress = false
                storageWarningMessage = storageCheck.errorMessage ?? "Not enough storage space"
                showStorageWarning = true
            }
            try? FileManager.default.removeItem(at: videoURL)
            logger.warning("Upload cancelled: insufficient storage space")
            return
        }

        let fileSizeString = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        await MainActor.run {
            currentFileSize = fileSizeString
            uploadProgressText = "Saving \(fileSizeString) video..."
        }

        await saveVideoFromURL(videoURL, destinationFolder: destinationFolder)
        try? FileManager.default.removeItem(at: videoURL)

        await MainActor.run {
            stopElapsedTimer()
        }

        await handleUploadCompletion()
    }

    // MARK: - Timer Management

    private func startElapsedTimer() {
        elapsedTime = 0
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedTime += 1
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

            // Check file size limit for free users
            let sizeCheck = await MainActor.run {
                SubscriptionService.shared.canUploadVideoSize(fileSizeBytes: fileSize)
            }

            if !sizeCheck.allowed {
                await MainActor.run {
                    storageWarningMessage = sizeCheck.message ?? "Video file too large"
                    showStorageWarning = true
                }
                // Delete the file we just copied since it exceeds the limit
                try? FileManager.default.removeItem(at: destinationURL)
                logger.error("Upload blocked: video exceeds size limit for free users")
                return
            }

            // Detect sport type before adding to MediaStore
            let asset = AVURLAsset(url: destinationURL)
            let (detectedType, confidence) = (try? await SportDetector.detectSport(from: asset)) ?? (.beach, 0.5)
            print("🏐 Detected sport: \(detectedType.displayName) (confidence: \(String(format: "%.1f%%", confidence * 100)))")

            // Add to MediaStore with detected sport type
            let success = mediaStore.addVideo(
                at: destinationURL,
                toFolder: destinationFolder,
                customName: nil,
                volleyballType: detectedType
            )

            if success {
                print("✅ Video added to MediaStore: \(fileName)")
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
            if StorageChecker.isStorageError(error) {
                logger.error("Storage full during upload: \(error.localizedDescription)")
                await MainActor.run {
                    storageWarningMessage = "Your device ran out of storage space while importing the video. Free up space in Settings > General > iPhone Storage, then try again."
                    showStorageWarning = true
                }
            } else {
                logger.error("Failed to save video: \(error.localizedDescription)")
            }
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
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM/yyyy"
        let suggestedName = "Uploaded video \(dateFormatter.string(from: Date()))"

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            namingContinuation = continuation
            namingDialogFileName = fileName
            namingDialogSuggestedName = suggestedName
            showNamingDialog = true
        }
    }

    /// Called from the SwiftUI naming alert when user saves or skips
    func completeNaming(customName: String?) {
        let fileName = namingDialogFileName
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let name = trimmed, !name.isEmpty {
            let success = mediaStore.renameVideo(fileName: fileName, to: name)
            if success {
                logger.info("Video named: \(name)")
            } else {
                logger.warning("Failed to name video: \(fileName)")
            }
        } else {
            // Skip — apply auto-generated name
            let suggestedName = namingDialogSuggestedName
            let success = mediaStore.renameVideo(fileName: fileName, to: suggestedName)
            if success {
                logger.info("Video auto-named: \(suggestedName)")
            } else {
                logger.warning("Failed to auto-name video: \(fileName)")
            }
        }
        showNamingDialog = false
        namingContinuation?.resume()
        namingContinuation = nil
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