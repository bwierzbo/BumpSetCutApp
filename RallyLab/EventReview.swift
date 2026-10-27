//
//  EventReview.swift
//  RallyLab
//
//  The Mac side of the Stage 1 rally-boundary review (D-024): opening a recording is
//  the shared operation every Mac caller goes through (CLAUDE.md: guards live in the
//  shared function) — it refuses the whole L2 withheld closure by name, by path and by
//  file fingerprint, requires the original footage, and writes the exposure-ledger row
//  before anything is returned; an unwritable ledger refuses the open, as
//  `BallPathBuilder.admission` does. The record, its rules and its mutations are the
//  cross-platform `EventReview` in Labeler/Shared/EventReviewRecord.swift.
//

import AVFoundation
import Foundation

extension EventReview {
    // MARK: - Opening a recording (the shared guard)

    struct Session {
        let session: VideoSession
        let fileURL: URL
        /// The record as it is, or a fresh one (no file written until the first save).
        var file: File
        let isNew: Bool
    }

    /// The names the L2 withheld closure covers (lineage holdout, legacy holdout, final test,
    /// candidates, with aliases), fail closed: an unreadable validation.json throws.
    static func withheldNames(in root: URL) throws -> Set<String> {
        try ReservedVideos.lineageWithheldNames(in: root)
    }

    /// What the sync publishes as withheld, so the server refuses exactly what `open` refuses: the named closure
    /// plus every session `refusal` refuses by path or content (a session over a withheld recording's file, or a
    /// byte-identical copy). Identities and sessions are read strictly; anything unreadable throws, and the caller
    /// publishes nothing then (fail closed).
    static func publishedWithheldNames(in root: URL) throws -> Set<String> {
        _ = try projectSourcesStrict(in: root)
        let sessions = try DatasetStore(root: root).loadSessionsStrict()
        // The protected identities (every withheld recording's files fingerprinted) are computed once for the scan.
        guard let context = try withheldContext(root: root, sessions: sessions) else { return [] }
        var names = context.withheld
        for s in sessions where !names.contains(s.name) {
            if refusal(of: s, context: context) != nil { names.insert(s.name) }
        }
        return names
    }

    /// What every refusal is judged against: the named closure, the project's sources, the files that belong to
    /// withheld recordings, and the withheld recordings' content fingerprints. Built once and reused across a scan.
    struct WithheldContext {
        let withheld: Set<String>
        let sources: [String: ClipSource]
        let files: [(path: String, owner: String, what: String)]
        let protected: Set<String>
    }

    /// nil when nothing is withheld. Throws when the identities cannot be read or a withheld recording's content
    /// fingerprint cannot be established (withheldIdentityUnknown): then nothing opens.
    static func withheldContext(root: URL, sessions: [VideoSession]) throws -> WithheldContext? {
        let withheld = try withheldNames(in: root)
        guard !withheld.isEmpty else { return nil }
        let sources = try projectSourcesStrict(in: root)
        func standard(_ path: String) -> String { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path }
        var files: [(path: String, owner: String, what: String)] = []
        for w in sessions where withheld.contains(w.name) { files.append((standard(w.sourcePath), w.name, "file")) }
        for (name, s) in sources where withheld.contains(name) {
            if !s.clipFile.isEmpty { files.append((standard(s.clipFile), name, "cut file")) }
            let origin = s.origin.trimmingCharacters(in: .whitespacesAndNewlines)
            if !origin.isEmpty, origin.hasPrefix("/") || origin.hasPrefix("~") { files.append((standard(origin), name, "original file")) }
        }
        // Every withheld recording must have a content fingerprint on hand (stored, derived from its file, its
        // session file or its cut file) — the same rule the lineage package applies — or a byte copy of a missing
        // original could not be told apart: then nothing opens.
        let protected: Set<String>
        do { protected = try LineagePackage.protectedSourceFingerprints(sessions: sessions, withheld: withheld, sources: sources) }
        catch { throw Failure.withheldIdentityUnknown(error.localizedDescription) }
        return WithheldContext(withheld: withheld, sources: sources, files: files, protected: protected)
    }

    /// The project's videos by session name, strictly: a project.json that exists but can't be decoded
    /// throws, since the withheld recordings' cut files and fingerprints would otherwise vanish from
    /// the guard. No project.json (a project from before the Projects tab) is an empty map.
    static func projectSourcesStrict(in root: URL) throws -> [String: ClipSource] {
        let url = root.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { _ = try decoder.decode(Project.self, from: Data(contentsOf: url)) } catch { throw Failure.projectUnreadable(error.localizedDescription) }
        return ReservedVideos.sources(in: root)
    }

    /// Why `session` is withheld, or nil when it may be reviewed. By name (the closure); by path (its
    /// file is a withheld recording's session file, cut file or local origin); and by content (its
    /// fingerprint is a withheld recording's — the recording's stored or derived fingerprint, its
    /// session file's, or its cut file's). Every withheld recording the project knows counts, whether
    /// or not it has a session: a YouTube source's effective fingerprint is its link, so its cut file
    /// is compared by content as well.
    static func refusal(of session: VideoSession, root: URL, sessions: [VideoSession]) throws -> String? {
        guard let context = try withheldContext(root: root, sessions: sessions) else { return nil }
        return refusal(of: session, context: context)
    }

    /// The same judgement against a context built once (a listed session is refused by name before its own
    /// files, which the context also holds, could match it).
    static func refusal(of session: VideoSession, context: WithheldContext) -> String? {
        let withheld = context.withheld, sources = context.sources, protected = context.protected
        if withheld.contains(session.name) { return "listed, or aliased to a listed recording" }
        let fm = FileManager.default
        let path = URL(fileURLWithPath: (session.sourcePath as NSString).expandingTildeInPath).standardizedFileURL.path
        let files = context.files.filter { $0.owner != session.name }
        if let hit = files.first(where: { $0.path == path }) { return "its video is \(hit.owner)'s \(hit.what)" }
        guard fm.fileExists(atPath: session.sourcePath), let mine = ProjectsModel.fileFingerprint(atPath: session.sourcePath) else { return nil }
        guard protected.contains(mine) else { return nil }
        for (name, s) in sources where withheld.contains(name) && name != session.name {
            if ReservedVideos.effectiveFingerprint(s) == mine { return "its content is \(name)'s" }
        }
        for f in files where fm.fileExists(atPath: f.path) {
            if ProjectsModel.fileFingerprint(atPath: f.path) == mine { return "its content is \(f.owner)'s" }
        }
        return "its content is a withheld recording's"
    }

    /// Opens a recording for Stage 1 review: refuses the withheld closure (every session read strictly,
    /// since an unreadable one may be a withheld recording's), requires the original video, records the use in the exposure ledger (an unwritable ledger refuses the open), then
    /// loads its record or starts a fresh one. GUI and headless callers both come through here.
    static func open(_ session: VideoSession, root: URL, tool: String, now: Date = Date()) async throws -> Session {
        // Every session, or nothing: a session file that can't be read may be a withheld recording's,
        // and its file identity would otherwise drop out of the guard (fail closed, as the audit does).
        let all: [VideoSession]
        do { all = try DatasetStore(root: root).loadSessionsStrict() } catch { throw Failure.sessionsUnreadable(error.localizedDescription) }
        if let why = try refusal(of: session, root: root, sessions: all) { throw Failure.withheld(name: session.name, reason: why) }
        guard session.isOnMac else { throw Failure.videoMissing(session.sourcePath) }
        let (frameRate, duration) = try await FrameIdentity.videoFacts(session.sourceURL)
        do {
            try ExposureLog.record(videos: [session.name], kind: .eventReview, ref: ledgerRef, note: "Stage 1 rally boundaries review", in: root, now: now)
        } catch { throw Failure.ledgerNotWritten(error.localizedDescription) }
        let url = url(forVideo: session.sourceURL)
        let fingerprint = ProjectsModel.fileFingerprint(atPath: session.sourcePath)
        if FileManager.default.fileExists(atPath: url.path) {
            let file = try read(url)
            if let problem = identityProblem(of: file, for: session) { throw problem }
            return Session(session: session, fileURL: url, file: file, isNew: false)
        }
        let fresh = File(video: session.name, sourceFingerprint: fingerprint, frameRate: frameRate, durationSec: duration, tool: tool)
        return Session(session: session, fileURL: url, file: fresh, isNew: true)
    }

    /// Why `file` is not `session`'s record: it names another video, or the video's content is no longer
    /// what it recorded. nil when the record belongs to the session as it is now.
    static func identityProblem(of file: File, for session: VideoSession) -> Failure? {
        guard file.video == session.name else { return .wrongVideo(expected: session.name, found: file.video) }
        if let recorded = file.sourceFingerprint, FileManager.default.fileExists(atPath: session.sourcePath),
           let current = ProjectsModel.fileFingerprint(atPath: session.sourcePath), recorded != current {
            return .sourceChanged(recorded: recorded, current: current)
        }
        return nil
    }
}
