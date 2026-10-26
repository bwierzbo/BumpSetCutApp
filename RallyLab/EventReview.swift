//
//  EventReview.swift
//  RallyLab
//
//  Stage 1 of the progressive rally review (D-024): the data foundation for the
//  `Rally Boundaries` workflow — a versioned `<video>.rallyevents.json` beside the
//  legacy `<video>.rallylabels.json`, which it never writes. Each rally is a record
//  with a persistent id, its first serve contact and first ball-dead moment as
//  `[earliest, latest]` intervals, its kind, flags and an edge marker; the recording
//  carries explicit *coverage* (the intervals a person has inspected — everything
//  else is unknown, never dead time or a negative example, D-010), spans of
//  non-rally ball activity, transition and uncertainty, and a completion mark that
//  is refused while any unknown gap wider than one video frame remains.
//
//  Opening a recording for review is the shared operation every caller goes
//  through (CLAUDE.md: guards live in the shared function): it refuses the whole L2
//  withheld closure — by name, by path and by file fingerprint — and writes the
//  exposure-ledger row before anything is returned; an unwritable ledger refuses the
//  open, as `BallPathBuilder.admission` does. Plan: docs/ml-roadmap/STAGE1_RALLY_BOUNDARIES_PLAN.md;
//  protocol: docs/ml-roadmap/EVENT_BOUNDARY_REVIEW_PROTOCOL.md (§4 rubric, §5 record).
//

import AVFoundation
import Foundation

enum EventReview {
    static let annotationVersion = "rally_event_truth_v1"
    /// An event interval wider than this (seconds of video time) is `ambiguous` (protocol §4).
    static let ambiguityThreshold = 0.2
    /// The ledger reference every open writes under.
    static let ledgerRef = "EventReview"

    // MARK: - Record

    enum Visibility: String, Codable { case clear, occluded }
    enum RallyKind: String, Codable { case rally, missedServe, other }
    enum ReviewState: String, Codable { case reviewed, withdrawn }
    enum Edge: String, Codable { case start, end }
    enum SpanKind: String, Codable { case nonRallyActivity, transition, uncertain }

    /// When an event happened: the last frame before and the first frame after it when the
    /// frame itself is not unambiguous, equal when it is.
    struct EventTime: Codable, Equatable {
        var earliest: Double
        var latest: Double
        var visibility: Visibility = .clear

        var isAmbiguous: Bool { latest - earliest > EventReview.ambiguityThreshold + 1e-9 }
    }

    /// An interval a person has inspected for rallies. Only `reviewed` exists: unknown is the
    /// absence of coverage, never a record.
    struct Coverage: Codable, Equatable {
        var start: Double
        var end: Double
        var state: String = "reviewed"
        var at: String
        var annotator: String
    }

    /// Ball activity that is not a rally, a transition, or a stretch the reviewer could not
    /// judge — a start and an end, no per-throw frames; always inside reviewed coverage.
    struct Span: Codable, Equatable {
        var id: UUID
        var kind: SpanKind
        var start: Double
        var end: Double
        var note: String?
    }

    struct SecondReview: Codable, Equatable {
        var annotator: String
        var reviewedAt: String
        /// `blind_repeat_same_reviewer_24h` or `second_reviewer` (protocol §6).
        var method: String
        var contact: EventTime?
        var dead: EventTime?
    }

    struct Rally: Codable, Equatable {
        /// Minted when the rally is first saved; never changes; a withdrawn rally keeps it.
        var rallyId: UUID
        var legacyIndex: Int?
        var legacyStart: Double?
        var legacyEnd: Double?
        var kind: RallyKind
        /// nil = unresolved (the event is not identifiable; needs `edge` for a `rally` or `missedServe`).
        var contact: EventTime?
        var dead: EventTime?
        var flags: [String] = []
        var edge: Edge?
        var sourceMethod: String = "manual_event"
        var reviewState: ReviewState = .reviewed
        var annotator: String
        var reviewedAt: String
        var secondReview: SecondReview?
    }

    struct Completion: Codable, Equatable {
        var at: String
        var annotator: String
        var tool: String
    }

    struct File: Codable, Equatable {
        var annotationVersion: String = EventReview.annotationVersion
        var video: String
        var sourceFingerprint: String?
        var frameRate: Double
        var durationSec: Double
        var tool: String
        var coverage: [Coverage] = []
        var spans: [Span] = []
        var rallies: [Rally] = []
        var stage1Complete: Completion?

        /// One video frame, the tolerance of every coverage comparison.
        var frameDuration: Double { 1 / frameRate }
    }

    // MARK: - Errors

    enum Failure: LocalizedError, Equatable {
        case unsupportedVersion(String)
        case unreadable(String)
        case invalid(String)
        case withheld(name: String, reason: String)
        case videoMissing(String)
        case videoUnreadable(String)
        case wrongVideo(expected: String, found: String)
        case sourceChanged(recorded: String, current: String)
        case ledgerNotWritten(String)
        case incomplete([String])

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "rallyevents.json is annotationVersion \(v); this build reads \(EventReview.annotationVersion) only."
            case .unreadable(let why): return "rallyevents.json can't be read: \(why)"
            case .invalid(let why): return "rallyevents.json is not valid: \(why)"
            case .withheld(let name, let reason): return "\(name) is withheld from review (\(reason)): the L2 withheld closure is refused by name, path and content."
            case .videoMissing(let path): return "The original video is not here (\(path)); review needs it, not a proxy."
            case .videoUnreadable(let why): return "The video's frame rate or duration can't be read: \(why)"
            case .wrongVideo(let expected, let found): return "rallyevents.json belongs to \(found), not \(expected)."
            case .sourceChanged(let recorded, let current): return "The video's content changed since its events were recorded (\(recorded.prefix(21))… → \(current.prefix(21))…)."
            case .ledgerNotWritten(let why): return "The exposure ledger could not record this review, so it does not open: \(why)"
            case .incomplete(let gaps): return "The recording is not fully reviewed: " + gaps.joined(separator: "; ")
            }
        }
    }

    // MARK: - File location, reading, writing

    static func url(forVideo video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("rallyevents.json")
    }

    static func read(_ url: URL) throws -> File {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.unreadable(error.localizedDescription) }
        // The version first, so a file from another build is refused whole, never half-read.
        guard let head = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable("not a JSON object") }
        let version = head["annotationVersion"] as? String ?? "(none)"
        guard version == annotationVersion else { throw Failure.unsupportedVersion(version) }
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch { throw Failure.unreadable(error.localizedDescription) }
        try validate(file)
        return file
    }

    /// Validates, then writes the whole file atomically (a temporary file renamed into place):
    /// a reader sees the previous file or the new one, never a partial write.
    static func write(_ file: File, to url: URL) throws {
        try validate(file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }

    // MARK: - Rules

    static func validate(_ file: File) throws {
        guard file.annotationVersion == annotationVersion else { throw Failure.unsupportedVersion(file.annotationVersion) }
        guard file.frameRate > 0, file.frameRate.isFinite else { throw Failure.invalid("frameRate must be positive") }
        guard file.durationSec > 0, file.durationSec.isFinite else { throw Failure.invalid("durationSec must be positive") }
        let tol = file.frameDuration
        for c in file.coverage {
            guard c.state == "reviewed" else { throw Failure.invalid("coverage state \(c.state): only reviewed intervals are recorded") }
            guard c.start >= -tol, c.end > c.start, c.end <= file.durationSec + tol else { throw Failure.invalid("coverage \(c.start)–\(c.end) is outside the video or empty") }
        }
        let reviewed = union(file.coverage)
        var spanIds = Set<UUID>()
        for s in file.spans {
            guard spanIds.insert(s.id).inserted else { throw Failure.invalid("span id \(s.id) appears twice") }
            guard s.end > s.start else { throw Failure.invalid("span \(s.kind.rawValue) \(s.start)–\(s.end) is empty") }
            guard covered(s.start, s.end, by: reviewed, tolerance: tol) else { throw Failure.invalid("span \(s.kind.rawValue) \(s.start)–\(s.end) lies outside reviewed coverage") }
        }
        var ids = Set<UUID>()
        for r in file.rallies {
            guard ids.insert(r.rallyId).inserted else { throw Failure.invalid("rallyId \(r.rallyId) appears twice") }
            for (label, e) in [("contact", r.contact), ("dead", r.dead)] {
                guard let e else { continue }
                guard e.earliest <= e.latest else { throw Failure.invalid("\(label) of \(r.rallyId): earliest after latest") }
                guard e.earliest >= -tol, e.latest <= file.durationSec + tol else { throw Failure.invalid("\(label) of \(r.rallyId) is outside the video") }
            }
            if let c = r.contact, let d = r.dead, d.latest < c.earliest { throw Failure.invalid("rally \(r.rallyId) ends before it starts") }
        }
        if file.stage1Complete != nil {
            let problems = completionProblems(in: file)
            guard problems.isEmpty else { throw Failure.invalid("stage1Complete is set but " + problems.joined(separator: "; ")) }
        }
    }

    /// The reviewed intervals merged, in order.
    static func union(_ coverage: [Coverage]) -> [(start: Double, end: Double)] {
        var out: [(start: Double, end: Double)] = []
        for c in coverage.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, c.start <= last.end { out[out.count - 1].end = max(last.end, c.end) }
            else { out.append((c.start, c.end)) }
        }
        return out
    }

    static func covered(_ start: Double, _ end: Double, by reviewed: [(start: Double, end: Double)], tolerance: Double) -> Bool {
        reviewed.contains { $0.start - tolerance <= start && end <= $0.end + tolerance }
    }

    /// The unknown stretches of the video wider than one frame: what stands between the
    /// recording and `stage1Complete`. Empty when the coverage reaches from the first frame to the last.
    static func gaps(in file: File) -> [(start: Double, end: Double)] {
        let tol = file.frameDuration + 1e-9
        var out: [(start: Double, end: Double)] = []
        var cursor = 0.0
        for r in union(file.coverage) {
            if r.start - cursor > tol { out.append((cursor, r.start)) }
            cursor = max(cursor, r.end)
        }
        if file.durationSec - cursor > tol { out.append((cursor, file.durationSec)) }
        return out
    }

    /// Where to resume: the start of the first unknown stretch, nil when there is none.
    static func firstUnknown(in file: File) -> Double? { gaps(in: file).first?.start }

    /// Why the recording cannot be marked complete, in words; empty when it can.
    static func completionProblems(in file: File) -> [String] {
        var problems = gaps(in: file).map { String(format: "unknown %.3f–%.3f s", $0.start, $0.end) }
        for r in file.rallies where r.reviewState == .reviewed && r.kind != .other {
            if r.contact == nil, r.edge != .start { problems.append("rally \(r.rallyId.uuidString.prefix(8)) has no serve contact and no start edge") }
            if r.dead == nil, r.edge != .end { problems.append("rally \(r.rallyId.uuidString.prefix(8)) has no ball-dead event and no end edge") }
        }
        return problems
    }

    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: - Mutations (the only ways the record changes)

    enum Mutation {
        /// Adds a rally, or replaces the one with the same id; a new rally gets its id here and keeps
        /// it for good. Returns the id. Sets `ambiguous_contact` / `ambiguous_dead` from the rubric.
        @discardableResult
        static func upsert(_ rally: Rally, in file: inout File) -> UUID {
            var r = rally
            r.flags.removeAll { $0 == "ambiguous_contact" || $0 == "ambiguous_dead" }
            if r.contact?.isAmbiguous == true { r.flags.append("ambiguous_contact") }
            if r.dead?.isAmbiguous == true { r.flags.append("ambiguous_dead") }
            if let i = file.rallies.firstIndex(where: { $0.rallyId == r.rallyId }) { file.rallies[i] = r } else { file.rallies.append(r) }
            return r.rallyId
        }

        /// A rally the reviewer removes stays, as withdrawn: its id is never reused or lost.
        static func withdraw(_ id: UUID, in file: inout File, at: Date, annotator: String) -> Bool {
            guard let i = file.rallies.firstIndex(where: { $0.rallyId == id }) else { return false }
            file.rallies[i].reviewState = .withdrawn
            file.rallies[i].reviewedAt = stamp(at)
            file.rallies[i].annotator = annotator
            return true
        }

        /// "Reviewed through here": one more coverage record, with this reviewer and time. Records are
        /// history and are never merged or rewritten; `union` gives the reviewed intervals for any calculation.
        static func markReviewed(from start: Double, to end: Double, in file: inout File, at: Date, annotator: String) {
            let s = max(0, start), e = min(file.durationSec, end)
            guard e > s else { return }
            file.coverage.append(Coverage(start: s, end: e, at: stamp(at), annotator: annotator))
        }

        /// Marks the recording fully reviewed, or says why it cannot be (nothing changes then).
        static func complete(_ file: inout File, at: Date, annotator: String, tool: String) throws {
            let problems = completionProblems(in: file)
            guard problems.isEmpty else { throw Failure.incomplete(problems) }
            file.stage1Complete = Completion(at: stamp(at), annotator: annotator, tool: tool)
        }
    }

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

    /// Why `session` is withheld, or nil when it may be reviewed. By name (the closure); by path (its
    /// file is a withheld recording's session file, cut file or local origin); and by content (its
    /// fingerprint is a withheld recording's — the recording's stored or derived fingerprint, its
    /// session file's, or its cut file's). Every withheld recording the project knows counts, whether
    /// or not it has a session: a YouTube source's effective fingerprint is its link, so its cut file
    /// is compared by content as well.
    static func refusal(of session: VideoSession, root: URL, sessions: [VideoSession]) throws -> String? {
        let withheld = try withheldNames(in: root)
        guard !withheld.isEmpty else { return nil }
        if withheld.contains(session.name) { return "listed, or aliased to a listed recording" }
        let fm = FileManager.default
        func standard(_ path: String) -> String { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path }
        let path = standard(session.sourcePath)
        let sources = ReservedVideos.sources(in: root)
        // Files that belong to withheld recordings, and whose they are.
        var files: [(path: String, owner: String, what: String)] = []
        for w in sessions where withheld.contains(w.name) && w.name != session.name { files.append((standard(w.sourcePath), w.name, "file")) }
        for (name, s) in sources where withheld.contains(name) && name != session.name {
            if !s.clipFile.isEmpty { files.append((standard(s.clipFile), name, "cut file")) }
            let origin = s.origin.trimmingCharacters(in: .whitespacesAndNewlines)
            if !origin.isEmpty, origin.hasPrefix("/") || origin.hasPrefix("~") { files.append((standard(origin), name, "original file")) }
        }
        if let hit = files.first(where: { $0.path == path }) { return "its video is \(hit.owner)'s \(hit.what)" }
        guard fm.fileExists(atPath: session.sourcePath), let mine = ProjectsModel.fileFingerprint(atPath: session.sourcePath) else { return nil }
        for (name, s) in sources where withheld.contains(name) && name != session.name {
            if ReservedVideos.effectiveFingerprint(s) == mine { return "its content is \(name)'s" }
        }
        for f in files where fm.fileExists(atPath: f.path) {
            if ProjectsModel.fileFingerprint(atPath: f.path) == mine { return "its content is \(f.owner)'s" }
        }
        return nil
    }

    /// Opens a recording for Stage 1 review: refuses the withheld closure, requires the original
    /// video, records the use in the exposure ledger (an unwritable ledger refuses the open), then
    /// loads its record or starts a fresh one. GUI and headless callers both come through here.
    static func open(_ session: VideoSession, root: URL, tool: String, now: Date = Date()) async throws -> Session {
        let all = DatasetStore(root: root).loadSessions()
        if let why = try refusal(of: session, root: root, sessions: all) { throw Failure.withheld(name: session.name, reason: why) }
        guard session.isOnMac else { throw Failure.videoMissing(session.sourcePath) }
        let (frameRate, duration) = try await videoFacts(session.sourceURL)
        do {
            try ExposureLog.record(videos: [session.name], kind: .eventReview, ref: ledgerRef, note: "Stage 1 rally boundaries review", in: root, now: now)
        } catch { throw Failure.ledgerNotWritten(error.localizedDescription) }
        let url = url(forVideo: session.sourceURL)
        let fingerprint = ProjectsModel.fileFingerprint(atPath: session.sourcePath)
        if FileManager.default.fileExists(atPath: url.path) {
            let file = try read(url)
            guard file.video == session.name else { throw Failure.wrongVideo(expected: session.name, found: file.video) }
            if let recorded = file.sourceFingerprint, let current = fingerprint, recorded != current { throw Failure.sourceChanged(recorded: recorded, current: current) }
            return Session(session: session, fileURL: url, file: file, isNew: false)
        }
        let fresh = File(video: session.name, sourceFingerprint: fingerprint, frameRate: frameRate, durationSec: duration, tool: tool)
        return Session(session: session, fileURL: url, file: fresh, isNew: true)
    }

    /// The video track's nominal frame rate and the asset's duration, from the original file.
    static func videoFacts(_ url: URL) async throws -> (frameRate: Double, duration: Double) {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.videoUnreadable("no video track") }
            let rate = Double(try await track.load(.nominalFrameRate))
            guard rate > 0, duration > 0 else { throw Failure.videoUnreadable("frame rate \(rate), duration \(duration)") }
            return (rate, duration)
        } catch let failure as Failure { throw failure } catch { throw Failure.videoUnreadable(error.localizedDescription) }
    }
}
