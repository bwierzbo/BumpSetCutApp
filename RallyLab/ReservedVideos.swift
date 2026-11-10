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
        /// The project video's name: its session's, or its card's when no session is over the card.
        let session: String
        let reserved: Bool
    }

    /// project.json is there but can't be read or decoded: the recordings' identities are unknown.
    struct ProjectUnreadable: LocalizedError {
        let file: URL
        let why: String
        var errorDescription: String? {
            "\(file.path) exists but can't be read, so the recordings' identities are unknown — which recordings are a reserved "
                + "one under another name can't be told, and nothing is cleared as unreserved. Fix the file first: \(why)"
        }
    }

    /// The project's videos by session name, from project.json. Empty when there is none (a dataset from
    /// before the Projects tab). A project.json that exists but can't be read or decoded throws: an empty
    /// map there would shrink every alias closure to the listed names, and a reserved recording's copy
    /// under another session name would pass as unreserved (D-002; fails closed).
    static func sources(in root: URL) throws -> [String: ClipSource] {
        let file = root.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let project: Project
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            project = try decoder.decode(Project.self, from: Data(contentsOf: file))
        } catch { throw ProjectUnreadable(file: file, why: error.localizedDescription) }
        var sources: [String: ClipSource] = [:]
        for clip in project.clips {
            for video in clip.videos { sources[DatasetStore.safeName(clip.videoId(of: video))] = video }
        }
        return sources
    }

    /// Every session that must be treated as reserved: the names in
    /// validation.json `finalTest` plus every alias — a session whose video
    /// shares a file fingerprint or a confirmed sourceId / sessionId /
    /// venueId with a reserved one. A reservation names a recording, not a
    /// filename. Throws when validation.json exists but can't be read, or
    /// project.json does (the aliases are then unknown).
    static func reservedNames(in root: URL) throws -> Set<String> {
        let named = try PipelineTuner.ValidationSet.loadStrict(from: root)?.reservedAsListed ?? []
        guard !named.isEmpty else { return [] }
        return closure(of: named, over: try sources(in: root))
    }

    /// Everything a lineage package must leave out (D-018): the reserved names
    /// plus validation.json `holdout` (the legacy holdout, which the manifest
    /// assigns by name only), all expanded through the project's identities —
    /// sessionless project videos included, since one can bridge a holdout
    /// recording to a session under another name. Throws like `reservedNames`.
    static func lineageWithheldNames(in root: URL) throws -> Set<String> {
        guard let set = try PipelineTuner.ValidationSet.loadStrict(from: root) else { return [] }
        let named = set.reservedAsListed.union(set.holdout)
        guard !named.isEmpty else { return [] }
        return closure(of: named, over: try sources(in: root))
    }

    /// The listed final test, lineage holdout and provisional candidates, each
    /// expanded to its aliases, kept apart in that precedence: a video that
    /// aliases a final-test video is final test; one that aliases a lineage
    /// holdout video is lineage holdout. For the manifest's split assignment.
    static func expanded(_ set: PipelineTuner.ValidationSet, sources: [String: ClipSource]) -> (finalTest: Set<String>, lineageHoldout: Set<String>, candidates: Set<String>) {
        let finalTest = closure(of: Set(set.finalTest), over: sources)
        let lineage = closure(of: Set(set.lineageHoldout), over: sources).subtracting(finalTest)
        let candidates = closure(of: Set(set.finalTestCandidates), over: sources).subtracting(finalTest).subtracting(lineage)
        return (finalTest, lineage, candidates)
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

    /// Every video's alias group over the whole project (sessionless videos
    /// included, since they can bridge two sessions): name → group ID, the
    /// smallest name in the group. Same identities as `closure`.
    static func groups(over sources: [String: ClipSource]) -> [String: String] {
        let ids = sources.mapValues(identities)
        var byIdentity: [String: [String]] = [:]
        for (name, mine) in ids { for id in mine { byIdentity[id, default: []].append(name) } }
        var parent = Dictionary(uniqueKeysWithValues: sources.keys.map { ($0, $0) })
        func find(_ x: String) -> String { var r = x; while parent[r] != r { r = parent[r]! }; return r }
        for names in byIdentity.values { for n in names.dropFirst() { parent[find(n)] = find(names[0]) } }
        var members: [String: [String]] = [:]
        for name in sources.keys { members[find(name), default: []].append(name) }
        var out: [String: String] = [:]
        for names in members.values { let id = names.min()!; for n in names { out[n] = id } }
        return out
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
    /// project's videos. A card with no session over it (missing or renamed)
    /// is still the project's recording — the reservations name cards — and
    /// is matched by its cut file's path or name, or by content. Throws when the reservations or project.json can't be read — or a
    /// session can't: a session that won't decode is unknown, not absent, and
    /// a video it may be over is neither cleared as unreserved nor read as
    /// having no cut ranges (D-002, D-030; fails closed).
    static func match(_ url: URL, root: URL) throws -> Match? {
        let reserved = try reservedNames(in: root)
        let sessions = try DatasetStore(root: root).loadSessionsStrict()
        let sources = try sources(in: root)
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
        let withSession = Set(sessions.map(\.name))
        let cards = sources.filter { !withSession.contains($0.key) }.sorted { $0.key < $1.key }
        func isThis(card name: String, _ source: ClipSource) -> Bool {
            let cut = URL(fileURLWithPath: source.clipFile)
            if cut.standardizedFileURL.path == path || cut.lastPathComponent == base || base.hasPrefix(name + ".") { return true }
            guard let mine = print else { return false }
            if effectiveFingerprint(source) == mine { return true }
            return FileManager.default.fileExists(atPath: cut.path) && ProjectsModel.fileFingerprint(atPath: cut.path) == mine
        }
        // Reserved videos are checked first — sessions, then cards with none — so a copy of one is refused
        // even if an unreserved video also matches.
        if let hit = sessions.first(where: { reserved.contains($0.name) && isThis($0) }) { return Match(session: hit.name, reserved: true) }
        if let hit = cards.first(where: { reserved.contains($0.key) && isThis(card: $0.key, $0.value) }) { return Match(session: hit.key, reserved: true) }
        if let hit = sessions.first(where: isThis) { return Match(session: hit.name, reserved: false) }
        if let hit = cards.first(where: { isThis(card: $0.key, $0.value) }) { return Match(session: hit.key, reserved: false) }
        return nil
    }
}
