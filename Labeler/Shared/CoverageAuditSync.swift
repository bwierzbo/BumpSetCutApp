//
//  CoverageAuditSync.swift
//  Labeler/Shared — compiled by RallyLab (macOS) and the Labeler iPhone app
//
//  How a coverage-audit record moves between a device and the server (migration 054), decided
//  the same way on both. The server keeps one coverage_audit_v2 record per drawn recording at a
//  revision; a save names the revision it was made from and the server refuses a stale one.
//  Each device keeps its own record and a shadow of the last one it synchronised, and merges
//  look by look — a look is one pass's verdict on one interval, and it is its reviewer's alone:
//
//   - only one side changed a look since the shadow → that side's look;
//   - both changed it, differently → a conflict: the server's look stays, this device's is kept
//     aside for the person to decide, and nothing is merged over it;
//   - the record's identity (recording, draw and its hash, footage, dataset, timescale, blind)
//     differs → nothing is merged at all.
//
//  The merged record is validated by the same rules a local verdict is (CoverageAudit.validate);
//  one that fails is never sent and never adopted. Last-write-wins is never used.
//

import Foundation

/// A `label_coverage_audit_draws` row: a frozen draw's bytes as published by the Mac, and their SHA-256.
struct LabelCoverageAuditDraw: Codable, Equatable, Sendable {
    var project: String
    var drawId: String
    var drawSha256: String
    var body: String
    var publishedAt: Date?
}

/// A `label_coverage_audit_recordings` row: what the Mac's admission found for a drawn recording when it last published.
struct LabelCoverageAuditRecording: Codable, Equatable, Sendable {
    var project: String
    var drawId: String
    var recordingId: String
    /// The recording's published copy (its label_videos row).
    var videoId: UUID
    var sourceFingerprint: String
    var marksSha256: String
    /// The draw's intervals still unmarked as drawn: no verdict is taken on any other.
    var openIndices: [Int]
    var publishedAt: Date?
}

/// A `label_coverage_audits` row.
struct LabelCoverageAudit: Codable, Equatable, Sendable {
    var project: String
    var drawId: String
    var recordingId: String
    var record: CoverageAudit.File
    var revision: Int
    var updatedBy: UUID?
    var updatedAt: Date?
}

/// A `label_coverage_audit_uses` row: a reviewer opened a drawn recording for review (the first time).
struct LabelCoverageAuditUse: Codable, Equatable, Sendable {
    var project: String
    var drawId: String
    var recordingId: String
    var reviewer: UUID
    var firstUsedAt: Date
}

enum CoverageAuditSync {
    /// Where a look lives: one pass's verdict on one interval.
    struct Slot: Hashable, Codable, Sendable, Comparable {
        var pass: CoverageAudit.Pass
        var index: Int

        static func < (a: Slot, b: Slot) -> Bool {
            let order = CoverageAudit.Pass.allCases
            return (order.firstIndex(of: a.pass)!, a.index) < (order.firstIndex(of: b.pass)!, b.index)
        }
    }

    /// One look as a pass holds it.
    enum Look: Equatable, Codable, Sendable {
        case first(CoverageAudit.Review)
        case repeatLook(CoverageAudit.RepeatReview)
        case resolution(CoverageAudit.Resolution)

        var reviewer: String {
            switch self {
            case .first(let r): return r.reviewer
            case .repeatLook(let r): return r.reviewer
            case .resolution(let r): return r.reviewer
            }
        }
    }

    /// A look both this device and another changed since they last agreed: the server's stays, this one is kept here.
    struct Conflict: Equatable, Codable, Sendable {
        var slot: Slot
        /// This device's look (nil: it withdrew the look the other device changed).
        var mine: Look?
    }

    static func slots(of file: CoverageAudit.File?) -> Set<Slot> {
        guard let file else { return [] }
        return Set(file.intervals.map { Slot(pass: .first, index: $0.index) }
            + (file.repeatPass?.intervals ?? []).map { Slot(pass: .repeatLook, index: $0.index) }
            + file.resolutions.map { Slot(pass: .resolution, index: $0.index) })
    }

    static func look(_ slot: Slot, in file: CoverageAudit.File?) -> Look? {
        guard let file else { return nil }
        switch slot.pass {
        case .first: return file.review(slot.index).map(Look.first)
        case .repeatLook: return file.repeatReview(slot.index).map(Look.repeatLook)
        case .resolution: return file.resolution(slot.index).map(Look.resolution)
        }
    }

    /// `file` with the look at `slot` replaced by `look` (removed when nil). The repeat's method follows its reviewers.
    static func setting(_ slot: Slot, to look: Look?, in file: CoverageAudit.File) -> CoverageAudit.File {
        var file = file
        switch slot.pass {
        case .first:
            file.intervals.removeAll { $0.index == slot.index }
            if case .first(let r)? = look { file.intervals.append(r) }
            file.intervals.sort { $0.index < $1.index }
        case .repeatLook:
            var looks = (file.repeatPass?.intervals ?? []).filter { $0.index != slot.index }
            if case .repeatLook(let r)? = look { looks.append(r) }
            file.repeatPass = looks.isEmpty ? nil : CoverageAudit.Repeat(method: CoverageAudit.Repeat.secondReviewer, intervals: looks.sorted { $0.index < $1.index })
            let method = CoverageAudit.repeatMethod(of: file)
            file.repeatPass?.method = method
        case .resolution:
            file.resolutions.removeAll { $0.index == slot.index }
            if case .resolution(let r)? = look { file.resolutions.append(r) }
            file.resolutions.sort { $0.index < $1.index }
        }
        return file
    }

    /// Why two records cannot be merged — they are records of different things — or nil.
    static func identityMismatch(_ a: CoverageAudit.File, _ b: CoverageAudit.File) -> String? {
        let fields: [(String, String, String)] = [("recording", a.recordingId, b.recordingId), ("footage", a.sourceFingerprint, b.sourceFingerprint),
                                                  ("draw", a.drawId, b.drawId), ("draw hash", a.drawSha256, b.drawSha256), ("dataset", a.datasetName, b.datasetName),
                                                  ("version", a.annotationVersion, b.annotationVersion)]
        if let (what, x, y) = fields.first(where: { $0.1 != $0.2 }) { return "the records are of different \(what) (\(x.prefix(24)) / \(y.prefix(24)))" }
        if a.timescale != b.timescale || a.blindToPipeline != b.blindToPipeline { return "the records differ in timescale or blindness" }
        return nil
    }

    struct Merge: Equatable {
        /// The merged record; nil when there is none on either side, or nothing could be merged (`refusal`).
        var record: CoverageAudit.File?
        /// Looks both sides changed: the server's kept in `record`, this device's here.
        var conflicts: [Conflict] = []
        /// Why nothing was merged (another recording's or footage's record, or a merged record that breaks a rule).
        var refusal: String?
    }

    /// The three-way merge of a device's record (`local`), its last synchronised copy (`shadow`) and the server's.
    static func merge(local: CoverageAudit.File?, shadow: CoverageAudit.File?, server: CoverageAudit.File?) -> Merge {
        guard let local else { return Merge(record: server) }
        guard let server else {
            // Nothing on the server: a record this device holds goes up as it is (the server decides).
            return Merge(record: local)
        }
        if let why = identityMismatch(local, server) { return Merge(record: nil, refusal: why) }
        if let shadow, let why = identityMismatch(shadow, server) { return Merge(record: nil, refusal: "the last synchronised copy: \(why)") }
        var merged = server
        var conflicts: [Conflict] = []
        for slot in slots(of: local).union(slots(of: shadow)).union(slots(of: server)).sorted() {
            let l = look(slot, in: local), b = look(slot, in: shadow), s = look(slot, in: server)
            if l == s || l == b { continue }
            if s == b { merged = setting(slot, to: l, in: merged); continue }
            conflicts.append(Conflict(slot: slot, mine: l))
        }
        do { try CoverageAudit.validate(merged) } catch {
            return Merge(record: nil, conflicts: conflicts, refusal: "the merged record breaks a rule: \(error.localizedDescription)")
        }
        return Merge(record: merged, conflicts: conflicts)
    }

    /// `file` with this device's look at a conflict's slot put back, explicitly (the person chose it over the
    /// other device's), and the shadow moved to the server's look there, so the next merge sends it as this device's change.
    static func keepMine(_ conflict: Conflict, local: CoverageAudit.File, shadow: CoverageAudit.File?, server: CoverageAudit.File)
        -> (local: CoverageAudit.File, shadow: CoverageAudit.File) {
        let base = shadow.map { setting(conflict.slot, to: look(conflict.slot, in: server), in: $0) } ?? server
        return (setting(conflict.slot, to: conflict.mine, in: local), base)
    }

    // MARK: - The server's refusals (054)

    enum Refusal: Equatable {
        case conflict(serverRevision: Int?)
        case withheld
        case identity
        case reviewer
        case interval
        case frozen
        case notLead
    }

    /// What kind of refusal a server message is, or nil for anything else (a transient failure: try again later).
    static func refusal(in message: String) -> Refusal? {
        let lowered = message.lowercased()
        func has(_ prefix: String) -> Bool { lowered.contains(prefix) }
        if has("conflict:") {
            let revision = message.range(of: #"revision (\d+)"#, options: .regularExpression)
                .flatMap { Int(message[$0].split(separator: " ").last ?? "") }
            return .conflict(serverRevision: revision)
        }
        if has("withheld:") { return .withheld }
        if has("identity:") { return .identity }
        if has("reviewer:") { return .reviewer }
        if has("interval:") { return .interval }
        if has("frozen:") { return .frozen }
        if has("leads only") { return .notLead }
        return nil
    }
}
