//
//  MediaStore+Migration.swift
//  BumpSetCut
//
//  One-time manifest migrations, gated by `FolderManifest.version`:
//    v1 → v2  split the library into SavedGames / ProcessedGames roots
//    v2 → v3  backfill `hasProcessingMetadata` from sidecars on disk
//  Each returns whether it changed the manifest; the caller saves once.
//

import Foundation
import os

private let logger = Logger(subsystem: "BumpSetCut", category: "MediaStore")

extension MediaStore {

    /// Manifest version once every migration below has run.
    static let currentManifestVersion = 3

    /// Ensure the library root folders exist on disk and in the manifest.
    /// Returns true when the manifest gained an entry.
    func ensureLibraryRootsExist() -> Bool {
        var changed = false
        for libraryType in LibraryType.allCases {
            let rootPath = libraryType.rootPath

            let physicalURL = baseDirectory.appendingPathComponent(rootPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: physicalURL, withIntermediateDirectories: true, attributes: nil)

            if manifest.folders[rootPath] == nil {
                manifest.folders[rootPath] = FolderMetadata(
                    name: libraryType.displayName,
                    path: rootPath,
                    parentPath: nil,
                    createdDate: Date(),
                    modifiedDate: Date(),
                    videoCount: 0,
                    subfolderCount: 0
                )
                changed = true
                logger.info("MediaStore: Created library root folder: \(rootPath)")
            }
        }
        return changed
    }

    /// v2 → v3: flag videos that have a metadata file on disk but predate the
    /// `hasProcessingMetadata` field. Runs once; the flag is kept current by
    /// `markVideoAsProcessed` afterwards.
    func migrateProcessedVideosIfNeeded() -> Bool {
        guard manifest.version < 3 else { return false }

        var migratedCount = 0
        for (key, var video) in manifest.videos where !video.hasProcessingMetadata {
            guard let fileSize = metadataStore.getMetadataFileSize(for: video.id) else { continue }
            video.updateMetadataTracking(fileSize: fileSize)
            manifest.videos[key] = video
            migratedCount += 1
        }

        manifest.version = 3
        logger.info("MediaStore: processed-flag migration flagged \(migratedCount) video(s)")
        return true
    }

    /// Migration to separate libraries is complete once both roots exist and
    /// the manifest is at least v2.
    private func hasCompletedLibraryMigration() -> Bool {
        return manifest.version >= 2 &&
               manifest.folders[LibraryType.saved.rootPath] != nil &&
               manifest.folders[LibraryType.processed.rootPath] != nil
    }

    /// v1 → v2: move existing videos and folders under the SavedGames /
    /// ProcessedGames roots. Returns true when the manifest changed.
    func migrateToSeparateLibraries() -> Bool {
        guard !hasCompletedLibraryMigration() else { return false }

        let isInLibraryRoot = { (path: String) in
            LibraryType.allCases.contains { self.isPath(path, in: $0) }
        }

        // Anything not already under a library root needs moving.
        let videosNeedingMigration = manifest.videos.values.filter { !isInLibraryRoot($0.folderPath) }
        let foldersNeedingMigration = manifest.folders.values.filter { !isInLibraryRoot($0.path) }

        guard !videosNeedingMigration.isEmpty || !foldersNeedingMigration.isEmpty else {
            manifest.version = max(manifest.version, 2)
            logger.info("MediaStore: No content to migrate, marking migration complete")
            return true
        }

        logger.info("MediaStore: Starting library migration — \(videosNeedingMigration.count) videos, \(foldersNeedingMigration.count) folders")

        let fileManager = FileManager.default

        // 1. Migrate folders first (create structure in both libraries if needed)
        for folder in foldersNeedingMigration {
            let oldPath = folder.path

            let videosInFolder = manifest.videos.values.filter { $0.folderPath == oldPath }
            let hasOriginals = videosInFolder.contains { !$0.isProcessed }
            let hasProcessed = videosInFolder.contains { $0.isProcessed }

            for (library, include, count) in [
                (LibraryType.saved, hasOriginals, videosInFolder.filter { !$0.isProcessed }.count),
                (LibraryType.processed, hasProcessed, videosInFolder.filter { $0.isProcessed }.count),
            ] where include {
                let newPath = fullPath(for: oldPath, in: library)
                let physicalURL = baseDirectory.appendingPathComponent(newPath, isDirectory: true)
                try? fileManager.createDirectory(at: physicalURL, withIntermediateDirectories: true, attributes: nil)

                let parentPath = oldPath.contains("/")
                    ? fullPath(for: String(oldPath.dropLast(oldPath.split(separator: "/").last?.count ?? 0).dropLast()), in: library)
                    : library.rootPath

                manifest.folders[newPath] = FolderMetadata(
                    name: folder.name,
                    path: newPath,
                    parentPath: parentPath,
                    createdDate: folder.createdDate,
                    modifiedDate: folder.modifiedDate,
                    videoCount: count,
                    subfolderCount: 0
                )
            }

            manifest.folders.removeValue(forKey: oldPath)
        }

        // 2. Migrate videos
        for video in videosNeedingMigration {
            let oldFolderPath = video.folderPath
            let targetLibrary: LibraryType = video.isProcessed ? .processed : .saved
            let newFolderPath = fullPath(for: oldFolderPath, in: targetLibrary)

            let oldURL = oldFolderPath.isEmpty
                ? baseDirectory.appendingPathComponent(video.fileName)
                : baseDirectory.appendingPathComponent(oldFolderPath).appendingPathComponent(video.fileName)
            let newURL = baseDirectory.appendingPathComponent(newFolderPath).appendingPathComponent(video.fileName)

            try? fileManager.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

            do {
                if fileManager.fileExists(atPath: oldURL.path) {
                    try fileManager.moveItem(at: oldURL, to: newURL)
                }
            } catch {
                // Keep the entry where the file actually is, or the launch
                // reconcile would find nothing at the new path.
                logger.error("MediaStore: Could not move \(video.fileName) during library migration: \(String(describing: error))")
                continue
            }

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
            if let contents = try? fileManager.contentsOfDirectory(atPath: oldPhysicalURL.path), contents.isEmpty {
                try? fileManager.removeItem(at: oldPhysicalURL)
            }
        }

        // 5. Mark migration complete
        manifest.version = max(manifest.version, 2)
        logger.info("MediaStore: Library migration complete")
        return true
    }
}
