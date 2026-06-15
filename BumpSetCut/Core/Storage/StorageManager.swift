//
//  StorageManager.swift
//  BumpSetCut
//
//  Extracted from MediaStore.swift so platform-neutral storage helpers can be
//  shared with the RallyLab macOS target without pulling in the full MediaStore.
//

import Foundation

// MARK: - Storage Utilities

struct StorageManager {
    /// Test seam: when non-nil, overrides the storage location so tests can run
    /// against an isolated temp directory instead of the shared on-disk library.
    /// Production never sets this, so the default behavior is unchanged.
    static var storageDirectoryOverride: URL?

    static func getPersistentStorageDirectory() -> URL {
        if let override = storageDirectoryOverride { return override }
        let fileManager = FileManager.default
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BumpSetCut", isDirectory: true)
    }

    static func verifyStorageIntegrity() {
        let baseDir = getPersistentStorageDirectory()
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: baseDir.path) else {
            print("StorageManager: ⚠️ Storage directory missing at \(baseDir.path)")
            return
        }

        if (try? fileManager.contentsOfDirectory(atPath: baseDir.path)) == nil {
            print("StorageManager: ⚠️ Failed to read storage directory \(baseDir.path)")
        }
    }
}
