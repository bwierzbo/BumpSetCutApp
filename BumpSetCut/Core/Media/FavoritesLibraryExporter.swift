//
//  FavoritesLibraryExporter.swift
//  BumpSetCut
//
//  Copies a game's favorited rallies into the Favorites library as their own
//  clips (trim-aware, framing burned in), filed into the collection the user
//  picked. Idempotent: Export, Done and back navigation all run it, so rallies
//  already copied are re-filed if needed, never duplicated.
//

import AVFoundation

@MainActor
struct FavoritesLibraryExporter {
    let mediaStore: MediaStore

    /// One favorited rally, already resolved against the user's trims.
    struct Rally {
        let index: Int
        let startTime: Double
        let endTime: Double
        let crop: ShareCrop?
        /// Collection chosen in the picker; nil = the Favorites root.
        let collection: String?
    }

    /// Export `rallies` of `source` and register them in the library.
    /// - Returns: how many rallies failed to export or register.
    func export(_ rallies: [Rally], from source: VideoMetadata) async -> Int {
        let fileManager = FileManager.default
        let baseDir = mediaStore.baseDirectory
        let favoritesRoot = LibraryType.favorites.rootPath
        try? fileManager.createDirectory(at: baseDir.appendingPathComponent(favoritesRoot, isDirectory: true),
                                         withIntermediateDirectories: true)

        // One pass over the manifest, up front. Prefix scan, not root-only:
        // clips the user moved into Favorites subfolders still count as copied.
        let alreadyCopiedByIndex = Dictionary(
            mediaStore.getAllVideos(in: .favorites)
                .filter { $0.sourceVideoId == source.id }
                .compactMap { video in video.sourceRallyIndex.map { ($0, video) } },
            uniquingKeysWith: { first, _ in first }
        )
        let manifestFolderPaths = Set(mediaStore.getAllFolders(in: .favorites).map(\.path))
        var resolvedFolderPaths: Set<String> = []

        // Resolve a collection choice to a manifest folder path, creating the
        // physical directory + manifest entry when missing (a collection the
        // user deleted since choosing it gets recreated by name).
        func folderPath(forCollection name: String?) -> String {
            guard let name else { return favoritesRoot }
            let path = "\(favoritesRoot)/\(name)"
            guard !resolvedFolderPaths.contains(path) else { return path }
            try? fileManager.createDirectory(at: baseDir.appendingPathComponent(path, isDirectory: true),
                                             withIntermediateDirectories: true)
            if !manifestFolderPaths.contains(path) {
                _ = mediaStore.createFolder(name: name, parentPath: favoritesRoot)
            }
            resolvedFolderPaths.insert(path)
            return path
        }

        let asset = AVURLAsset(url: source.originalURL)
        let exporter = VideoExporter()
        var failureCount = 0

        for rally in rallies {
            if let existing = alreadyCopiedByIndex[rally.index] {
                // Already copied: honor a later explicit collection choice by
                // re-filing the existing clip. Manual drags (no recorded
                // choice) are never disturbed.
                if rally.collection != nil {
                    let destPath = folderPath(forCollection: rally.collection)
                    if existing.folderPath != destPath {
                        _ = mediaStore.moveVideo(fileName: existing.fileName, toFolder: destPath)
                    }
                }
                continue
            }
            guard rally.endTime > rally.startTime else { continue }

            do {
                let timeRange = CMTimeRange(
                    start: CMTime(seconds: rally.startTime, preferredTimescale: 600),
                    end: CMTime(seconds: rally.endTime, preferredTimescale: 600)
                )

                // A framed rally is burned in, so the favorites clip looks like
                // the player did; unframed rallies keep the cheap passthrough.
                let exportedURL: URL
                if let crop = rally.crop {
                    exportedURL = try await exporter.exportStitchedClips(
                        [.init(url: source.originalURL, timeRange: timeRange, crop: crop)]
                    )
                } else {
                    let tempURL = fileManager.temporaryDirectory
                        .appendingPathComponent("fav_rally_\(rally.index)_\(UUID().uuidString).mp4")
                    exportedURL = try await exporter.exportClip(asset: asset, timeRange: timeRange, to: tempURL)
                }

                // Move to persistent storage (into the chosen collection)
                let destFolderPath = folderPath(forCollection: rally.collection)
                let destURL = baseDir.appendingPathComponent(destFolderPath, isDirectory: true)
                    .appendingPathComponent(UUID().uuidString + ".mp4")
                try fileManager.moveItem(at: exportedURL, to: destURL)

                // Register with a source backlink for sync. An unregistered
                // clip would sit on disk untracked — remove it.
                guard mediaStore.addVideo(
                    at: destURL,
                    toFolder: destFolderPath,
                    customName: String(localized: "\(source.displayName) - Rally \(rally.index + 1)",
                                       comment: "Name of a favorited rally clip; %1$@ is the source video name, %2$lld the rally number"),
                    sourceVideoId: source.id,
                    sourceRallyIndex: rally.index
                ) else {
                    try? fileManager.removeItem(at: destURL)
                    failureCount += 1
                    continue
                }
            } catch {
                failureCount += 1
                print("Failed to export favorite rally \(rally.index): \(error)")
            }
        }
        return failureCount
    }
}
