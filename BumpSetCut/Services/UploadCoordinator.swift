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
            // Copy to our temp location (Apple owns the received file and may clean it up)
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
    var currentFileSize: String = ""

    /// Determinate import progress (0...1) for the Photos-picker path, including the
    /// iCloud download for off-device videos. `nil` means indeterminate (e.g. drag-drop).
    var importProgress: Double?

    // Storage warning
    var showStorageWarning = false
    var storageWarningMessage = ""

    // Import failure (network/iCloud download errors, etc.)
    var showImportError = false
    var importErrorMessage = ""

    @ObservationIgnored private var importProgressObservation: NSKeyValueObservation?
    @ObservationIgnored private var importProgressHandle: Progress?
    @ObservationIgnored private var importWasCancelled = false

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
        cancelImport()
        showCompleted = false
    }

    /// Cancel an in-flight Photos import (including an ongoing iCloud download).
    /// The underlying `loadTransferable` resumes with a cancellation error, which
    /// `processItem` treats as a user cancellation (no error alert).
    func cancelImport() {
        importWasCancelled = true
        importProgressHandle?.cancel()
        importProgressObservation?.invalidate()
        importProgressObservation = nil
        importProgressHandle = nil
        importProgress = nil
        uploadProgressText = ""
        isUploadInProgress = false
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
            await processItem(item, destinationFolder: destinationFolder)
        }
    }

    private func processItem(_ item: PhotosPickerItem, destinationFolder: String) async {
        await MainActor.run {
            importProgress = 0
            importWasCancelled = false
            recentlyUploadedFileNames.removeAll()
            uploadProgressText = "Importing from Photos…"
        }

        let videoURL: URL?
        do {
            videoURL = try await loadVideoToTempFile(from: item, index: 0)
        } catch {
            // User cancellation resumes with an error too — don't surface an alert for it.
            if importWasCancelled {
                logger.info("Import cancelled by user")
                return
            }
            logger.warning("Failed to import video from Photos: \(error.localizedDescription)")
            await MainActor.run {
                importProgress = nil
                isUploadInProgress = false
                importErrorMessage = Self.importErrorMessage(for: error)
                showImportError = true
            }
            return
        }

        // The download may have finished just as the user cancelled — discard the result.
        if importWasCancelled {
            if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
            logger.info("Import cancelled by user")
            return
        }

        guard let videoURL else {
            logger.warning("Photos import returned no file")
            await MainActor.run {
                importProgress = nil
                isUploadInProgress = false
                importErrorMessage = "The video couldn't be imported from Photos. It may still be downloading from iCloud — open it in the Photos app to finish the download, then try again."
                showImportError = true
            }
            return
        }

        let fileSize = StorageChecker.getFileSize(at: videoURL)

        // Check storage space
        let storageCheck = StorageChecker.checkAvailableSpace(requiredBytes: fileSize)
        if !storageCheck.isSufficient {
            await MainActor.run {
                importProgress = nil
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

        await handleUploadCompletion()
    }

    /// Load video from PhotosPickerItem to a temp file (memory efficient for large videos).
    ///
    /// Uses the completion-handler form of `loadTransferable`, which returns a `Progress`
    /// we can observe. That progress covers the iCloud download for videos not yet on-device,
    /// so we can drive a determinate bar instead of an opaque spinner. Errors are propagated
    /// (rather than swallowed) so callers can surface iCloud/network failures to the user.
    private func loadVideoToTempFile(from item: PhotosPickerItem, index: Int) async throws -> URL? {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let progress = item.loadTransferable(type: VideoTransferable.self) { result in
                    Task { @MainActor in
                        self.importProgressObservation?.invalidate()
                        self.importProgressObservation = nil
                        self.importProgressHandle = nil
                    }
                    switch result {
                    case .success(let movie):
                        continuation.resume(returning: movie?.url)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                importProgressHandle = progress

                // Observe download/copy progress (covers iCloud materialization for off-device videos).
                importProgressObservation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        self?.importProgress = fraction
                    }
                }
            }
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            logger.warning("VideoTransferable failed for item \(index) after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription)")
            throw error
        }
    }

    /// Map an import error to a user-facing message, calling out the common iCloud/network case.
    private static func importErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain || nsError.domain == "CKErrorDomain" {
            return "This video couldn't be downloaded from iCloud. Check your internet connection, make sure the full video has finished downloading in the Photos app, then try again."
        }
        return "The video couldn't be imported from Photos. It may still be downloading from iCloud — open it in the Photos app to finish the download, then try again."
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

            // Move file (O(1) rename on same filesystem, avoids full copy)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

            // Add to MediaStore
            let success = mediaStore.addVideo(
                at: destinationURL,
                toFolder: destinationFolder,
                customName: nil
            )

            if success {
                logger.info("Video upload completed: \(fileName)")
                // Track for post-upload naming
                await MainActor.run {
                    recentlyUploadedFileNames.append(fileName)
                }
            } else {
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
        }
    }
    
    private func handleUploadCompletion() async {
        // Show naming dialog for each uploaded video
        for fileName in recentlyUploadedFileNames {
            await showPostUploadNamingDialog(for: fileName)
        }

        await MainActor.run {
            showCompleted = true
            recentlyUploadedFileNames.removeAll()
            // Notify LibraryView to refresh its contents
            uploadCompletedSubject.send()
        }

        // Auto-dismiss after 2 seconds to keep it simple
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        await MainActor.run {
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
        // Guard against double-calls (SwiftUI alert binding setter fires after button action)
        guard namingContinuation != nil else { return }
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
        // Update UI state immediately for responsiveness
        isUploadInProgress = false
        showCompleted = false

        // Move the cleanup to a background task
        Task {
            uploadManager.clearCompleted()
            await MainActor.run {
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