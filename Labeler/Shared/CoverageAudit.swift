//
//  CoverageAudit.swift
//  Labeler/Shared — compiled by RallyLab (macOS) and the Labeler iPhone app
//
//  The negative-coverage audit's record (owner, 2026-11-14: "The owner does not waive
//  negative-label verification"): a person watches every *unmarked interval* of a drawn
//  recording — the time no mark of any kind and no cut range covers — and says whether a
//  rally, a missed serve or anything else was left unmarked there. This file is the data:
//
//   - the unmarked intervals of a recording, in ticks at the classifier dataset's
//     timescale (600), from its marks and cut ranges as `RallyTruth` reads them — the
//     same pieces, the same `tick` and the same rally start (the serve contact when one
//     is marked: `RallyClassifierExporter.rallyStart`) the dataset exporter writes, so
//     an interval's bounds are the dataset's rally, excluded-span and cut-range ticks;
//   - the frozen draw (`coverage_audit_draw_v2`, written by
//     scripts/rally_classifier/coverage_audit_draw.py): which recordings, which
//     intervals, which of them are reviewed a second time;
//   - the sidecar `<video>.coverageaudit.json` (`coverage_audit_v2`) beside the marks:
//     one review per interval, the blind repeat, the resolutions of disagreements;
//   - what follows from a record: an interval's standing after the repeat and its
//     resolution, the recording's state (derived, never stored), and `cleanIntervals`,
//     the only time the dataset exporter may trust as not-rally.
//
//  `clean` exists only as a reviewer's explicit verdict on an interval played whole at no
//  more than 2× (`PlayedCoverage`): a record that says clean without it does not read.
//  Nothing here opens a video, runs a model or writes a rally mark. A verdict changes a
//  record only through `applying` (below), the one set of rules both devices use: on the
//  Mac `CoverageAudit.record` (CoverageAuditRecording.swift) wraps it with the admission,
//  the ledger row and the sidecar; on the phone the audit (CoverageAuditPhone.swift) wraps
//  it with the published draw state and the server's save. The unmarked intervals are
//  derived from the marks on the Mac only (CoverageAuditRecording.swift).
//

import CryptoKit
import Foundation

enum CoverageAudit {
    static let annotationVersion = "coverage_audit_v2"
    static let drawVersion = "coverage_audit_draw_v2"
    /// The classifier dataset's clock (RallyClassifierExporter reads it from here, so both count the same ticks).
    static let timescale = 600
    /// Nothing played faster than this earns coverage.
    static let maxCreditRate = 2.0
    /// What is played either side of an interval for context, in seconds (clamped to the recording).
    static let contextSec = 1.0
    /// A repeat by the reviewer who gave the first verdict is accepted this long after it, not before.
    static let sameReviewerWait: TimeInterval = 24 * 3600

    static func tick(_ seconds: Double) -> Int { Int((seconds * Double(timescale)).rounded(.toNearestOrEven)) }
    static func seconds(_ tick: Int) -> Double { Double(tick) / Double(timescale) }

    /// Ticks `startTick ..< endTick`.
    struct Span: Codable, Equatable, Hashable {
        var startTick: Int
        var endTick: Int
        var ticks: Int { max(0, endTick - startTick) }
    }

    /// An unmarked interval of a recording, numbered in time order from 0.
    struct Interval: Codable, Equatable, Hashable {
        var index: Int
        var startTick: Int
        var endTick: Int
        var span: Span { Span(startTick: startTick, endTick: endTick) }
    }

    // MARK: - The draw

    /// The frozen sample (`coverage_audit_draw_v2`). Only what the review needs is read, and that strictly; the
    /// draw's other fields (hashes, seed, the recordings not drawn) are the draw tool's and are left alone.
    struct Draw: Decodable, Equatable {
        struct Dataset: Decodable, Equatable {
            var name: String
            var timescale: Int
        }

        struct Recording: Decodable, Equatable {
            var recordingId: String
            var groupId: String
            /// The identity the dataset carries for the recording's card (a link's id, or the file it was registered from).
            var fingerprint: String?
            var sourceId: String?
            /// The content fingerprint (`ProjectsModel.fileFingerprint`) of the recording's file when the draw was made.
            var contentFingerprint: String
            var marksSha256: String
            var durationTicks: Int
            var intervals: [Interval]
            /// The intervals reviewed a second time (the blind repeat), by index.
            var repeatIndices: [Int]
            var surface: String?

            func interval(_ index: Int) -> Interval? { intervals.first { $0.index == index } }
        }

        var schemaVersion: String
        var drawId: String
        var dataset: Dataset
        var recordings: [Recording]
        /// The earlier draws of the same stage this one replaces (the draw tool writes them with its `--reason`): a
        /// record of one of them is set aside, kept whole, when a recording is opened under this draw.
        var supersedes: [String]?

        var datasetName: String { dataset.name }

        func recording(_ id: String) -> Recording? { recordings.first { $0.recordingId == id } }
    }

    /// A draw file as read: its content, where it is, and the SHA-256 of its bytes (what a record is bound to).
    struct LoadedDraw: Equatable {
        let draw: Draw
        let url: URL
        let sha256: String
    }

    /// Where a project keeps its draws.
    static func drawsDirectory(in root: URL) -> URL { root.appendingPathComponent("manifests/coverage-audit", isDirectory: true) }

    /// Reads and checks a draw file: the version, the timescale, one entry per recording, each recording's
    /// intervals numbered from 0 in time order without overlap inside the recording, the repeat a subset of them.
    static func loadDraw(_ url: URL) throws -> LoadedDraw {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.drawUnreadable(error.localizedDescription) }
        return try loadDraw(data, url: url)
    }

    /// The same checks on a draw's bytes (the phone has them from the server, published by the Mac); `url` is where they are kept.
    static func loadDraw(_ data: Data, url: URL) throws -> LoadedDraw {
        guard let head = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.drawUnreadable("not a JSON object") }
        let version = head["schemaVersion"] as? String ?? "(none)"
        guard version == drawVersion else { throw Failure.drawUnreadable("schemaVersion \(version); this build reads \(drawVersion) only") }
        let draw: Draw
        do { draw = try JSONDecoder().decode(Draw.self, from: data) } catch { throw Failure.drawUnreadable(String(describing: error)) }
        guard draw.dataset.timescale == timescale else { throw Failure.drawUnreadable("timescale \(draw.dataset.timescale), not \(timescale)") }
        guard !draw.drawId.isEmpty, !draw.datasetName.isEmpty else { throw Failure.drawUnreadable("no drawId or dataset name") }
        guard Set(draw.recordings.map(\.recordingId)).count == draw.recordings.count else { throw Failure.drawUnreadable("a recording is listed twice") }
        for r in draw.recordings {
            guard r.durationTicks > 0 else { throw Failure.drawUnreadable("\(r.recordingId): durationTicks must be positive") }
            var cursor = 0
            for (i, interval) in r.intervals.enumerated() {
                guard interval.index == i, interval.startTick >= cursor, interval.startTick < interval.endTick, interval.endTick <= r.durationTicks else {
                    throw Failure.drawUnreadable("\(r.recordingId): interval \(i) is out of order, empty, overlapping or outside the recording")
                }
                cursor = interval.endTick
            }
            guard Set(r.repeatIndices).count == r.repeatIndices.count, r.repeatIndices.allSatisfy({ r.intervals.indices.contains($0) }) else {
                throw Failure.drawUnreadable("\(r.recordingId): the repeat set is not a set of its interval indices")
            }
        }
        return LoadedDraw(draw: draw, url: url, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - The record

    enum Verdict: String, Codable { case clean, notClean = "not_clean" }

    enum FindingKind: String, Codable, CaseIterable {
        /// A serve contact followed by play that no mark covers, including one clipped by the recording's start or end.
        case missedRally = "missed_rally"
        /// A served ball that does not become a rally, that no mark covers.
        case missedServe = "missed_serve"
        /// The neighbouring mark starts after the serve contact or ends before the ball is dead by more than 1.0 s.
        case boundaryError = "boundary_error"
        /// Ball in flight that is not a rally: pepper, drills, warm-up hitting, toss-and-catch, a ball rolled back.
        case nonRallyActivity = "non_rally_activity"
        /// Replay, slow motion, montage, camera cut, black frames, an overlay covering play.
        case editedFootage = "edited_footage"
        /// Cannot tell (occlusion, file edge, artefact); needs a note.
        case uncertain

        /// The edges a finding of this kind may carry: a missed rally clipped by the recording's start or end; a
        /// boundary error at the mark before the interval (`leading`: it ends early) or after it (`trailing`: it starts late).
        var edges: [Edge] {
            switch self {
            case .missedRally: return [.start, .end]
            case .boundaryError: return [.leading, .trailing]
            default: return []
            }
        }
    }

    enum Edge: String, Codable { case start, end, leading, trailing }

    struct Finding: Codable, Equatable {
        var kind: FindingKind
        /// Seconds of the recording, to about a second.
        var approxStartSec: Double?
        var approxEndSec: Double?
        var edge: Edge?
        var note: String?
    }

    /// The first review of one interval.
    struct Review: Codable, Equatable {
        var index: Int
        var startTick: Int
        var endTick: Int
        var verdict: Verdict
        var reviewer: String
        var reviewedAt: String
        /// Set when the whole interval was played before the verdict: the fastest rate any of it was played at.
        /// A `clean` has it always; a `not_clean` without it has findings from a partial look.
        var playedAllAtMaxRate: Double?
        var findings: [Finding] = []

        var span: Span { Span(startTick: startTick, endTick: endTick) }

        init(index: Int, startTick: Int, endTick: Int, verdict: Verdict, reviewer: String, reviewedAt: String, playedAllAtMaxRate: Double?, findings: [Finding] = []) {
            (self.index, self.startTick, self.endTick, self.verdict) = (index, startTick, endTick, verdict)
            (self.reviewer, self.reviewedAt, self.playedAllAtMaxRate, self.findings) = (reviewer, reviewedAt, playedAllAtMaxRate, findings)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = try c.decode(Int.self, forKey: .index)
            startTick = try c.decode(Int.self, forKey: .startTick)
            endTick = try c.decode(Int.self, forKey: .endTick)
            verdict = try c.decode(Verdict.self, forKey: .verdict)
            reviewer = try c.decode(String.self, forKey: .reviewer)
            reviewedAt = try c.decode(String.self, forKey: .reviewedAt)
            playedAllAtMaxRate = try c.decodeIfPresent(Double.self, forKey: .playedAllAtMaxRate)
            findings = try c.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        }
    }

    /// A second look at an interval of the repeat set, made without the first verdict in view.
    struct RepeatReview: Codable, Equatable {
        var index: Int
        var verdict: Verdict
        var reviewer: String
        var reviewedAt: String
        var playedAllAtMaxRate: Double?
        var findings: [Finding] = []

        init(index: Int, verdict: Verdict, reviewer: String, reviewedAt: String, playedAllAtMaxRate: Double?, findings: [Finding] = []) {
            (self.index, self.verdict, self.reviewer, self.reviewedAt, self.playedAllAtMaxRate, self.findings) = (index, verdict, reviewer, reviewedAt, playedAllAtMaxRate, findings)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = try c.decode(Int.self, forKey: .index)
            verdict = try c.decode(Verdict.self, forKey: .verdict)
            reviewer = try c.decode(String.self, forKey: .reviewer)
            reviewedAt = try c.decode(String.self, forKey: .reviewedAt)
            playedAllAtMaxRate = try c.decodeIfPresent(Double.self, forKey: .playedAllAtMaxRate)
            findings = try c.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        }
    }

    struct Repeat: Codable, Equatable {
        static let secondReviewer = "second_reviewer"
        static let sameReviewer = "same_reviewer_after_24h"
        /// `second_reviewer` only when no repeat verdict is by the reviewer who gave that interval's first one;
        /// otherwise `same_reviewer_after_24h`, which is never independent inter-rater agreement.
        var method: String
        var intervals: [RepeatReview]
    }

    /// A disagreement between the first and the repeat verdict, settled by a third look with both in view: what counts.
    struct Resolution: Codable, Equatable {
        var index: Int
        var verdict: Verdict
        var findings: [Finding] = []
        var reviewer: String
        var resolvedAt: String
        var playedAllAtMaxRate: Double?
        var note: String?

        init(index: Int, verdict: Verdict, findings: [Finding] = [], reviewer: String, resolvedAt: String, playedAllAtMaxRate: Double?, note: String? = nil) {
            (self.index, self.verdict, self.findings, self.reviewer) = (index, verdict, findings, reviewer)
            (self.resolvedAt, self.playedAllAtMaxRate, self.note) = (resolvedAt, playedAllAtMaxRate, note)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = try c.decode(Int.self, forKey: .index)
            verdict = try c.decode(Verdict.self, forKey: .verdict)
            findings = try c.decodeIfPresent([Finding].self, forKey: .findings) ?? []
            reviewer = try c.decode(String.self, forKey: .reviewer)
            resolvedAt = try c.decode(String.self, forKey: .resolvedAt)
            playedAllAtMaxRate = try c.decodeIfPresent(Double.self, forKey: .playedAllAtMaxRate)
            note = try c.decodeIfPresent(String.self, forKey: .note)
        }
    }

    /// `<video>.coverageaudit.json`. Never written by live tagging or the phone sync.
    struct File: Codable, Equatable {
        var annotationVersion = CoverageAudit.annotationVersion
        var recordingId: String
        /// The content fingerprint of the recording's file as it was reviewed; the record is void for any other file.
        var sourceFingerprint: String
        var drawId: String
        var drawSha256: String
        var datasetName: String
        /// The marks sidecar's SHA-256 at the last verdict.
        var marksSha256: String
        var timescale = CoverageAudit.timescale
        /// No ball path, detector output or pipeline result was on screen. A record that says otherwise does not read.
        var blindToPipeline = true
        var tool: String
        var intervals: [Review] = []
        var repeatPass: Repeat?
        var resolutions: [Resolution] = []

        enum CodingKeys: String, CodingKey {
            case annotationVersion, recordingId, sourceFingerprint, drawId, drawSha256, datasetName, marksSha256, timescale, blindToPipeline, tool, intervals, resolutions
            case repeatPass = "repeat"
        }

        init(recordingId: String, sourceFingerprint: String, drawId: String, drawSha256: String, datasetName: String, marksSha256: String, tool: String) {
            (self.recordingId, self.sourceFingerprint, self.drawId, self.drawSha256) = (recordingId, sourceFingerprint, drawId, drawSha256)
            (self.datasetName, self.marksSha256, self.tool) = (datasetName, marksSha256, tool)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            annotationVersion = try c.decode(String.self, forKey: .annotationVersion)
            recordingId = try c.decode(String.self, forKey: .recordingId)
            sourceFingerprint = try c.decode(String.self, forKey: .sourceFingerprint)
            drawId = try c.decode(String.self, forKey: .drawId)
            drawSha256 = try c.decode(String.self, forKey: .drawSha256)
            datasetName = try c.decode(String.self, forKey: .datasetName)
            marksSha256 = try c.decode(String.self, forKey: .marksSha256)
            timescale = try c.decode(Int.self, forKey: .timescale)
            blindToPipeline = try c.decode(Bool.self, forKey: .blindToPipeline)
            tool = try c.decode(String.self, forKey: .tool)
            intervals = try c.decodeIfPresent([Review].self, forKey: .intervals) ?? []
            repeatPass = try c.decodeIfPresent(Repeat.self, forKey: .repeatPass)
            resolutions = try c.decodeIfPresent([Resolution].self, forKey: .resolutions) ?? []
        }

        func review(_ index: Int) -> Review? { intervals.first { $0.index == index } }
        func repeatReview(_ index: Int) -> RepeatReview? { repeatPass?.intervals.first { $0.index == index } }
        func resolution(_ index: Int) -> Resolution? { resolutions.first { $0.index == index } }
    }

    /// Which look at an interval: the first review, the blind repeat, or the resolution of their disagreement.
    enum Pass: String, CaseIterable, Codable, Sendable {
        case first
        case repeatLook = "repeat"
        case resolution
    }

    /// What a reviewer does to one interval in one pass.
    enum Entry: Equatable, Sendable {
        /// Nothing was left unmarked here. Only for an interval played whole.
        case clean
        /// Something was: added to the interval's findings (the interval is `not_clean`).
        case finding(Finding)
        /// The interval has now been played whole under its findings: recorded on the `not_clean` verdict, which
        /// until then holds findings from a partial look (and leaves the recording partial).
        case playedWhole
        /// Takes back the last finding added — or the verdict, when it is a clean or holds one finding.
        case withdrawLast
        /// Takes back the pass's whole verdict on the interval.
        case withdraw

        /// Gives or adds to a verdict (anything but taking one back).
        var adds: Bool { self != .withdraw && self != .withdrawLast }
    }

    struct Request: Sendable {
        var recordingId: String
        var index: Int
        var pass: Pass
        var entry: Entry
        var reviewer: String
        /// What the reviewer has played of the recording in this look.
        var played = PlayedCoverage()
        /// A resolution's note.
        var note: String?
    }

    /// One look's verdict on an interval, whichever pass holds it.
    struct Look: Equatable {
        var verdict: Verdict
        var findings: [Finding]
        var reviewer: String
        var at: String
        var playedAllAtMaxRate: Double?
    }

    /// `entry` applied to what a pass holds for `interval` (nil: nothing yet): the look as it becomes, nil when it is
    /// withdrawn. `clean` needs the interval played whole and no findings under it; a finding must be well-formed
    /// and lie in the interval (a second either side allowed, the context the reviewer was shown).
    static func applied(_ entry: Entry, to existing: Look?, interval: Interval, played: PlayedCoverage, reviewer: String, at: String) throws -> Look? {
        // A look is its reviewer's: what they saw, how much of it they played, when. Another person changes nothing of
        // it — not a finding, not its completion, not its withdrawal — so no one's viewing is ever counted for another.
        if let existing, existing.reviewer != reviewer { throw Failure.othersLook(index: interval.index, reviewer: existing.reviewer) }
        let whole = played.covers(interval.span) ? played.maxRate : nil
        switch entry {
        case .clean:
            if existing?.verdict == .notClean { throw Failure.hasFindings(index: interval.index) }
            guard let whole else {
                throw Failure.notPlayed(index: interval.index, missingSec: seconds(interval.span.ticks - played.playedTicks(in: interval.span)))
            }
            return Look(verdict: .clean, findings: [], reviewer: reviewer, at: at, playedAllAtMaxRate: whole)
        case .finding(let finding):
            if finding.kind == .uncertain, (finding.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Failure.uncertainWithoutNote }
            if let why = problem(finding) { throw Failure.badFinding(why) }
            let shown = (seconds(interval.startTick) - contextSec - 0.01)...(seconds(interval.endTick) + contextSec + 0.01)
            guard [finding.approxStartSec, finding.approxEndSec].compactMap({ $0 }).allSatisfy(shown.contains) else {
                throw Failure.badFinding("its approximate time is outside interval \(interval.index)")
            }
            let kept = existing?.verdict == .notClean ? existing?.findings ?? [] : []
            return Look(verdict: .notClean, findings: kept + [finding], reviewer: reviewer, at: at, playedAllAtMaxRate: whole ?? existing?.playedAllAtMaxRate)
        case .playedWhole:
            guard var look = existing, look.verdict == .notClean else { throw Failure.noFindings(index: interval.index) }
            guard let whole else {
                throw Failure.notPlayed(index: interval.index, missingSec: seconds(interval.span.ticks - played.playedTicks(in: interval.span)))
            }
            look.playedAllAtMaxRate = whole
            return look
        case .withdrawLast:
            guard var look = existing else { throw Failure.nothingToWithdraw(index: interval.index) }
            guard look.verdict == .notClean, look.findings.count > 1 else { return nil }
            look.findings.removeLast()
            return look
        case .withdraw:
            guard existing != nil else { throw Failure.nothingToWithdraw(index: interval.index) }
            return nil
        }
    }

    // MARK: - Applying a verdict

    /// `request`'s entry, by `reviewer`, applied to `file` for the draw's `interval` of `recording`: the record as it
    /// becomes, validated. The rules both devices apply — clean only over an interval played whole at 2× or slower
    /// and without findings, a look changed only by its own reviewer, a first look frozen under a later one, the
    /// repeat only in the repeat set after a first verdict and, by the first reviewer, a day after it, a resolution
    /// only where the two looks disagree. What a device must check besides (the recording admitted, the interval
    /// still as drawn, the ledger) is its caller's.
    static func applying(_ request: Request, reviewer: String, to file: File, interval: Interval, recording: Draw.Recording, now: Date) throws -> File {
        var file = file
        let index = interval.index
        let adds = request.entry.adds
        let at = EventReview.stamp(now)
        func apply(to existing: Look?) throws -> Look? {
            try applied(request.entry, to: existing, interval: interval, played: request.played, reviewer: reviewer, at: at)
        }

        switch request.pass {
        case .first:
            // Playing an unfinished look to its end changes no verdict, finding or time, so it is taken beneath a later look.
            if file.repeatReview(index) != nil, request.entry != .playedWhole { throw Failure.frozen(index: index, by: "repeat verdict") }
            let next = try apply(to: file.review(index).map {
                Look(verdict: $0.verdict, findings: $0.findings, reviewer: $0.reviewer, at: $0.reviewedAt, playedAllAtMaxRate: $0.playedAllAtMaxRate)
            })
            file.intervals.removeAll { $0.index == index }
            if let next {
                file.intervals.append(Review(index: index, startTick: interval.startTick, endTick: interval.endTick, verdict: next.verdict, reviewer: next.reviewer,
                                             reviewedAt: next.at, playedAllAtMaxRate: next.playedAllAtMaxRate, findings: next.findings))
                file.intervals.sort { $0.index < $1.index }
            }
        case .repeatLook:
            guard let first = file.review(index) else { throw Failure.noFirstVerdict(index: index) }
            guard repeatSet(recording, file: file).contains(index) else { throw Failure.notInRepeatSet(index: index) }
            if file.resolution(index) != nil, request.entry != .playedWhole { throw Failure.frozen(index: index, by: "resolution") }
            // The first reviewer's own second look is blind only once the first is a day old.
            if adds, reviewer == first.reviewer, let firstAt = date(first.reviewedAt), now.timeIntervalSince(firstAt) < sameReviewerWait {
                throw Failure.sameReviewerTooSoon(index: index, acceptedFrom: EventReview.stamp(firstAt.addingTimeInterval(sameReviewerWait)))
            }
            let next = try apply(to: file.repeatReview(index).map {
                Look(verdict: $0.verdict, findings: $0.findings, reviewer: $0.reviewer, at: $0.reviewedAt, playedAllAtMaxRate: $0.playedAllAtMaxRate)
            })
            var looks = (file.repeatPass?.intervals ?? []).filter { $0.index != index }
            if let next {
                looks.append(RepeatReview(index: index, verdict: next.verdict, reviewer: next.reviewer, reviewedAt: next.at,
                                          playedAllAtMaxRate: next.playedAllAtMaxRate, findings: next.findings))
            }
            file.repeatPass = looks.isEmpty ? nil : Repeat(method: Repeat.secondReviewer, intervals: looks.sorted { $0.index < $1.index })
            let method = repeatMethod(of: file)
            file.repeatPass?.method = method
        case .resolution:
            guard let first = file.review(index), let second = file.repeatReview(index),
                  !agree((first.verdict, first.findings), (second.verdict, second.findings)) else { throw Failure.noDisagreement(index: index) }
            let before = file.resolution(index)
            let next = try apply(to: before.map {
                Look(verdict: $0.verdict, findings: $0.findings, reviewer: $0.reviewer, at: $0.resolvedAt, playedAllAtMaxRate: $0.playedAllAtMaxRate)
            })
            file.resolutions.removeAll { $0.index == index }
            if let next {
                let note = request.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                file.resolutions.append(Resolution(index: index, verdict: next.verdict, findings: next.findings, reviewer: next.reviewer, resolvedAt: next.at,
                                                   playedAllAtMaxRate: next.playedAllAtMaxRate, note: (note ?? "").isEmpty ? before?.note : note))
                file.resolutions.sort { $0.index < $1.index }
            }
        }

        try validate(file)
        return file
    }

    // MARK: - Failures

    enum Failure: LocalizedError, Equatable {
        case drawUnreadable(String)
        case unsupportedVersion(String)
        case unreadable(String)
        case invalid(String)
        case emptyClosure
        case withheld(name: String, reason: String)
        case notInDraw(String)
        case intervalNotInDraw(recording: String, index: Int)
        case noSession(String)
        case notComplete(String)
        case videoMissing(String)
        case sourceChanged(recording: String, draw: String, current: String)
        case marksUnreadable(String)
        case marksChanged(recording: String, index: Int)
        case otherDraw(recording: String, recorded: String, given: String)
        case wrongRecord(expected: String, found: String)
        case notPlayed(index: Int, missingSec: Double)
        case hasFindings(index: Int)
        case uncertainWithoutNote
        case badFinding(String)
        case noReviewer
        case notInRepeatSet(index: Int)
        case noFirstVerdict(index: Int)
        case sameReviewerTooSoon(index: Int, acceptedFrom: String)
        case noDisagreement(index: Int)
        case frozen(index: Int, by: String)
        case nothingToWithdraw(index: Int)
        case noFindings(index: Int)
        case othersLook(index: Int, reviewer: String)
        case supersededRecordKept(path: String)
        case ledgerNotWritten(String)
        /// The phone: the recording may not be reviewed on this device now (CoverageAuditPhone.unavailable).
        case notOnThisDevice(recording: String, why: String)

        var errorDescription: String? {
            switch self {
            case .drawUnreadable(let why): return "The draw file can't be used: \(why)."
            case .unsupportedVersion(let v): return "coverageaudit.json is annotationVersion \(v); this build reads \(CoverageAudit.annotationVersion) only."
            case .unreadable(let why): return "coverageaudit.json can't be read: \(why)"
            case .invalid(let why): return "coverageaudit.json is not valid: \(why)"
            case .emptyClosure: return "The withheld closure is empty (no validation.json reservations): an empty closure proves nothing, so nothing is audited."
            case .withheld(let name, let reason): return "\(name) is withheld (\(reason)): no withheld recording, or alias of one, is opened for the coverage audit."
            case .notInDraw(let name): return "\(name) is not one of the draw's recordings: only drawn recordings are audited."
            case .intervalNotInDraw(let recording, let index): return "\(recording) has no interval \(index) in the draw."
            case .noSession(let name): return "\(name) is not a recording of this project."
            case .notComplete(let name): return "\(name)'s pass is not declared complete (not every rally marked): the audit is for declared-complete recordings."
            case .videoMissing(let path): return "The original video is not here (\(path)); the audit needs it, not a review copy."
            case .sourceChanged(let recording, let draw, let current):
                return "\(recording)'s file is not the one the draw was made from (\(draw.prefix(21))… → \(current.prefix(21))…): nothing is recorded against another file."
            case .marksUnreadable(let why): return "The recording's rally marks can't be read: \(why)"
            case .marksChanged(let recording, let index):
                return "\(recording)'s marks or cut ranges changed since the draw: interval \(index) is no longer an unmarked interval as drawn. A new draw (or stage) is needed for it."
            case .otherDraw(let recording, let recorded, let given):
                return "\(recording) already has an audit record from draw \(recorded); this is draw \(given). One record belongs to one draw."
            case .wrongRecord(let expected, let found): return "coverageaudit.json belongs to \(found), not \(expected)."
            case .notPlayed(let index, let missing):
                return String(format: "Interval %d has not been played whole at 2× or slower (%.1f s to go): clean is only for an interval watched from start to end. Seeking earns nothing.", index, missing)
            case .hasFindings(let index): return "Interval \(index) has findings; withdraw them before calling it clean."
            case .uncertainWithoutNote: return "An uncertain interval needs a note saying what could not be told."
            case .badFinding(let why): return "The finding is not valid: \(why)."
            case .noReviewer: return "No reviewer: sign in as a labeler, or type your name."
            case .notInRepeatSet(let index): return "Interval \(index) is not in the repeat set (the draw's repeat intervals and the ones first left uncertain)."
            case .noFirstVerdict(let index): return "Interval \(index) has no first verdict yet."
            case .sameReviewerTooSoon(let index, let from):
                return "You gave interval \(index)'s first verdict less than 24 hours ago: your own repeat is accepted from \(from), or have a second reviewer do it."
            case .noDisagreement(let index): return "Interval \(index)'s first and repeat verdicts do not disagree: there is nothing to resolve."
            case .frozen(let index, let by): return "Interval \(index) has a \(by); withdraw that first."
            case .nothingToWithdraw(let index): return "Interval \(index) has nothing to withdraw in this pass."
            case .noFindings(let index): return "Interval \(index) has no findings in this pass to complete by playing it whole."
            case .supersededRecordKept(let path): return "A record of the superseded draw is already kept at \(path); nothing is moved over it."
            case .othersLook(let index, let reviewer): return "Interval \(index)'s look in this pass is \(reviewer)'s: only \(reviewer) can change, complete or withdraw it."
            case .ledgerNotWritten(let why): return "The exposure ledger could not record this audit, so nothing is saved: \(why)"
            case .notOnThisDevice(let recording, let why): return "\(recording) can't be reviewed on this phone now: \(why)."
            }
        }
    }

    // MARK: - File location, reading, writing

    static func url(forVideo video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("coverageaudit.json")
    }

    /// Where a record of a superseded draw is kept once a replacement draw opens its recording: beside the video,
    /// under that draw's id. Nothing reads it as a record of the recording any more; it stays as evidence.
    static func supersededURL(forVideo video: URL, drawId: String) -> URL {
        video.deletingPathExtension().appendingPathExtension("coverageaudit.\(drawId).json")
    }

    static func read(_ url: URL) throws -> File {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.unreadable(error.localizedDescription) }
        // The version first, so a file from another build is refused whole, never half-read.
        guard let head = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable("not a JSON object") }
        let version = head["annotationVersion"] as? String ?? "(none)"
        guard version == annotationVersion else { throw Failure.unsupportedVersion(version) }
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch { throw Failure.unreadable(String(describing: error)) }
        try validate(file)
        return file
    }

    /// Validates, then writes the whole file atomically (a temporary file renamed into place): a reader sees the
    /// previous record or the new one, never a partial write.
    static func write(_ file: File, to url: URL) throws {
        try validate(file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }

    // MARK: - Rules

    static func date(_ stamp: String) -> Date? { ISO8601DateFormatter().date(from: stamp) }

    /// Why a verdict with these findings is not a valid one, or nil. `clean` has no finding and was played whole at
    /// no more than 2×; `not_clean` has at least one finding, each well-formed; an `uncertain` finding has a note.
    static func problem(verdict: Verdict, findings: [Finding], playedAllAtMaxRate: Double?) -> String? {
        if let rate = playedAllAtMaxRate, !(rate > 0 && rate <= maxCreditRate) { return "playedAllAtMaxRate \(rate) is not in (0, \(maxCreditRate)]" }
        switch verdict {
        case .clean:
            if !findings.isEmpty { return "a clean interval carries findings" }
            if playedAllAtMaxRate == nil { return "a clean interval that was not played whole" }
        case .notClean:
            if findings.isEmpty { return "a not_clean interval without a finding" }
        }
        for f in findings {
            if let why = problem(f) { return why }
        }
        return nil
    }

    static func problem(_ f: Finding) -> String? {
        for t in [f.approxStartSec, f.approxEndSec].compactMap({ $0 }) where !(t.isFinite && t >= 0) { return "an approximate time is not a time" }
        if let a = f.approxStartSec, let b = f.approxEndSec, b < a { return "a finding ends before it starts" }
        if let edge = f.edge, !f.kind.edges.contains(edge) { return "\(f.kind.rawValue) cannot carry edge \(edge.rawValue)" }
        if f.kind == .uncertain, (f.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "an uncertain finding without a note" }
        return nil
    }

    /// Whether two verdicts on one interval say the same: the verdict, and the kinds found (each as often).
    static func agree(_ a: (Verdict, [Finding]), _ b: (Verdict, [Finding])) -> Bool {
        a.0 == b.0 && a.1.map(\.kind.rawValue).sorted() == b.1.map(\.kind.rawValue).sorted()
    }

    /// The repeat's method as recorded: independent only when no repeat verdict is the first reviewer's own.
    static func repeatMethod(of file: File) -> String {
        let own = (file.repeatPass?.intervals ?? []).contains { r in file.review(r.index)?.reviewer == r.reviewer }
        return own ? Repeat.sameReviewer : Repeat.secondReviewer
    }

    static func validate(_ file: File) throws {
        guard file.annotationVersion == annotationVersion else { throw Failure.unsupportedVersion(file.annotationVersion) }
        func invalid(_ why: String) -> Failure { .invalid(why) }
        guard file.timescale == timescale else { throw invalid("timescale \(file.timescale), not \(timescale)") }
        guard file.blindToPipeline else { throw invalid("blindToPipeline is false: a review with predictions in view is not an audit record") }
        guard !file.recordingId.isEmpty, !file.sourceFingerprint.isEmpty, !file.drawId.isEmpty, !file.drawSha256.isEmpty else {
            throw invalid("recordingId, sourceFingerprint, drawId and drawSha256 are required")
        }
        guard Set(file.intervals.map(\.index)).count == file.intervals.count else { throw invalid("an interval is reviewed twice") }
        for r in file.intervals {
            guard r.index >= 0, r.startTick >= 0, r.startTick < r.endTick else { throw invalid("interval \(r.index) has no extent") }
            guard !r.reviewer.isEmpty, date(r.reviewedAt) != nil else { throw invalid("interval \(r.index) has no reviewer or time") }
            if let why = problem(verdict: r.verdict, findings: r.findings, playedAllAtMaxRate: r.playedAllAtMaxRate) { throw invalid("interval \(r.index): \(why)") }
        }
        let repeats = file.repeatPass?.intervals ?? []
        guard Set(repeats.map(\.index)).count == repeats.count else { throw invalid("an interval is repeated twice") }
        for r in repeats {
            guard let first = file.review(r.index) else { throw invalid("repeat of interval \(r.index), which has no first verdict") }
            guard !r.reviewer.isEmpty, let at = date(r.reviewedAt), let firstAt = date(first.reviewedAt) else { throw invalid("repeat \(r.index) has no reviewer or time") }
            if let why = problem(verdict: r.verdict, findings: r.findings, playedAllAtMaxRate: r.playedAllAtMaxRate) { throw invalid("repeat \(r.index): \(why)") }
            if r.reviewer == first.reviewer, at.timeIntervalSince(firstAt) < sameReviewerWait {
                throw invalid("repeat \(r.index) is by the first reviewer less than 24 h after the first verdict")
            }
        }
        if let pass = file.repeatPass {
            guard pass.method == repeatMethod(of: file) else { throw invalid("repeat.method \(pass.method) is not what its reviewers make it (\(repeatMethod(of: file)))") }
        }
        guard Set(file.resolutions.map(\.index)).count == file.resolutions.count else { throw invalid("an interval is resolved twice") }
        for r in file.resolutions {
            guard let first = file.review(r.index), let second = file.repeatReview(r.index) else { throw invalid("resolution of interval \(r.index), which has no first and repeat verdict") }
            guard !agree((first.verdict, first.findings), (second.verdict, second.findings)) else { throw invalid("resolution of interval \(r.index), whose verdicts agree") }
            guard !r.reviewer.isEmpty, date(r.resolvedAt) != nil else { throw invalid("resolution \(r.index) has no reviewer or time") }
            if let why = problem(verdict: r.verdict, findings: r.findings, playedAllAtMaxRate: r.playedAllAtMaxRate) { throw invalid("resolution \(r.index): \(why)") }
        }
    }

    // MARK: - What a record says

    /// What counts for one interval once the repeat and its resolution are taken into account.
    enum Standing: Equatable {
        case unreviewed
        /// The first and the repeat verdict disagree and nobody has resolved it: nothing counts yet.
        case disputed
        /// `playedWhole`: the look that counts covered the whole interval (always, for a clean).
        case settled(verdict: Verdict, findings: [Finding], playedWhole: Bool)
    }

    static func standing(of index: Int, in file: File) -> Standing {
        guard let first = file.review(index) else { return .unreviewed }
        if let resolved = file.resolution(index) {
            return .settled(verdict: resolved.verdict, findings: resolved.findings, playedWhole: resolved.playedAllAtMaxRate != nil)
        }
        if let second = file.repeatReview(index), !agree((first.verdict, first.findings), (second.verdict, second.findings)) { return .disputed }
        return .settled(verdict: first.verdict, findings: first.findings, playedWhole: first.playedAllAtMaxRate != nil)
    }

    /// The intervals a second look is owed: the draw's repeat set and every interval the first review left uncertain.
    static func repeatSet(_ recording: Draw.Recording, file: File?) -> [Int] {
        let uncertain = (file?.intervals ?? []).filter { $0.findings.contains { $0.kind == .uncertain } }.map(\.index)
        return Set(recording.repeatIndices).union(uncertain).intersection(recording.intervals.map(\.index)).sorted()
    }

    /// The intervals whose first and repeat verdicts disagree (resolved or not).
    static func disagreements(in file: File) -> [Int] {
        (file.repeatPass?.intervals ?? []).compactMap { second in
            guard let first = file.review(second.index) else { return nil }
            return agree((first.verdict, first.findings), (second.verdict, second.findings)) ? nil : second.index
        }.sorted()
    }

    /// A recording's audit state — derived from the record and the draw's intervals, never stored. `partial`: an
    /// interval of the draw is not reviewed (no verdict, a verdict on other bounds, findings from a look that did
    /// not cover the interval, or a disagreement nobody resolved), or one is `uncertain` or has a `boundary_error`.
    /// `contaminated`: a `missed_rally` or `missed_serve` was found. Contaminated outranks partial; both are told.
    struct RecordingState: Equatable {
        var contaminated: Bool
        var partial: Bool

        var name: String { contaminated ? "contaminated" : partial ? "partial" : "audited_clean" }
        var text: String { contaminated && partial ? "contaminated (and partial)" : name }
    }

    static func state(of file: File?, intervals: [Interval]) -> RecordingState {
        var state = RecordingState(contaminated: false, partial: false)
        for interval in intervals {
            guard let file, let first = file.review(interval.index), first.span == interval.span else { state.partial = true; continue }
            switch standing(of: interval.index, in: file) {
            case .unreviewed, .disputed: state.partial = true
            case .settled(_, let findings, let playedWhole):
                let kinds = Set(findings.map(\.kind))
                if !playedWhole || kinds.contains(.uncertain) || kinds.contains(.boundaryError) { state.partial = true }
                if kinds.contains(.missedRally) || kinds.contains(.missedServe) { state.contaminated = true }
            }
        }
        return state
    }

    /// The intervals the record says are clean once the repeat and its resolution are counted, in time order: the
    /// only time of the recording a dataset may trust as not-rally (with the recording's file unchanged from
    /// `sourceFingerprint`, and intersected with the time that is unmarked now).
    static func cleanIntervals(_ file: File) -> [Span] {
        file.intervals.filter { review in
            if case .settled(.clean, _, true) = standing(of: review.index, in: file) { return true }
            return false
        }.map(\.span).sorted { $0.startTick < $1.startTick }
    }

    // MARK: - Progress

    /// What a recording's record says against the draw, counted the same on the Mac (the status, the Audit tab) and on
    /// the phone. `asDrawn`: the draw's intervals still unmarked as drawn (the Mac from the marks now; the phone as the
    /// Mac last published them) — a moved interval takes no verdict, so no pass owes it work.
    struct Tally: Equatable, Sendable {
        /// The draw's intervals, and how many have a first verdict on the bounds drawn.
        var total = 0
        var reviewed = 0
        /// The intervals owed a second look (the draw's repeat set and the ones first left uncertain), and how many have one
        /// that is finished — a look with findings counts only once the interval has played whole in it.
        var repeatOwed = 0
        var repeatDone = 0
        /// Disagreements between the first and the repeat verdict nobody has resolved.
        var unresolved = 0
        /// Intervals still unmarked as drawn that the repeat pass owes a finished look: in the repeat set, with no repeat
        /// look yet, or one with findings not played whole.
        var repeatLeft = 0
        /// Disagreements on intervals still unmarked as drawn without a finished resolution: the resolution pass's work.
        var resolveLeft = 0
        /// Intervals whose findings come from a look that did not cover the interval: not reviewed whole yet.
        var partialLooks = 0
        var state = RecordingState(contaminated: false, partial: true)
        /// The findings that count, by kind.
        var findings: [FindingKind: Int] = [:]
        /// Draw intervals that are no longer unmarked intervals as drawn: the marks or cut ranges changed.
        var movedIntervals = 0
        /// Draw intervals still unmarked as drawn that the first look has not finished: no verdict yet, or findings
        /// given before the interval had played whole. The first pass's work left in the recording.
        var firstLeft = 0

        /// Work left in `pass`.
        func left(in pass: Pass) -> Int {
            switch pass {
            case .first: return firstLeft
            case .repeatLook: return repeatLeft
            case .resolution: return resolveLeft
            }
        }
    }

    /// The intervals `pass` still owes a finished look, in time order: still unmarked as drawn (`asDrawn`), and —
    /// first: no look on the bounds drawn, or findings from a look that did not play it whole; repeat: in the repeat
    /// set without a finished second look; resolution: a disagreement without a finished resolution.
    static func owed(_ pass: Pass, recording: Draw.Recording, file: File?, asDrawn: Set<Int>) -> [Int] {
        switch pass {
        case .first:
            return recording.intervals.filter { interval in
                guard asDrawn.contains(interval.index) else { return false }
                guard let look = file?.review(interval.index), look.span == interval.span else { return true }
                return look.playedAllAtMaxRate == nil
            }.map(\.index)
        case .repeatLook:
            guard let file else { return [] }
            return repeatSet(recording, file: file).filter { asDrawn.contains($0) && file.repeatReview($0)?.playedAllAtMaxRate == nil }
        case .resolution:
            guard let file else { return [] }
            return disagreements(in: file).filter { asDrawn.contains($0) && file.resolution($0)?.playedAllAtMaxRate == nil }
        }
    }

    static func tally(of recording: Draw.Recording, file: File?, asDrawn: Set<Int>) -> Tally {
        var t = Tally(total: recording.intervals.count, repeatOwed: recording.repeatIndices.count, state: state(of: file, intervals: recording.intervals))
        t.movedIntervals = recording.intervals.filter { !asDrawn.contains($0.index) }.count
        t.firstLeft = owed(.first, recording: recording, file: file, asDrawn: asDrawn).count
        guard let file else { return t }
        let owedRepeat = repeatSet(recording, file: file)
        t.repeatOwed = owedRepeat.count
        t.repeatDone = owedRepeat.filter { file.repeatReview($0)?.playedAllAtMaxRate != nil }.count
        t.repeatLeft = owed(.repeatLook, recording: recording, file: file, asDrawn: asDrawn).count
        t.resolveLeft = owed(.resolution, recording: recording, file: file, asDrawn: asDrawn).count
        for interval in recording.intervals where file.review(interval.index)?.span == interval.span {
            t.reviewed += 1
            switch standing(of: interval.index, in: file) {
            case .disputed: t.unresolved += 1
            case .settled(_, let findings, let playedWhole):
                for f in findings { t.findings[f.kind, default: 0] += 1 }
                if !playedWhole { t.partialLooks += 1 }
            case .unreviewed: break
            }
        }
        return t
    }

    /// The findings of `counts` in the kinds' fixed order: "missed_rally 2, uncertain 1"; "none" when there is none.
    static func countsText(_ counts: [FindingKind: Int]) -> String {
        let parts = FindingKind.allCases.compactMap { kind in counts[kind].map { "\(kind.rawValue) \($0)" } }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    // MARK: - Played coverage

    /// The ticks of a recording a reviewer has played forward at no more than 2×. Seeking adds nothing: only
    /// `credit` grows it, and it takes a stretch that was played.
    struct PlayedCoverage: Equatable {
        private(set) var spans: [Span] = []
        /// The fastest rate any credited stretch was played at.
        private(set) var maxRate = 0.0

        /// Credits ticks `from ..< to`, played forward at `rate`. Nothing for a rate above 2× or a stretch with no extent.
        mutating func credit(fromTick from: Int, toTick to: Int, rate: Double) {
            guard rate > 0, rate <= CoverageAudit.maxCreditRate, to > from else { return }
            var merged: [Span] = []
            var mine = Span(startTick: from, endTick: to)
            for s in spans {
                if s.endTick < mine.startTick || s.startTick > mine.endTick { merged.append(s) }
                else { mine = Span(startTick: min(s.startTick, mine.startTick), endTick: max(s.endTick, mine.endTick)) }
            }
            merged.append(mine)
            spans = merged.sorted { $0.startTick < $1.startTick }
            maxRate = max(maxRate, rate)
        }

        func playedTicks(in span: Span) -> Int {
            spans.reduce(0) { $0 + max(0, min($1.endTick, span.endTick) - max($1.startTick, span.startTick)) }
        }

        func covers(_ span: Span) -> Bool { playedTicks(in: span) == span.ticks }
    }

    /// Follows a player's clock into `PlayedCoverage`: what plays forward between two observations is credited; a
    /// seek, a pause or a step too long to have been played drops the baseline, so nothing is credited across it.
    struct PlayTracker: Equatable {
        /// Recording time between two observations beyond which the stretch is not taken as played.
        static let maxStepSec = 1.5

        private(set) var played = PlayedCoverage()
        private var last: Double?

        /// Playback started (or resumed, or a seek landed while playing) at `t`.
        mutating func began(at t: Double) { last = t }

        /// The player's clock while playing at `rate`.
        mutating func observed(_ t: Double, rate: Double) {
            defer { last = t }
            guard let last, t > last, t - last <= Self.maxStepSec else { return }
            played.credit(fromTick: CoverageAudit.tick(last), toTick: CoverageAudit.tick(t), rate: rate)
        }

        /// Playback paused at `t`: what played up to here counts, and nothing after until it begins again.
        mutating func stopped(at t: Double, rate: Double) {
            observed(t, rate: rate)
            last = nil
        }

        /// The recording played to its end at `rate`: everything from the last observation through `durationTicks` was shown.
        mutating func reachedEnd(durationTicks: Int, rate: Double) {
            if let last, CoverageAudit.seconds(durationTicks) - last <= Self.maxStepSec {
                played.credit(fromTick: CoverageAudit.tick(last), toTick: durationTicks, rate: rate)
            }
            last = nil
        }

        /// A seek: nothing is credited across it.
        mutating func jumped() { last = nil }
    }
}
