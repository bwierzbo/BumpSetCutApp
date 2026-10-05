//
//  MediaStore.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import Foundation
import AVFoundation
import Observation
import os

// File-scoped so every type in this file shares it. Unlike print, os.Logger
// redacts interpolated values in release logs, keeping user content private.
private let logger = Logger(subsystem: "BumpSetCut", category: "MediaStore")

/// How the manifest came off disk at launch. Anything but `.clean`/`.created`
/// means entries may be missing, so the launch reconcile re-adopts untracked
/// files and skips the orphaned-sidecar sweep (their videos may come back).
enum ManifestLoadOutcome: Equatable {
    case created
    case clean
    /// Some entries failed to decode and were dropped (original backed up).
    case partial
    /// The manifest was missing or undecodable; the last-good copy was used.
    case restoredFromLastGood
    /// Nothing usable: started empty (original backed up).
    case reset
    /// The file couldn't be read, or couldn't be backed up before replacing
    /// it. Saves are refused so it isn't overwritten; next launch retries.
    case unreadable
}

/// The single source of truth for the video library: `manifest.json` maps
/// file names to `VideoMetadata` and folder paths to `FolderMetadata`.
///
/// Every mutation is persisted before it's reported as successful. If the
/// manifest can't be written, the in-memory change (and any file move made
/// for it) is rolled back, the mutator returns false, and the failure is
/// surfaced through `PersistenceMonitor`.
@MainActor @Observable final class MediaStore {
    /// Mutated only by MediaStore and its extensions, which persist it.
    var manifest: FolderManifest
    let baseDirectory: URL
    /// Sidecars for this library (same directory as `MetadataStore.shared`
    /// in production; isolated with the store in tests).
    let metadataStore: MetadataStore
    private(set) var contentVersion: Int = 0

    @ObservationIgnored let manifestURL: URL
    @ObservationIgnored let lastGoodManifestURL: URL
    @ObservationIgnored let loadOutcome: ManifestLoadOutcome
    /// Saves are refused while the manifest on disk couldn't be read.
    @ObservationIgnored let isReadOnly: Bool
    /// An earlier save failed; the next save (or `PersistenceMonitor`'s
    /// background retry) writes the whole manifest again.
    @ObservationIgnored private(set) var hasUnsavedChanges = false
    /// Called with the ids of videos whose entries were removed (deleted by
    /// the user or found missing), after their files and sidecars are gone —
    /// lets processing and the flywheel drop work for them.
    @ObservationIgnored var onVideosRemoved: ((Set<UUID>) -> Void)?

    private static let saveRetryKey = "MediaStore.manifest"

    /// - Parameter baseDirectory: library root. Tests pass an isolated
    ///   directory (and set `StorageManager.storageDirectoryOverride` to the
    ///   same one, since `VideoMetadata`'s URL helpers resolve through it).
    init(baseDirectory: URL = StorageManager.getPersistentStorageDirectory()) {
        self.baseDirectory = baseDirectory
        self.manifestURL = baseDirectory.appendingPathComponent("manifest.json")
        self.lastGoodManifestURL = baseDirectory.appendingPathComponent("manifest.last-good.json")
        self.metadataStore = MetadataStore(baseDirectory: baseDirectory)

        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: nil)

        let loaded = Self.loadManifest(at: manifestURL, lastGoodURL: lastGoodManifestURL, baseDirectory: baseDirectory)
        self.manifest = loaded.manifest
        self.loadOutcome = loaded.outcome
        self.isReadOnly = loaded.outcome == .unreadable

        // Roots must exist before the first read; the migrations are one-time
        // and version-gated. One save covers everything that changed.
        var changed = loaded.outcome != .clean && loaded.outcome != .unreadable
        changed = ensureLibraryRootsExist() || changed
        changed = migrateToSeparateLibraries() || changed
        changed = migrateProcessedVideosIfNeeded() || changed
        if changed { saveManifest() }

        #if DEBUG
        // UI Testing: inject test video from the test runner
        injectTestVideoIfNeeded()

        // Dev convenience: prefill library with sample videos
        prefillLibraryIfNeeded()
        #endif

        // The per-file reconcile scan used to block launch. Defer it off the
        // main thread so the library renders immediately; the UI refreshes via
        // contentVersion if anything is reconciled.
        Task { await reconcileStorageOffMain() }
    }

    // MARK: - Manifest I/O

    private struct LoadedManifest {
        let manifest: FolderManifest
        let outcome: ManifestLoadOutcome
    }

    /// Read the manifest without ever destroying it: per-entry decode keeps
    /// the good entries, an undecodable file falls back to the last-good copy,
    /// and nothing is replaced unless the unreadable original was backed up
    /// first. A read (I/O) error is not corruption — it yields a read-only
    /// store so the file is left alone.
    private static func loadManifest(at url: URL, lastGoodURL: URL, baseDirectory: URL) -> LoadedManifest {
        let fileManager = FileManager.default
        let lastGood = { () -> FolderManifest? in
            guard let data = try? Data(contentsOf: lastGoodURL),
                  let manifest = try? JSONDecoder().decode(FolderManifest.self, from: data) else { return nil }
            return manifest
        }

        guard fileManager.fileExists(atPath: url.path) else {
            if let restored = lastGood() {
                logger.error("MediaStore: manifest missing — restored \(restored.videos.count) videos from the last-good copy")
                return LoadedManifest(manifest: restored, outcome: .restoredFromLastGood)
            }
            logger.info("MediaStore: Created new manifest")
            return LoadedManifest(manifest: FolderManifest(), outcome: .created)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("MediaStore: manifest exists but couldn't be read (\(String(describing: error))) — read-only until next launch")
            return LoadedManifest(manifest: lastGood() ?? FolderManifest(), outcome: .unreadable)
        }

        do {
            let manifest = try JSONDecoder().decode(FolderManifest.self, from: data)
            if manifest.droppedEntryCount == 0 {
                do {
                    try data.write(to: lastGoodURL, options: .atomic)
                } catch {
                    logger.error("MediaStore: couldn't write last-good manifest: \(String(describing: error))")
                }
                logger.info("MediaStore: Loaded \(manifest.videos.count) videos, \(manifest.folders.count) folders")
                return LoadedManifest(manifest: manifest, outcome: .clean)
            }
            guard backUpUnreadableManifest(at: url, in: baseDirectory) else {
                return LoadedManifest(manifest: manifest, outcome: .unreadable)
            }
            logger.error("MediaStore: dropped \(manifest.droppedEntryCount) undecodable manifest entries (original backed up)")
            return LoadedManifest(manifest: manifest, outcome: .partial)
        } catch is DecodingError {
            guard backUpUnreadableManifest(at: url, in: baseDirectory) else {
                return LoadedManifest(manifest: lastGood() ?? FolderManifest(), outcome: .unreadable)
            }
            if let restored = lastGood() {
                logger.error("MediaStore: manifest undecodable — restored \(restored.videos.count) videos from the last-good copy")
                return LoadedManifest(manifest: restored, outcome: .restoredFromLastGood)
            }
            logger.error("MediaStore: manifest undecodable and no last-good copy — starting empty (original backed up)")
            return LoadedManifest(manifest: FolderManifest(), outcome: .reset)
        } catch {
            logger.error("MediaStore: manifest load failed (\(String(describing: error))) — read-only until next launch")
            return LoadedManifest(manifest: lastGood() ?? FolderManifest(), outcome: .unreadable)
        }
    }

    /// Copy an unreadable manifest aside before anything replaces it.
    private static func backUpUnreadableManifest(at url: URL, in baseDirectory: URL) -> Bool {
        let backupURL = baseDirectory.appendingPathComponent("manifest.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.copyItem(at: url, to: backupURL)
            return true
        } catch {
            logger.error("MediaStore: couldn't back up the unreadable manifest (\(String(describing: error))) — not replacing it")
            return false
        }
    }

    /// Persist the manifest. On failure the change stays in memory, is marked
    /// unsaved, retried by the next save and on app background, and the user
    /// is told. Returns whether it reached disk.
    @discardableResult
    func saveManifest() -> Bool {
        // In-memory state changed either way; observers refresh.
        contentVersion += 1
        do {
            try writeManifest()
            PersistenceMonitor.shared.resolve(retryKey: Self.saveRetryKey)
            return true
        } catch {
            PersistenceMonitor.shared.reportFailure(error, context: "library manifest", retryKey: Self.saveRetryKey) { [weak self] in
                guard let self else { return true }
                return (try? self.writeManifest()) != nil
            }
            return false
        }
    }

    private enum ManifestWriteError: LocalizedError {
        case readOnly
        var errorDescription: String? { String(localized: "The library index couldn't be read at launch, so it isn't being overwritten.") }
    }

    private func writeManifest() throws {
        guard !isReadOnly else {
            hasUnsavedChanges = true
            throw ManifestWriteError.readOnly
        }
        manifest.updateModifiedDate()
        let fileManager = FileManager.default
        let tempURL = baseDirectory.appendingPathComponent(".manifest_tmp_\(UUID().uuidString).json")
        // replaceItemAt consumes the temp file on success; this only cleans up
        // after a failure so temps never pile up.
        defer { try? fileManager.removeItem(at: tempURL) }
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: tempURL, options: [.atomic])
            if fileManager.fileExists(atPath: manifestURL.path) {
                _ = try fileManager.replaceItemAt(manifestURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: manifestURL)
            }
            hasUnsavedChanges = false
        } catch {
            hasUnsavedChanges = true
            throw error
        }
    }

    /// Apply `change` and persist it. If the save fails the manifest is put
    /// back and `rollbackFiles` undoes any filesystem change already made, so
    /// the library never claims something that isn't on disk.
    func commit(_ change: () -> Void, rollbackFiles: () -> Void = {}) -> Bool {
        let snapshot = manifest
        change()
        guard saveManifest() else {
            manifest = snapshot
            rollbackFiles()
            contentVersion += 1
            return false
        }
        return true
    }

    func adjustVideoCount(of folderPath: String, by delta: Int) {
        guard !folderPath.isEmpty, let folder = manifest.folders[folderPath] else { return }
        manifest.folders[folderPath]?.videoCount = max(0, folder.videoCount + delta)
        manifest.folders[folderPath]?.modifiedDate = Date()
    }

    func fileURL(for video: VideoMetadata) -> URL {
        baseDirectory.appendingPathComponent(video.folderPath).appendingPathComponent(video.fileName)
    }
}

// MARK: - Folder Operations

extension MediaStore {
    func createFolder(name: String, parentPath: String = "") -> Bool {
        // Reject path-traversal / illegal names (e.g. "../evil", names containing "/")
        // so no caller can escape the library root. This is the single choke point;
        // callers must not construct folder paths without going through here.
        guard FolderValidationRules.isValidName(name) else { return false }

        let folderPath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        guard manifest.folders[folderPath] == nil else { return false }

        let physicalURL = baseDirectory.appendingPathComponent(folderPath, isDirectory: true)
        let existedBefore = FileManager.default.fileExists(atPath: physicalURL.path)

        do {
            try FileManager.default.createDirectory(at: physicalURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("Failed to create folder: \(String(describing: error))")
            return false
        }

        return commit({
            manifest.folders[folderPath] = FolderMetadata(
                name: name,
                path: folderPath,
                parentPath: parentPath.isEmpty ? nil : parentPath,
                createdDate: Date(),
                modifiedDate: Date(),
                videoCount: 0,
                subfolderCount: 0
            )
            if !parentPath.isEmpty {
                manifest.folders[parentPath]?.subfolderCount += 1
                manifest.folders[parentPath]?.modifiedDate = Date()
            }
        }, rollbackFiles: {
            if !existedBefore { try? FileManager.default.removeItem(at: physicalURL) }
        })
    }

    func renameFolder(at path: String, to newName: String) -> Bool {
        // Reject path-traversal / illegal names before they reach the filesystem.
        guard FolderValidationRules.isValidName(newName) else { return false }
        guard var folderMetadata = manifest.folders[path] else { return false }

        let parentPath = folderMetadata.parentPath ?? ""
        let newPath = parentPath.isEmpty ? newName : "\(parentPath)/\(newName)"
        guard manifest.folders[newPath] == nil else { return false } // Name already exists

        let oldURL = baseDirectory.appendingPathComponent(path, isDirectory: true)
        let newURL = baseDirectory.appendingPathComponent(newPath, isDirectory: true)

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            logger.error("Failed to rename folder: \(String(describing: error))")
            return false
        }

        return commit({
            folderMetadata.name = newName
            folderMetadata.path = newPath
            folderMetadata.modifiedDate = Date()
            manifest.folders.removeValue(forKey: path)
            manifest.folders[newPath] = folderMetadata
            updateChildPaths(oldPath: path, newPath: newPath)
        }, rollbackFiles: {
            try? FileManager.default.moveItem(at: newURL, to: oldURL)
        })
    }

    /// Remove a folder, everything under it, and (via the usual video
    /// teardown) its videos' sidecars and processed copies.
    func deleteFolder(at path: String) -> Bool {
        guard let folderMetadata = manifest.folders[path] else { return false }

        let childVideoKeys = manifest.videos.filter {
            // Boundary-aware: "Team" must not match "Team B"
            $0.value.folderPath == path || $0.value.folderPath.hasPrefix("\(path)/")
        }.map(\.key)

        guard let removed = commitVideoRemoval(keys: childVideoKeys, cascadeToProcessedCopies: true, alsoChange: {
            manifest.folders.removeValue(forKey: path)
            for key in manifest.folders.keys where key.hasPrefix("\(path)/") {
                manifest.folders.removeValue(forKey: key)
            }
            if let parentPath = folderMetadata.parentPath, let parent = manifest.folders[parentPath] {
                manifest.folders[parentPath]?.subfolderCount = max(0, parent.subfolderCount - 1)
                manifest.folders[parentPath]?.modifiedDate = Date()
            }
        }) else { return false }

        // The manifest no longer references anything here. A leftover on
        // failure is harmless: the launch reconcile re-adopts untracked videos.
        let physicalURL = baseDirectory.appendingPathComponent(path, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: physicalURL)
        } catch {
            logger.error("Failed to delete folder directory: \(String(describing: error))")
        }
        discardRemovedVideos(removed, deleteFiles: true)
        return true
    }

    private func updateChildPaths(oldPath: String, newPath: String) {
        let oldPathPrefix = oldPath + "/"

        // Update ALL descendant folders (not just immediate children)
        // Sort by path depth (ascending) to process parents before children
        let descendantFolders = manifest.folders
            .filter { $0.key.hasPrefix(oldPathPrefix) }
            .sorted { $0.key.components(separatedBy: "/").count < $1.key.components(separatedBy: "/").count }

        for (oldFolderPath, var folder) in descendantFolders {
            let newFolderPath = newPath + String(oldFolderPath.dropFirst(oldPath.count))

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
            video.folderPath = newPath + String(video.folderPath.dropFirst(oldPath.count))
            manifest.videos[videoKey] = video
        }
    }
}

// MARK: - Video Operations

extension MediaStore {

    enum ImportError: LocalizedError {
        case invalidDestination
        case storageFull
        case registrationFailed
        case fileSystem(Error)

        var errorDescription: String? {
            switch self {
            case .invalidDestination:
                return String(localized: "That folder isn't available anymore.")
            case .storageFull:
                return String(localized: "Your device ran out of storage space while importing the video. Free up space in Settings > General > iPhone Storage, then try again.")
            case .registrationFailed:
                return String(localized: "The video couldn't be added to your library.")
            case .fileSystem(let error):
                return error.localizedDescription
            }
        }
    }

    /// Trims control characters and whitespace and caps length, so no import
    /// path can store an unbounded or invisible name.
    static func sanitizedVideoName(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = name
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(100))
    }

    /// Move a video file the caller owns (a temp copy) into the library and
    /// register it — the one import path. On any failure the source and any
    /// moved copy are removed, so nothing is left on disk untracked.
    @discardableResult
    func importVideo(from sourceURL: URL, toFolder folderPath: String, customName: String?) throws -> VideoMetadata {
        let fileManager = FileManager.default
        let fileName = "Video_\(DateFormatter.yyyyMMdd_HHmmss.string(from: Date()))_\(UUID().uuidString.prefix(4)).mp4"
        let destinationURL = baseDirectory
            .appendingPathComponent(folderPath, isDirectory: true)
            .appendingPathComponent(fileName)

        // Never trust a caller-supplied folder to stay inside the library, and
        // only import into folders the library knows (else the video is invisible).
        let rootPath = baseDirectory.standardizedFileURL.path
        guard destinationURL.standardizedFileURL.path.hasPrefix(rootPath + "/"),
              folderPath.isEmpty || manifest.folders[folderPath] != nil else {
            logger.error("Rejected import destination '\(folderPath)'")
            try? fileManager.removeItem(at: sourceURL)
            throw ImportError.invalidDestination
        }

        do {
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // O(1) rename on the same volume — no full copy of a large video.
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: sourceURL)
            if StorageChecker.isStorageError(error) {
                throw ImportError.storageFull
            }
            throw ImportError.fileSystem(error)
        }

        guard addVideo(at: destinationURL, toFolder: folderPath, customName: Self.sanitizedVideoName(customName)),
              let added = manifest.videos[fileName] else {
            try? fileManager.removeItem(at: destinationURL)
            throw ImportError.registrationFailed
        }
        logger.info("Imported \(fileName) into '\(folderPath)'")
        return added
    }

    /// Before re-running detection on a video: drop the sidecars the new run
    /// invalidates (rally-index keyed state, evidence, checkpoint) but keep
    /// `{id}.json`, which the processor reads to carry manual rallies over
    /// and replaces when it finishes. The manifest keeps the video marked as
    /// having metadata — it still does until the new run lands.
    func prepareForReprocess(videoId: UUID) {
        metadataStore.deleteSidecarsForReprocess(videoId: videoId)
    }

    /// Record that rally detection finished for a video.
    @discardableResult
    func markVideoAsProcessed(videoId: UUID, metadataFileSize: Int64) -> Bool {
        guard let key = manifest.videos.first(where: { $0.value.id == videoId })?.key else {
            logger.error("❌ MediaStore.markVideoAsProcessed: Video with ID \(videoId) not found")
            return false
        }
        manifest.videos[key]?.updateMetadataTracking(fileSize: metadataFileSize)
        return saveManifest()
    }

    /// Favorite clips remember which rally they came from by index. After a
    /// timeline edit reorders/removes rallies, move those indices with them;
    /// a clip whose rally was deleted loses the link.
    @discardableResult
    func remapFavoriteSourceIndices(sourceVideoId: UUID, oldToNew: [Int: Int]) -> Bool {
        let affected = manifest.videos.compactMap { key, video -> (String, Int?)? in
            guard video.sourceVideoId == sourceVideoId, let oldIndex = video.sourceRallyIndex else { return nil }
            let newIndex = oldToNew[oldIndex]
            return newIndex == oldIndex ? nil : (key, newIndex)
        }
        guard !affected.isEmpty else { return true }
        return commit {
            for (key, newIndex) in affected {
                manifest.videos[key]?.sourceRallyIndex = newIndex
            }
        }
    }

    /// Replace a video's file on disk with a new file (e.g. after trimming).
    /// Atomic: if the swap fails the original is untouched and false is
    /// returned. Updates fileSize now and duration once it's loaded.
    func replaceVideoFile(id: UUID, withFileAt newURL: URL) -> Bool {
        guard let (videoKey, video) = manifest.videos.first(where: { $0.value.id == id }) else {
            logger.error("❌ replaceVideoFile: Video with ID \(id) not found")
            return false
        }

        let destinationURL = fileURL(for: video)
        let fileManager = FileManager.default

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: newURL)
            } else {
                try fileManager.moveItem(at: newURL, to: destinationURL)
            }
        } catch {
            logger.error("❌ replaceVideoFile: \(String(describing: error))")
            return false
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: destinationURL.path),
           let newSize = attributes[.size] as? Int64 {
            manifest.videos[videoKey]?.fileSize = newSize
        }
        // The file is already replaced; a failed save here is retried.
        saveManifest()

        Task {
            let asset = AVURLAsset(url: destinationURL)
            if let duration = try? await asset.load(.duration) {
                let durationSeconds = CMTimeGetSeconds(duration)
                if durationSeconds > 0 && !durationSeconds.isNaN {
                    self.updateVideoDuration(id: id, duration: durationSeconds)
                }
            }
        }
        return true
    }

    private func updateVideoDuration(id: UUID, duration: TimeInterval) {
        guard let videoKey = manifest.videos.first(where: { $0.value.id == id })?.key else { return }
        manifest.videos[videoKey]?.duration = duration
        saveManifest()
    }

    /// Register a distinct processed export (debug mode) and link it to its
    /// original. Returns the new entry, or nil if it couldn't be recorded.
    @discardableResult
    func addProcessedVideo(at url: URL, toFolder folderPath: String = "", customName: String? = nil, originalVideoId: UUID) -> VideoMetadata? {
        let videoKey = url.lastPathComponent
        guard manifest.videos[videoKey] == nil else {
            logger.error("❌ addProcessedVideo: '\(videoKey)' is already in the library")
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            logger.error("❌ MediaStore.addProcessedVideo: failed to read attributes for \(url.path)")
            return nil
        }

        var videoMetadata = VideoMetadata(
            originalURL: url,
            customName: customName,
            folderPath: folderPath,
            createdDate: attributes[.creationDate] as? Date ?? Date(),
            fileSize: fileSize,
            duration: nil
        )
        videoMetadata.isProcessed = true
        videoMetadata.processedDate = Date()
        videoMetadata.originalVideoId = originalVideoId

        let saved = commit {
            manifest.videos[videoKey] = videoMetadata
            if let originalKey = manifest.videos.first(where: { $0.value.id == originalVideoId })?.key {
                manifest.videos[originalKey]?.processedVideoIds.append(videoMetadata.id)
            } else {
                logger.warning("⚠️ Original video with ID \(originalVideoId) not found")
            }
            adjustVideoCount(of: folderPath, by: 1)
        }
        return saved ? videoMetadata : nil
    }

    /// Register a file already inside the library. Refuses a file name that's
    /// already registered (the manifest is keyed by file name).
    func addVideo(at url: URL, toFolder folderPath: String = "", customName: String? = nil, sourceVideoId: UUID? = nil, sourceRallyIndex: Int? = nil) -> Bool {
        let videoKey = url.lastPathComponent
        guard manifest.videos[videoKey] == nil else {
            logger.error("❌ addVideo: '\(videoKey)' is already in the library")
            return false
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            logger.error("❌ Failed to get file attributes for: \(url.path)")
            return false
        }

        var videoMetadata = VideoMetadata(
            originalURL: url,
            customName: customName,
            folderPath: folderPath,
            createdDate: attributes[.creationDate] as? Date ?? Date(),
            fileSize: fileSize,
            duration: nil
        )
        videoMetadata.sourceVideoId = sourceVideoId
        videoMetadata.sourceRallyIndex = sourceRallyIndex

        return commit {
            manifest.videos[videoKey] = videoMetadata
            adjustVideoCount(of: folderPath, by: 1)
        }
    }

    func moveVideo(fileName: String, toFolder newFolderPath: String) -> Bool {
        guard let videoMetadata = manifest.videos[fileName] else { return false }

        let oldFolderPath = videoMetadata.folderPath
        guard oldFolderPath != newFolderPath else { return true }
        let fileURL = baseDirectory.appendingPathComponent(oldFolderPath).appendingPathComponent(fileName)
        let newFileURL = baseDirectory.appendingPathComponent(newFolderPath).appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(
                at: newFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try FileManager.default.moveItem(at: fileURL, to: newFileURL)
        } catch {
            logger.error("Failed to move video: \(String(describing: error))")
            return false
        }

        return commit({
            manifest.videos[fileName]?.folderPath = newFolderPath
            adjustVideoCount(of: oldFolderPath, by: -1)
            adjustVideoCount(of: newFolderPath, by: 1)
        }, rollbackFiles: {
            try? FileManager.default.moveItem(at: newFileURL, to: fileURL)
        })
    }

    func renameVideo(fileName: String, to newName: String) -> Bool {
        guard manifest.videos[fileName] != nil else { return false }
        return commit {
            manifest.videos[fileName]?.customName = newName
        }
    }

    /// Delete a video: its file, sidecars, debug data and — for an original —
    /// its legacy processed copies. The manifest is saved first; files go only
    /// once it no longer references them.
    func deleteVideo(fileName: String) -> Bool {
        guard manifest.videos[fileName] != nil,
              let removed = commitVideoRemoval(keys: [fileName], cascadeToProcessedCopies: true) else {
            return false
        }
        discardRemovedVideos(removed, deleteFiles: true)
        return true
    }

    /// Remove entries (plus, with `cascadeToProcessedCopies`, the processed
    /// copies of removed originals — found by id, whether or not their file
    /// still exists) and persist. Processed copies whose original survives
    /// are unlinked from it. Returns the removed entries, or nil when the save
    /// failed and everything was rolled back.
    func commitVideoRemoval(keys: [String], cascadeToProcessedCopies: Bool,
                            alsoChange: () -> Void = {}) -> [VideoMetadata]? {
        var removedByKey: [String: VideoMetadata] = [:]
        for key in keys {
            guard let video = manifest.videos[key] else { continue }
            removedByKey[key] = video
            if cascadeToProcessedCopies, !video.isProcessed, !video.processedVideoIds.isEmpty {
                for (copyKey, copy) in manifest.videos where video.processedVideoIds.contains(copy.id) {
                    removedByKey[copyKey] = copy
                }
            }
        }
        let removedIds = Set(removedByKey.values.map(\.id))

        let saved = commit {
            alsoChange()
            for (key, video) in removedByKey {
                manifest.videos.removeValue(forKey: key)
                adjustVideoCount(of: video.folderPath, by: -1)
                if video.isProcessed, let originalId = video.originalVideoId, !removedIds.contains(originalId),
                   let originalKey = manifest.videos.first(where: { $0.value.id == originalId })?.key {
                    manifest.videos[originalKey]?.processedVideoIds.removeAll { $0 == video.id }
                }
            }
        }
        return saved ? Array(removedByKey.values) : nil
    }

    /// After their entries are gone: delete files (when asked), sidecars and
    /// debug dumps, then tell `onVideosRemoved`.
    func discardRemovedVideos(_ removed: [VideoMetadata], deleteFiles: Bool) {
        guard !removed.isEmpty else { return }
        let fileManager = FileManager.default
        for video in removed {
            let url = fileURL(for: video)
            if deleteFiles, fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    // Untracked now; the launch reconcile re-adopts it rather than leaking it.
                    logger.error("⚠️ Failed to delete video file \(video.fileName): \(String(describing: error))")
                }
            }
            metadataStore.deleteAllSidecars(for: video.id)
            if let debugURL = debugDataURL(for: video) {
                try? fileManager.removeItem(at: debugURL)
            }
        }
        onVideosRemoved?(Set(removed.map(\.id)))
    }
}

// MARK: - Query Operations

extension MediaStore {
    /// Child folders of `parentPath`, with counts computed from the manifest
    /// in one grouped pass (stored counts can drift).
    func getFolders(in parentPath: String = "") -> [FolderMetadata] {
        let parent: String? = parentPath.isEmpty ? nil : parentPath
        let children = manifest.folders.values.filter { $0.parentPath == parent }
        guard !children.isEmpty else { return [] }

        var videoCounts: [String: Int] = [:]
        for video in manifest.videos.values {
            videoCounts[video.folderPath, default: 0] += 1
        }
        var subfolderCounts: [String: Int] = [:]
        for folder in manifest.folders.values {
            if let parentPath = folder.parentPath {
                subfolderCounts[parentPath, default: 0] += 1
            }
        }

        return children
            .map { folder in
                var counted = folder
                counted.videoCount = videoCounts[folder.path] ?? 0
                counted.subfolderCount = subfolderCounts[folder.path] ?? 0
                return counted
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func getVideos(in folderPath: String = "") -> [VideoMetadata] {
        let matchingFolderVideos = manifest.videos.values.filter { $0.folderPath == folderPath }

        // Batch file existence check: one directory listing instead of N file checks
        let folderURL = folderPath.isEmpty
            ? baseDirectory
            : baseDirectory.appendingPathComponent(folderPath, isDirectory: true)

        let existingFiles: Set<String>
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            existingFiles = Set(contents.map { $0.lastPathComponent })
        } catch {
            existingFiles = []
        }

        return matchingFolderVideos
            .filter { existingFiles.contains($0.fileName) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func searchVideos(query: String) -> [VideoMetadata] {
        let fileManager = FileManager.default
        let lowercaseQuery = query.lowercased()
        return manifest.videos.values
            .filter { video in
                video.displayName.lowercased().contains(lowercaseQuery) ||
                video.fileName.lowercased().contains(lowercaseQuery)
            }
            .filter { fileManager.fileExists(atPath: fileURL(for: $0).path) }
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

        if !query.isEmpty {
            let lowercaseQuery = query.lowercased()
            results = results.filter { video in
                video.displayName.lowercased().contains(lowercaseQuery) ||
                video.fileName.lowercased().contains(lowercaseQuery)
            }
        }

        if let fileType = fileType, !fileType.isEmpty {
            results = results.filter { video in
                video.fileName.lowercased().hasSuffix(".\(fileType.lowercased())")
            }
        }

        if let minSize = minSize {
            results = results.filter { $0.fileSize >= minSize }
        }

        if let maxSize = maxSize {
            results = results.filter { $0.fileSize <= maxSize }
        }

        if let fromDate = fromDate {
            results = results.filter { $0.createdDate >= fromDate }
        }

        if let toDate = toDate {
            results = results.filter { $0.createdDate <= toDate }
        }

        if let inFolder = inFolder {
            if inFolder.isEmpty {
                results = results.filter { $0.folderPath.isEmpty }
            } else {
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

    func getVideoURL(for metadata: VideoMetadata) -> URL {
        fileURL(for: metadata)
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

    /// Search videos within a specific library
    func searchVideos(query: String, in library: LibraryType) -> [VideoMetadata] {
        searchVideos(query: query).filter { isPath($0.folderPath, in: library) }
    }

    /// Search folders within a specific library
    func searchFolders(query: String, in library: LibraryType) -> [FolderMetadata] {
        searchFolders(query: query).filter { isPath($0.path, in: library) }
    }

    /// Get all videos in a library (for stats)
    func getAllVideos(in library: LibraryType) -> [VideoMetadata] {
        getAllVideos().filter { isPath($0.folderPath, in: library) }
    }

    /// Get all folders in a library
    func getAllFolders(in library: LibraryType) -> [FolderMetadata] {
        getAllFolders().filter { isPath($0.path, in: library) }
    }
}
