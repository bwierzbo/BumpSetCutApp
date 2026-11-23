//
//  CoverageAuditPhone.swift
//  Labeler/Shared — compiled by the Labeler iPhone app and RallyLab (whose tests hold it)
//
//  The coverage audit as the phone keeps it between launches: one frozen draw, as the Mac
//  published it (its bytes, checked against their SHA-256), what the Mac's admission found
//  for each drawn recording, this phone's record of each recording with the copy it last
//  agreed with the server on (the shadow), and where the reviewer was. Nothing here plays a
//  video or talks to the server; every verdict goes through `CoverageAudit.applying`, the
//  rules the Mac's own verdicts follow, and the record format is the Mac's coverage_audit_v2.
//
//  What the phone refuses besides the rules: a recording the Mac has not published (or no
//  longer offers), one whose project's withheld list names it or is not known, one whose
//  published copy is not of the draw's footage, and an interval the Mac no longer publishes
//  as unmarked as drawn (its marks or cut ranges moved: a new draw is needed).
//

import Foundation

struct CoverageAuditPhone: Codable, Equatable {
    var project: String
    var drawId: String
    var drawSha256: String
    /// The draw file's bytes as published (their SHA-256 is `drawSha256`).
    var drawBody: Data
    /// What the Mac's admission found, by recording.
    var recordings: [String: LabelCoverageAuditRecording] = [:]
    /// This phone's record of each recording, verdicts not yet on the server included.
    var local: [String: CoverageAudit.File] = [:]
    /// Each record as this phone last agreed with the server, and the server's revision then.
    var shadow: [String: CoverageAudit.File] = [:]
    var revision: [String: Int] = [:]
    /// Looks both this phone and another device changed: the other's kept, this phone's here until the reviewer decides.
    var conflicts: [String: [CoverageAuditSync.Conflict]] = [:]
    /// Why the server refused a recording's record (kept on the phone, not sent again until it is reloaded).
    var refusals: [String: String] = [:]
    /// "<account>|<recording>": the uses an account of this phone put on the server's ledger (`coverage_audit_open`)
    /// before any frame was shown.
    var opened: Set<String> = []
    /// Where the reviewer was: the next launch opens here.
    var position: Position?
    /// The draw, read from `drawBody` (checked when it came, and again whenever the store is read).
    private(set) var draw: CoverageAudit.LoadedDraw

    enum CodingKeys: String, CodingKey {
        case project, drawId, drawSha256, drawBody, recordings, local, shadow, revision, conflicts, refusals, opened, position
    }

    struct Position: Codable, Equatable, Hashable {
        var pass: CoverageAudit.Pass
        var recordingId: String
        var index: Int
    }

    /// The draw's bytes from the server, checked: their SHA-256 must be the one published with them, and they must
    /// read as a draw (`CoverageAudit.loadDraw`'s checks).
    init(row: LabelCoverageAuditDraw) throws {
        let body = Data(row.body.utf8)
        draw = try Self.read(body, drawId: row.drawId, sha256: row.drawSha256)
        (project, drawId, drawSha256, drawBody) = (row.project, row.drawId, row.drawSha256, body)
    }

    /// The store as kept: the draw's bytes are checked again (a store that no longer holds them whole is refused, not half-read).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decode(String.self, forKey: .project)
        drawId = try c.decode(String.self, forKey: .drawId)
        drawSha256 = try c.decode(String.self, forKey: .drawSha256)
        drawBody = try c.decode(Data.self, forKey: .drawBody)
        recordings = try c.decodeIfPresent([String: LabelCoverageAuditRecording].self, forKey: .recordings) ?? [:]
        local = try c.decodeIfPresent([String: CoverageAudit.File].self, forKey: .local) ?? [:]
        shadow = try c.decodeIfPresent([String: CoverageAudit.File].self, forKey: .shadow) ?? [:]
        revision = try c.decodeIfPresent([String: Int].self, forKey: .revision) ?? [:]
        conflicts = try c.decodeIfPresent([String: [CoverageAuditSync.Conflict]].self, forKey: .conflicts) ?? [:]
        refusals = try c.decodeIfPresent([String: String].self, forKey: .refusals) ?? [:]
        opened = try c.decodeIfPresent(Set<String>.self, forKey: .opened) ?? []
        position = try c.decodeIfPresent(Position.self, forKey: .position)
        draw = try Self.read(drawBody, drawId: drawId, sha256: drawSha256)
    }

    private static func read(_ body: Data, drawId: String, sha256: String) throws -> CoverageAudit.LoadedDraw {
        let loaded = try CoverageAudit.loadDraw(body, url: URL(fileURLWithPath: "/\(drawId)-draw.json"))
        guard loaded.sha256 == sha256, loaded.draw.drawId == drawId else {
            throw CoverageAudit.Failure.drawUnreadable("its bytes are not the ones published (SHA-256 or draw id differs)")
        }
        return loaded
    }

    // MARK: - The file on the phone

    enum Stored: Equatable {
        /// No store yet.
        case none
        case store(CoverageAuditPhone)
        /// The store could not be read; it was moved, whole, to `keptAt` (never overwritten, never half-read).
        case setAside(keptAt: URL, why: String)
        /// The store could not be read nor moved aside: nothing may be written over it.
        case blocked(String)
    }

    /// Reads the store at `url`. A file that is there but can't be read or decoded may hold verdicts not on the server
    /// yet: it is moved aside under a dated name, so that a new store never replaces it.
    static func load(from url: URL, now: Date = Date()) -> Stored {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .none }
        let why: String
        do { return .store(try JSONDecoder().decode(CoverageAuditPhone.self, from: Data(contentsOf: url))) } catch { why = String(describing: error) }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let kept = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        do { try fm.moveItem(at: url, to: kept) } catch { return .blocked("\(why); and it could not be set aside: \(error.localizedDescription)") }
        return .setAside(keptAt: kept, why: why)
    }

    // MARK: - Which draw

    /// Whether this store holds anything not settled with the server: a verdict not sent, or a conflict not decided.
    var holdsUnsettled: Bool { local.contains { shadow[$0.key] != $0.value } || conflicts.values.contains { !$0.isEmpty } }

    enum DrawChoice: Equatable {
        /// Go on with the draw held.
        case keep
        /// Start the audit of this published draw (none held, or the held one is settled and replaced or withdrawn).
        case start(LabelCoverageAuditDraw)
        /// The held draw is no longer served, or another replaces it, but it holds unsettled work: kept, and said so.
        case keepUnsettled(String)
        /// Nothing held and nothing published.
        case nothing
    }

    /// Which draw the phone audits, from the draws published now: the held one while it is served and not replaced; a
    /// draw that names it in `supersedes`, or the stage 2 draw that `follows` it (the newest such), once nothing of the
    /// held one is unsettled; the newest published draw when none is held. Unsettled work is never dropped for another draw.
    static func choose(held: CoverageAuditPhone?, published rows: [LabelCoverageAuditDraw]) -> DrawChoice {
        guard let held else { return rows.max(by: { $0.drawId < $1.drawId }).map(DrawChoice.start) ?? .nothing }
        let served = rows.contains { $0.project == held.project && $0.drawId == held.drawId && $0.drawSha256 == held.drawSha256 }
        let replacement = rows.filter { row in
            guard row.project == held.project, row.drawId != held.drawId,
                  let draw = (try? CoverageAudit.loadDraw(Data(row.body.utf8), url: URL(fileURLWithPath: "/")))?.draw else { return false }
            return (draw.supersedes ?? []).contains(held.drawId)
                || draw.follows == CoverageAudit.Draw.Follows(drawId: held.drawId, sha256: held.drawSha256)
        }.max { $0.drawId < $1.drawId }
        if served && replacement == nil { return .keep }
        if held.holdsUnsettled {
            return .keepUnsettled("Draw \(held.drawId) is " + (served ? "followed or replaced by \(replacement!.drawId)" : "no longer published")
                                  + "; its unsent verdicts or undecided conflicts are kept on this phone until they are settled.")
        }
        if let replacement { return .start(replacement) }
        return rows.max(by: { $0.drawId < $1.drawId }).map(DrawChoice.start) ?? .nothing
    }

    // MARK: - What may be reviewed

    /// Why `recordingId` cannot be reviewed on this phone now, or nil. `video`: its published copy's row as last
    /// loaded; `withheld`: its project's withheld list says so (true), says not (false), or is not known (nil).
    func unavailable(_ recordingId: String, video: LabelVideo?, withheld: Bool?) -> String? {
        guard let drawn = draw.draw.recording(recordingId) else { return "not a recording of draw \(drawId)" }
        guard let published = recordings[recordingId] else { return "not offered for review yet — RallyLab publishes it when its original is on the Mac" }
        switch withheld {
        case true?: return "withheld: no review of it anywhere"
        case nil: return "its project's withheld list is not known here yet — nothing is reviewed until it is"
        case false?: break
        }
        // The draw holds only recordings typed continuous: one typed otherwise since is not audited for negatives.
        if let type = video?.recordingType, type != "continuous" { return "typed \(type) since the draw: not audited, and no source of negatives" }
        guard published.sourceFingerprint == drawn.contentFingerprint else { return "the Mac published other footage than the draw's" }
        guard let video, video.id == published.videoId, video.sourceFingerprint == drawn.contentFingerprint else {
            return "no copy of the draw's footage is published for it"
        }
        guard let digest = video.frameTimesDigest, !digest.isEmpty else { return "the Mac has not published its frame identity: the copy can't be checked" }
        return nil
    }

    /// The draw's intervals the Mac last published as still unmarked as drawn (none when it published nothing).
    func asDrawn(_ recordingId: String) -> Set<Int> { Set(recordings[recordingId]?.openIndices ?? []) }

    func tally(_ recordingId: String) -> CoverageAudit.Tally? {
        draw.draw.recording(recordingId).map { CoverageAudit.tally(of: $0, file: local[recordingId], asDrawn: asDrawn(recordingId)) }
    }

    /// The intervals `pass` owes a look, in the draw's order, of the recordings that may be reviewed now (`reviewable`).
    func queue(_ pass: CoverageAudit.Pass, reviewable: (String) -> Bool, reviewer: String, now: Date) -> [Position] {
        draw.draw.recordings.flatMap { recording -> [Position] in
            guard reviewable(recording.recordingId) else { return [] }
            return CoverageAudit.owed(pass, recording: recording, file: local[recording.recordingId], asDrawn: asDrawn(recording.recordingId))
                .map { Position(pass: pass, recordingId: recording.recordingId, index: $0) }
        }
    }

    /// The next interval to review after `position` in its pass (wrapping round), or the first; nil when none is owed.
    func next(after position: Position?, pass: CoverageAudit.Pass, reviewable: (String) -> Bool, reviewer: String, now: Date) -> Position? {
        let queue = queue(pass, reviewable: reviewable, reviewer: reviewer, now: now)
        guard let position, position.pass == pass else { return queue.first }
        let order = draw.draw.recordings.map(\.recordingId)
        func key(_ p: Position) -> (Int, Int) { (order.firstIndex(of: p.recordingId) ?? .max, p.index) }
        return queue.first { key($0) > key(position) } ?? queue.first
    }

    /// Where to open on launch: the interval the reviewer was on while it still owes its look, else the next one.
    /// Always in the first pass (amendment 2): a place an older build kept in the repeat or the resolution — where a
    /// record from then may still hold a disagreement — is never reopened, since no look can be given there.
    func resume(reviewable: (String) -> Bool, reviewer: String, now: Date) -> Position? {
        let queue = queue(.first, reviewable: reviewable, reviewer: reviewer, now: now)
        if let position, queue.contains(position) { return position }
        return next(after: position, pass: .first, reviewable: reviewable, reviewer: reviewer, now: now)
    }

    // MARK: - What the reviewer sees

    /// The looks the reviewer may see on an interval in `pass`: in the first pass the first look; in the blind repeat
    /// the repeat look only — never the first verdict; in the resolution all three, side by side.
    func shown(_ pass: CoverageAudit.Pass, recordingId: String, index: Int) -> [CoverageAuditSync.Look] {
        let file = local[recordingId]
        return Self.visible(in: pass).compactMap { CoverageAuditSync.look(.init(pass: $0, index: index), in: file) }
    }

    /// Whose looks a pass may show: the first pass its own; the blind repeat its own only (never the first verdict);
    /// the resolution all three.
    static func visible(in pass: CoverageAudit.Pass) -> [CoverageAudit.Pass] {
        switch pass {
        case .first: return [.first]
        case .repeatLook: return [.repeatLook]
        case .resolution: return [.first, .repeatLook, .resolution]
        }
    }

    struct OpenConflict: Equatable, Identifiable {
        var recordingId: String
        var conflict: CoverageAuditSync.Conflict
        var id: String { "\(recordingId)/\(conflict.slot.pass.rawValue)/\(conflict.slot.index)" }
    }

    /// Every conflict the reviewer may see and decide in `pass`, whatever is left to review: only those of the passes
    /// it shows — a conflict over a first look carries that look, and is never shown during the blind repeat.
    func shownConflicts(_ pass: CoverageAudit.Pass) -> [OpenConflict] {
        let visible = Self.visible(in: pass)
        return draw.draw.recordings.flatMap { recording in
            (conflicts[recording.recordingId] ?? []).filter { visible.contains($0.slot.pass) }.map { OpenConflict(recordingId: recording.recordingId, conflict: $0) }
        }
    }

    struct Totals: Equatable {
        var reviewed = 0
        var total = 0
        /// Intervals the pass still owes a look, of the recordings that may be reviewed.
        var left = 0
        var recordingsDone = 0
        var recordings = 0
        /// The findings that count, by kind — never in the blind repeat (they come from the first verdicts).
        var findings: [CoverageAudit.FindingKind: Int] = [:]
        var findingsHidden = false
        /// Recordings that may not be reviewed on this phone now (not published, withheld, no checked copy).
        var unavailable = 0
        /// Verdicts on this phone not on the server yet.
        var pending = 0
    }

    func totals(_ pass: CoverageAudit.Pass, reviewable: (String) -> Bool) -> Totals {
        var t = Totals(recordings: draw.draw.recordings.count, findingsHidden: pass == .repeatLook)
        for recording in draw.draw.recordings {
            let id = recording.recordingId
            let tally = CoverageAudit.tally(of: recording, file: local[id], asDrawn: asDrawn(id))
            t.total += tally.total
            t.reviewed += tally.reviewed
            if !t.findingsHidden { for (kind, n) in tally.findings { t.findings[kind, default: 0] += n } }
            if local[id] != shadow[id] { t.pending += 1 }
            guard reviewable(id) else { t.unavailable += 1; continue }
            let left = tally.left(in: pass)
            t.left += left
            if left == 0 { t.recordingsDone += 1 }
        }
        return t
    }

    // MARK: - Giving a verdict

    /// `entry` by `reviewer` on interval `index` of `recordingId` in `pass`, applied by the shared rules to this phone's
    /// record (a new one when it has none), stamped with the marks hash the Mac published. Refuses, first, a recording
    /// that may not be reviewed here now (`unavailable`, judged on `video` and `withheld` as the phone knows them at
    /// this moment: a recording withheld since it was opened is refused), and an interval the Mac no longer publishes
    /// as unmarked as drawn. Returns the record as it now is (kept in `local`).
    @discardableResult
    mutating func give(_ entry: CoverageAudit.Entry, pass: CoverageAudit.Pass, recordingId: String, index: Int, video: LabelVideo?, withheld: Bool?,
                       played: CoverageAudit.PlayedCoverage, reviewer: String, note: String? = nil, tool: String, now: Date = Date()) throws -> CoverageAudit.File {
        if let why = unavailable(recordingId, video: video, withheld: withheld) { throw CoverageAudit.Failure.notOnThisDevice(recording: recordingId, why: why) }
        let reviewer = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reviewer.isEmpty else { throw CoverageAudit.Failure.noReviewer }
        let loaded = draw
        guard let recording = loaded.draw.recording(recordingId), let published = recordings[recordingId] else { throw CoverageAudit.Failure.notInDraw(recordingId) }
        guard let interval = recording.interval(index) else { throw CoverageAudit.Failure.intervalNotInDraw(recording: recordingId, index: index) }
        if entry.adds, !published.openIndices.contains(index) { throw CoverageAudit.Failure.marksChanged(recording: recordingId, index: index) }
        guard published.sourceFingerprint == recording.contentFingerprint else {
            throw CoverageAudit.Failure.sourceChanged(recording: recordingId, draw: recording.contentFingerprint, current: published.sourceFingerprint)
        }
        let file = local[recordingId] ?? CoverageAudit.File(recordingId: recordingId, sourceFingerprint: recording.contentFingerprint, drawId: drawId,
                                                            drawSha256: drawSha256, datasetName: loaded.draw.datasetName, marksSha256: published.marksSha256, tool: tool)
        var next = try CoverageAudit.applying(CoverageAudit.Request(recordingId: recordingId, index: index, pass: pass, entry: entry, reviewer: reviewer, played: played, note: note),
                                              reviewer: reviewer, to: file, interval: interval, recording: recording, now: now)
        next.marksSha256 = published.marksSha256
        next.tool = tool
        try CoverageAudit.validate(next)
        local[recordingId] = next
        return next
    }

    // MARK: - Synchronising

    enum Step: Equatable {
        /// Nothing to send: the server's record (or none) is this phone's.
        case upToDate
        /// Send this record at the server's revision `expected`.
        case push(CoverageAudit.File, expected: Int)
        /// Nothing can be merged (the server's record is of other footage, or the merge breaks a rule): kept, not sent.
        case refused(String)
    }

    /// Merges a recording's record with the server's row (nil: none there) and says what to do; the server's looks
    /// and any conflict are taken in here at once (the phone shows the merged record).
    mutating func merge(_ recordingId: String, server: LabelCoverageAudit?) -> Step {
        let result = CoverageAuditSync.merge(local: local[recordingId], shadow: shadow[recordingId], server: server?.record)
        if let why = result.refusal { return .refused(why) }
        if !result.conflicts.isEmpty { conflicts[recordingId] = (conflicts[recordingId] ?? []) + result.conflicts }
        guard var record = result.record else { return .upToDate }
        if let published = recordings[recordingId] { record.marksSha256 = published.marksSha256 }
        local[recordingId] = record
        if record == server?.record {
            shadow[recordingId] = record
            revision[recordingId] = server?.revision
            return .upToDate
        }
        // What was taken from the server is agreed now, whether or not the send that follows goes through.
        shadow[recordingId] = CoverageAuditSync.base(after: record, server: server?.record, shadow: shadow[recordingId])
        return .push(record, expected: server?.revision ?? 0)
    }

    /// The server took `sent` and saved it as `saved`: the shadow moves to it, and the phone's record too unless the
    /// reviewer gave another verdict meanwhile (that one stays, and goes next).
    mutating func pushed(_ sent: CoverageAudit.File, saved: LabelCoverageAudit) {
        shadow[saved.recordingId] = saved.record
        revision[saved.recordingId] = saved.revision
        if local[saved.recordingId] == sent { local[saved.recordingId] = saved.record }
        refusals[saved.recordingId] = nil
    }

    /// The reviewer chose this phone's look over the other device's (`keep`) or the other's (`!keep`). This phone's is
    /// put back only when the record stays valid with it (a later look may stand on the other device's — a repeat on a
    /// first look, a resolution on both): otherwise nothing changes, the conflict stays, and why is thrown.
    mutating func resolve(_ conflict: CoverageAuditSync.Conflict, recordingId: String, keep: Bool) throws {
        if keep, let local = local[recordingId], let server = shadow[recordingId] {
            let kept = CoverageAuditSync.keepMine(conflict, local: local, shadow: shadow[recordingId], server: server)
            do { try CoverageAudit.validate(kept.local) } catch {
                throw CoverageAudit.Failure.invalid("this phone's look can't be put back on interval \(conflict.slot.index): \(error.localizedDescription) "
                                                    + "Withdraw the later look first, or keep the other device's")
            }
            self.local[recordingId] = kept.local
            shadow[recordingId] = kept.shadow
        }
        conflicts[recordingId]?.removeAll { $0 == conflict }
        if conflicts[recordingId]?.isEmpty == true { conflicts[recordingId] = nil }
    }
}

// MARK: - Placing a finding by scrubbing

extension CoverageAuditPhone {
    /// A finding being placed on the phone: the reviewer scrubs the footage and says where it starts and where it
    /// ends, instead of typing times. Nothing here is a verdict until `finding` is given; a scrub is a jump, so
    /// placing one earns no viewing credit.
    struct Marking: Equatable {
        /// A mark off by this much or less is inside the tolerance (protocol §5: a boundary error is more than 1.0 s).
        static let boundaryToleranceSec = 1.0

        let kind: CoverageAudit.FindingKind
        /// A boundary error given as a trim: the end of the interval it takes off. That end of the stretch is the
        /// interval's own and does not move (`leading`: from the interval's start; `trailing`: to its end).
        let trim: CoverageAudit.Edge?
        /// The times the stretch may name: the interval for a trim, otherwise what is shown (its context included).
        let bounds: ClosedRange<Double>
        /// Where the reviewer was when the marking began: playback returns there.
        let resume: Double
        private(set) var start: Double
        /// Nil: the finding names only where it starts.
        private(set) var end: Double?
        /// A missed rally clipped by the recording's start or end.
        var edge: CoverageAudit.Edge?
        var note = ""

        /// A finding of `kind` on `interval`, begun at `playhead` with `shown` on screen. `trim` makes it the boundary
        /// error at that end of the interval.
        init(kind: CoverageAudit.FindingKind, trim: CoverageAudit.Edge? = nil, interval: CoverageAudit.Interval, shown: ClosedRange<Double>, playhead: Double) {
            let a = CoverageAudit.seconds(interval.startTick), b = CoverageAudit.seconds(interval.endTick)
            self.kind = trim == nil ? kind : .boundaryError
            self.trim = trim
            bounds = trim == nil ? shown : a...b
            resume = playhead
            let here = Self.snapped(playhead, in: bounds)
            switch trim {
            case .leading: (start, end) = (a, here)
            case .trailing: (start, end) = (here, b)
            default: (start, end) = (here, nil)
            }
        }

        /// A time as a finding names it: inside `bounds`, to a tenth of a second.
        static func snapped(_ t: Double, in bounds: ClosedRange<Double>) -> Double {
            min(max((t * 10).rounded() / 10, bounds.lowerBound), bounds.upperBound)
        }

        var startIsFixed: Bool { trim == .leading }
        var endIsFixed: Bool { trim == .trailing }

        /// The finding starts at `t`. An end before it no longer holds and is dropped.
        mutating func setStart(_ t: Double) {
            guard !startIsFixed else { return }
            start = Self.snapped(t, in: bounds)
            if let end, end < start, !endIsFixed { self.end = nil }
        }

        /// The finding ends at `t`. A start after it moves back to it.
        mutating func setEnd(_ t: Double) {
            guard !endIsFixed else { return }
            let t = Self.snapped(t, in: bounds)
            if t < start, !startIsFixed { start = t }
            end = max(t, start)
        }

        mutating func clearEnd() { if trim == nil { end = nil } }

        /// Why the finding cannot be saved as placed, in the reviewer's words. Nil: it can.
        var problem: String? {
            if trim != nil, let end, end - start <= Self.boundaryToleranceSec {
                return String(format: "%.1f s is inside the 1 s tolerance. A mark that close is right — cancel and give Clean.", end - start)
            }
            if kind == .uncertain, note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "An uncertain finding needs a note saying what could not be told." }
            return nil
        }

        /// The finding as placed (nil while `problem` holds).
        var finding: CoverageAudit.Finding? {
            guard problem == nil else { return nil }
            let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return CoverageAudit.Finding(kind: kind, approxStartSec: start, approxEndSec: end, edge: trim ?? edge, note: text.isEmpty ? nil : text)
        }
    }
}
