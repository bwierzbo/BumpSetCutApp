//
//  MediaStore.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import Foundation

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

protocol CaptureDelegate: AnyObject {
    func presentCaptureInterface()
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
    }
    
    // CodingKeys enum for custom coding
    private enum CodingKeys: String, CodingKey {
        case id, fileName, customName, folderPath, createdDate, fileSize, duration
        case debugSessionId, debugDataPath, debugCollectionDate, debugDataSize
        case isProcessed, processedDate, originalVideoId, processedVideoIds
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
        return isOriginalVideo
    }
    
    var originalURL: URL {
        let baseDirectory = StorageManager.getPersistentStorageDirectory()
        return baseDirectory
            .appendingPathComponent(folderPath)
            .appendingPathComponent(fileName)
    }
    
    init(originalURL: URL, customName: String?, folderPath: String, createdDate: Date, fileSize: Int64, duration: TimeInterval?) {
        self.id = UUID()
        self.fileName = originalURL.lastPathComponent
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

@MainActor class MediaStore: ObservableObject {
    weak var captureDelegate: CaptureDelegate?
    
    private var manifest: FolderManifest
    private let manifestURL: URL
    let baseDirectory: URL
    
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
        
        // Clean up stale entries
        cleanupStaleEntries()
    }
    
    private func saveManifest() {
        do {
            manifest.updateModifiedDate()
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL)
        } catch {
            print("Failed to save manifest: \(error)")
        }
    }
    
    private func cleanupStaleEntries() {
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
        // Update child folders
        let childFolders = manifest.folders.filter { $0.value.parentPath == oldPath }
        for (_, var folder) in childFolders {
            let oldFolderPath = folder.path
            let newFolderPath = folder.path.replacingOccurrences(of: oldPath, with: newPath)
            
            manifest.folders.removeValue(forKey: oldFolderPath)
            folder.path = newFolderPath
            folder.parentPath = newPath
            manifest.folders[newFolderPath] = folder
        }
        
        // Update child videos
        let childVideos = manifest.videos.filter { $0.value.folderPath == oldPath }
        for (videoKey, var video) in childVideos {
            video.folderPath = newPath
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
    func addProcessedVideo(at url: URL, toFolder folderPath: String = "", customName: String? = nil, originalVideoId: UUID) -> Bool {
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
    
    func addVideo(at url: URL, toFolder folderPath: String = "", customName: String? = nil) -> Bool {
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
        
        let videoMetadata = VideoMetadata(
            originalURL: url,
            customName: customName,
            folderPath: folderPath,
            createdDate: attributes[.creationDate] as? Date ?? Date(),
            fileSize: fileSize,
            duration: nil // Can be populated later if needed
        )
        
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
        let fileURL = baseDirectory.appendingPathComponent(folderPath).appendingPathComponent(fileName)
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            
            // Clean up processed video relationships
            cleanupProcessedVideoRelationships(for: videoMetadata)
            
            manifest.videos.removeValue(forKey: fileName)
            
            // Update folder video count
            if !folderPath.isEmpty {
                manifest.folders[folderPath]?.videoCount -= 1
                manifest.folders[folderPath]?.modifiedDate = Date()
            }
            
            saveManifest()
            return true
        } catch {
            print("Failed to delete video: \(error)")
            return false
        }
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
    func getFolders(in parentPath: String = "") -> [FolderMetadata] {
        return manifest.folders.values
            .filter { $0.parentPath == (parentPath.isEmpty ? nil : parentPath) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    func getVideos(in folderPath: String = "") -> [VideoMetadata] {
        print("🔍 MediaStore.getVideos called for folderPath: '\(folderPath)'")
        print("   Total videos in manifest: \(manifest.videos.count)")
        
        let fileManager = FileManager.default
        let matchingFolderVideos = manifest.videos.values.filter { $0.folderPath == folderPath }
        print("   Videos matching folder path: \(matchingFolderVideos.count)")
        
        let result = matchingFolderVideos
            .filter { video in
                let videoPath = baseDirectory
                    .appendingPathComponent(video.folderPath)
                    .appendingPathComponent(video.fileName)
                let exists = fileManager.fileExists(atPath: videoPath.path)
                if !exists {
                    print("   ⚠️ Video file not found: \(videoPath.path)")
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

// MARK: - Original Capture Functionality

extension MediaStore {
    func presentCapturePopup() {
        captureDelegate?.presentCaptureInterface()
    }
}


