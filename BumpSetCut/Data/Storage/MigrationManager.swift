//
//  MigrationManager.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 9/1/25.
//

import Foundation
import os

enum MigrationError: Error {
    case migrationFailed(String)
    case rollbackFailed(String)
    case invalidState(String)
}

struct MigrationResult {
    let success: Bool
    let migratedCount: Int
    let errors: [String]
    let duration: TimeInterval
    let backupPath: URL?
}

@MainActor
class MigrationManager: ObservableObject {
    private let logger = Logger(subsystem: "BumpSetCut", category: "Migration")
    private let mediaStore: MediaStore
    
    @Published var isRunning = false
    @Published var progress: Double = 0.0
    @Published var currentOperation = ""
    
    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
    }
    
    func runMigrations() async throws -> MigrationResult {
        guard !isRunning else {
            throw MigrationError.invalidState("Migration already in progress")
        }
        
        isRunning = true
        progress = 0.0
        currentOperation = "Starting migration..."
        
        let startTime = Date()
        var migratedCount = 0
        var errors: [String] = []
        var backupPath: URL?
        
        defer {
            isRunning = false
            progress = 0.0
            currentOperation = ""
        }
        
        do {
            // Step 1: Create backup
            currentOperation = "Creating backup..."
            progress = 0.1
            backupPath = try await createBackup()
            logger.info("Backup created at: \(backupPath?.path ?? "unknown")")
            
            // Step 2: Check if migration is needed
            currentOperation = "Checking migration requirements..."
            progress = 0.2
            
            let needsMigration = try await checkMigrationNeeded()
            if !needsMigration {
                logger.info("No migration needed")
                return MigrationResult(
                    success: true,
                    migratedCount: 0,
                    errors: [],
                    duration: Date().timeIntervalSince(startTime),
                    backupPath: backupPath
                )
            }
            
            // Step 3: Run folder structure migration
            currentOperation = "Migrating to folder structure..."
            progress = 0.3
            
            let folderMigration = FolderMigration(mediaStore: mediaStore)
            migratedCount = try await folderMigration.migrate { progressPercent, operation in
                await MainActor.run {
                    self.progress = 0.3 + (progressPercent * 0.6) // 30% to 90%
                    self.currentOperation = operation
                }
            }
            
            // Step 4: Validate migration
            currentOperation = "Validating migrated data..."
            progress = 0.9
            
            try await validateMigration()
            
            // Step 5: Complete
            currentOperation = "Migration completed successfully"
            progress = 1.0
            
            logger.info("Migration completed successfully. Migrated \(migratedCount) videos")
            
            return MigrationResult(
                success: true,
                migratedCount: migratedCount,
                errors: errors,
                duration: Date().timeIntervalSince(startTime),
                backupPath: backupPath
            )
            
        } catch {
            logger.error("Migration failed: \(error.localizedDescription)")
            errors.append(error.localizedDescription)
            
            // Attempt rollback if backup exists
            if let backupPath = backupPath {
                currentOperation = "Migration failed, attempting rollback..."
                do {
                    try await rollback(from: backupPath)
                    logger.info("Rollback completed successfully")
                } catch {
                    logger.error("Rollback failed: \(error.localizedDescription)")
                    errors.append("Rollback failed: \(error.localizedDescription)")
                }
            }
            
            return MigrationResult(
                success: false,
                migratedCount: migratedCount,
                errors: errors,
                duration: Date().timeIntervalSince(startTime),
                backupPath: backupPath
            )
        }
    }
    
    private func checkMigrationNeeded() async throws -> Bool {
        // Check if there are videos in the old flat structure that need migration
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let files = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            let videoFiles = files.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mov" || ext == "mp4"
            }
            
            // If there are video files in the root documents directory, migration is needed
            return !videoFiles.isEmpty
        } catch {
            logger.error("Failed to check migration requirements: \(error.localizedDescription)")
            return false
        }
    }
    
    private func createBackup() async throws -> URL {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = documentsURL.appendingPathComponent("BumpSetCut_Backup_\(timestamp)", isDirectory: true)
        
        try fileManager.createDirectory(at: backupURL, withIntermediateDirectories: true, attributes: nil)
        
        // Copy all video files to backup
        let files = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
        let videoFiles = files.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "mov" || ext == "mp4"
        }
        
        for videoFile in videoFiles {
            let backupFile = backupURL.appendingPathComponent(videoFile.lastPathComponent)
            try fileManager.copyItem(at: videoFile, to: backupFile)
        }
        
        return backupURL
    }
    
    private func validateMigration() async throws {
        // Validate that all videos have been properly migrated
        let videos = mediaStore.getVideos(in: "")
        
        for video in videos {
            // Check that video file exists at expected location
            let videoURL = mediaStore.baseDirectory.appendingPathComponent(video.folderPath).appendingPathComponent(video.fileName)
            
            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                throw MigrationError.migrationFailed("Video file not found after migration: \(video.fileName)")
            }
            
            // Validate metadata consistency
            guard video.displayName.count > 0 else {
                throw MigrationError.migrationFailed("Invalid video metadata for: \(video.fileName)")
            }
        }
        
        logger.info("Migration validation completed successfully")
    }
    
    private func rollback(from backupURL: URL) async throws {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let bumpSetCutURL = documentsURL.appendingPathComponent("BumpSetCut", isDirectory: true)
        
        // Remove the new folder structure
        if fileManager.fileExists(atPath: bumpSetCutURL.path) {
            try fileManager.removeItem(at: bumpSetCutURL)
        }
        
        // Restore video files from backup
        let backupFiles = try fileManager.contentsOfDirectory(at: backupURL, includingPropertiesForKeys: nil)
        
        for backupFile in backupFiles {
            let originalFile = documentsURL.appendingPathComponent(backupFile.lastPathComponent)
            try fileManager.copyItem(at: backupFile, to: originalFile)
        }
        
        logger.info("Rollback completed successfully")
    }
    
    func cleanupBackups(olderThan days: Int = 7) async throws {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        let files = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.creationDateKey])
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        
        for file in files {
            guard file.lastPathComponent.hasPrefix("BumpSetCut_Backup_") else { continue }
            
            if let creationDate = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
               creationDate < cutoffDate {
                try fileManager.removeItem(at: file)
                logger.info("Cleaned up old backup: \(file.lastPathComponent)")
            }
        }
    }
}