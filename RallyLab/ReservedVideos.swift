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

    /// The project's videos by session name, from project.json (empty when there is none).
    static func sources(in root: URL) -> [String: ClipSource] {
        let project = (try? Data(contentsOf: root.appendingPathComponent("project.json"))).flatMap { data -> Project? in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Project.self, from: data)
        }
        var sources: [String: ClipSource] = [:]
        for clip in project?.clips ?? [] {
            for video in clip.videos { sources[DatasetStore.safeName(clip.videoId(of: video))] = video }
        }
        return sources
    }

    /// Every session that must be treated as reserved: the names in
    /// validation.json `finalTest` plus every alias — a session whose video
    /// shares a file fingerprint or a confirmed sourceId / sessionId /
    /// venueId with a reserved one. A reservation names a recording, not a
    /// filename. Throws when validation.json exists but can't be read.
    static func reservedNames(in root: URL) throws -> Set<String> {
        let named = Set(try PipelineTuner.ValidationSet.loadStrict(from: root)?.finalTest ?? [])
        guard !named.isEmpty else { return [] }
        let sources = sources(in: root)
        func identities(_ s: ClipSource) -> Set<String> {
            var ids = Set<String>()
            if let f = s.fingerprint { ids.insert("fp:" + f) }
            if let v = s.sourceId, !v.isEmpty { ids.insert("src:" + v) }
            if let v = s.sessionId, !v.isEmpty { ids.insert("ses:" + v) }
            if let v = s.venueId, !v.isEmpty { ids.insert("ven:" + v) }
            return ids
        }
        var reservedIds = Set<String>()
        for name in named { if let s = sources[name] { reservedIds.formUnion(identities(s)) } }
        var all = named
        for (name, source) in sources where !identities(source).isDisjoint(with: reservedIds) { all.insert(name) }
        return all
    }

    /// The project video `url` is, or nil for a file that is not one of the
    /// project's videos. Throws when the reservations can't be read.
    static func match(_ url: URL, root: URL) throws -> Match? {
        let reserved = try reservedNames(in: root)
        let sessions = DatasetStore(root: root).loadSessions()
        let sources = sources(in: root)
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
