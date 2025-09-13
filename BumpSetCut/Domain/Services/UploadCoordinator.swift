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
import os

// MARK: - Enhanced Upload Coordinator

@MainActor
class UploadCoordinator: ObservableObject {
    private let mediaStore: MediaStore
    let uploadManager: UploadManager
    private let logger = Logger(subsystem: "BumpSetCut", category: "UploadCoordinator")
    
    @Published var isUploadInProgress = false
    @Published var showingUploadProgress = false
    @Published var showCompleted = false
    
    // Publisher for notifying when upload is completed
    private let uploadCompletedSubject = PassthroughSubject<Void, Never>()
    var uploadCompletedPublisher: AnyPublisher<Void, Never> {
        uploadCompletedSubject.eraseToAnyPublisher()
    }
    
    // Upload flow state
    private var pendingUploads: [PhotosPickerItem] = []
    private var currentUploadIndex = 0
    private var currentFolderPath: String = ""
    
    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
        self.uploadManager = UploadManager(mediaStore: mediaStore)
        setupUploadCompletionListener()
    }
    
    private func setupUploadCompletionListener() {
        // Removed old notification-based system - now using direct completion handling
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
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                logger.warning("Failed to load data for item \(index)")
                continue
            }
            
            let fileName = "VID_\(Date().timeIntervalSince1970).mp4"
            await uploadManager.addUpload(
                data: data,
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
            Task { @MainActor in
                logger.info("About to present VideoUploadNamingDialog")
                
                await VideoUploadNamingDialog(
                    uploadItem: uploadItem,
                    onName: { customName in
                        Task { @MainActor in
                            uploadItem.displayName = customName
                            uploadItem.finalName = customName
                            self.logger.info("Video named: \(customName)")
                            continuation.resume()
                        }
                    },
                    onSkip: {
                        Task { @MainActor in
                            self.logger.info("Video naming skipped")
                            continuation.resume()
                        }
                    },
                    onCancel: {
                        Task { @MainActor in
                            uploadItem.cancel()
                            self.logger.info("Video naming cancelled")
                            continuation.resume()
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
            Task {
                await FolderSelectionPopup(
                    mediaStore: mediaStore,
                    currentFolderPath: currentFolderPath,
                    onFolderSelected: { selectedPath in
                        Task {
                            uploadItem.destinationFolderPath = selectedPath
                            continuation.resume()
                        }
                    },
                    onCancel: {
                        Task {
                            uploadItem.cancel()
                            continuation.resume()
                        }
                    }
                ).present()
            }
        }
    }
    
    private func waitForUploadCompletion(_ uploadItem: UploadItem) async {
        while true {
            switch uploadItem.status {
            case .complete, .cancelled, .failed:
                return
            default:
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
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
        guard let data = try? Data(contentsOf: url) else { return }
        
        await MainActor.run {
            uploadCoordinator.isUploadInProgress = true
        }
        
        await uploadCoordinator.uploadManager.addUpload(
            data: data,
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
        
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                logger.warning("Failed to load data for item \(index)")
                continue
            }
            
            print("✅ Loaded data for item \(index), size: \(data.count) bytes")
            
            // Save directly to MediaStore without the fake upload simulation
            await saveVideoDirectly(data: data, destinationFolder: destinationFolder)
        }
        
        print("✨ Finished processing all items")
        await handleUploadCompletion()
    }
    
    private func saveVideoDirectly(data: Data, destinationFolder: String) async {
        do {
            let fileName = "Video_\(DateFormatter.yyyyMMdd_HHmmss.string(from: Date())).mp4"
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
            
            // Write file
            try data.write(to: destinationURL)
            print("✅ Successfully wrote file to: \(destinationURL.path)")
            
            // Create auto-generated name for uploaded video
            let uploadDate = DateFormatter.shortDate.string(from: Date())
            let autoName = "Uploaded video \(uploadDate)"
            
            // Add to MediaStore with auto-generated name
            let success = mediaStore.addVideo(
                at: destinationURL,
                toFolder: destinationFolder,
                customName: autoName
            )
            
            if success {
                print("✅ Video successfully added to MediaStore with name: \(autoName)")
                logger.info("Video upload completed: \(fileName) -> \(autoName)")
            } else {
                print("❌ Failed to add video to MediaStore")
                logger.error("Failed to add video to MediaStore: \(fileName)")
            }
            
        } catch {
            logger.error("Failed to save video: \(error.localizedDescription)")
        }
    }
    
    private func handleUploadCompletion() async {
        print("🎉 All uploads completed, showing completion state")
        
        await MainActor.run {
            showCompleted = true
            
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