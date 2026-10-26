//
//  EventReviewRecord.swift
//  Labeler/Shared — compiled by RallyLab (macOS) and the Labeler iPhone app
//
//  The Stage 1 rally-boundary record (D-024): `<video>.rallyevents.json`, its rules and
//  the only ways it changes. One schema and one set of rules for both platforms; what
//  differs per platform — opening a recording (the withheld-closure refusal and the
//  exposure-ledger row on the Mac), playback, frame stepping — lives beside this file,
//  never in a second copy of the rules. Each rally is a record with a persistent id,
//  its first serve contact and first ball-dead moment as `[earliest, latest]` intervals,
//  its kind, flags and an edge marker; the recording carries explicit *coverage* (the
//  intervals a person has inspected — everything else is unknown, never dead time or a
//  negative example, D-010), spans of non-rally ball activity, transition and
//  uncertainty, and a completion mark that is refused while any unknown gap wider than
//  one video frame remains. Plan: docs/ml-roadmap/STAGE1_RALLY_BOUNDARIES_PLAN.md;
//  protocol: docs/ml-roadmap/EVENT_BOUNDARY_REVIEW_PROTOCOL.md (§4 rubric, §5 record).
//

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
        /// The app that recorded it (`RallyLab …` or `Labeler …`): a second review on the other
        /// platform is the Mac-vs-iPhone comparison on identical source frames. nil from older records.
        var tool: String?

        static let sameReviewer = "blind_repeat_same_reviewer_24h"
        static let otherReviewer = "second_reviewer"
        /// The same reviewer may repeat blind only after this long (protocol §6).
        static let repeatGap: TimeInterval = 24 * 3600
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
        /// The ORIGINAL recording's content fingerprint (`file:<sha256>`), on every platform — a phone
        /// reviewing a re-encoded copy still records the original it stands for.
        var sourceFingerprint: String?
        var frameRate: Double
        var durationSec: Double
        var tool: String
        var coverage: [Coverage] = []
        var spans: [Span] = []
        var rallies: [Rally] = []
        var stage1Complete: Completion?
        /// Digest of the original's frame presentation times (`FrameClock.digest`): what a copy on another
        /// device must reproduce before its commits count as the original's frames. nil = not established.
        var frameTimesDigest: String?
        /// The synchronised revision this record was loaded from; a save sends it back so an edit made from a
        /// stale copy is detected, not merged over. 0 = never synchronised.
        var revision: Int = 0

        /// One video frame, the tolerance of every coverage comparison.
        var frameDuration: Double { 1 / frameRate }

        init(annotationVersion: String = EventReview.annotationVersion, video: String, sourceFingerprint: String?, frameRate: Double, durationSec: Double, tool: String,
             coverage: [Coverage] = [], spans: [Span] = [], rallies: [Rally] = [], stage1Complete: Completion? = nil, frameTimesDigest: String? = nil, revision: Int = 0) {
            self.annotationVersion = annotationVersion; self.video = video; self.sourceFingerprint = sourceFingerprint
            self.frameRate = frameRate; self.durationSec = durationSec; self.tool = tool
            self.coverage = coverage; self.spans = spans; self.rallies = rallies; self.stage1Complete = stage1Complete
            self.frameTimesDigest = frameTimesDigest; self.revision = revision
        }

        private enum CodingKeys: String, CodingKey {
            case annotationVersion, video, sourceFingerprint, frameRate, durationSec, tool, coverage, spans, rallies, stage1Complete, frameTimesDigest, revision
        }

        /// Records written before `frameTimesDigest` and `revision` existed read with their defaults (decodeIfPresent).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            annotationVersion = try c.decode(String.self, forKey: .annotationVersion)
            video = try c.decode(String.self, forKey: .video)
            sourceFingerprint = try c.decodeIfPresent(String.self, forKey: .sourceFingerprint)
            frameRate = try c.decode(Double.self, forKey: .frameRate)
            durationSec = try c.decode(Double.self, forKey: .durationSec)
            tool = try c.decode(String.self, forKey: .tool)
            coverage = try c.decodeIfPresent([Coverage].self, forKey: .coverage) ?? []
            spans = try c.decodeIfPresent([Span].self, forKey: .spans) ?? []
            rallies = try c.decodeIfPresent([Rally].self, forKey: .rallies) ?? []
            stage1Complete = try c.decodeIfPresent(Completion.self, forKey: .stage1Complete)
            frameTimesDigest = try c.decodeIfPresent(String.self, forKey: .frameTimesDigest)
            revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        }
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
        case sessionsUnreadable(String)
        case projectUnreadable(String)
        case withheldIdentityUnknown(String)
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
            case .sessionsUnreadable(let why): return "The project's sessions can't all be read, so the withheld recordings' files are unknown; nothing opens: \(why)"
            case .projectUnreadable(let why): return "project.json exists but can't be read, so the withheld recordings' identities are unknown; nothing opens: \(why)"
            case .withheldIdentityUnknown(let why): return "A withheld recording's content cannot be fingerprinted, so a copy of it could not be told apart; nothing opens: \(why)"
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

        /// The blind repeat of a reviewed rally's events: recorded beside the first result, which it never
        /// changes. The method follows from who reviews: another person is a second reviewer; the same
        /// person may repeat only after `SecondReview.repeatGap` from the first review (the first result
        /// hidden by the tool). Throws when the gap is not met or the rally is not a reviewed one.
        static func recordSecondReview(of id: UUID, contact: EventTime?, dead: EventTime?, in file: inout File, at: Date, annotator: String, tool: String) throws {
            guard let i = file.rallies.firstIndex(where: { $0.rallyId == id && $0.reviewState == .reviewed }) else { throw Failure.invalid("second review: the rally is not on record as reviewed") }
            let first = file.rallies[i]
            let method: String
            if first.annotator == annotator {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
                guard let firstAt = f.date(from: first.reviewedAt) else { throw Failure.invalid("second review: the first review's time (\(first.reviewedAt)) is unreadable") }
                let gap = at.timeIntervalSince(firstAt)
                guard gap >= SecondReview.repeatGap else {
                    throw Failure.invalid(String(format: "second review by the same reviewer needs %.0f h after the first (%.1f h so far)", SecondReview.repeatGap / 3600, gap / 3600))
                }
                method = SecondReview.sameReviewer
            } else {
                method = SecondReview.otherReviewer
            }
            file.rallies[i].secondReview = SecondReview(annotator: annotator, reviewedAt: stamp(at), method: method, contact: contact, dead: dead, tool: tool)
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
}
