//
//  FolderMigration.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 9/1/25.
//

import Foundation
import os

class FolderMigration {
    private let logger = Logger(subsystem: "BumpSetCut", category: "FolderMigration")
    private let mediaStore: MediaStore
    private let batchSize = 10
    
    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
    }
    
    @MainActor
    func migrate(progressCallback: @escaping (Double, String) async -> Void) async throws -> Int {
        logger.info("Starting folder structure migration")
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let bumpSetCutURL = documentsURL.appendingPathComponent("BumpSetCut", isDirectory: true)
        
        // Step 1: Create BumpSetCut directory structure
        await progressCallback(0.1, "Creating folder structure...")
        try fileManager.createDirectory(at: bumpSetCutURL, withIntermediateDirectories: true, attributes: nil)
        
        // Step 2: Find all video files in root documents
        await progressCallback(0.2, "Scanning for videos...")
        let files = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])
        let videoFiles = files.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "mov" || ext == "mp4"
        }
        
        logger.info("Found \(videoFiles.count) video files to migrate")
        
        if videoFiles.isEmpty {
            await progressCallback(1.0, "No videos to migrate")
            return 0
        }
        
        // Step 3: Process videos in batches
        var migratedCount = 0
        let totalCount = videoFiles.count
        
        for (index, videoURL) in videoFiles.enumerated() {
            let progress = 0.2 + (Double(index) / Double(totalCount)) * 0.7 // 20% to 90%
            await progressCallback(progress, "Migrating video \(index + 1) of \(totalCount): \(videoURL.lastPathComponent)")
            
            do {
                try await migrateVideo(videoURL, to: bumpSetCutURL)
                migratedCount += 1
                
                // Small delay to prevent overwhelming the system
                if index % batchSize == 0 && index > 0 {
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                }
            } catch {
                logger.error("Failed to migrate video \(videoURL.lastPathComponent): \(error.localizedDescription)")
                // Continue with other videos instead of failing completely
            }
        }
        
        // Step 4: Trigger MediaStore migration to update manifest
        await progressCallback(0.95, "Updating metadata...")
        mediaStore.migrateExistingVideos()
        
        await progressCallback(1.0, "Migration completed")
        logger.info("Successfully migrated \(migratedCount) of \(totalCount) videos")
        
        return migratedCount
    }
    
    private func migrateVideo(_ videoURL: URL, to bumpSetCutURL: URL) async throws {
        let fileManager = FileManager.default
        let fileName = videoURL.lastPathComponent
        
        // Move video file to BumpSetCut directory (root level)
        var newVideoURL = bumpSetCutURL.appendingPathComponent(fileName)
        
        // Check if destination already exists
        if fileManager.fileExists(atPath: newVideoURL.path) {
            // Generate unique name if conflict
            let baseName = videoURL.deletingPathExtension().lastPathComponent
            let ext = videoURL.pathExtension
            var counter = 1
            var uniqueURL = newVideoURL
            
            while fileManager.fileExists(atPath: uniqueURL.path) {
                let uniqueName = "\(baseName)_\(counter).\(ext)"
                uniqueURL = bumpSetCutURL.appendingPathComponent(uniqueName)
                counter += 1
            }
            
            newVideoURL = uniqueURL
        }
        
        // Move the file
        try fileManager.moveItem(at: videoURL, to: newVideoURL)
        logger.debug("Moved video: \(fileName) -> \(newVideoURL.lastPathComponent)")
    }
}