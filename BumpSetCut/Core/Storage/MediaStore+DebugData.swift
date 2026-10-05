//
//  MediaStore+DebugData.swift
//  BumpSetCut
//
//  Trajectory debug dumps attached to debug-mode exports. Stored in
//  `<library>/.debug_data/{videoId}_{sessionId}.json`, excluded from backups;
//  the manifest keeps only the file name.
//

import Foundation

extension MediaStore {

    var debugDataDirectory: URL {
        baseDirectory.appendingPathComponent(".debug_data", isDirectory: true)
    }

    /// Absolute location of a video's debug dump, if it has one.
    func debugDataURL(for video: VideoMetadata) -> URL? {
        video.debugDataPath.map { debugDataDirectory.appendingPathComponent($0) }
    }

    /// Write a debug dump for a video and record it in the manifest. Returns
    /// the dump's absolute path.
    @discardableResult
    func saveDebugData(for videoId: UUID, debugData: Data, sessionId: UUID) throws -> String {
        guard let (key, video) = manifest.videos.first(where: { $0.value.id == videoId }) else {
            throw NSError(domain: "DebugError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Video not found"])
        }

        let fileName = "\(videoId.uuidString)_\(sessionId.uuidString).json"
        try FileManager.default.createDirectory(at: debugDataDirectory, withIntermediateDirectories: true)
        StorageManager.excludeFromBackup(debugDataDirectory)
        let fileURL = debugDataDirectory.appendingPathComponent(fileName)
        try debugData.write(to: fileURL, options: .atomic)

        var updated = video
        updated.attachDebugData(sessionId: sessionId, fileName: fileName, size: Int64(debugData.count))
        manifest.videos[key] = updated
        saveManifest()

        return fileURL.path
    }

    func loadDebugData(for videoId: UUID) -> Data? {
        guard let video = manifest.videos.values.first(where: { $0.id == videoId }),
              let url = debugDataURL(for: video) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Delete a video by id; its debug dump goes with it (see `deleteVideo`).
    func deleteVideoWithDebugData(videoId: UUID) {
        guard let key = manifest.videos.first(where: { $0.value.id == videoId })?.key else { return }
        _ = deleteVideo(fileName: key)
    }

    /// Remove dumps whose video is no longer in the manifest.
    func sweepOrphanedDebugData(keeping validVideoIds: Set<UUID>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: debugDataDirectory.path) else { return }
        for name in names {
            guard let videoId = UUID(uuidString: String(name.prefix(36))),
                  !validVideoIds.contains(videoId) else { continue }
            try? FileManager.default.removeItem(at: debugDataDirectory.appendingPathComponent(name))
        }
    }
}
