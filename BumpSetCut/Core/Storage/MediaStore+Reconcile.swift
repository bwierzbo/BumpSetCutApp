//
//  MediaStore+Reconcile.swift
//  BumpSetCut
//
//  Bringing the manifest back in line with what's on disk. Never drops an
//  entry whose file still exists somewhere in the library: a video found
//  under another folder is relinked, untracked videos are re-adopted, and
//  only entries whose file is truly gone are removed (with their sidecars).
//

import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "BumpSetCut", category: "MediaStore")

/// Video files under the library roots, found off the main actor.
struct LibraryDiskScan: Sendable {
    /// Video file name → folder paths (relative to the library base) holding
    /// a file of that name.
    private(set) var videoFolders: [String: [String]] = [:]

    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func scan(baseDirectory: URL, roots: [String]) -> LibraryDiskScan {
        var result = LibraryDiskScan()
        for root in roots {
            let rootURL = baseDirectory.appendingPathComponent(root, isDirectory: true)
            guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: rootURL.path) else { continue }
            for subpath in subpaths {
                let components = subpath.split(separator: "/").map(String.init)
                guard let name = components.last,
                      !components.contains(where: { $0.hasPrefix(".") }),
                      videoExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                let folder = ([root] + components.dropLast()).joined(separator: "/")
                result.videoFolders[name, default: []].append(folder)
            }
        }
        return result
    }

    func folders(containing fileName: String) -> [String] {
        videoFolders[fileName] ?? []
    }
}

extension MediaStore {

    /// Synchronous variant for the library screens' refresh: relinks or
    /// removes entries whose file is missing. Cheap when nothing is missing
    /// (the common case); only then does it scan the library roots.
    func cleanupStaleEntries() {
        let fileManager = FileManager.default
        let missingVideoKeys = manifest.videos
            .filter { !fileManager.fileExists(atPath: fileURL(for: $0.value).path) }
            .map(\.key)
        let missingFolderKeys = manifest.folders.keys.filter {
            !fileManager.fileExists(atPath: baseDirectory.appendingPathComponent($0, isDirectory: true).path)
        }
        guard !missingVideoKeys.isEmpty || !missingFolderKeys.isEmpty else { return }

        let disk = missingVideoKeys.isEmpty
            ? LibraryDiskScan()
            : LibraryDiskScan.scan(baseDirectory: baseDirectory, roots: LibraryType.allCases.map(\.rootPath))
        applyReconcile(missingVideoKeys: missingVideoKeys, missingFolderKeys: missingFolderKeys,
                       disk: disk, adoptUntracked: false)
    }

    /// Launch-time reconciliation, kept off the main thread. The library
    /// renders immediately from the loaded manifest; the filesystem scan runs
    /// on a background executor, then changes are applied on the main actor
    /// (re-validated there, since the user may have acted meanwhile).
    func reconcileStorageOffMain() async {
        let base = baseDirectory
        StorageManager.verifyStorageIntegrity(at: base)

        // Snapshot the paths on the main actor (manifest is main-actor state)...
        let videoSnapshot: [(key: String, path: String)] = manifest.videos.map { key, video in
            (key, fileURL(for: video).path)
        }
        let folderSnapshot: [(key: String, path: String)] = manifest.folders.keys.map { key in
            (key, base.appendingPathComponent(key, isDirectory: true).path)
        }
        let roots = LibraryType.allCases.map(\.rootPath)

        // ...then do the filesystem work off the main thread.
        let (missingVideoKeys, missingFolderKeys, disk) = await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let videos = videoSnapshot.filter { !fileManager.fileExists(atPath: $0.path) }.map(\.key)
            let folders = folderSnapshot.filter { !fileManager.fileExists(atPath: $0.path) }.map(\.key)
            return (videos, folders, LibraryDiskScan.scan(baseDirectory: base, roots: roots))
        }.value

        await recoverInterruptedReplacements()
        metadataStore.removeIncompleteTransactionFiles()
        applyReconcile(missingVideoKeys: missingVideoKeys, missingFolderKeys: missingFolderKeys,
                       disk: disk, adoptUntracked: true)
        removeLeftoverManifestTemps()

        // Only a manifest that loaded intact is a trustworthy list of live
        // videos — after a partial load or reset, sidecars whose videos were
        // dropped may still be wanted.
        if loadOutcome == .clean {
            let liveIds = Set(manifest.videos.values.map(\.id))
            metadataStore.sweepOrphanedSidecars(keeping: liveIds)
            sweepOrphanedDebugData(keeping: liveIds)
        }
    }

    private func applyReconcile(missingVideoKeys: [String], missingFolderKeys: [String],
                                disk: LibraryDiskScan, adoptUntracked: Bool) {
        let fileManager = FileManager.default
        let fileExists = { (folder: String, name: String) in
            fileManager.fileExists(atPath: self.baseDirectory
                .appendingPathComponent(folder).appendingPathComponent(name).path)
        }
        var changed = false
        var staleKeys: [String] = []

        // Missing at the recorded path: relink if the file is elsewhere in the
        // library, otherwise it's really gone.
        for key in missingVideoKeys {
            guard let video = manifest.videos[key],
                  !fileManager.fileExists(atPath: fileURL(for: video).path) else { continue }
            if let folder = disk.folders(containing: video.fileName).first(where: { fileExists($0, video.fileName) }) {
                ensureFolderChain(folder)
                adjustVideoCount(of: video.folderPath, by: -1)
                manifest.videos[key]?.folderPath = folder
                adjustVideoCount(of: folder, by: 1)
                changed = true
                logger.warning("Relinked \(video.fileName) to '\(folder)'")
            } else {
                staleKeys.append(key)
            }
        }

        // Video files the manifest doesn't know: re-adopt rather than leak.
        if adoptUntracked {
            for (name, folders) in disk.videoFolders where manifest.videos[name] == nil {
                guard let folder = folders.first(where: { fileExists($0, name) }) else { continue }
                let url = baseDirectory.appendingPathComponent(folder).appendingPathComponent(name)
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      let fileSize = attributes[.size] as? Int64 else { continue }
                ensureFolderChain(folder)
                manifest.videos[name] = VideoMetadata(
                    fileName: name,
                    customName: nil,
                    folderPath: folder,
                    createdDate: attributes[.creationDate] as? Date ?? Date(),
                    fileSize: fileSize,
                    duration: nil
                )
                adjustVideoCount(of: folder, by: 1)
                changed = true
                logger.warning("Re-adopted untracked video \(name) in '\(folder)'")
            }
        }

        let rootPaths = Set(LibraryType.allCases.map(\.rootPath))
        for key in missingFolderKeys where manifest.folders[key] != nil {
            let url = baseDirectory.appendingPathComponent(key, isDirectory: true)
            guard !fileManager.fileExists(atPath: url.path) else { continue }
            if rootPaths.contains(key) {
                // Never drop a library root — recreate it.
                try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            logger.warning("Removing folder entry \(key) (directory not found)")
            manifest.folders.removeValue(forKey: key)
            changed = true
        }

        if !staleKeys.isEmpty {
            for key in staleKeys {
                logger.warning("Removing video entry \(key) (file not found anywhere in the library)")
            }
            // Saves everything above too. On failure the earlier changes stay
            // in memory as unsaved and are retried.
            if let removed = commitVideoRemoval(keys: staleKeys, cascadeToProcessedCopies: false) {
                discardRemovedVideos(removed, deleteFiles: false)
            }
        } else if changed {
            saveManifest()
        }
    }

    /// Make sure every folder on `path` (e.g. "SavedGames/Team/2025") has an
    /// entry, so a relinked or adopted video is reachable in the UI.
    private func ensureFolderChain(_ path: String) {
        let components = path.split(separator: "/").map(String.init)
        for depth in components.indices {
            let folderPath = components[...depth].joined(separator: "/")
            guard manifest.folders[folderPath] == nil else { continue }
            let parentPath = depth == 0 ? nil : components[..<depth].joined(separator: "/")
            manifest.folders[folderPath] = FolderMetadata(
                name: components[depth],
                path: folderPath,
                parentPath: parentPath,
                createdDate: Date(),
                modifiedDate: Date(),
                videoCount: 0,
                subfolderCount: 0
            )
            if let parentPath {
                manifest.folders[parentPath]?.subfolderCount += 1
            }
        }
    }

    private func removeLeftoverManifestTemps() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: baseDirectory.path) else { return }
        for name in names where name.hasPrefix(".manifest_tmp_") {
            try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(name))
        }
    }

    /// Finish or roll back a "Free Up Space" trim that was interrupted between
    /// installing the shorter video and swapping in its remapped metadata:
    /// the staged metadata records the trimmed duration, so it's committed
    /// only if the video on disk is the trimmed one.
    private func recoverInterruptedReplacements() async {
        for videoId in metadataStore.videoIdsWithStagedSidecars() {
            let candidates = manifest.videos.values.filter { $0.id == videoId || $0.originalVideoId == videoId }
            guard let staged = metadataStore.stagedMetadata(for: videoId),
                  let expected = staged.sourceDurationSec,
                  !candidates.isEmpty else {
                metadataStore.discardStagedSidecars(for: videoId)
                continue
            }

            var matches = false
            for video in candidates {
                if let duration = try? await AVURLAsset(url: fileURL(for: video)).load(.duration),
                   abs(CMTimeGetSeconds(duration) - expected) < 0.5 {
                    matches = true
                    break
                }
            }

            if matches {
                do {
                    try metadataStore.commitStagedSidecars(for: videoId)
                    logger.warning("Completed an interrupted space-saver trim for \(videoId)")
                } catch {
                    logger.error("Couldn't complete interrupted trim for \(videoId): \(String(describing: error))")
                }
            } else {
                metadataStore.discardStagedSidecars(for: videoId)
                logger.warning("Discarded staged metadata of an unfinished trim for \(videoId)")
            }
        }
    }
}
