//
//  MetadataStore.swift
//  BumpSetCut
//
//  Created for Metadata Video Processing - Task 002
//

import Foundation

// MARK: - Metadata Storage Errors

enum MetadataStoreError: Error, LocalizedError {
    case directoryCreationFailed(path: String, underlying: Error)
    case fileWriteFailed(path: String, underlying: Error)
    case fileReadFailed(path: String, underlying: Error)
    case fileDeleteFailed(path: String, underlying: Error)
    case backupCreationFailed(path: String, underlying: Error)
    case atomicWriteFailed(path: String, underlying: Error)
    case metadataNotFound(videoId: UUID)
    case invalidJSON(path: String, underlying: Error)
    case corruptedMetadata(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let path, let underlying):
            return "Failed to create metadata directory at \(path): \(underlying.localizedDescription)"
        case .fileWriteFailed(let path, let underlying):
            return "Failed to write metadata file at \(path): \(underlying.localizedDescription)"
        case .fileReadFailed(let path, let underlying):
            return "Failed to read metadata file at \(path): \(underlying.localizedDescription)"
        case .fileDeleteFailed(let path, let underlying):
            return "Failed to delete metadata file at \(path): \(underlying.localizedDescription)"
        case .backupCreationFailed(let path, let underlying):
            return "Failed to create backup for metadata at \(path): \(underlying.localizedDescription)"
        case .atomicWriteFailed(let path, let underlying):
            return "Failed to perform atomic write for metadata at \(path): \(underlying.localizedDescription)"
        case .metadataNotFound(let videoId):
            return "Metadata not found for video ID: \(videoId)"
        case .invalidJSON(let path, let underlying):
            return "Invalid JSON in metadata file at \(path): \(underlying.localizedDescription)"
        case .corruptedMetadata(let path, let reason):
            return "Corrupted metadata file at \(path): \(reason)"
        }
    }
}

// MARK: - MetadataStore Service

@MainActor class MetadataStore: ObservableObject {

    // MARK: - Properties

    private let fileManager: FileManager
    private let metadataDirectory: URL
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    // MARK: - Initialization

    init() {
        self.fileManager = FileManager.default

        // Use the same base directory pattern as MediaStore for consistency
        let baseDirectory = StorageManager.getPersistentStorageDirectory()
        self.metadataDirectory = baseDirectory.appendingPathComponent("ProcessedMetadata", isDirectory: true)

        // Configure JSON encoder/decoder with consistent formatting
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.jsonEncoder.dateEncodingStrategy = .iso8601

        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.dateDecodingStrategy = .iso8601

        // Ensure metadata directory exists
        do {
            try createMetadataDirectoryIfNeeded()
            print("MetadataStore: Initialized with directory: \(metadataDirectory.path)")
        } catch {
            print("MetadataStore: Failed to create metadata directory: \(error)")
        }
    }

    // MARK: - Directory Management

    private func createMetadataDirectoryIfNeeded() throws {
        var isDirectory: ObjCBool = false
        let directoryExists = fileManager.fileExists(atPath: metadataDirectory.path, isDirectory: &isDirectory)

        if !directoryExists || !isDirectory.boolValue {
            do {
                try fileManager.createDirectory(
                    at: metadataDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                print("MetadataStore: Created metadata directory at: \(metadataDirectory.path)")
            } catch {
                throw MetadataStoreError.directoryCreationFailed(
                    path: metadataDirectory.path,
                    underlying: error
                )
            }
        }
    }

    // MARK: - File Path Generation

    private func metadataURL(for videoId: UUID) -> URL {
        let filename = "\(videoId.uuidString).json"
        return metadataDirectory.appendingPathComponent(filename)
    }

    private func backupURL(for videoId: UUID) -> URL {
        let filename = "\(videoId.uuidString).json.backup"
        return metadataDirectory.appendingPathComponent(filename)
    }

    private func temporaryURL(for videoId: UUID) -> URL {
        let filename = "\(videoId.uuidString).json.tmp"
        return metadataDirectory.appendingPathComponent(filename)
    }
}

// MARK: - Core CRUD Operations

extension MetadataStore {

    /// Save metadata with atomic write operations and backup creation
    func saveMetadata(_ metadata: ProcessingMetadata) throws {
        let metadataURL = metadataURL(for: metadata.videoId)
        let backupURL = backupURL(for: metadata.videoId)
        let temporaryURL = temporaryURL(for: metadata.videoId)

        print("MetadataStore: Saving metadata for video \(metadata.videoId)")
        print("MetadataStore: Target URL: \(metadataURL.path)")

        do {
            // Ensure directory exists
            try createMetadataDirectoryIfNeeded()

            // Create backup if existing file exists
            if fileManager.fileExists(atPath: metadataURL.path) {
                try createBackup(from: metadataURL, to: backupURL)
            }

            // Encode metadata to JSON
            let jsonData = try jsonEncoder.encode(metadata)

            // Perform atomic write using temporary file
            try performAtomicWrite(data: jsonData, to: metadataURL, using: temporaryURL)

            // Cleanup old backup after successful write
            try? fileManager.removeItem(at: backupURL)

            print("MetadataStore: Successfully saved metadata (\(jsonData.count) bytes)")

        } catch let error as MetadataStoreError {
            throw error
        } catch {
            throw MetadataStoreError.fileWriteFailed(path: metadataURL.path, underlying: error)
        }
    }

    /// Load metadata with error handling and validation
    func loadMetadata(for videoId: UUID) throws -> ProcessingMetadata {
        let metadataURL = metadataURL(for: videoId)

        print("MetadataStore: Loading metadata for video \(videoId)")
        print("MetadataStore: Source URL: \(metadataURL.path)")

        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw MetadataStoreError.metadataNotFound(videoId: videoId)
        }

        do {
            let jsonData = try Data(contentsOf: metadataURL)

            // Validate that the data is not empty
            guard !jsonData.isEmpty else {
                throw MetadataStoreError.corruptedMetadata(
                    path: metadataURL.path,
                    reason: "File is empty"
                )
            }

            let metadata = try jsonDecoder.decode(ProcessingMetadata.self, from: jsonData)

            // Validate that the loaded metadata matches the requested video ID
            guard metadata.videoId == videoId else {
                throw MetadataStoreError.corruptedMetadata(
                    path: metadataURL.path,
                    reason: "Video ID mismatch: expected \(videoId), found \(metadata.videoId)"
                )
            }

            print("MetadataStore: Successfully loaded metadata (\(jsonData.count) bytes)")
            return metadata

        } catch let error as MetadataStoreError {
            throw error
        } catch let decodingError as DecodingError {
            throw MetadataStoreError.invalidJSON(path: metadataURL.path, underlying: decodingError)
        } catch {
            throw MetadataStoreError.fileReadFailed(path: metadataURL.path, underlying: error)
        }
    }

    /// Delete metadata file with cleanup
    func deleteMetadata(for videoId: UUID) throws {
        let metadataURL = metadataURL(for: videoId)
        let backupURL = backupURL(for: videoId)

        print("MetadataStore: Deleting metadata for video \(videoId)")

        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw MetadataStoreError.metadataNotFound(videoId: videoId)
        }

        do {
            // Remove main metadata file
            try fileManager.removeItem(at: metadataURL)

            // Remove backup file if it exists
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }

            print("MetadataStore: Successfully deleted metadata")

        } catch {
            throw MetadataStoreError.fileDeleteFailed(path: metadataURL.path, underlying: error)
        }
    }

    /// Check if metadata exists for a video
    func metadataExists(for videoId: UUID) -> Bool {
        let metadataURL = metadataURL(for: videoId)
        return fileManager.fileExists(atPath: metadataURL.path)
    }
}

// MARK: - Atomic Operations

extension MetadataStore {

    /// Create backup of existing metadata file
    private func createBackup(from source: URL, to backup: URL) throws {
        do {
            // Remove existing backup if it exists
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }

            // Copy current file to backup
            try fileManager.copyItem(at: source, to: backup)

            print("MetadataStore: Created backup at: \(backup.path)")

        } catch {
            throw MetadataStoreError.backupCreationFailed(path: backup.path, underlying: error)
        }
    }

    /// Perform atomic write using temporary file
    private func performAtomicWrite(data: Data, to target: URL, using temporary: URL) throws {
        do {
            // Remove temporary file if it exists
            if fileManager.fileExists(atPath: temporary.path) {
                try fileManager.removeItem(at: temporary)
            }

            // Write to temporary file
            try data.write(to: temporary, options: .atomic)

            // Move temporary file to target location (atomic operation)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: temporary, to: target)

            print("MetadataStore: Completed atomic write to: \(target.path)")

        } catch {
            // Cleanup temporary file on failure
            try? fileManager.removeItem(at: temporary)
            throw MetadataStoreError.atomicWriteFailed(path: target.path, underlying: error)
        }
    }
}

// MARK: - Query Operations

extension MetadataStore {

    /// Get all video IDs that have metadata
    func getAllMetadataVideoIds() -> [UUID] {
        do {
            let files = try fileManager.contentsOfDirectory(at: metadataDirectory, includingPropertiesForKeys: nil)

            return files.compactMap { fileURL in
                let filename = fileURL.lastPathComponent

                // Skip backup and temporary files
                guard filename.hasSuffix(".json") && !filename.contains(".backup") && !filename.contains(".tmp") else {
                    return nil
                }

                // Extract UUID from filename
                let uuidString = String(filename.dropLast(5)) // Remove ".json"
                return UUID(uuidString: uuidString)
            }

        } catch {
            print("MetadataStore: Failed to list metadata files: \(error)")
            return []
        }
    }

    /// Get metadata file size for a video
    func getMetadataFileSize(for videoId: UUID) -> Int64? {
        let metadataURL = metadataURL(for: videoId)

        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: metadataURL.path)
            return attributes[.size] as? Int64
        } catch {
            print("MetadataStore: Failed to get file size for \(videoId): \(error)")
            return nil
        }
    }

    /// Get total storage used by metadata files
    func getTotalStorageUsed() -> Int64 {
        let videoIds = getAllMetadataVideoIds()
        return videoIds.compactMap { getMetadataFileSize(for: $0) }.reduce(0, +)
    }
}

// MARK: - Maintenance Operations

extension MetadataStore {

    /// Clean up orphaned metadata files (where video no longer exists)
    func cleanupOrphanedMetadata(validVideoIds: Set<UUID>) -> Int {
        let allMetadataIds = Set(getAllMetadataVideoIds())
        let orphanedIds = allMetadataIds.subtracting(validVideoIds)

        var cleanupCount = 0

        for videoId in orphanedIds {
            do {
                try deleteMetadata(for: videoId)
                cleanupCount += 1
                print("MetadataStore: Cleaned up orphaned metadata for video \(videoId)")
            } catch {
                print("MetadataStore: Failed to cleanup orphaned metadata for \(videoId): \(error)")
            }
        }

        if cleanupCount > 0 {
            print("MetadataStore: Cleaned up \(cleanupCount) orphaned metadata files")
        }

        return cleanupCount
    }

    /// Verify integrity of metadata files
    func verifyMetadataIntegrity() -> [UUID: String] {
        var corruptedFiles: [UUID: String] = [:]
        let metadataIds = getAllMetadataVideoIds()

        for videoId in metadataIds {
            do {
                _ = try loadMetadata(for: videoId)
            } catch {
                corruptedFiles[videoId] = error.localizedDescription
                print("MetadataStore: Corrupted metadata detected for \(videoId): \(error)")
            }
        }

        if corruptedFiles.isEmpty {
            print("MetadataStore: All metadata files passed integrity check")
        } else {
            print("MetadataStore: Found \(corruptedFiles.count) corrupted metadata files")
        }

        return corruptedFiles
    }
}

// MARK: - Trim Adjustment Persistence

extension MetadataStore {

    private func trimURL(for videoId: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(videoId.uuidString)_trims.json")
    }

    /// Save per-rally trim adjustments for a video.
    /// Keys are rally index strings ("0", "1", ...) mapping to RallyTrimAdjustment.
    func saveTrimAdjustments(_ adjustments: [Int: RallyTrimAdjustment], for videoId: UUID) throws {
        let url = trimURL(for: videoId)
        try createMetadataDirectoryIfNeeded()

        // Convert Int keys to String keys for JSON encoding
        let stringKeyed = Dictionary(uniqueKeysWithValues: adjustments.map { (String($0.key), $0.value) })
        let data = try jsonEncoder.encode(stringKeyed)
        try data.write(to: url, options: .atomic)
    }

    /// Load previously saved trim adjustments for a video. Returns empty dict if none saved.
    func loadTrimAdjustments(for videoId: UUID) -> [Int: RallyTrimAdjustment] {
        let url = trimURL(for: videoId)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let stringKeyed = try? jsonDecoder.decode([String: RallyTrimAdjustment].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: stringKeyed.compactMap { key, value in
            guard let intKey = Int(key) else { return nil }
            return (intKey, value)
        })
    }
}

// MARK: - Review Selections Persistence

extension MetadataStore {

    private func reviewSelectionsURL(for videoId: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(videoId.uuidString)_selections.json")
    }

    /// Save rally review selections (saved/removed sets) for a video.
    func saveReviewSelections(_ selections: RallyReviewSelections, for videoId: UUID) throws {
        let url = reviewSelectionsURL(for: videoId)
        try createMetadataDirectoryIfNeeded()
        let data = try jsonEncoder.encode(selections)
        try data.write(to: url, options: .atomic)
    }

    /// Load previously saved review selections for a video. Returns empty selections if none saved.
    func loadReviewSelections(for videoId: UUID) -> RallyReviewSelections {
        let url = reviewSelectionsURL(for: videoId)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let selections = try? jsonDecoder.decode(RallyReviewSelections.self, from: data) else {
            return RallyReviewSelections()
        }
        return selections
    }
}