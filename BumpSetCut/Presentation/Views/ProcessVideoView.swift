//
//  ProcessVideoView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/31/25.
//

import SwiftUI

struct ProcessVideoView: View {
    let videoURL: URL
    let mediaStore: MediaStore
    let folderPath: String
    let onComplete: () -> ()
    @Environment(\.dismiss) private var dismiss
    @State private var processor = VideoProcessor()
    @State private var currentTask: Task<Void, Never>? = nil
    @State private var currentVideoMetadata: VideoMetadata? = nil
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                createHeaderView()
                createProcessingContent()
                createActionButtons()
            }
            .padding(24)
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle("AI Processing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: createToolbar)
            .onDisappear { currentTask?.cancel() }
            .onAppear { loadCurrentVideoMetadata() }
        }
    }
}

// MARK: - Header
private extension ProcessVideoView {
    func createHeaderView() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            
            Text("Rally Detection")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("AI will analyze your video to remove dead time and keep only active rallies")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Processing Content
private extension ProcessVideoView {
    func createProcessingContent() -> some View {
        VStack(spacing: 16) {
            if processor.isProcessing {
                createProcessingView()
            } else if processor.processedURL != nil {
                createCompletedView()
            } else {
                createReadyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
    
    func createProcessingView() -> some View {
        VStack(spacing: 12) {
            ProgressView(value: min(1.0, max(0.0, processor.progress)))
                .progressViewStyle(LinearProgressViewStyle())
            
            Text("Processing video... \(Int(min(100.0, max(0.0, processor.progress * 100))))%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    func createCompletedView() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.green)
            
            Text("Processing Complete!")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text("Your video has been processed and saved to your library")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
        }
    }
    
    func createReadyView() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "play.circle")
                .font(.system(size: 32))
                .foregroundColor(.blue)
            
            Text("Ready to Process")
                .font(.headline)
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Action Buttons
private extension ProcessVideoView {
    func createActionButtons() -> some View {
        VStack(spacing: 12) {
            if processor.isProcessing {
                // No buttons during processing
                EmptyView()
            } else if processor.processedURL != nil {
                createDoneButton()
            } else if let metadata = currentVideoMetadata, !metadata.canBeProcessed {
                createAlreadyProcessedMessage()
            } else {
                createStartButtons()
            }
        }
    }
    
    func createStartButtons() -> some View {
        VStack(spacing: 14) {
            // AI Processing Button - Primary action
            Button(action: { startProcessing(isDebugMode: false) }) {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 16, weight: .medium))
                    Text("Start AI Processing")
                        .font(.system(size: 16, weight: .semibold))
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [Color.blue, Color.blue.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(12)
                .shadow(color: .blue.opacity(0.3), radius: 4, x: 0, y: 2)
            }
            
            // Debug Processing Button - Secondary action
            Button(action: { startProcessing(isDebugMode: true) }) {
                HStack(spacing: 8) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 16, weight: .medium))
                    Text("Start Debug Processing")
                        .font(.system(size: 16, weight: .medium))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            
            Text("AI Processing removes dead time • Debug Processing includes analysis data")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }
    
    func createAlreadyProcessedMessage() -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                Image(systemName: processingStatusIcon)
                    .font(.system(size: 40))
                    .foregroundColor(processingStatusColor)
                
                Text(processingStatusTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            
            VStack(spacing: 8) {
                Text(processingStatusDescription)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                if let detailText = processingStatusDetail {
                    Text(detailText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                }
            }
        }
        .padding(24)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Processing Status Helpers
    
    private var processingStatusIcon: String {
        guard let metadata = currentVideoMetadata else { return "video.slash" }
        
        if metadata.isProcessed {
            return "checkmark.seal.fill"
        } else {
            return "arrow.branch"
        }
    }
    
    private var processingStatusColor: Color {
        guard let metadata = currentVideoMetadata else { return .secondary }
        
        if metadata.isProcessed {
            return .orange
        } else {
            return .blue
        }
    }
    
    private var processingStatusTitle: String {
        guard let metadata = currentVideoMetadata else { return "Cannot Process" }
        
        if metadata.isProcessed {
            return "Processed Video"
        } else {
            return "Already Has Versions"
        }
    }
    
    private var processingStatusDescription: String {
        guard let metadata = currentVideoMetadata else { 
            return "This video cannot be processed."
        }
        
        if metadata.isProcessed {
            return "This video is the result of AI processing and cannot be processed again. Only original videos can be processed."
        } else {
            let count = metadata.processedVideoIds.count
            return "This original video already has \(count) processed version\(count == 1 ? "" : "s"). To avoid duplicates, videos can only be processed once."
        }
    }
    
    private var processingStatusDetail: String? {
        guard let metadata = currentVideoMetadata else { return nil }
        
        if metadata.isProcessed {
            return "Result of AI processing"
        } else if !metadata.processedVideoIds.isEmpty {
            let count = metadata.processedVideoIds.count
            return "\(count) processed version\(count == 1 ? "" : "s") exist"
        }
        return nil
    }
    
    func createDoneButton() -> some View {
        Button(action: { dismiss() }) {
            HStack {
                Image(systemName: "checkmark")
                Text("Done")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }
}

// MARK: - Toolbar
private extension ProcessVideoView {
    func createToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if !processor.isProcessing {
                Button("Cancel") {
                    currentTask?.cancel()
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Helpers
private extension ProcessVideoView {
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
        
        // If not found, this is likely a new video that hasn't been added to MediaStore yet
        currentVideoMetadata = nil
    }
    
    func getVideoDisplayName() -> String {
        // First try to find the video in MediaStore by URL to get its display name
        let fileName = videoURL.lastPathComponent
        
        // Search through all videos in the folder to find the matching one
        let videosInFolder = mediaStore.getVideos(in: folderPath)
        if let matchingVideo = videosInFolder.first(where: { $0.fileName == fileName }) {
            return matchingVideo.displayName
        }
        
        // Also check other folders in case the video was moved
        let allFolders = mediaStore.getFolders(in: "")
        for folder in allFolders {
            let videosInOtherFolder = mediaStore.getVideos(in: folder.path)
            if let matchingVideo = videosInOtherFolder.first(where: { $0.fileName == fileName }) {
                return matchingVideo.displayName
            }
        }
        
        // Check root folder too
        let rootVideos = mediaStore.getVideos(in: "")
        if let matchingVideo = rootVideos.first(where: { $0.fileName == fileName }) {
            return matchingVideo.displayName
        }
        
        // Fallback to filename without extension
        return videoURL.deletingPathExtension().lastPathComponent
    }
    
    func getNextProcessedVideoName(originalDisplayName: String, prefix: String) -> String {
        // Get all videos in the current folder
        let videosInFolder = mediaStore.getVideos(in: folderPath)
        
        // Find existing processed videos with this base name
        let existingNumbers = videosInFolder.compactMap { video -> Int? in
            let displayName = video.displayName
            // Check if it matches the pattern: "Prefix## OriginalName"
            if displayName.hasPrefix("\(prefix)") && displayName.hasSuffix(" \(originalDisplayName)") {
                let afterPrefix = String(displayName.dropFirst(prefix.count))
                let beforeOriginalName = String(afterPrefix.dropLast(" \(originalDisplayName)".count))
                return Int(beforeOriginalName)
            }
            return nil
        }
        
        // Find the next available number
        let nextNumber = (existingNumbers.max() ?? 0) + 1
        let sanitizedDisplayName = sanitizeFilename(originalDisplayName)
        return String(format: "%@%02d %@", prefix, nextNumber, sanitizedDisplayName)
    }
    
    /// Sanitize filename by removing or replacing invalid characters
    func sanitizeFilename(_ filename: String) -> String {
        // Replace invalid characters with safe alternatives
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = filename.components(separatedBy: invalidChars).joined(separator: "-")
        
        // Remove leading/trailing whitespace and dots
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        
        // Ensure the filename isn't empty
        return trimmed.isEmpty ? "Video" : trimmed
    }
}

// MARK: - Actions
private extension ProcessVideoView {
    func startProcessing(isDebugMode: Bool) {
        // Cancel any in-flight job (e.g., a stuck debug run) before starting
        currentTask?.cancel()
        // Debug data reset
        
        currentTask = Task {
            do {
                let tempProcessedURL: URL
                let debugData: TrajectoryDebugger?
                
                if isDebugMode {
                    tempProcessedURL = try await processor.processVideoDebug(videoURL)
                    debugData = processor.trajectoryDebugger
                } else {
                    tempProcessedURL = try await processor.processVideo(videoURL)
                    debugData = nil
                }
                
                await MainActor.run { 
                    currentTask = nil
                }
                
                // Move processed video to MediaStore directory structure
                let originalDisplayName = getVideoDisplayName()
                let prefix = isDebugMode ? "Debug" : "Processed"
                let processedName = getNextProcessedVideoName(originalDisplayName: originalDisplayName, prefix: prefix)
                let processedFileName = "\(processedName).mp4"
                
                // Get MediaStore base directory and target folder
                let mediaStoreBase = mediaStore.baseDirectory
                let targetDirectory = folderPath.isEmpty ? mediaStoreBase : mediaStoreBase.appendingPathComponent(folderPath)
                let finalURL = targetDirectory.appendingPathComponent(processedFileName)
                
                let logPrefix = isDebugMode ? "🐛" : "🎬"
                print("\(logPrefix) Moving \(isDebugMode ? "debug" : "processed") video to MediaStore directory:")
                print("   - TempURL: \(tempProcessedURL)")
                print("   - TargetDirectory: \(targetDirectory)")
                print("   - FinalURL: \(finalURL)")
                
                // Ensure target directory exists
                try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true, attributes: nil)
                
                // Move file from temp location to final location
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: tempProcessedURL, to: finalURL)
                print("✅ Successfully moved \(isDebugMode ? "debug" : "processed") video to: \(finalURL)")
                
                // Add processed video to MediaStore
                print("\(logPrefix) About to add \(isDebugMode ? "debug" : "processed") video to MediaStore:")
                print("   - ProcessedURL: \(finalURL)")
                print("   - FolderPath: '\(folderPath)'")
                print("   - ProcessedName: '\(processedName)'")
                print("   - File exists: \(FileManager.default.fileExists(atPath: finalURL.path))")
                
                // Get the original video ID
                let originalVideoId = currentVideoMetadata?.id ?? UUID() // Fallback UUID if metadata not found
                
                // Use the new addProcessedVideo method
                let success = mediaStore.addProcessedVideo(at: finalURL, toFolder: folderPath, customName: processedName, originalVideoId: originalVideoId)
                print("Added \(isDebugMode ? "debug" : "processed") video to MediaStore in folder '\(folderPath)': \(success ? "✅ Success" : "❌ Failed")")
                
                // Save debug data if available and video was successfully added
                if isDebugMode, success, let debugger = debugData {
                    do {
                        // Find the video metadata that was just added
                        if let addedVideo = mediaStore.getVideos(in: folderPath).first(where: { $0.displayName == processedName }) {
                            // Export debug data to JSON
                            if let jsonData = debugger.exportToJSON() {
                                let sessionId = UUID()
                                
                                // Save debug data to MediaStore
                                let debugPath = try mediaStore.saveDebugData(
                                    for: addedVideo.id,
                                    debugData: jsonData,
                                    sessionId: sessionId
                                )
                                
                                print("🐛 Debug data saved: \(debugPath)")
                            } else {
                                print("❌ Failed to export debug data to JSON")
                            }
                        }
                    } catch {
                        print("❌ Failed to save debug data: \(error)")
                        // Don't fail the entire process if debug data saving fails
                    }
                }
                
                await MainActor.run {
                    print("🔄 Calling onComplete() to refresh library...")
                    onComplete() // Refresh the library
                    print("✅ onComplete() called")
                }
            } catch is CancellationError {
                await MainActor.run { 
                    currentTask = nil 
                    processor.isProcessing = false
                }
                print("\(isDebugMode ? "Debug p" : "P")rocessing cancelled by user")
            } catch {
                await MainActor.run { 
                    currentTask = nil 
                    processor.isProcessing = false
                }
                print("\(isDebugMode ? "Debug p" : "P")rocessing failed: \(error)")
            }
        }
    }
}
