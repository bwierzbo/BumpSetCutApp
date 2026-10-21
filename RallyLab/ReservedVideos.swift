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
        return closure(of: named, over: sources(in: root))
    }

    /// A video's file identity as ProjectsModel computes it: the stored
    /// fingerprint, else derived from its origin (older videos stored none).
    static func effectiveFingerprint(_ s: ClipSource) -> String? {
        if let stored = s.fingerprint { return stored }
        let origin = s.origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !origin.isEmpty else { return nil }
        let path = (origin as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? ProjectsModel.fileFingerprint(atPath: path) : ProjectsModel.linkFingerprint(origin)
    }

    static func identities(_ s: ClipSource) -> Set<String> {
        var ids = Set<String>()
        if let f = effectiveFingerprint(s) { ids.insert("fp:" + f) }
        if let v = s.sourceId, !v.isEmpty { ids.insert("src:" + v) }
        if let v = s.sessionId, !v.isEmpty { ids.insert("ses:" + v) }
        if let v = s.venueId, !v.isEmpty { ids.insert("ven:" + v) }
        return ids
    }

    /// The named sessions plus everything reachable through shared
    /// identities, to a fixed point: A reserved, A and B share a file, B and
    /// C share a confirmed venue → A, B and C are all reserved.
    static func closure(of named: Set<String>, over sources: [String: ClipSource]) -> Set<String> {
        let ids = sources.mapValues(identities)
        var all = named
        var reservedIds = Set<String>()
        var grew = true
        while grew {
            grew = false
            for name in all { reservedIds.formUnion(ids[name] ?? []) }
            for (name, mine) in ids where !all.contains(name) && !mine.isDisjoint(with: reservedIds) {
                all.insert(name)
                grew = true
            }
        }
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
            if source.flatMap(effectiveFingerprint) == mine { return true }
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
