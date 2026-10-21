//
//  ReservedVideos.swift
//  RallyLab
//
//  Which project video an arbitrary file on disk is — by path, by name, or
//  by content — so a copy or rename of a reserved final-test recording
//  (D-002) is still recognised and refused, and so a run on any project
//  video is logged under its session name.
//

import Foundation

enum ReservedVideos {
    struct Match: Equatable {
        let session: String
        let reserved: Bool
    }

    /// The project video `url` is, or nil for a file that is not one of the
    /// project's videos. Throws when the reservations can't be read.
    static func match(_ url: URL, root: URL) throws -> Match? {
        let reserved = try PipelineTuner.ValidationSet.finalTestNames(in: root)
        let sessions = DatasetStore(root: root).loadSessions()
        let project = (try? Data(contentsOf: root.appendingPathComponent("project.json"))).flatMap { data -> Project? in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Project.self, from: data)
        }
        var sources: [String: ClipSource] = [:]
        for clip in project?.clips ?? [] {
            for video in clip.videos { sources[DatasetStore.safeName(clip.videoId(of: video))] = video }
        }
        let path = url.standardizedFileURL.path
        let base = url.lastPathComponent
        lazy var print: String? = ProjectsModel.fileFingerprint(atPath: path)

        func isThis(_ session: VideoSession) -> Bool {
            if URL(fileURLWithPath: session.sourcePath).standardizedFileURL.path == path { return true }
            let source = sources[session.name]
            if (source?.clipFile).map({ URL(fileURLWithPath: $0).lastPathComponent == base }) == true || base.hasPrefix(session.name + ".") { return true }
            guard let mine = print else { return false }
            if source?.fingerprint == mine { return true }
            // A YouTube-origin video stores the link's ID; compare against its cut file's content when that file is here.
            if let cut = source?.clipFile, FileManager.default.fileExists(atPath: cut), ProjectsModel.fileFingerprint(atPath: cut) == mine { return true }
            if FileManager.default.fileExists(atPath: session.sourcePath), ProjectsModel.fileFingerprint(atPath: session.sourcePath) == mine { return true }
            return false
        }
        // Reserved sessions are checked first so a copy of one is refused even if another session also matches.
        if let hit = sessions.first(where: { reserved.contains($0.name) && isThis($0) }) { return Match(session: hit.name, reserved: true) }
        if let hit = sessions.first(where: isThis) { return Match(session: hit.name, reserved: false) }
        return nil
    }
}
