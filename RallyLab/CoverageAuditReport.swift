//
//  CoverageAuditReport.swift
//  RallyLab
//
//  What a draw's audit says so far, read from the records — nothing here writes a record
//  or a ledger row, and no video is played: per drawn recording how many intervals are
//  reviewed, the derived state, the findings that count (after the repeat and its
//  resolution), the repeat's progress, and whether the marks moved since the draw
//  (`status`, the Audit tab's list and `RallyLab --coverage-audit-status`); and the
//  findings as a list for the marking pass (`findingsList`), since the audit itself
//  writes no rally mark. A withheld recording in a draw is named and not read.
//

import Foundation

extension CoverageAudit {
    /// One drawn recording's audit as its files say.
    struct RecordingStatus: Equatable, Identifiable, Sendable {
        var id: String { recordingId }
        var recordingId: String
        var surface: String?
        /// The draw's intervals, and how many have a first verdict on the bounds drawn.
        var total: Int
        var reviewed = 0
        /// The intervals owed a second look (the draw's repeat set and the ones first left uncertain), and how many have one
        /// that is finished — a look with findings counts only once the interval has played whole in it.
        var repeatOwed: Int
        var repeatDone = 0
        /// Disagreements between the first and the repeat verdict nobody has resolved.
        var unresolved = 0
        /// Intervals still unmarked as drawn that the repeat pass owes a finished look: in the repeat set, with no repeat
        /// look yet, or one with findings not played whole. A moved interval is not counted: no verdict is taken on it.
        var repeatLeft = 0
        /// Disagreements on intervals still unmarked as drawn without a finished resolution: the resolution pass's work.
        var resolveLeft = 0
        /// Intervals whose findings come from a look that did not cover the interval: not reviewed whole yet.
        var partialLooks = 0
        var state: RecordingState
        /// The findings that count, by kind.
        var findings: [FindingKind: Int] = [:]
        /// The rallies marked in the recording now (what missed rallies and serves are counted against).
        var rallyMarks = 0
        /// Draw intervals that are no longer unmarked intervals as drawn: the marks or cut ranges changed.
        var movedIntervals = 0
        /// Draw intervals still unmarked as drawn that the first look has not finished: no verdict yet, or findings
        /// given before the interval had played whole. The first pass's work left in the recording.
        var firstLeft = 0
        /// Why the recording is not read, or its record does not count; nil when nothing is wrong.
        var problem: String?
    }

    /// What a report judges the draw's recordings against: the withheld closure (an empty one is refused, as
    /// `admit` refuses it), the project's identities, its sessions by name, and the withheld context the live
    /// path-and-content check reads (`EventReview.refusal`, as `admit` applies it) — all read strictly.
    private struct ProjectAsRead {
        let closures: ScoringExposure.Closures
        let sources: [String: ClipSource]
        let sessions: [String: VideoSession]
        let context: EventReview.WithheldContext?

        /// Why the session as it is today may not be read: repointed since the draw at a withheld recording's file, or
        /// at a byte copy of one. The identities the draw froze are `listedRefusal`'s, asked first.
        func liveRefusal(of session: VideoSession) -> String? {
            context.flatMap { EventReview.refusal(of: session, context: $0) }
        }
    }

    private static func projectAsRead(_ root: URL) throws -> ProjectAsRead {
        let closures = try ScoringExposure.Closures.current(in: root)
        guard !closures.withheld.isEmpty else { throw Failure.emptyClosure }
        let all = try sessions(in: root)
        return ProjectAsRead(closures: closures, sources: try ReservedVideos.sources(in: root),
                             sessions: Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }),
                             context: try EventReview.withheldContext(root: root, sessions: all))
    }

    /// Every recording of the draw, in the draw's order. Reads the reservations, the project's identities and the
    /// sessions strictly (anything unreadable throws); a recording's own trouble — withheld, no session, a record
    /// that can't be read or belongs to another draw or file — is its `problem`, and nothing of it is counted.
    static func status(draw: LoadedDraw, root: URL) throws -> [RecordingStatus] {
        let project = try projectAsRead(root)
        return draw.draw.recordings.map { recording in
            var status = RecordingStatus(recordingId: recording.recordingId, surface: recording.surface, total: recording.intervals.count,
                                         repeatOwed: recording.repeatIndices.count, state: state(of: nil, intervals: recording.intervals))
            if let why = listedRefusal(of: recording, closures: project.closures, sources: project.sources) {
                status.problem = "withheld (\(why)) — not read"
                return status
            }
            guard let session = project.sessions[recording.recordingId] else {
                status.problem = "not a recording of this project"
                return status
            }
            if let why = project.liveRefusal(of: session) {
                status.problem = "withheld (\(why)) — not read"
                return status
            }
            var problems: [String] = []
            var current: Set<Span> = []
            do {
                if let marks = try RallyTruth.records(inSidecarOf: session.sourceURL) {
                    status.rallyMarks = RallyTruth(marks: marks.map(RallyTruth.Mark.init), cuts: session.cutRanges, complete: true).positives.count
                    current = Set(unmarkedIntervals(marks: marks, cuts: session.cutRanges, durationTicks: recording.durationTicks).map(\.span))
                    status.movedIntervals = recording.intervals.filter { !current.contains($0.span) }.count
                } else {
                    problems.append("no rally marks beside the video")
                }
            } catch { problems.append("rally marks unreadable") }
            if !session.isOnMac {
                problems.append("the original is not on this Mac")
            } else if ProjectsModel.fileFingerprint(atPath: session.sourcePath) != recording.contentFingerprint {
                problems.append("its file is not the one the draw was made from")
            }
            // The first pass's work left: drawn intervals still unmarked as drawn without a finished first look.
            func firstLeft(_ file: File?) -> Int {
                recording.intervals.filter { interval in
                    guard current.contains(interval.span) else { return false }
                    guard let look = file?.review(interval.index), look.span == interval.span else { return true }
                    return look.playedAllAtMaxRate == nil
                }.count
            }
            status.firstLeft = firstLeft(nil)
            do {
                if let file = try existingRecord(of: recording, video: session.sourceURL, contentFingerprint: recording.contentFingerprint, draw: draw) {
                    status.firstLeft = firstLeft(file)
                    let owed = repeatSet(recording, file: file)
                    status.repeatOwed = owed.count
                    status.repeatDone = owed.filter { file.repeatReview($0)?.playedAllAtMaxRate != nil }.count
                    let asDrawn = Set(recording.intervals.filter { current.contains($0.span) }.map(\.index))
                    status.repeatLeft = owed.filter { asDrawn.contains($0) && file.repeatReview($0)?.playedAllAtMaxRate == nil }.count
                    status.resolveLeft = disagreements(in: file).filter { asDrawn.contains($0) && file.resolution($0)?.playedAllAtMaxRate == nil }.count
                    status.state = state(of: file, intervals: recording.intervals)
                    for interval in recording.intervals where file.review(interval.index)?.span == interval.span {
                        status.reviewed += 1
                        switch standing(of: interval.index, in: file) {
                        case .disputed: status.unresolved += 1
                        case .settled(_, let findings, let playedWhole):
                            for f in findings { status.findings[f.kind, default: 0] += 1 }
                            if !playedWhole { status.partialLooks += 1 }
                        case .unreviewed: break
                        }
                    }
                }
            } catch { problems.append(error.localizedDescription) }
            status.problem = problems.isEmpty ? nil : problems.joined(separator: "; ")
            return status
        }
    }

    /// The findings of `counts` in the kinds' fixed order: "missed_rally 2, uncertain 1"; "none" when there is none.
    static func countsText(_ counts: [FindingKind: Int]) -> String {
        let parts = FindingKind.allCases.compactMap { kind in counts[kind].map { "\(kind.rawValue) \($0)" } }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    /// The status as the headless command prints it: a line per recording, then the totals. The pilot's pass or
    /// fail is not judged here — that is the frozen protocol's evaluation; these are the counts it reads.
    static func statusLines(_ statuses: [RecordingStatus], draw: Draw) -> [String] {
        var lines = ["Coverage audit — draw \(draw.drawId) (\(draw.datasetName)): \(statuses.count) recording(s), \(statuses.reduce(0) { $0 + $1.total }) interval(s)"]
        let width = statuses.map(\.recordingId.count).max() ?? 0
        for s in statuses {
            var line = "  " + s.recordingId.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  \(s.reviewed)/\(s.total) reviewed · \(s.state.text) · repeat \(s.repeatDone)/\(s.repeatOwed)"
            if s.unresolved > 0 { line += " · \(s.unresolved) disagreement(s) unresolved" }
            if s.partialLooks > 0 { line += " · \(s.partialLooks) with findings not played whole" }
            line += " · findings: \(countsText(s.findings))"
            if s.movedIntervals > 0 { line += " · ⚠️ marks changed since the draw: \(s.movedIntervals) interval(s) no longer as drawn" }
            if let problem = s.problem { line += " · ⚠️ \(problem)" }
            lines.append(line)
        }
        var totals: [FindingKind: Int] = [:]
        for s in statuses { for (kind, n) in s.findings { totals[kind, default: 0] += n } }
        let byState = Dictionary(grouping: statuses, by: \.state.name).mapValues(\.count)
        lines.append("Total: \(statuses.reduce(0) { $0 + $1.reviewed })/\(statuses.reduce(0) { $0 + $1.total }) intervals reviewed · "
            + ["audited_clean", "partial", "contaminated"].map { "\($0) \(byState[$0] ?? 0)" }.joined(separator: " · ")
            + " · repeat \(statuses.reduce(0) { $0 + $1.repeatDone })/\(statuses.reduce(0) { $0 + $1.repeatOwed })")
        lines.append("Findings: \(countsText(totals)) · missed rallies + missed serves \((totals[.missedRally] ?? 0) + (totals[.missedServe] ?? 0)) "
            + "against \(statuses.reduce(0) { $0 + $1.rallyMarks }) rally mark(s)")
        return lines
    }

    // MARK: - The findings, for the marking pass

    /// What the audit found, listed for the marking pass: the audit writes no mark.
    struct FindingsList: Codable, Equatable {
        struct Item: Codable, Equatable {
            var recordingId: String
            var intervalIndex: Int
            var intervalStartSec: Double
            var intervalEndSec: Double
            var kind: FindingKind
            var approxStartSec: Double?
            var approxEndSec: Double?
            var edge: Edge?
            var note: String?
        }
        var drawId: String
        var datasetName: String
        var createdAt: String
        var findings: [Item]
        /// What is not in the list, and why: a recording that could not be read, a disagreement nobody resolved.
        var notListed: [String]
    }

    /// Every finding that counts in the draw's records (after the repeat and its resolution), in the draw's order.
    static func findingsList(draw: LoadedDraw, root: URL, now: Date = Date()) throws -> FindingsList {
        let project = try projectAsRead(root)
        var list = FindingsList(drawId: draw.draw.drawId, datasetName: draw.draw.datasetName, createdAt: EventReview.stamp(now), findings: [], notListed: [])
        for recording in draw.draw.recordings {
            let name = recording.recordingId
            if let why = listedRefusal(of: recording, closures: project.closures, sources: project.sources) { list.notListed.append("\(name): withheld (\(why))"); continue }
            guard let session = project.sessions[name] else { list.notListed.append("\(name): not a recording of this project"); continue }
            if let why = project.liveRefusal(of: session) { list.notListed.append("\(name): withheld (\(why))"); continue }
            // The findings' times describe the footage that was reviewed: not listed when the file is another now.
            guard session.isOnMac else { list.notListed.append("\(name): the original is not on this Mac, so its file can't be checked"); continue }
            guard ProjectsModel.fileFingerprint(atPath: session.sourcePath) == recording.contentFingerprint else {
                list.notListed.append("\(name): its file is not the one the draw was made from (replaced since): the findings' times describe other footage")
                continue
            }
            let file: File?
            do { file = try existingRecord(of: recording, video: session.sourceURL, contentFingerprint: recording.contentFingerprint, draw: draw) } catch {
                list.notListed.append("\(name): \(error.localizedDescription)")
                continue
            }
            guard let file else { continue }
            for interval in recording.intervals where file.review(interval.index)?.span == interval.span {
                switch standing(of: interval.index, in: file) {
                case .disputed: list.notListed.append("\(name) interval \(interval.index): the first and the repeat verdict disagree, not resolved")
                case .settled(_, let findings, _):
                    list.findings += findings.map {
                        FindingsList.Item(recordingId: name, intervalIndex: interval.index, intervalStartSec: seconds(interval.startTick), intervalEndSec: seconds(interval.endTick),
                                          kind: $0.kind, approxStartSec: $0.approxStartSec, approxEndSec: $0.approxEndSec, edge: $0.edge, note: $0.note)
                    }
                case .unreviewed: break
                }
            }
        }
        return list
    }

    static func findingsText(_ list: FindingsList) -> String {
        var text = "Coverage-audit findings — draw \(list.drawId) (\(list.datasetName)), \(list.createdAt)\n"
        text += "For the marking pass: what a reviewer found in time no mark covers. The audit wrote no mark.\n"
        for (recording, items) in Dictionary(grouping: list.findings, by: \.recordingId).sorted(by: { $0.key < $1.key }) {
            text += "\n\(recording)\n"
            for item in items {
                var line = "  interval \(item.intervalIndex) (\(clockText(item.intervalStartSec))–\(clockText(item.intervalEndSec)))  \(item.kind.rawValue)"
                if let a = item.approxStartSec { line += "  ~\(clockText(a))" + (item.approxEndSec.map { "–\(clockText($0))" } ?? "") }
                if let edge = item.edge { line += "  edge: \(edge.rawValue)" }
                if let note = item.note, !note.isEmpty { line += "  — \(note)" }
                text += line + "\n"
            }
        }
        if list.findings.isEmpty { text += "\nNo finding recorded.\n" }
        if !list.notListed.isEmpty { text += "\nNot listed:\n" + list.notListed.map { "  \($0)\n" }.joined() }
        return text
    }

    /// Writes the list beside the draw as `<drawId>-findings-<stamp>.json` and `.txt`; never over an existing file.
    static func writeFindings(_ list: FindingsList, in root: URL, stamp: String) throws -> (json: URL, text: URL) {
        let dir = drawsDirectory(in: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = dir.appendingPathComponent("\(list.drawId)-findings-\(stamp).json"), text = dir.appendingPathComponent("\(list.drawId)-findings-\(stamp).txt")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: json, options: .withoutOverwriting)
        try Data(findingsText(list).utf8).write(to: text, options: .withoutOverwriting)
        return (json, text)
    }
}
