//
//  MediaModels.swift
//  BumpSetCut
//
//  Library data model: the manifest and its video/folder entries.
//

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

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

// MARK: - Video Metadata Models

struct VideoMetadata: Codable, Identifiable, Hashable {
    let id: UUID
    let fileName: String
    var customName: String?
    var folderPath: String
    let createdDate: Date
    var fileSize: Int64
    var duration: TimeInterval?
    
    // Debug data fields
    var debugSessionId: UUID?
    /// File name inside `<library>/.debug_data/` (older builds stored an
    /// absolute path, which broke whenever the app container moved).
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

    // Favorite source tracking (for syncing unfavorite back to rally player)
    var sourceVideoId: UUID?
    var sourceRallyIndex: Int?

    /// Where the video was filmed from, picked before processing.
    var cameraSetup: CameraSetup?

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
            .map { ($0 as NSString).lastPathComponent }
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

        // Favorite source tracking with defaults for backwards compatibility
        sourceVideoId = try container.decodeIfPresent(UUID.self, forKey: .sourceVideoId)
        sourceRallyIndex = try container.decodeIfPresent(Int.self, forKey: .sourceRallyIndex)
        cameraSetup = try container.decodeIfPresent(CameraSetup.self, forKey: .cameraSetup)
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

        // Favorite source tracking
        try container.encodeIfPresent(sourceVideoId, forKey: .sourceVideoId)
        try container.encodeIfPresent(sourceRallyIndex, forKey: .sourceRallyIndex)
        try container.encodeIfPresent(cameraSetup, forKey: .cameraSetup)
    }
    
    // CodingKeys enum for custom coding
    private enum CodingKeys: String, CodingKey {
        case id, fileName, customName, folderPath, createdDate, fileSize, duration
        case debugSessionId, debugDataPath, debugCollectionDate, debugDataSize
        case isProcessed, processedDate, originalVideoId, processedVideoIds
        case hasProcessingMetadata, metadataCreatedDate, metadataFileSize
        case sourceVideoId, sourceRallyIndex
        case cameraSetup
    }
    
    var displayName: String {
        customName ?? URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }
    
    var isOriginalVideo: Bool {
        return originalVideoId == nil && !isProcessed
    }

    var canBeProcessed: Bool {
        // Can only process original videos that haven't been processed yet. Processing
        // now annotates the original in place (rally metadata), so a video that already
        // has metadata is "processed" even without a separate processed-copy entry.
        // `processedVideoIds` still guards legacy libraries that have processed copies.
        return isOriginalVideo && processedVideoIds.isEmpty && !hasMetadata
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
        self.sourceVideoId = nil
        self.sourceRallyIndex = nil
    }

    // Debug data management methods
    mutating func attachDebugData(sessionId: UUID, fileName: String, size: Int64) {
        self.debugSessionId = sessionId
        self.debugDataPath = fileName
        self.debugCollectionDate = Date()
        self.debugDataSize = size
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
    /// Entries skipped on load because they failed to decode (never encoded).
    /// Decoding is per-entry so one bad entry can't cost the whole library.
    private(set) var droppedEntryCount = 0

    private enum CodingKeys: String, CodingKey {
        case folders, videos, version, createdDate, lastModified
    }

    init() {
        let now = Date()
        self.createdDate = now
        self.lastModified = now
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawFolders = try container.decodeIfPresent([String: LossyEntry<FolderMetadata>].self, forKey: .folders) ?? [:]
        let rawVideos = try container.decodeIfPresent([String: LossyEntry<VideoMetadata>].self, forKey: .videos) ?? [:]
        folders = rawFolders.compactMapValues(\.value)
        videos = rawVideos.compactMapValues(\.value)
        droppedEntryCount = (rawFolders.count - folders.count) + (rawVideos.count - videos.count)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let now = Date()
        createdDate = try container.decodeIfPresent(Date.self, forKey: .createdDate) ?? now
        lastModified = try container.decodeIfPresent(Date.self, forKey: .lastModified) ?? now
    }

    mutating func updateModifiedDate() {
        lastModified = Date()
    }
}

/// Decodes to nil instead of throwing, so a collection keeps its good entries.
private struct LossyEntry<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
