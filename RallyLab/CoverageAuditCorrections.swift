//
//  CoverageAuditCorrections.swift
//  RallyLab
//
//  The marking pass's use of the coverage audit's boundary errors (protocol amendment 1, A1.3;
//  D-040). A boundary error says the mark beside an unmarked interval ends early (`leading`) or
//  starts late (`trailing`), and how much of the interval is play. Here each one that counts
//  becomes a proposal to move that mark's edge, which a person applies or declines one by one.
//
//  The audit itself still writes no mark: nothing here runs from a verdict. A correction is
//  refused while the stage that holds the finding is incomplete — an interval not reviewed, a
//  repeat pending, a disagreement unresolved, a look unfinished, a recording that can't be
//  read — so no mark moves under a review in progress. Every decision goes on the draw's
//  corrections ledger before the mark is touched; a ledger that can't be read or written
//  stops the operation. A moved mark changes the intervals the draw was made from: those are
//  audited again under a new draw (protocol §8).
//

import Foundation

extension CoverageAudit {
    /// One boundary error as a proposed edit of the neighbouring mark.
    struct Correction: Codable, Equatable, Identifiable {
        var recordingId: String
        var intervalIndex: Int
        /// `leading`: the mark before the interval ends at `toSec` instead; `trailing`: the mark after it starts at `toSec`.
        var edge: Edge
        /// The neighbouring mark as it is now.
        var markStartSec: Double
        var markEndSec: Double
        var toSec: Double

        var id: String { "\(recordingId)#\(intervalIndex)#\(edge.rawValue)" }
        /// How much the mark grows.
        var addedSec: Double { edge == .leading ? toSec - markEndSec : markStartSec - toSec }
    }

    /// A decision on a correction, as the ledger keeps it.
    struct CorrectionEntry: Codable, Equatable {
        enum Action: String, Codable { case applied, declined }
        var correction: Correction
        var action: Action
        var at: String
    }

    struct Corrections: Equatable {
        var proposals: [Correction] = []
        /// Boundary errors that are not proposals, and why.
        var notProposed: [String] = []
        /// Why nothing may be applied or declined now; nil when the stage is complete.
        var blocked: String?
    }

    enum CorrectionFailure: LocalizedError, Equatable {
        case blocked(String)
        case stale(String)

        var errorDescription: String? {
            switch self {
            case .blocked(let why): return "No correction now: \(why)"
            case .stale(let id): return "\(id) is no longer what the audit's records and the marks propose: reload the corrections."
            }
        }
    }

    /// How near a mark's edge must be to the interval's for it to be the interval's neighbour, in seconds (a tick is 1/600 s).
    private static let neighbourTolerance = 0.01

    static func correctionsLedger(in root: URL, drawId: String) -> URL {
        drawsDirectory(in: root).appendingPathComponent("\(drawId)-corrections.json")
    }

    /// The ledger's entries: none when there is no file yet; throws when it can't be read.
    static func correctionEntries(in root: URL, drawId: String) throws -> [CorrectionEntry] {
        let url = correctionsLedger(in: root, drawId: drawId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([CorrectionEntry].self, from: Data(contentsOf: url))
    }

    private static func write(_ entries: [CorrectionEntry], in root: URL, drawId: String) throws {
        let url = correctionsLedger(in: root, drawId: drawId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    /// Why the draw's stage is not complete, or nil: every recording read without trouble, and no pass owing work.
    static func incompleteness(of statuses: [RecordingStatus]) -> String? {
        if let s = statuses.first(where: { $0.problem != nil }) { return "\(s.recordingId) can't be counted (\(s.problem ?? ""))" }
        let first = statuses.reduce(0) { $0 + $1.firstLeft }, again = statuses.reduce(0) { $0 + $1.repeatLeft }, resolve = statuses.reduce(0) { $0 + $1.resolveLeft }
        guard first + again + resolve > 0 else { return nil }
        return "the review is not finished (\(first) first look(s), \(again) second look(s) and \(resolve) disagreement(s) to go). Corrections wait until it is, so no mark moves under a review in progress"
    }

    /// The boundary errors that count in the draw's records, as proposals against the marks as they are now. Ones
    /// already applied or declined are left out.
    static func corrections(draw: LoadedDraw, root: URL) throws -> Corrections {
        var out = Corrections(blocked: incompleteness(of: try status(draw: draw, root: root)))
        let decided = Set(try correctionEntries(in: root, drawId: draw.draw.drawId).map(\.correction.id))
        let sessions = Dictionary(try sessions(in: root).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for item in try findingsList(draw: draw, root: root).findings where item.kind == .boundaryError {
            let what = "\(item.recordingId) interval \(item.intervalIndex)"
            guard let edge = item.edge, edge == .leading || edge == .trailing, let a = item.approxStartSec, let b = item.approxEndSec, b > a else {
                out.notProposed.append("\(what): the finding does not say which mark or how much (no edge, or no start and end)")
                continue
            }
            guard let session = sessions[item.recordingId], let marks = try RallyTruth.records(inSidecarOf: session.sourceURL) else {
                out.notProposed.append("\(what): no rally marks beside the video")
                continue
            }
            let at = edge == .leading ? item.intervalStartSec : item.intervalEndSec
            guard let mark = marks.first(where: { abs((edge == .leading ? $0.endTime : $0.startTime) - at) <= neighbourTolerance }) else {
                out.notProposed.append("\(what): no mark \(edge == .leading ? "ends" : "starts") where the interval \(edge == .leading ? "starts" : "ends") any more (moved since, or the interval is bounded by a cut range or the recording's edge)")
                continue
            }
            let correction = Correction(recordingId: item.recordingId, intervalIndex: item.intervalIndex, edge: edge, markStartSec: mark.startTime, markEndSec: mark.endTime,
                                        toSec: edge == .leading ? b : a)
            guard correction.addedSec > 0, correction.toSec >= item.intervalStartSec, correction.toSec <= item.intervalEndSec else {
                out.notProposed.append("\(what): the finding's times lie outside the interval")
                continue
            }
            if !decided.contains(correction.id) { out.proposals.append(correction) }
        }
        // Two trims of one interval that cross would make its two neighbours overlap: neither is proposed.
        for (key, pair) in Dictionary(grouping: out.proposals, by: { "\($0.recordingId)#\($0.intervalIndex)" }) where pair.count == 2 {
            guard let lead = pair.first(where: { $0.edge == .leading }), let trail = pair.first(where: { $0.edge == .trailing }), lead.toSec > trail.toSec else { continue }
            out.proposals.removeAll { $0.recordingId == lead.recordingId && $0.intervalIndex == lead.intervalIndex }
            out.notProposed.append("\(key.replacingOccurrences(of: "#", with: " interval ")): its two trims cross (the one before to \(clockText(lead.toSec)), the one after from \(clockText(trail.toSec)))")
        }
        return out
    }

    /// Applies or declines `correction`: on the ledger first, then — applied — the mark's edge moved in the sidecar.
    /// Refused while the stage is incomplete, and when the records and the marks no longer propose exactly this.
    static func decide(_ correction: Correction, _ action: CorrectionEntry.Action, draw: LoadedDraw, root: URL, now: Date = Date()) throws {
        let current = try corrections(draw: draw, root: root)
        if let why = current.blocked { throw CorrectionFailure.blocked(why) }
        guard current.proposals.contains(correction) else { throw CorrectionFailure.stale(correction.id) }
        let drawId = draw.draw.drawId
        let before = try correctionEntries(in: root, drawId: drawId)
        try write(before + [CorrectionEntry(correction: correction, action: action, at: EventReview.stamp(now))], in: root, drawId: drawId)
        guard action == .applied else { return }
        do {
            guard let session = try sessions(in: root).first(where: { $0.name == correction.recordingId }),
                  var marks = try RallyTruth.records(inSidecarOf: session.sourceURL),
                  let i = marks.firstIndex(where: { $0.startTime == correction.markStartSec && $0.endTime == correction.markEndSec }) else {
                throw CorrectionFailure.stale(correction.id)
            }
            if correction.edge == .leading { marks[i].endTime = correction.toSec } else { marks[i].startTime = correction.toSec }
            try RallyMarkModel.write(marks, to: RallyMarkModel.labelsURL(for: session.sourceURL))
        } catch {
            // The mark was not moved: the ledger must not say it was.
            try write(before, in: root, drawId: drawId)
            throw error
        }
    }
}
