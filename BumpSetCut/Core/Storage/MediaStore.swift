//
//  MediaStore.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import Foundation
import Observation

// MARK: - Library Type

enum LibraryType: String, Codable, CaseIterable {
    case saved = "saved"
    case processed = "processed"
    case favorites = "favorites"

    var rootPath: String {
        switch self {
        case .saved: return "SavedGames"
        case .processed: return "ProcessedGames"
        case .favorites: return "FavoriteRallies"
        }
    }

    var displayName: String {
        switch self {
        case .saved: return "Library"
        case .processed: return "Processed Games"
        case .favorites: return "Favorite Rallies"
        }
    }
}

// MARK: - Storage Utilities

struct StorageManager {
    static func getPersistentStorageDirectory() -> URL {
        let fileManager = FileManager.default
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BumpSetCut", isDirectory: true)
    }
    
    static func verifyStorageIntegrity() {
        let baseDir = getPersistentStorageDirectory()
        let fileManager = FileManager.default
        
        print("StorageManager: Verifying storage at: \(baseDir.path)")
        print("StorageManager: Directory exists: \(fileManager.fileExists(atPath: baseDir.path))")
        
        if fileManager.fileExists(atPath: baseDir.path) {
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: baseDir.path)
                print("StorageManager: Directory contents: \(contents)")
            } catch {
                print("StorageManager: Error reading directory: \(error)")
            }
        }
    }
}


// MARK: - Video Metadata Models

struct VideoMetadata: Codable, Identifiable, Hashable {
    let id: UUID
    let fileName: String
    var customName: String?
    var folderPath: String
    let createdDate: Date
    let fileSize: Int64
    let duration: TimeInterval?
    
    // Debug data fields
    var debugSessionId: UUID?
    var debugDataPath: String?
    var debugCollectionDate: Date?
    var debugDataSize: Int64?
    
    // Processing tracking fields
    var isProcessed: Bool = false
    var processedDate: Date?
    var originalVideoId: UUID? // Points to the original video if this is a processed version
    var processedVideoIds: [UUID] = [] // IDs of videos processed from this original

    // Metadata tracking fields
    var hasProcessingMetadata: Bool = false
    var metadataCreatedDate: Date?
    var metadataFileSize: Int64?

    // Volleyball type (nil for legacy videos)
    var volleyballType: VolleyballType?

    // Favorite source tracking (for syncing unfavorite back to rally player)
    var sourceVideoId: UUID?
    var sourceRallyIndex: Int?

    // Custom decoder to handle backwards compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        folderPath = try container.decode(String.self, forKey: .folderPath)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        
        // Debug fields with defaults for backwards compatibility
        debugSessionId = try container.decodeIfPresent(UUID.self, forKey: .debugSessionId)
        debugDataPath = try container.decodeIfPresent(String.self, forKey: .debugDataPath)
        debugCollectionDate = try container.decodeIfPresent(Date.self, forKey: .debugCollectionDate)
        debugDataSize = try container.decodeIfPresent(Int64.self, forKey: .debugDataSize)
        
        // Processing tracking fields with defaults for backwards compatibility
        isProcessed = try container.decodeIfPresent(Bool.self, forKey: .isProcessed) ?? false
        processedDate = try container.decodeIfPresent(Date.self, forKey: .processedDate)
        originalVideoId = try container.decodeIfPresent(UUID.self, forKey: .originalVideoId)
        processedVideoIds = try container.decodeIfPresent([UUID].self, forKey: .processedVideoIds) ?? []

        // Metadata tracking fields with defaults for backwards compatibility
        hasProcessingMetadata = try container.decodeIfPresent(Bool.self, forKey: .hasProcessingMetadata) ?? false
        metadataCreatedDate = try container.decodeIfPresent(Date.self, forKey: .metadataCreatedDate)
        metadataFileSize = try container.decodeIfPresent(Int64.self, forKey: .metadataFileSize)

        // Volleyball type with default for backwards compatibility
        volleyballType = try container.decodeIfPresent(VolleyballType.self, forKey: .volleyballType)

        // Favorite source tracking with defaults for backwards compatibility
        sourceVideoId = try container.decodeIfPresent(UUID.self, forKey: .sourceVideoId)
        sourceRallyIndex = try container.decodeIfPresent(Int.self, forKey: .sourceRallyIndex)
    }
    
    // Custom encoder
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encode(fileName, forKey: .fileName)
        try container.encodeIfPresent(customName, forKey: .customName)
        try container.encode(folderPath, forKey: .folderPath)
        try container.encode(createdDate, forKey: .createdDate)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(duration, forKey: .duration)
        
        // Debug fields
        try container.encodeIfPresent(debugSessionId, forKey: .debugSessionId)
        try container.encodeIfPresent(debugDataPath, forKey: .debugDataPath)
        try container.encodeIfPresent(debugCollectionDate, forKey: .debugCollectionDate)
        try container.encodeIfPresent(debugDataSize, forKey: .debugDataSize)
        
        // Processing tracking fields
        try container.encode(isProcessed, forKey: .isProcessed)
        try container.encodeIfPresent(processedDate, forKey: .processedDate)
        try container.encodeIfPresent(originalVideoId, forKey: .originalVideoId)
        try container.encode(processedVideoIds, forKey: .processedVideoIds)

        // Metadata tracking fields
        try container.encode(hasProcessingMetadata, forKey: .hasProcessingMetadata)
        try container.encodeIfPresent(metadataCreatedDate, forKey: .metadataCreatedDate)
        try container.encodeIfPresent(metadataFileSize, forKey: .metadataFileSize)

        // Volleyball type
        try container.encodeIfPresent(volleyballType, forKey: .volleyballType)

        // Favorite source tracking
        try container.encodeIfPresent(sourceVideoId, forKey: .sourceVideoId)
        try container.encodeIfPresent(sourceRallyIndex, forKey: .sourceRallyIndex)
    }
    
    // CodingKeys enum for custom coding
    private enum CodingKeys: String, CodingKey {
        case id, fileName, customName, folderPath, createdDate, fileSize, duration
        case debugSessionId, debugDataPath, debugCollectionDate, debugDataSize
        case isProcessed, processedDate, originalVideoId, processedVideoIds
        case hasProcessingMetadata, metadataCreatedDate, metadataFileSize
        case volleyballType
        case sourceVideoId, sourceRallyIndex
    }
    
    var displayName: String {
        customName ?? URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }
    
    var debugDataAvailable: Bool {
        return debugSessionId != nil && debugDataPath != nil
    }
    
    var isOriginalVideo: Bool {
        return originalVideoId == nil && !isProcessed
    }

    var canBeProcessed: Bool {
        // Can only process original videos that don't already have processed versions
        return isOriginalVideo && processedVideoIds.isEmpty
    }
    
    var originalURL: URL {
        let baseDirectory = StorageManager.getPersistentStorageDirectory()
        return baseDirectory
            .appendingPathComponent(folderPath)
            .appendingPathComponent(fileName)
    }

    // MARK: - Metadata Properties

    /// Path to the metadata JSON file for this video
    var metadataFilePath: URL {
        let baseDirectory = StorageManager.getPersistentStorageDirectory()
        let metadataDirectory = baseDirectory.appendingPathComponent("ProcessedMetadata", isDirectory: true)
        let filename = "\(id.uuidString).json"
        return metadataDirectory.appendingPathComponent(filename)
    }

    /// Check if metadata file exists for this video
    var hasMetadata: Bool {
        let fileManager = FileManager.default
        let metadataPath = metadataFilePath.path
        return fileManager.fileExists(atPath: metadataPath)
    }
    
    init(originalURL: URL, customName: String?, folderPath: String, createdDate: Date, fileSize: Int64, duration: TimeInterval?, volleyballType: VolleyballType? = nil) {
        self.id = UUID()
        self.fileName = originalURL.lastPathComponent
        self.customName = customName
        self.folderPath = folderPath
        self.createdDate = createdDate
        self.fileSize = fileSize
        self.duration = duration
        self.volleyballType = volleyballType
        self.debugSessionId = nil
        self.debugDataPath = nil
        self.debugCollectionDate = nil
        self.debugDataSize = nil
        self.isProcessed = false
        self.processedDate = nil
        self.originalVideoId = nil
        self.processedVideoIds = []
        self.hasProcessingMetadata = false
        self.metadataCreatedDate = nil
        self.metadataFileSize = nil
        self.sourceVideoId = nil
        self.sourceRallyIndex = nil
    }

    init(fileName: String, customName: String?, folderPath: String, createdDate: Date, fileSize: Int64, duration: TimeInterval?) {
        self.id = UUID()
        self.fileName = fileName
        self.customName = customName
        self.folderPath = folderPath
        self.createdDate = createdDate
        self.fileSize = fileSize
        self.duration = duration
        self.debugSessionId = nil
        self.debugDataPath = nil
        self.debugCollectionDate = nil
        self.debugDataSize = nil
        self.isProcessed = false
        self.processedDate = nil
        self.originalVideoId = nil
        self.processedVideoIds = []
        self.hasProcessingMetadata = false
        self.metadataCreatedDate = nil
        self.metadataFileSize = nil
        self.volleyballType = nil
        self.sourceVideoId = nil
        self.sourceRallyIndex = nil
    }
    
    // Debug data management methods
    mutating func attachDebugData(sessionId: UUID, dataPath: String, size: Int64) {
        self.debugSessionId = sessionId
        self.debugDataPath = dataPath
        self.debugCollectionDate = Date()
        self.debugDataSize = size
    }
    
    mutating func clearDebugData() {
        self.debugSessionId = nil
        self.debugDataPath = nil
        self.debugCollectionDate = nil
        self.debugDataSize = nil
    }

    // MARK: - Metadata Management Methods

    /// Update metadata tracking when metadata is created/updated
    mutating func updateMetadataTracking(fileSize: Int64) {
        self.hasProcessingMetadata = true
        self.metadataCreatedDate = Date()
        self.metadataFileSize = fileSize
    }

    /// Clear metadata tracking when metadata is deleted
    mutating func clearMetadataTracking() {
        self.hasProcessingMetadata = false
        self.metadataCreatedDate = nil
        self.metadataFileSize = nil
    }

    /// Get current metadata file size from disk (if it exists)
    func getCurrentMetadataSize() -> Int64? {
        guard hasMetadata else { return nil }

        let fileManager = FileManager.default
        do {
            let attributes = try fileManager.attributesOfItem(atPath: metadataFilePath.path)
            return attributes[.size] as? Int64
        } catch {
            return nil
        }
    }
}

// MARK: - VideoMetadata + Transferable

import CoreTransferable
import UniformTypeIdentifiers

extension VideoMetadata: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .videoMetadata)
    }
}

extension UTType {
    static var videoMetadata: UTType {
        UTType(exportedAs: "com.bumpsetcut.video-metadata")
    }
}

struct FolderMetadata: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var parentPath: String?
    let createdDate: Date
    var modifiedDate: Date
    var videoCount: Int
    var subfolderCount: Int
    
    init(name: String, path: String, parentPath: String?, createdDate: Date, modifiedDate: Date, videoCount: Int, subfolderCount: Int) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.parentPath = parentPath
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.videoCount = videoCount
        self.subfolderCount = subfolderCount
    }
}

// MARK: - Folder Manifest

struct FolderManifest: Codable {
    var folders: [String: FolderMetadata] = [:]
    var videos: [String: VideoMetadata] = [:]
    var version: Int = 1
    let createdDate: Date
    var lastModified: Date
    
    init() {
        let now = Date()
        self.createdDate = now
        self.lastModified = now
    }
    
    mutating func updateModifiedDate() {
        lastModified = Date()
    }
}

@MainActor @Observable class MediaStore {
    private var manifest: FolderManifest
    private let manifestURL: URL
    let baseDirectory: URL
    private(set) var contentVersion: Int = 0
    
    init() {
        let fileManager = FileManager.default
        
        // Use shared storage directory
        self.baseDirectory = StorageManager.getPersistentStorageDirectory()
        self.manifestURL = baseDirectory.appendingPathComponent("manifest.json")
        
        // Create base directory if it doesn't exist
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: nil)
        print("MediaStore: Base directory: \(baseDirectory.path)")
        print("MediaStore: Manifest URL: \(manifestURL.path)")
        
        // Load or create manifest
        if let data = try? Data(contentsOf: manifestURL),
           let loadedManifest = try? JSONDecoder().decode(FolderManifest.self, from: data) {
            self.manifest = loadedManifest
            print("MediaStore: Loaded manifest with \(manifest.videos.count) videos and \(manifest.folders.count) folders")
        } else {
            self.manifest = FolderManifest()
            print("MediaStore: Created new manifest")
            saveManifest()
        }
        
        // Verify storage integrity
        StorageManager.verifyStorageIntegrity()

        // Ensure library roots exist and run migration if needed
        ensureLibraryRootsExist()
        migrateToSeparateLibraries()

        // Migrate processed videos to set hasProcessingMetadata flag
        migrateProcessedVideos()

        // Clean up stale entries
        cleanupStaleEntries()

        // UI Testing: inject test video from the test runner
        injectTestVideoIfNeeded()
    }

    /// When running UI tests, symlink the test video into storage and add it to the manifest.
    private func injectTestVideoIfNeeded() {
        guard CommandLine.arguments.contains("--uitesting"),
              let testVideoPath = ProcessInfo.processInfo.environment["TEST_VIDEO_PATH"],
              FileManager.default.fileExists(atPath: testVideoPath) else { return }

        let sourceURL = URL(fileURLWithPath: testVideoPath)
        let savedDir = baseDirectory.appendingPathComponent(LibraryType.saved.rootPath)
        try? FileManager.default.createDirectory(at: savedDir, withIntermediateDirectories: true)
        let destURL = savedDir.appendingPathComponent(sourceURL.lastPathComponent)

        if !FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.createSymbolicLink(at: destURL, withDestinationURL: sourceURL)
        }

        // Only add if not already in manifest
        let videoKey = sourceURL.lastPathComponent
        if manifest.videos[videoKey] == nil {
            _ = addVideo(at: destURL, toFolder: LibraryType.saved.rootPath, customName: "Test Rally Video")
        }

        // Inject pre-processed metadata if provided (skips ML processing in UI tests)
        if let metadataPath = ProcessInfo.processInfo.environment["TEST_METADATA_PATH"],
           FileManager.default.fileExists(atPath: metadataPath),
           let videoMeta = manifest.videos[videoKey] {
            injectPreProcessedMetadata(metadataTemplatePath: metadataPath, videoMetadata: videoMeta)
        }

        // Inject a favorite video if provided (for favorites UI tests)
        if let favVideoPath = ProcessInfo.processInfo.environment["TEST_FAVORITES_VIDEO_PATH"],
           FileManager.default.fileExists(atPath: favVideoPath) {
            let favSourceURL = URL(fileURLWithPath: favVideoPath)
            let favDir = baseDirectory.appendingPathComponent(LibraryType.favorites.rootPath)
            try? FileManager.default.createDirectory(at: favDir, withIntermediateDirectories: true)
            let favDestURL = favDir.appendingPathComponent("fav_" + favSourceURL.lastPathComponent)

            if !FileManager.default.fileExists(atPath: favDestURL.path) {
                try? FileManager.default.createSymbolicLink(at: favDestURL, withDestinationURL: favSourceURL)
            }

            let favVideoKey = favDestURL.lastPathComponent
            if manifest.videos[favVideoKey] == nil {
                _ = addVideo(at: favDestURL, toFolder: LibraryType.favorites.rootPath, customName: "Test Favorite Rally")
            }
        }
    }

    /// Inject a pre-processed metadata JSON template, replacing the videoId with the actual video's UUID.
    private func injectPreProcessedMetadata(metadataTemplatePath: String, videoMetadata: VideoMetadata) {
        let fileManager = FileManager.default
        let videoId = videoMetadata.id

        // Read the template JSON
        guard let templateData = fileManager.contents(atPath: metadataTemplatePath) else {
            print("MediaStore: ⚠️ Could not read metadata template at \(metadataTemplatePath)")
            return
        }

        // Parse, replace videoId, re-encode
        guard var json = try? JSONSerialization.jsonObject(with: templateData) as? [String: Any] else {
            print("MediaStore: ⚠️ Could not parse metadata template JSON")
            return
        }

        json["videoId"] = videoId.uuidString

        guard let correctedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            print("MediaStore: ⚠️ Could not re-encode metadata JSON")
            return
        }

        // Write to ProcessedMetadata/{videoId}.json
        let metadataDir = baseDirectory.appendingPathComponent("ProcessedMetadata", isDirectory: true)
        try? fileManager.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        let destURL = metadataDir.appendingPathComponent("\(videoId.uuidString).json")

        do {
            try correctedData.write(to: destURL, options: .atomic)
            print("MediaStore: ✅ Injected pre-processed metadata for video \(videoId)")

            // Update manifest entry to reflect metadata presence and processed status
            let videoKey = videoMetadata.fileName
            if var updatedMeta = manifest.videos[videoKey] {
                updatedMeta.updateMetadataTracking(fileSize: Int64(correctedData.count))
                // Mark as processed so filter logic recognizes it
                if updatedMeta.processedVideoIds.isEmpty {
                    updatedMeta.processedVideoIds.append(videoId)
                }
                manifest.videos[videoKey] = updatedMeta
                saveManifest()
            }
        } catch {
            print("MediaStore: ❌ Failed to write metadata: \(error)")
        }
    }
    
    private func saveManifest() {
        do {
            manifest.updateModifiedDate()
            let data = try JSONEncoder().encode(manifest)

            // Atomic write: write to temp file, then replace original
            let tempURL = manifestURL.deletingLastPathComponent()
                .appendingPathComponent(".manifest_tmp_\(UUID().uuidString).json")
            try data.write(to: tempURL, options: [.atomic])

            // Use replaceItemAt for crash-safe swap (preserves file metadata)
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tempURL)

            // Increment version so @Observable consumers detect the change
            contentVersion += 1
        } catch {
            print("Failed to save manifest: \(error)")
        }
    }
    
    func cleanupStaleEntries() {
        let fileManager = FileManager.default
        var needsSave = false
        
        // Remove videos whose files no longer exist
        let staleVideoKeys = manifest.videos.keys.filter { key in
            guard let video = manifest.videos[key] else { return true }
            let videoPath = baseDirectory
                .appendingPathComponent(video.folderPath)
                .appendingPathComponent(video.fileName)
            return !fileManager.fileExists(atPath: videoPath.path)
        }
        
        for key in staleVideoKeys {
            if let video = manifest.videos[key] {
                print("Removing stale video entry: \(video.displayName) (file not found)")
                manifest.videos.removeValue(forKey: key)
                needsSave = true
                
                // Update folder video count
                if !video.folderPath.isEmpty,
                   var folderMetadata = manifest.folders[video.folderPath] {
                    folderMetadata.videoCount = max(0, folderMetadata.videoCount - 1)
                    manifest.folders[video.folderPath] = folderMetadata
                }
            }
        }
        
        // Remove folders whose directories no longer exist
        let staleFolderKeys = manifest.folders.keys.filter { folderPath in
            let folderURL = baseDirectory.appendingPathComponent(folderPath, isDirectory: true)
            return !fileManager.fileExists(atPath: folderURL.path)
        }
        
        for key in staleFolderKeys {
            if let folder = manifest.folders[key] {
                print("Removing stale folder entry: \(folder.name) (directory not found)")
                manifest.folders.removeValue(forKey: key)
                needsSave = true
            }
        }
        
        if needsSave {
            saveManifest()
        }
    }
}

// MARK: - Folder Operations

extension MediaStore {
    func createFolder(name: String, parentPath: String = "") -> Bool {
        let folderPath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        
        // Check if folder already exists
        if manifest.folders[folderPath] != nil {
            return false
        }
        
        let physicalURL = baseDirectory.appendingPathComponent(folderPath, isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: physicalURL, withIntermediateDirectories: true, attributes: nil)
            
            let folderMetadata = FolderMetadata(
                name: name,
                path: folderPath,
                parentPath: parentPath.isEmpty ? nil : parentPath,
                createdDate: Date(),
                modifiedDate: Date(),
                videoCount: 0,
                subfolderCount: 0
            )
            
            manifest.folders[folderPath] = folderMetadata
            
            // Update parent folder subfolder count
            if !parentPath.isEmpty {
                manifest.folders[parentPath]?.subfolderCount += 1
                manifest.folders[parentPath]?.modifiedDate = Date()
            }
            
            saveManifest()
            return true
        } catch {
            print("Failed to create folder: \(error)")
            return false
        }
    }
    
    func renameFolder(at path: String, to newName: String) -> Bool {
        guard var folderMetadata = manifest.folders[path] else { return false }
        
        let parentPath = folderMetadata.parentPath ?? ""
        let newPath = parentPath.isEmpty ? newName : "\(parentPath)/\(newName)"
        
        if manifest.folders[newPath] != nil {
            return false // Name already exists
        }
        
        let oldURL = baseDirectory.appendingPathComponent(path, isDirectory: true)
        let newURL = baseDirectory.appendingPathComponent(newPath, isDirectory: true)
        
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            
            // Update folder metadata
            folderMetadata.name = newName
            folderMetadata.path = newPath
            folderMetadata.modifiedDate = Date()
            
            manifest.folders.removeValue(forKey: path)
            manifest.folders[newPath] = folderMetadata
            
            // Update all child folders and videos
            updateChildPaths(oldPath: path, newPath: newPath)
            
            saveManifest()
            return true
        } catch {
            print("Failed to rename folder: \(error)")
            return false
        }
    }
    
    func deleteFolder(at path: String) -> Bool {
        guard let folderMetadata = manifest.folders[path] else { return false }
        
        let physicalURL = baseDirectory.appendingPathComponent(path, isDirectory: true)
        
        do {
            try FileManager.default.removeItem(at: physicalURL)
            
            // Remove folder from manifest
            manifest.folders.removeValue(forKey: path)
            
            // Remove all child folders and videos
            removeChildItems(at: path)
            
            // Update parent folder subfolder count
            if let parentPath = folderMetadata.parentPath {
                manifest.folders[parentPath]?.subfolderCount -= 1
                manifest.folders[parentPath]?.modifiedDate = Date()
            }
            
            saveManifest()
            return true
        } catch {
            print("Failed to delete folder: \(error)")
            return false
        }
    }
    
    private func updateChildPaths(oldPath: String, newPath: String) {
        let oldPathPrefix = oldPath + "/"

        // Update ALL descendant folders (not just immediate children)
        // Sort by path depth (ascending) to process parents before children
        let descendantFolders = manifest.folders
            .filter { $0.key.hasPrefix(oldPathPrefix) }
            .sorted { $0.key.components(separatedBy: "/").count < $1.key.components(separatedBy: "/").count }

        for (oldFolderPath, var folder) in descendantFolders {
            // Calculate new path by replacing the old prefix with new prefix
            let newFolderPath = newPath + String(oldFolderPath.dropFirst(oldPath.count))

            // Update parent path
            let newParentPath: String?
            if let currentParent = folder.parentPath {
                if currentParent == oldPath {
                    newParentPath = newPath
                } else if currentParent.hasPrefix(oldPathPrefix) {
                    newParentPath = newPath + String(currentParent.dropFirst(oldPath.count))
                } else {
                    newParentPath = currentParent
                }
            } else {
                newParentPath = nil
            }

            manifest.folders.removeValue(forKey: oldFolderPath)
            folder.path = newFolderPath
            folder.parentPath = newParentPath
            manifest.folders[newFolderPath] = folder
        }

        // Update ALL videos in the renamed folder AND all descendant folders
        let affectedVideos = manifest.videos.filter {
            $0.value.folderPath == oldPath || $0.value.folderPath.hasPrefix(oldPathPrefix)
        }
        for (videoKey, var video) in affectedVideos {
            if video.folderPath == oldPath {
                video.folderPath = newPath
            } else {
                video.folderPath = newPath + String(video.folderPath.dropFirst(oldPath.count))
            }
            manifest.videos[videoKey] = video
        }
    }
    
    private func removeChildItems(at path: String) {
        // Remove child folders
        let childFolders = manifest.folders.filter { $0.key.hasPrefix("\(path)/") }
        for (folderKey, _) in childFolders {
            manifest.folders.removeValue(forKey: folderKey)
        }
        
        // Remove child videos
        let childVideos = manifest.videos.filter { $0.value.folderPath.hasPrefix(path) }
        for (videoKey, _) in childVideos {
            manifest.videos.removeValue(forKey: videoKey)
        }
    }
}

// MARK: - Video Operations

extension MediaStore {
    /// Mark a video as having processing metadata after rally detection completes
    func markVideoAsProcessed(videoId: UUID, metadataFileSize: Int64, volleyballType: VolleyballType? = nil) -> Bool {
        print("📹 MediaStore.markVideoAsProcessed called:")
        print("   - VideoId: \(videoId)")
        print("   - MetadataFileSize: \(metadataFileSize) bytes")

        // Find the video
        guard var video = manifest.videos.values.first(where: { $0.id == videoId }) else {
            print("❌ Video with ID \(videoId) not found")
            return false
        }

        let videoKey = video.fileName
        print("   - Video: \(video.displayName)")
        print("   - Folder: \(video.folderPath)")

        // Update metadata tracking
        video.updateMetadataTracking(fileSize: metadataFileSize)
        if let volleyballType {
            video.volleyballType = volleyballType
        }
        manifest.videos[videoKey] = video

        saveManifest()
        print("✅ Video marked as processed with metadata")
        return true
    }

    func addProcessedVideo(at url: URL, toFolder folderPath: String = "", customName: String? = nil, originalVideoId: UUID, volleyballType: VolleyballType? = nil) -> Bool {
        let videoKey = url.lastPathComponent
        print("📹 MediaStore.addProcessedVideo called:")
        print("   - URL: \(url)")
        print("   - FolderPath: '\(folderPath)'")
        print("   - CustomName: '\(customName ?? "nil")'")
        print("   - OriginalVideoId: \(originalVideoId)")
        print("   - VideoKey: '\(videoKey)'")

        // Get file attributes
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            print("❌ Failed to get file attributes for: \(url.path)")
            return false
        }
        print("✅ File attributes retrieved, size: \(fileSize) bytes")

        var videoMetadata = VideoMetadata(
            originalURL: url,
            customName: customName,
            folderPath: folderPath,
            createdDate: attributes[.creationDate] as? Date ?? Date(),
            fileSize: fileSize,
            duration: nil // Can be populated later if needed
        )

        // Mark as processed and link to original
        videoMetadata.isProcessed = true
        videoMetadata.processedDate = Date()
        videoMetadata.originalVideoId = originalVideoId
        videoMetadata.volleyballType = volleyballType

        manifest.videos[videoKey] = videoMetadata
        print("✅ Processed video metadata added to manifest with key: '\(videoKey)'")

        // Update the original video to reference this processed version
        if var originalVideo = manifest.videos.values.first(where: { $0.id == originalVideoId }) {
            let originalKey = originalVideo.fileName
            originalVideo.processedVideoIds.append(videoMetadata.id)
            manifest.videos[originalKey] = originalVideo
            print("✅ Updated original video '\(originalKey)' with processed video ID: \(videoMetadata.id)")
        } else {
            print("⚠️ Original video with ID \(originalVideoId) not found")
        }

        // Update folder video count
        if !folderPath.isEmpty {
            if manifest.folders[folderPath] != nil {
                manifest.folders[folderPath]?.videoCount += 1
                manifest.folders[folderPath]?.modifiedDate = Date()
                print("✅ Updated folder '\(folderPath)' video count to: \(manifest.folders[folderPath]?.videoCount ?? 0)")
            } else {
                print("⚠️ Folder '\(folderPath)' not found in manifest.folders")
                print("   Available folders: \(manifest.folders.keys.sorted())")
            }
        } else {
            print("📁 Added to root folder")
        }

        saveManifest()
        print("✅ Manifest saved successfully")
        return true
    }
    
    func addVideo(at url: URL, toFolder folderPath: String = "", customName: String? = nil, volleyballType: VolleyballType? = nil, sourceVideoId: UUID? = nil, sourceRallyIndex: Int? = nil) -> Bool {
        let videoKey = url.lastPathComponent
        print("📹 MediaStore.addVideo called:")
        print("   - URL: \(url)")
        print("   - FolderPath: '\(folderPath)'")
        print("   - CustomName: '\(customName ?? "nil")'")
        print("   - VideoKey: '\(videoKey)'")
        
        // Get file attributes
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            print("❌ Failed to get file attributes for: \(url.path)")
            return false
        }
        print("✅ File attributes retrieved, size: \(fileSize) bytes")
        
        var videoMetadata = VideoMetadata(
            originalURL: url,
            customName: customName,
            folderPath: folderPath,
            createdDate: attributes[.creationDate] as? Date ?? Date(),
            fileSize: fileSize,
            duration: nil, // Can be populated later if needed
            volleyballType: volleyballType
        )
        videoMetadata.sourceVideoId = sourceVideoId
        videoMetadata.sourceRallyIndex = sourceRallyIndex

        manifest.videos[videoKey] = videoMetadata
        print("✅ Video metadata added to manifest with key: '\(videoKey)'")
        
        // Update folder video count
        if !folderPath.isEmpty {
            if manifest.folders[folderPath] != nil {
                manifest.folders[folderPath]?.videoCount += 1
                manifest.folders[folderPath]?.modifiedDate = Date()
                print("✅ Updated folder '\(folderPath)' video count to: \(manifest.folders[folderPath]?.videoCount ?? 0)")
            } else {
                print("⚠️ Folder '\(folderPath)' not found in manifest.folders")
                print("   Available folders: \(manifest.folders.keys.sorted())")
            }
        } else {
            print("📁 Added to root folder")
        }
        
        saveManifest()
        print("✅ Manifest saved successfully")
        return true
    }
    
    func moveVideo(fileName: String, toFolder newFolderPath: String) -> Bool {
        guard var videoMetadata = manifest.videos[fileName] else { return false }
        
        let oldFolderPath = videoMetadata.folderPath
        let fileURL = baseDirectory.appendingPathComponent(oldFolderPath).appendingPathComponent(fileName)
        let newFileURL = baseDirectory.appendingPathComponent(newFolderPath).appendingPathComponent(fileName)
        
        do {
            // Ensure destination directory exists
            try FileManager.default.createDirectory(
                at: newFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            
            try FileManager.default.moveItem(at: fileURL, to: newFileURL)
            
            // Update metadata
            videoMetadata.folderPath = newFolderPath
            manifest.videos[fileName] = videoMetadata
            
            // Update folder counts
            if !oldFolderPath.isEmpty {
                manifest.folders[oldFolderPath]?.videoCount -= 1
                manifest.folders[oldFolderPath]?.modifiedDate = Date()
            }
            
            if !newFolderPath.isEmpty {
                manifest.folders[newFolderPath]?.videoCount += 1
                manifest.folders[newFolderPath]?.modifiedDate = Date()
            }
            
            saveManifest()
            return true
        } catch {
            print("Failed to move video: \(error)")
            return false
        }
    }
    
    func renameVideo(fileName: String, to newName: String) -> Bool {
        guard var videoMetadata = manifest.videos[fileName] else { return false }
        
        videoMetadata.customName = newName
        manifest.videos[fileName] = videoMetadata
        saveManifest()
        return true
    }
    
    func deleteVideo(fileName: String) -> Bool {
        guard let videoMetadata = manifest.videos[fileName] else { return false }

        let folderPath = videoMetadata.folderPath
        let fileURL = folderPath.isEmpty
            ? baseDirectory.appendingPathComponent(fileName)
            : baseDirectory.appendingPathComponent(folderPath).appendingPathComponent(fileName)

        // Attempt file deletion but continue even if file doesn't exist
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                print("⚠️ Failed to delete video file (will still clean manifest): \(error)")
            }
        } else {
            print("⚠️ Video file not found on disk, cleaning up manifest entry: \(fileName)")
        }

        // Always clean up manifest regardless of file state
        cleanupProcessedVideoRelationships(for: videoMetadata)
        manifest.videos.removeValue(forKey: fileName)

        // Update folder video count
        if !folderPath.isEmpty {
            manifest.folders[folderPath]?.videoCount -= 1
            manifest.folders[folderPath]?.modifiedDate = Date()
        }

        saveManifest()
        return true
    }
    
    private func cleanupProcessedVideoRelationships(for videoMetadata: VideoMetadata) {
        if videoMetadata.isProcessed {
            // This is a processed video - remove its ID from the original video's processedVideoIds
            if let originalVideoId = videoMetadata.originalVideoId {
                // Find the original video and remove this processed video's ID from its array
                for (fileName, var originalVideo) in manifest.videos {
                    if originalVideo.id == originalVideoId {
                        originalVideo.processedVideoIds.removeAll { $0 == videoMetadata.id }
                        manifest.videos[fileName] = originalVideo
                        print("🔗 Removed processed video \(videoMetadata.id) from original video \(originalVideoId)")
                        break
                    }
                }
            }
        } else {
            // This is an original video - delete all its processed versions
            let processedVideoIds = videoMetadata.processedVideoIds
            if !processedVideoIds.isEmpty {
                print("🗑️ Deleting \(processedVideoIds.count) processed videos for original \(videoMetadata.id)")
                
                // Find and delete all processed videos
                let processedVideosToDelete = manifest.videos.filter { (_, video) in
                    processedVideoIds.contains(video.id)
                }
                
                for (fileName, processedVideo) in processedVideosToDelete {
                    let processedFileURL = baseDirectory.appendingPathComponent(processedVideo.folderPath).appendingPathComponent(fileName)
                    do {
                        try FileManager.default.removeItem(at: processedFileURL)
                        manifest.videos.removeValue(forKey: fileName)
                        print("🗑️ Deleted processed video: \(fileName)")
                        
                        // Also clean up debug data if it exists
                        if let debugPath = processedVideo.debugDataPath {
                            let debugURL = URL(fileURLWithPath: debugPath)
                            try? FileManager.default.removeItem(at: debugURL)
                        }
                    } catch {
                        print("❌ Failed to delete processed video \(fileName): \(error)")
                    }
                }
            }
        }
    }
}

// MARK: - Query Operations

extension MediaStore {
    /// Computes the actual video count for a folder by counting videos in manifest
    func computeVideoCount(for folderPath: String) -> Int {
        manifest.videos.values.filter { $0.folderPath == folderPath }.count
    }

    /// Computes the actual subfolder count for a folder by counting subfolders in manifest
    func computeSubfolderCount(for folderPath: String) -> Int {
        manifest.folders.values.filter { $0.parentPath == folderPath }.count
    }

    func getFolders(in parentPath: String = "") -> [FolderMetadata] {
        return manifest.folders.values
            .filter { $0.parentPath == (parentPath.isEmpty ? nil : parentPath) }
            .map { folder in
                var mutableFolder = folder
                // Compute counts dynamically to prevent desync
                mutableFolder.videoCount = computeVideoCount(for: folder.path)
                mutableFolder.subfolderCount = computeSubfolderCount(for: folder.path)
                return mutableFolder
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Paginated folder query for large libraries
    func getFoldersPaginated(in parentPath: String = "", limit: Int? = nil, offset: Int = 0) -> [FolderMetadata] {
        let filtered = manifest.folders.values
            .filter { $0.parentPath == (parentPath.isEmpty ? nil : parentPath) }
            .map { folder -> FolderMetadata in
                var mutableFolder = folder
                mutableFolder.videoCount = computeVideoCount(for: folder.path)
                mutableFolder.subfolderCount = computeSubfolderCount(for: folder.path)
                return mutableFolder
            }
            .sorted { (a: FolderMetadata, b: FolderMetadata) in
                a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

        let offsetResults = Array(filtered.dropFirst(offset))
        return limit.map { Array(offsetResults.prefix($0)) } ?? offsetResults
    }

    /// Returns total folder count without loading all data
    func getFolderCount(in parentPath: String = "") -> Int {
        manifest.folders.values.filter { $0.parentPath == (parentPath.isEmpty ? nil : parentPath) }.count
    }

    func getVideos(in folderPath: String = "") -> [VideoMetadata] {
        print("🔍 MediaStore.getVideos called for folderPath: '\(folderPath)'")
        print("   Total videos in manifest: \(manifest.videos.count)")

        let matchingFolderVideos = manifest.videos.values.filter { $0.folderPath == folderPath }
        print("   Videos matching folder path: \(matchingFolderVideos.count)")

        // Batch file existence check: one directory listing instead of N file checks
        let folderURL = folderPath.isEmpty
            ? baseDirectory
            : baseDirectory.appendingPathComponent(folderPath, isDirectory: true)

        let existingFiles: Set<String>
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            existingFiles = Set(contents.map { $0.lastPathComponent })
        } catch {
            print("   ⚠️ Could not list directory contents: \(error)")
            existingFiles = []
        }

        let result = matchingFolderVideos
            .filter { video in
                let exists = existingFiles.contains(video.fileName)
                if !exists {
                    print("   ⚠️ Video file not found: \(video.fileName)")
                }
                return exists
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        print("   Final filtered videos: \(result.count)")
        print("   Video names: \(result.map { $0.displayName })")
        return result
    }
    
    func searchVideos(query: String) -> [VideoMetadata] {
        let fileManager = FileManager.default
        let lowercaseQuery = query.lowercased()
        return manifest.videos.values
            .filter { video in
                let videoPath = baseDirectory
                    .appendingPathComponent(video.folderPath)
                    .appendingPathComponent(video.fileName)
                return fileManager.fileExists(atPath: videoPath.path)
            }
            .filter { video in
                video.displayName.lowercased().contains(lowercaseQuery) ||
                video.fileName.lowercased().contains(lowercaseQuery)
            }
    }
    
    func searchFolders(query: String) -> [FolderMetadata] {
        let lowercaseQuery = query.lowercased()
        return manifest.folders.values.filter { folder in
            folder.name.lowercased().contains(lowercaseQuery) ||
            folder.path.lowercased().contains(lowercaseQuery)
        }
    }
    
    func getAllFolders() -> [FolderMetadata] {
        return Array(manifest.folders.values)
    }
    
    func getAllVideos() -> [VideoMetadata] {
        return Array(manifest.videos.values)
    }
    
    func advancedSearchVideos(
        query: String,
        fileType: String? = nil,
        minSize: Int64? = nil,
        maxSize: Int64? = nil,
        fromDate: Date? = nil,
        toDate: Date? = nil,
        inFolder: String? = nil
    ) -> [VideoMetadata] {
        var results = Array(manifest.videos.values)
        
        // Text search
        if !query.isEmpty {
            let lowercaseQuery = query.lowercased()
            results = results.filter { video in
                video.displayName.lowercased().contains(lowercaseQuery) ||
                video.fileName.lowercased().contains(lowercaseQuery)
            }
        }
        
        // File type filter
        if let fileType = fileType, !fileType.isEmpty {
            results = results.filter { video in
                video.fileName.lowercased().hasSuffix(".\(fileType.lowercased())")
            }
        }
        
        // Size filters
        if let minSize = minSize {
            results = results.filter { $0.fileSize >= minSize }
        }
        
        if let maxSize = maxSize {
            results = results.filter { $0.fileSize <= maxSize }
        }
        
        // Date filters
        if let fromDate = fromDate {
            results = results.filter { $0.createdDate >= fromDate }
        }
        
        if let toDate = toDate {
            results = results.filter { $0.createdDate <= toDate }
        }
        
        // Folder filter
        if let inFolder = inFolder {
            if inFolder.isEmpty {
                // Root folder only
                results = results.filter { $0.folderPath.isEmpty }
            } else {
                // Specific folder and its subfolders
                results = results.filter { 
                    $0.folderPath == inFolder || $0.folderPath.hasPrefix("\(inFolder)/")
                }
            }
        }
        
        return results
    }
    
    func getFolderMetadata(at path: String) -> FolderMetadata? {
        return manifest.folders[path]
    }
    
    func getVideoMetadata(fileName: String) -> VideoMetadata? {
        return manifest.videos[fileName]
    }

    /// Get video by its UUID
    func getVideo(byId id: UUID) -> VideoMetadata? {
        return manifest.videos.values.first(where: { $0.id == id })
    }
}

// MARK: - Migration

extension MediaStore {
    func migrateExistingVideos() {
        let fileManager = FileManager.default
        
        // Find all videos in root documents directory
        if let files = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]) {
            let videoFiles = files.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mov" || ext == "mp4"
            }
            
            for videoURL in videoFiles {
                let fileName = videoURL.lastPathComponent
                
                // Skip if already in manifest
                if manifest.videos[fileName] != nil {
                    continue
                }
                
                // Add to root folder (empty path)
                _ = addVideo(at: videoURL, toFolder: "", customName: nil)
            }
        }
    }
}

// MARK: - Legacy Compatibility Layer

extension MediaStore {
    @available(*, deprecated, message: "Use getVideos(in:) with folder path parameter")
    func getAllVideoURLs() -> [URL] {
        let videos = getVideos(in: "")
        return videos.compactMap { video in
            let fullPath = baseDirectory.appendingPathComponent(video.folderPath).appendingPathComponent(video.fileName)
            return URL(fileURLWithPath: fullPath.path)
        }
    }
    
    @available(*, deprecated, message: "Use addVideo(at:toFolder:customName:) instead")
    func saveVideo(at url: URL) -> Bool {
        return addVideo(at: url, toFolder: "", customName: nil)
    }
    
    @available(*, deprecated, message: "Use deleteVideo(fileName:) instead")
    func removeVideo(at url: URL) -> Bool {
        let fileName = url.lastPathComponent
        return deleteVideo(fileName: fileName)
    }
    
    func getVideoURL(for metadata: VideoMetadata) -> URL {
        return baseDirectory
            .appendingPathComponent(metadata.folderPath)
            .appendingPathComponent(metadata.fileName)
    }
    
    func loadVideosFromDocuments() -> [URL] {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        guard let files = try? fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) else {
            return []
        }
        
        return files.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "mov" || ext == "mp4"
        }
    }
    
    func needsMigration() -> Bool {
        return !loadVideosFromDocuments().isEmpty
    }
    
    // MARK: - Debug Data Operations
    
    func saveDebugData(
        for videoId: UUID,
        debugData: Data,
        sessionId: UUID
    ) throws -> String {
        // Find video metadata by ID
        guard let (fileName, videoMetadata) = manifest.videos.first(where: { $0.value.id == videoId }) else {
            throw NSError(domain: "DebugError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Video not found"])
        }
        var updatedVideoMetadata = videoMetadata
        
        let debugPath = generateDebugDataPath(videoId: videoId, sessionId: sessionId)
        let debugURL = URL(fileURLWithPath: debugPath)
        
        // Ensure debug data directory exists
        try FileManager.default.createDirectory(
            at: debugURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        
        // Write debug data to file
        try debugData.write(to: debugURL)
        
        // Update video metadata
        updatedVideoMetadata.attachDebugData(
            sessionId: sessionId,
            dataPath: debugPath,
            size: Int64(debugData.count)
        )
        
        // Update manifest and save
        manifest.videos[fileName] = updatedVideoMetadata
        saveManifest()
        
        return debugPath
    }
    
    func loadDebugData(for videoId: UUID) -> Data? {
        guard let videoMetadata = manifest.videos.values.first(where: { $0.id == videoId }),
              let debugPath = videoMetadata.debugDataPath else {
            return nil
        }
        
        let debugURL = URL(fileURLWithPath: debugPath)
        return try? Data(contentsOf: debugURL)
    }
    
    func deleteVideoWithDebugData(videoId: UUID) {
        // Find video metadata
        guard let (fileName, videoMetadata) = manifest.videos.first(where: { $0.value.id == videoId }) else {
            return
        }
        
        // Clean up debug data first
        if let debugPath = videoMetadata.debugDataPath {
            let debugURL = URL(fileURLWithPath: debugPath)
            try? FileManager.default.removeItem(at: debugURL)
        }
        
        // Use existing deletion method
        _ = deleteVideo(fileName: fileName)
    }
    
    private func generateDebugDataPath(videoId: UUID, sessionId: UUID) -> String {
        let debugDir = baseDirectory.appendingPathComponent(".debug_data")
        let filename = "\(videoId.uuidString)_\(sessionId.uuidString).json"
        return debugDir.appendingPathComponent(filename).path
    }
}

// MARK: - Library-Specific Operations

extension MediaStore {
    /// Get full path including library prefix
    func fullPath(for relativePath: String, in library: LibraryType) -> String {
        return relativePath.isEmpty ? library.rootPath : "\(library.rootPath)/\(relativePath)"
    }

    /// Get relative path without library prefix
    func relativePath(from fullPath: String, in library: LibraryType) -> String {
        let prefix = library.rootPath + "/"
        if fullPath.hasPrefix(prefix) {
            return String(fullPath.dropFirst(prefix.count))
        } else if fullPath == library.rootPath {
            return ""
        }
        return fullPath
    }

    /// Check if a path belongs to a specific library
    func isPath(_ path: String, in library: LibraryType) -> Bool {
        return path == library.rootPath || path.hasPrefix(library.rootPath + "/")
    }

    /// Get folders in a specific library (relative path)
    func getFolders(inRelativePath relativePath: String, library: LibraryType) -> [FolderMetadata] {
        let fullPath = self.fullPath(for: relativePath, in: library)
        return getFolders(in: fullPath)
    }

    /// Get videos in a specific library (relative path)
    func getVideos(inRelativePath relativePath: String, library: LibraryType) -> [VideoMetadata] {
        let fullPath = self.fullPath(for: relativePath, in: library)
        return getVideos(in: fullPath)
    }

    /// Create folder in a specific library
    func createFolder(name: String, parentRelativePath: String, in library: LibraryType) -> Bool {
        let fullParentPath = self.fullPath(for: parentRelativePath, in: library)
        return createFolder(name: name, parentPath: fullParentPath)
    }

    /// Add video to a specific library
    func addVideo(at url: URL, toRelativeFolder relativePath: String, in library: LibraryType, customName: String? = nil) -> Bool {
        let fullPath = self.fullPath(for: relativePath, in: library)
        return addVideo(at: url, toFolder: fullPath, customName: customName)
    }

    /// Search videos within a specific library
    func searchVideos(query: String, in library: LibraryType) -> [VideoMetadata] {
        let prefix = library.rootPath
        return searchVideos(query: query).filter {
            $0.folderPath == prefix || $0.folderPath.hasPrefix(prefix + "/")
        }
    }

    /// Search folders within a specific library
    func searchFolders(query: String, in library: LibraryType) -> [FolderMetadata] {
        let prefix = library.rootPath
        return searchFolders(query: query).filter {
            $0.path == prefix || $0.path.hasPrefix(prefix + "/")
        }
    }

    /// Get all videos in a library (for stats)
    func getAllVideos(in library: LibraryType) -> [VideoMetadata] {
        let prefix = library.rootPath
        return getAllVideos().filter {
            $0.folderPath == prefix || $0.folderPath.hasPrefix(prefix + "/")
        }
    }

    /// Get all folders in a library
    func getAllFolders(in library: LibraryType) -> [FolderMetadata] {
        let prefix = library.rootPath
        return getAllFolders().filter {
            $0.path == prefix || $0.path.hasPrefix(prefix + "/")
        }
    }

    /// Ensure library root folders exist
    private func ensureLibraryRootsExist() {
        for libraryType in LibraryType.allCases {
            let rootPath = libraryType.rootPath

            // Create physical directory
            let physicalURL = baseDirectory.appendingPathComponent(rootPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: physicalURL, withIntermediateDirectories: true, attributes: nil)

            // Create folder metadata if not exists
            if manifest.folders[rootPath] == nil {
                let folderMetadata = FolderMetadata(
                    name: libraryType.displayName,
                    path: rootPath,
                    parentPath: nil,
                    createdDate: Date(),
                    modifiedDate: Date(),
                    videoCount: 0,
                    subfolderCount: 0
                )
                manifest.folders[rootPath] = folderMetadata
                print("MediaStore: Created library root folder: \(rootPath)")
            }
        }
        saveManifest()
    }

    /// Migrate existing processed videos to set hasProcessingMetadata flag
    /// This detects videos that have metadata files on disk but weren't flagged
    func migrateProcessedVideos() {
        print("MediaStore: Checking for processed videos to migrate...")
        let metadataDirectory = baseDirectory.appendingPathComponent("ProcessedMetadata", isDirectory: true)

        var migratedCount = 0
        for (key, var video) in manifest.videos {
            // Skip if already marked as having metadata
            guard !video.hasProcessingMetadata else { continue }

            // Check if metadata file exists for this video
            let metadataPath = metadataDirectory.appendingPathComponent("\(video.id.uuidString).json")
            guard FileManager.default.fileExists(atPath: metadataPath.path) else { continue }

            // Get metadata file size
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: metadataPath.path),
                  let fileSize = attributes[.size] as? Int64 else {
                continue
            }

            // Update video metadata
            video.updateMetadataTracking(fileSize: fileSize)
            manifest.videos[key] = video
            migratedCount += 1
            print("MediaStore: Migrated processed video: \(video.displayName)")
        }

        if migratedCount > 0 {
            saveManifest()
            print("MediaStore: ✅ Migrated \(migratedCount) processed video(s)")
        } else {
            print("MediaStore: No processed videos to migrate")
        }
    }
}

// MARK: - Library Migration

extension MediaStore {
    /// Check if migration to separate libraries has been completed
    private func hasCompletedLibraryMigration() -> Bool {
        // Migration is complete if both library roots exist AND manifest version >= 2
        return manifest.version >= 2 &&
               manifest.folders[LibraryType.saved.rootPath] != nil &&
               manifest.folders[LibraryType.processed.rootPath] != nil
    }

    /// Migrate existing videos to separate libraries
    func migrateToSeparateLibraries() {
        // Skip if already migrated
        guard !hasCompletedLibraryMigration() else {
            print("MediaStore: Library migration already complete")
            return
        }

        // Check if there are any videos that need migration (not already in a library root)
        let videosNeedingMigration = manifest.videos.values.filter { video in
            !isPath(video.folderPath, in: .saved) && !isPath(video.folderPath, in: .processed)
        }

        let foldersNeedingMigration = manifest.folders.values.filter { folder in
            !isPath(folder.path, in: .saved) && !isPath(folder.path, in: .processed)
        }

        guard !videosNeedingMigration.isEmpty || !foldersNeedingMigration.isEmpty else {
            // No migration needed, just mark as complete
            manifest.version = 2
            saveManifest()
            print("MediaStore: No content to migrate, marking migration complete")
            return
        }

        print("MediaStore: Starting library migration...")
        print("MediaStore: Videos to migrate: \(videosNeedingMigration.count)")
        print("MediaStore: Folders to migrate: \(foldersNeedingMigration.count)")

        let fileManager = FileManager.default

        // 1. Migrate folders first (create structure in both libraries if needed)
        for folder in foldersNeedingMigration {
            let oldPath = folder.path

            // Check what videos exist in this folder
            let videosInFolder = manifest.videos.values.filter { $0.folderPath == oldPath }
            let hasOriginals = videosInFolder.contains { !$0.isProcessed }
            let hasProcessed = videosInFolder.contains { $0.isProcessed }

            // Create folder in SavedGames if it has original videos
            if hasOriginals {
                let savedPath = fullPath(for: oldPath, in: .saved)
                let savedPhysicalURL = baseDirectory.appendingPathComponent(savedPath, isDirectory: true)
                try? fileManager.createDirectory(at: savedPhysicalURL, withIntermediateDirectories: true, attributes: nil)

                let parentPath = oldPath.contains("/")
                    ? fullPath(for: String(oldPath.dropLast(oldPath.split(separator: "/").last?.count ?? 0).dropLast()), in: .saved)
                    : LibraryType.saved.rootPath

                let savedFolder = FolderMetadata(
                    name: folder.name,
                    path: savedPath,
                    parentPath: parentPath,
                    createdDate: folder.createdDate,
                    modifiedDate: folder.modifiedDate,
                    videoCount: videosInFolder.filter { !$0.isProcessed }.count,
                    subfolderCount: 0
                )
                manifest.folders[savedPath] = savedFolder
                print("MediaStore: Created folder in SavedGames: \(savedPath)")
            }

            // Create folder in ProcessedGames if it has processed videos
            if hasProcessed {
                let processedPath = fullPath(for: oldPath, in: .processed)
                let processedPhysicalURL = baseDirectory.appendingPathComponent(processedPath, isDirectory: true)
                try? fileManager.createDirectory(at: processedPhysicalURL, withIntermediateDirectories: true, attributes: nil)

                let parentPath = oldPath.contains("/")
                    ? fullPath(for: String(oldPath.dropLast(oldPath.split(separator: "/").last?.count ?? 0).dropLast()), in: .processed)
                    : LibraryType.processed.rootPath

                let processedFolder = FolderMetadata(
                    name: folder.name,
                    path: processedPath,
                    parentPath: parentPath,
                    createdDate: folder.createdDate,
                    modifiedDate: folder.modifiedDate,
                    videoCount: videosInFolder.filter { $0.isProcessed }.count,
                    subfolderCount: 0
                )
                manifest.folders[processedPath] = processedFolder
                print("MediaStore: Created folder in ProcessedGames: \(processedPath)")
            }

            // Remove old folder entry
            manifest.folders.removeValue(forKey: oldPath)
        }

        // 2. Migrate videos
        for video in videosNeedingMigration {
            let oldFolderPath = video.folderPath
            let targetLibrary: LibraryType = video.isProcessed ? .processed : .saved
            let newFolderPath = fullPath(for: oldFolderPath, in: targetLibrary)

            // Move physical file
            let oldURL = oldFolderPath.isEmpty
                ? baseDirectory.appendingPathComponent(video.fileName)
                : baseDirectory.appendingPathComponent(oldFolderPath).appendingPathComponent(video.fileName)

            let newURL = baseDirectory.appendingPathComponent(newFolderPath).appendingPathComponent(video.fileName)

            // Ensure destination directory exists
            try? fileManager.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

            do {
                if fileManager.fileExists(atPath: oldURL.path) {
                    try fileManager.moveItem(at: oldURL, to: newURL)
                    print("MediaStore: Moved video \(video.fileName) to \(newFolderPath)")
                }
            } catch {
                print("MediaStore: Warning - Could not move video file: \(error)")
            }

            // Update video metadata
            var updatedVideo = video
            updatedVideo.folderPath = newFolderPath
            manifest.videos[video.fileName] = updatedVideo
        }

        // 3. Update subfolder counts for library roots
        for libraryType in LibraryType.allCases {
            let rootPath = libraryType.rootPath
            if var rootFolder = manifest.folders[rootPath] {
                rootFolder.subfolderCount = manifest.folders.values.filter { $0.parentPath == rootPath }.count
                rootFolder.videoCount = manifest.videos.values.filter { $0.folderPath == rootPath }.count
                manifest.folders[rootPath] = rootFolder
            }
        }

        // 4. Clean up empty old folders
        for folder in foldersNeedingMigration {
            let oldPhysicalURL = baseDirectory.appendingPathComponent(folder.path, isDirectory: true)
            if fileManager.fileExists(atPath: oldPhysicalURL.path) {
                // Only remove if empty
                if let contents = try? fileManager.contentsOfDirectory(atPath: oldPhysicalURL.path), contents.isEmpty {
                    try? fileManager.removeItem(at: oldPhysicalURL)
                }
            }
        }

        // 5. Mark migration complete
        manifest.version = 2
        saveManifest()
        print("MediaStore: Library migration complete!")
    }
}



