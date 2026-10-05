//
//  StorageManager.swift
//  BumpSetCut
//
//  Extracted from MediaStore.swift so platform-neutral storage helpers can be
//  shared with the RallyLab macOS target without pulling in the full MediaStore.
//

import Foundation
import os

private let logger = Logger(subsystem: "BumpSetCut", category: "StorageManager")

// MARK: - Storage Utilities

struct StorageManager {
    /// Test seam: when non-nil, overrides the storage location so tests can run
    /// against an isolated temp directory instead of the shared on-disk library.
    /// Production never sets this, so the default behavior is unchanged.
    /// Test-only: set before anything touches storage, never concurrently.
    nonisolated(unsafe) static var storageDirectoryOverride: URL?

    static func getPersistentStorageDirectory() -> URL {
        if let override = storageDirectoryOverride { return override }
        let fileManager = FileManager.default
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BumpSetCut", isDirectory: true)
    }

    static func verifyStorageIntegrity(at baseDir: URL) {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: baseDir.path) else {
            logger.error("Storage directory missing at \(baseDir.path)")
            return
        }

        if (try? fileManager.contentsOfDirectory(atPath: baseDir.path)) == nil {
            logger.error("Failed to read storage directory \(baseDir.path)")
        }
    }

    /// Keep regenerable or bulky derived data (debug dumps, checkpoints,
    /// flywheel staging, detector evidence) out of iCloud backups. Must be
    /// re-applied after every `.atomic` write: that replaces the file and the
    /// new inode doesn't carry the old resource value.
    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        do {
            try mutableURL.setResourceValues(values)
        } catch {
            logger.error("Couldn't exclude \(url.lastPathComponent) from backup: \(error.localizedDescription)")
        }
    }

    /// Move an unreadable file aside as `<name>.corrupt-<unix time>` so the next
    /// save can't overwrite the only copy of whatever it held. Returns the
    /// quarantine location, or nil if the move failed.
    @discardableResult
    static func quarantineCorruptFile(at url: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: url, to: destination)
            logger.error("Quarantined unreadable \(url.lastPathComponent) as \(destination.lastPathComponent)")
            return destination
        } catch {
            logger.error("Couldn't quarantine \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}
