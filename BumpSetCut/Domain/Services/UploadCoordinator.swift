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
import os

// MARK: - Enhanced Upload Coordinator

@MainActor
class UploadCoordinator: ObservableObject {
    private let mediaStore: MediaStore
    let uploadManager: UploadManager
    private let logger = Logger(subsystem: "BumpSetCut", category: "UploadCoordinator")
    
    @Published var isUploadInProgress = false
    @Published var showingUploadProgress = false
    
    // Upload flow state
    private var pendingUploads: [PhotosPickerItem] = []
    private var currentUploadIndex = 0
    private var currentFolderPath: String = ""
    
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
        
        return await withCheckedContinuation { continuation in
            Task {
                await VideoUploadNamingDialog(
                    uploadItem: uploadItem,
                    onName: { customName in
                        Task {
                            uploadItem.displayName = customName
                            uploadItem.finalName = customName
                            continuation.resume()
                        }
                    },
                    onSkip: {
                        Task {
                            // Keep original name
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
        resetUploadFlow()
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
                provider.loadObject(ofClass: URL.self) { url, error in
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
        
        await uploadCoordinator.uploadManager.addUpload(
            data: data,
            fileName: url.lastPathComponent,
            destinationFolderPath: destinationFolder
        )
        
        // Show upload progress
        await UploadProgressPopup(uploadManager: uploadCoordinator.uploadManager).present()
        
        // Start upload immediately for dropped files
        for item in uploadCoordinator.uploadManager.uploadItems {
            uploadCoordinator.uploadManager.startUpload(item: item)
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
        startUploadFlow(from: items, destinationFolder: destinationFolder)
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