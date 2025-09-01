//
//  UploadManager.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import Foundation
import UIKit
import AVFoundation
import os

// MARK: - Upload Item Models

enum UploadStatus: Equatable {
    case pending
    case naming
    case selectingFolder
    case uploading(progress: Double, transferRate: String?, eta: String?)
    case complete
    case cancelled
    case failed(error: String)
}

@MainActor
class UploadItem: ObservableObject, Identifiable {
    let id = UUID()
    let sourceData: Data
    let originalFileName: String
    let fileSize: Int64
    
    @Published var displayName: String
    @Published var finalName: String?
    @Published var destinationFolderPath: String
    @Published var status: UploadStatus = .pending
    @Published var thumbnail: UIImage?
    @Published var canCancel: Bool = true
    
    private var uploadTask: Task<Void, Never>?
    
    init(sourceData: Data, originalFileName: String, fileSize: Int64, destinationFolderPath: String = "") {
        self.sourceData = sourceData
        self.originalFileName = originalFileName
        self.fileSize = fileSize
        self.displayName = originalFileName
        self.destinationFolderPath = destinationFolderPath
    }
    
    var statusDescription: String {
        switch status {
        case .pending:
            return "Waiting..."
        case .naming:
            return "Choosing name..."
        case .selectingFolder:
            return "Selecting folder..."
        case .uploading(let progress, _, _):
            return "Uploading \(Int(progress * 100))%"
        case .complete:
            return "Complete"
        case .cancelled:
            return "Cancelled"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
    
    func cancel() {
        guard canCancel else { return }
        uploadTask?.cancel()
        status = .cancelled
        canCancel = false
    }
    
    func setUploadTask(_ task: Task<Void, Never>) {
        self.uploadTask = task
    }
}

// MARK: - Upload Manager

@MainActor
class UploadManager: ObservableObject {
    private let mediaStore: MediaStore
    private let logger = Logger(subsystem: "BumpSetCut", category: "UploadManager")
    
    @Published var uploadItems: [UploadItem] = []
    var isActive: Bool { !uploadItems.isEmpty && !isComplete }
    var isComplete: Bool { uploadItems.allSatisfy { 
        switch $0.status {
        case .complete, .cancelled, .failed: return true
        default: return false
        }
    }}
    var canCancel: Bool { uploadItems.contains { $0.canCancel } }
    
    var totalItems: Int { uploadItems.count }
    var completedItems: Int { 
        uploadItems.filter { 
            switch $0.status {
            case .complete: return true
            default: return false
            }
        }.count 
    }
    var overallProgress: Double {
        guard totalItems > 0 else { return 0 }
        let totalProgress = uploadItems.reduce(0.0) { result, item in
            switch item.status {
            case .complete: return result + 1.0
            case .uploading(let progress, _, _): return result + progress
            default: return result
            }
        }
        return totalProgress / Double(totalItems)
    }
    
    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
    }
    
    // MARK: - Upload Management
    
    func addUpload(data: Data, fileName: String, destinationFolderPath: String = "") async {
        let fileSize = Int64(data.count)
        let uploadItem = UploadItem(
            sourceData: data,
            originalFileName: fileName,
            fileSize: fileSize,
            destinationFolderPath: destinationFolderPath
        )
        
        uploadItems.append(uploadItem)
        
        // Generate thumbnail
        await generateThumbnail(for: uploadItem)
        
        logger.info("Added upload item: \(fileName) (\(fileSize) bytes)")
    }
    
    func startUpload(item: UploadItem, customName: String? = nil, folderPath: String? = nil) {
        let task = Task {
            await performUpload(item: item, customName: customName, folderPath: folderPath)
        }
        item.setUploadTask(task)
    }
    
    func startAllUploads() {
        for item in uploadItems {
            guard case .pending = item.status else { continue }
            startUpload(item: item)
        }
    }
    
    func cancelUpload(_ itemId: UUID) {
        guard let item = uploadItems.first(where: { $0.id == itemId }) else { return }
        item.cancel()
        logger.info("Cancelled upload: \(item.originalFileName)")
    }
    
    func cancelAllUploads() {
        for item in uploadItems {
            item.cancel()
        }
        logger.info("Cancelled all uploads")
    }
    
    func clearCompleted() {
        uploadItems.removeAll { 
            switch $0.status {
            case .complete, .cancelled: return true
            default: return false
            }
        }
    }
    
    func reset() {
        cancelAllUploads()
        uploadItems.removeAll()
    }
    
    // MARK: - Private Upload Implementation
    
    private func performUpload(item: UploadItem, customName: String?, folderPath: String?) async {
        do {
            // Update final name and destination
            if let customName = customName {
                item.finalName = customName
                item.displayName = customName
            }
            if let folderPath = folderPath {
                item.destinationFolderPath = folderPath
            }
            
            // Simulate upload progress
            try await simulateUploadProgress(item: item)
            
            // Save to media store
            let fileName = UUID().uuidString + ".mp4"
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let destinationURL = documentsURL.appendingPathComponent("BumpSetCut")
                .appendingPathComponent(item.destinationFolderPath)
                .appendingPathComponent(fileName)
            
            // Ensure directory exists
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            
            // Write file
            try item.sourceData.write(to: destinationURL)
            
            // Add to MediaStore
            let success = mediaStore.addVideo(
                at: destinationURL,
                toFolder: item.destinationFolderPath,
                customName: item.finalName
            )
            
            if success {
                item.status = .complete
                item.canCancel = false
                logger.info("Upload completed: \(item.displayName)")
                
                // Post completion notification
                NotificationCenter.default.post(name: .uploadCompleted, object: item)
            } else {
                throw UploadError.saveError("Failed to save to media store")
            }
            
        } catch {
            if error is CancellationError {
                item.status = .cancelled
            } else {
                item.status = .failed(error: error.localizedDescription)
            }
            item.canCancel = false
            logger.error("Upload failed: \(item.displayName) - \(error.localizedDescription)")
        }
    }
    
    private func simulateUploadProgress(item: UploadItem) async throws {
        let totalSteps = 100
        let stepDuration: UInt64 = 50_000_000 // 50ms
        
        for step in 0...totalSteps {
            try Task.checkCancellation()
            
            let progress = Double(step) / Double(totalSteps)
            let transferRate = formatTransferRate(bytesPerSecond: Double(item.fileSize) / 5.0) // Assume 5 second upload
            let remainingSeconds = Double(totalSteps - step) * 0.05
            let eta = formatETA(seconds: remainingSeconds)
            
            item.status = .uploading(progress: progress, transferRate: transferRate, eta: eta)
            
            if step < totalSteps {
                try await Task.sleep(nanoseconds: stepDuration)
            }
        }
    }
    
    private func generateThumbnail(for item: UploadItem) async {
        // Create temporary file to generate thumbnail
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        
        do {
            try item.sourceData.write(to: tempURL)
            
            if let thumbnail = await VideoThumbnailGenerator.generateThumbnail(from: tempURL) {
                item.thumbnail = thumbnail
            }
            
            // Clean up temporary file
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            logger.error("Failed to generate thumbnail: \(error.localizedDescription)")
        }
    }
    
    private func formatTransferRate(bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .binary
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }
    
    private func formatETA(seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s left"
        } else {
            let minutes = Int(seconds) / 60
            return "\(minutes)m left"
        }
    }
}

// MARK: - Upload Errors

enum UploadError: LocalizedError {
    case saveError(String)
    case invalidData
    case networkError(String)
    
    var errorDescription: String? {
        switch self {
        case .saveError(let message):
            return message
        case .invalidData:
            return "Invalid video data"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

// MARK: - Video Thumbnail Generator

struct VideoThumbnailGenerator {
    static func generateThumbnail(from url: URL) async -> UIImage? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                let asset = AVAsset(url: url)
                let imageGenerator = AVAssetImageGenerator(asset: asset)
                imageGenerator.appliesPreferredTrackTransform = true
                
                let time = CMTime(seconds: 1.0, preferredTimescale: 600)
                
                do {
                    let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
                    let thumbnail = UIImage(cgImage: cgImage)
                    continuation.resume(returning: thumbnail)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}