//
//  UploadCoordinator.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import Foundation
import SwiftUI
import Photos
import PhotosUI
import AVFoundation
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
    /// Display name of the video being imported, for the global upload pill.
    var currentVideoName: String = ""

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
    /// ~30s grace on iOS < 26; on 26+ the continued-processing task below is
    /// the real lifeline for iCloud downloads that outlive backgrounding.
    @ObservationIgnored private let importGuard = BackgroundProcessingGuard()
    @ObservationIgnored private var importProgressHandle: Progress?
    /// In-flight PhotoKit resource download (the background-capable path).
    @ObservationIgnored private var importResourceRequest: PHAssetResourceDataRequestID?
    @ObservationIgnored private var importWasCancelled = false
    // Ties loadTransferable callbacks to the import that created them — a cancelled
    // import's late completion must not tear down a newer import's progress/handle
    @ObservationIgnored private var importGeneration = 0

    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
        self.uploadManager = UploadManager(mediaStore: mediaStore)
    }

    /// Keep the import alive across backgrounding: continued-processing task
    /// on iOS 26+ (system progress UI), 30s grace window otherwise.
    ///
    /// Neither expiry cancels the download. A PhotoKit fetch isn't lost when
    /// the app is suspended — it stops making progress and picks up again on
    /// return — so running out of background time is a pause, not a failure.
    /// (An earlier version tore the import down here and told the user to keep
    /// the app open, which both contradicted the feature and turned an import
    /// that would have finished into one that never could.) Real failures
    /// still arrive through PhotoKit's completion handler.
    @MainActor private func beginImportContinuation() {
        let keeper = ProcessingBackgroundKeeper.importing
        // The one genuine stop: the user tapped cancel in the system progress UI.
        keeper.onSystemCancel = { [weak self] in
            self?.cancelImport()
        }
        keeper.onExpiration = nil
        keeper.begin(subtitle: currentVideoName)
        importGuard.begin(onExpiring: {})
    }

    @MainActor private func endImportContinuation(success: Bool) {
        ProcessingBackgroundKeeper.importing.finish(success: success)
        importGuard.end()
    }
    
    // MARK: - Public Interface

    /// Cancel an in-flight Photos import (including an ongoing iCloud download).
    /// The underlying `loadTransferable` resumes with a cancellation error, which
    /// `processItem` treats as a user cancellation (no error alert).
    func cancelImport() {
        tearDownImport()
    }

    /// Stop the in-flight transfer and clear pill state. A late
    /// `loadTransferable` result is discarded silently via `importWasCancelled`.
    private func tearDownImport() {
        importWasCancelled = true
        importGeneration += 1
        if let requestID = importResourceRequest {
            PHAssetResourceManager.default().cancelDataRequest(requestID)
            importResourceRequest = nil
        }
        importProgressHandle?.cancel()
        importProgressObservation?.invalidate()
        importProgressObservation = nil
        importProgressHandle = nil
        importProgress = nil
        uploadProgressText = ""
        isUploadInProgress = false
        Task { @MainActor in
            self.endImportContinuation(success: false)
        }
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

        // The provider only *claims* movie content — verify the bytes are a
        // playable video before storing them in the library.
        let isPlayable = (try? await AVURLAsset(url: tempURL).load(.isPlayable)) ?? false
        guard isPlayable else {
            try? FileManager.default.removeItem(at: tempURL)
            print("❌ Dropped file is not a playable video, rejecting")
            return
        }

        await MainActor.run {
            uploadCoordinator.isUploadInProgress = true
        }

        // Start exactly the item we created — `uploadItems.last` after the await
        // could be another drop's item, double-starting one and orphaning the other
        let uploadItem = await uploadCoordinator.uploadManager.addUpload(
            url: tempURL,
            fileName: url.lastPathComponent,
            destinationFolderPath: destinationFolder
        )
        await uploadCoordinator.uploadManager.startUpload(item: uploadItem).value

        // Drive the same completion flow as the picker path — without it
        // isUploadInProgress stayed true and the upload overlay never dismissed
        await uploadCoordinator.handleUploadCompletion()
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
    func handlePhotosPickerItem(_ item: PhotosPickerItem, destinationFolder: String = "", customName: String? = nil) {
        logger.info("Handling photos picker item")

        Task { @MainActor in
            isUploadInProgress = true
        }

        Task {
            await processItem(item, destinationFolder: destinationFolder, customName: customName)
        }
    }

    private func processItem(_ item: PhotosPickerItem, destinationFolder: String, customName: String?) async {
        await MainActor.run {
            importProgress = 0
            importWasCancelled = false
            currentVideoName = Self.sanitizedCustomName(customName) ?? "video"
            uploadProgressText = "Importing from Photos…"
            beginImportContinuation()
        }

        let videoURL: URL?
        do {
            // PhotoKit first: it downloads with real progress and keeps going
            // while the continued-processing task holds the app alive. The
            // picker's own transfer only works in the foreground.
            if let identifier = item.itemIdentifier,
               let url = try await loadVideoViaPhotoKit(identifier: identifier) {
                videoURL = url
            } else {
                videoURL = try await loadVideoWithRetry(from: item)
            }
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
                endImportContinuation(success: false)
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
                endImportContinuation(success: false)
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
                endImportContinuation(success: false)
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

        let saved = await saveVideoFromURL(videoURL, destinationFolder: destinationFolder, customName: customName)

        guard saved else {
            await MainActor.run {
                importProgress = nil
                isUploadInProgress = false
                endImportContinuation(success: false)
            }
            return
        }

        await handleUploadCompletion()
    }

    /// Materialize the picked asset through PhotoKit instead of the picker's
    /// out-of-process transfer. PhotoKit streams the iCloud download to us with
    /// genuine progress and continues while our process is alive under the
    /// continued-processing task — the picker transfer stalls the moment the
    /// app leaves the foreground, which the system then reports as a failed
    /// task. Returns nil when PhotoKit can't serve this asset (library access
    /// declined, or the asset isn't in a limited selection) so the caller
    /// falls back to the picker path.
    private func loadVideoViaPhotoKit(identifier: String) async throws -> URL? {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { return nil }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              asset.mediaType == .video else { return nil }

        // The edited render when one exists (what the picker's `.current`
        // delivers), otherwise the original.
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video }) else { return nil }

        let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "mov"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_\(UUID().uuidString).\(ext)")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else { return nil }
        let handle = try FileHandle(forWritingTo: tempURL)

        importGeneration += 1
        let gen = importGeneration
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] fraction in
            Task { @MainActor in
                guard let self, gen == self.importGeneration else { return }
                self.importProgress = fraction
                ProcessingBackgroundKeeper.importing.updateProgress(fraction, subtitle: self.currentVideoName)
            }
        }

        let manager = PHAssetResourceManager.default()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Chunks arrive on PhotoKit's queue in order; stream them
                // straight to disk so a multi-GB video never sits in memory.
                let requestID = manager.requestData(for: resource, options: options) { chunk in
                    try? handle.write(contentsOf: chunk)
                } completionHandler: { error in
                    try? handle.close()
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
                importResourceRequest = requestID
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        if gen == importGeneration {
            importResourceRequest = nil
        }
        return tempURL
    }

    /// Backoff between import attempts. iCloud-only videos routinely fail the
    /// first `loadTransferable` while Photos is still materializing the
    /// download, then succeed instantly on the next try — so a single failure
    /// must never reach the user.
    private static let importRetryDelays: [UInt64] = [1, 2, 4].map { $0 * 1_000_000_000 }

    private func loadVideoWithRetry(from item: PhotosPickerItem) async throws -> URL? {
        var lastError: Error?
        for attempt in 0...Self.importRetryDelays.count {
            do {
                if let url = try await loadVideoToTempFile(from: item, index: attempt) {
                    return url
                }
                lastError = nil // "no file" is transient too while iCloud is fetching
            } catch {
                if importWasCancelled { throw error }
                lastError = error
            }
            guard attempt < Self.importRetryDelays.count, !importWasCancelled else { break }
            logger.info("Import attempt \(attempt + 1) produced no file, retrying")
            await MainActor.run { uploadProgressText = "Waiting for iCloud…" }
            try? await Task.sleep(nanoseconds: Self.importRetryDelays[attempt])
            await MainActor.run { uploadProgressText = "Importing from Photos…" }
        }
        if let lastError { throw lastError }
        return nil
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
            importGeneration += 1
            let gen = importGeneration
            return try await withCheckedThrowingContinuation { continuation in
                let progress = item.loadTransferable(type: VideoTransferable.self) { result in
                    Task { @MainActor in
                        // Only tear down state still owned by this import
                        guard gen == self.importGeneration else { return }
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
                        guard let self, gen == self.importGeneration else { return }
                        self.importProgress = fraction
                        ProcessingBackgroundKeeper.importing.updateProgress(fraction, subtitle: self.currentVideoName)
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

    /// The name prompt caps input, but the coordinator is shared API — enforce the
    /// same limits here so no caller can inject unbounded or control-character names.
    private static func sanitizedCustomName(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = name
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(100))
    }

    /// Save video from URL to final destination. Returns whether the video landed in the library.
    private func saveVideoFromURL(_ sourceURL: URL, destinationFolder: String, customName: String?) async -> Bool {
        do {
            let fileName = "Video_\(DateFormatter.yyyyMMdd_HHmmss.string(from: Date()))_\(UUID().uuidString.prefix(4)).mp4"
            let baseURL = StorageManager.getPersistentStorageDirectory()
            let destinationURL = baseURL
                .appendingPathComponent(destinationFolder)
                .appendingPathComponent(fileName)

            // Folder paths are validated at creation, but never trust a caller-supplied
            // path to stay inside the library — reject anything that resolves outside
            // the storage root (e.g. a "../" segment).
            let rootPath = baseURL.standardizedFileURL.path
            guard destinationURL.standardizedFileURL.path.hasPrefix(rootPath + "/") else {
                logger.error("Rejected upload destination outside storage root")
                try? FileManager.default.removeItem(at: sourceURL)
                return false
            }

            // Ensure directory exists
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )

            // Move file (O(1) rename on same filesystem, avoids full copy)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

            let resolvedName: String
            if let name = Self.sanitizedCustomName(customName) {
                resolvedName = name
            } else {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "dd/MM/yyyy"
                resolvedName = "Uploaded video \(dateFormatter.string(from: Date()))"
            }

            // Add to MediaStore
            let success = mediaStore.addVideo(
                at: destinationURL,
                toFolder: destinationFolder,
                customName: resolvedName
            )

            if success {
                logger.info("Video upload completed: \(fileName)")
            } else {
                logger.error("Failed to add video to MediaStore: \(fileName)")
            }
            return success

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
            return false
        }
    }

    func handleUploadCompletion() async {
        // The save window is sub-second; if the user confirmed cancel during it,
        // don't resurrect the pill with a completion state.
        guard !importWasCancelled else { return }

        await MainActor.run {
            endImportContinuation(success: true)
            showCompleted = true
        }

        // Auto-dismiss after 2 seconds to keep it simple
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        await MainActor.run {
            isUploadInProgress = false
            showCompleted = false
            importProgress = nil
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