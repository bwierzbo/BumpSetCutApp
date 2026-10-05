//
//  MediaStore+DebugSeeding.swift
//  BumpSetCut
//
//  DEBUG-only library seeding for UI tests (--uitesting) and local dev
//  (--prefill-library). Compiled out of release builds.
//

#if DEBUG
import Foundation
import os

private let logger = Logger(subsystem: "BumpSetCut", category: "MediaStore")

extension MediaStore {
    /// When running with --prefill-library, symlink all videos from PREFILL_VIDEOS_DIR into the library.
    func prefillLibraryIfNeeded() {
        guard CommandLine.arguments.contains("--prefill-library"),
              let dirPath = ProcessInfo.processInfo.environment["PREFILL_VIDEOS_DIR"],
              FileManager.default.fileExists(atPath: dirPath) else { return }

        let sourceDir = URL(fileURLWithPath: dirPath)
        let savedDir = baseDirectory.appendingPathComponent(LibraryType.saved.rootPath)
        try? FileManager.default.createDirectory(at: savedDir, withIntermediateDirectories: true)

        let validExtensions: Set<String> = ["mov", "mp4", "m4v"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sourceDir, includingPropertiesForKeys: nil) else { return }

        for fileURL in contents where validExtensions.contains(fileURL.pathExtension.lowercased()) {
            let destURL = savedDir.appendingPathComponent(fileURL.lastPathComponent)

            // Symlink (not copy) to avoid wasting disk space
            if !FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.createSymbolicLink(at: destURL, withDestinationURL: fileURL)
            }

            // Add to manifest if not already there
            let videoKey = fileURL.lastPathComponent
            if manifest.videos[videoKey] == nil {
                let name = fileURL.deletingPathExtension().lastPathComponent
                _ = addVideo(at: destURL, toFolder: LibraryType.saved.rootPath, customName: name)
            }
        }
    }

    /// When running UI tests, symlink the test video into storage and add it to the manifest.
    func injectTestVideoIfNeeded() {
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
            logger.warning("MediaStore: ⚠️ Could not read metadata template at \(metadataTemplatePath)")
            return
        }

        // Parse, replace videoId, re-encode
        guard var json = try? JSONSerialization.jsonObject(with: templateData) as? [String: Any] else {
            logger.warning("MediaStore: ⚠️ Could not parse metadata template JSON")
            return
        }

        json["videoId"] = videoId.uuidString

        guard let correctedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            logger.warning("MediaStore: ⚠️ Could not re-encode metadata JSON")
            return
        }

        // Write to ProcessedMetadata/{videoId}.json
        let metadataDir = baseDirectory.appendingPathComponent("ProcessedMetadata", isDirectory: true)
        try? fileManager.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        let destURL = metadataDir.appendingPathComponent("\(videoId.uuidString).json")

        do {
            try correctedData.write(to: destURL, options: .atomic)
            logger.info("MediaStore: ✅ Injected pre-processed metadata for video \(videoId)")

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
            logger.error("MediaStore: ❌ Failed to write metadata: \(String(describing: error))")
        }
    }
}
#endif
