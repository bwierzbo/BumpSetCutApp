//
//  CoverageAuditRecording.swift
//  RallyLab
//
//  The only ways a recording is opened for the negative-coverage audit and its record
//  changed (CLAUDE.md: guards live in the shared function, ledgers fail closed). Every
//  caller — the Coverage tab, a test, a later command — comes through `open` and
//  `record`, and both begin with `admit`, which refuses:
//
//   - a recording that is not one of the frozen draw's;
//   - the withheld closure: by name (`ScoringExposure.Closures`: the final test, its
//     candidates, the lineage and legacy holdouts and every alias), by the identities
//     the draw carries for the recording (its card's fingerprint, its confirmed source,
//     its file's content — against the closure's identities), and by path and content
//     (`EventReview.refusal`: its file is a withheld recording's, or a byte copy of
//     one). An empty closure is refused: it proves nothing;
//   - a recording whose pass is not declared complete, whose original is not on this
//     Mac, or whose file is not the one the draw was made from (content fingerprint);
//   - marks that can't be read.
//
//  `record` then refuses, for one interval: an interval the draw does not hold; one
//  that is no longer an unmarked interval as drawn (the marks or cut ranges changed —
//  a new draw is needed); `clean` for an interval not played whole at 2× or slower, or
//  over findings; an `uncertain` finding without a note; a repeat outside the repeat
//  set, before a first verdict, or by the first reviewer inside 24 hours; a resolution
//  where nothing disagrees; a change under a later look (withdraw that first). Only
//  then: the `coverage_audit` ledger row (one per recording per draw; an unwritable
//  ledger fails the save, so no record exists without it), and the sidecar, whole and
//  atomically. `open` writes the same ledger row before a frame is shown.
//
//  No model runs here and no rally mark is written: findings go to the marking pass
//  as a list (CoverageAuditReport.swift).
//

import Foundation

extension CoverageAudit {
    /// The ledger reference of one draw's audit.
    static func ledgerRef(_ drawId: String) -> String { "coverage-audit \(drawId)" }

    /// Which look at an interval: the first review, the blind repeat, or the resolution of their disagreement.
    enum Pass: String, CaseIterable, Sendable {
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

    /// A drawn recording that may be audited, as it is now.
    struct Admission: Sendable {
        let recording: Draw.Recording
        let session: VideoSession
        /// The content fingerprint of its file, equal to the draw's.
        let contentFingerprint: String
        /// Its marks as the sidecar keeps them now, and that file's SHA-256.
        let marks: [RallyMarkRecord]
        let marksSha256: String

        var video: URL { session.sourceURL }
        var sidecar: URL { CoverageAudit.url(forVideo: video) }
        /// The recording's unmarked intervals as its marks and cut ranges are now.
        var currentIntervals: [Interval] { CoverageAudit.unmarkedIntervals(marks: marks, cuts: session.cutRanges, durationTicks: recording.durationTicks) }
    }

    struct Opened: Sendable {
        let admission: Admission
        /// The recording's record, nil before its first verdict.
        let file: File?
    }

    // MARK: - Admission

    /// Why the draw's `recording` is withheld by name or by an identity the draw carries for it, or nil.
    static func listedRefusal(of recording: Draw.Recording, closures: ScoringExposure.Closures, sources: [String: ClipSource]) -> String? {
        if let standing = closures.standing(of: recording.recordingId) { return standing }
        let withheld = RallyClassifierExporter.Withheld(
            names: closures.withheld.sorted(),
            sourceIds: Set(closures.withheld.compactMap { sources[$0]?.sourceId }.filter { !$0.isEmpty }).sorted(),
            fingerprints: Set(closures.withheld.compactMap { sources[$0].flatMap(ReservedVideos.effectiveFingerprint) }).sorted())
        return RallyClassifierExporter.withheldIdentity(name: recording.recordingId, sourceId: recording.sourceId, fingerprint: recording.fingerprint,
                                                        content: recording.contentFingerprint, in: withheld)
            .map { "the draw's \($0) for it is one of the withheld identities" }
    }

    /// Admits one recording of the draw to the audit, or throws why not (see the file header). Reads the reservations,
    /// the project's identities and every session strictly: anything unreadable throws, and nothing is admitted.
    /// Writes nothing.
    static func admit(_ recordingId: String, draw: LoadedDraw, root: URL) throws -> Admission {
        guard let recording = draw.draw.recording(recordingId) else { throw Failure.notInDraw(recordingId) }
        let closures = try ScoringExposure.Closures.current(in: root)
        guard !closures.withheld.isEmpty else { throw Failure.emptyClosure }
        if let why = listedRefusal(of: recording, closures: closures, sources: try ReservedVideos.sources(in: root)) {
            throw Failure.withheld(name: recordingId, reason: why)
        }
        let sessions = try sessions(in: root)
        guard let session = sessions.first(where: { $0.name == recordingId }) else { throw Failure.noSession(recordingId) }
        if let why = try EventReview.refusal(of: session, root: root, sessions: sessions) { throw Failure.withheld(name: recordingId, reason: why) }
        guard session.ralliesMarked == true else { throw Failure.notComplete(recordingId) }
        guard session.isOnMac, let content = ProjectsModel.fileFingerprint(atPath: session.sourcePath) else { throw Failure.videoMissing(session.sourcePath) }
        guard content == recording.contentFingerprint else {
            throw Failure.sourceChanged(recording: recordingId, draw: recording.contentFingerprint, current: content)
        }
        let marksURL = RallyMarkModel.labelsURL(for: session.sourceURL)
        let read: [RallyMarkRecord]?
        do { read = try RallyTruth.records(inSidecarOf: session.sourceURL) } catch { throw Failure.marksUnreadable(error.localizedDescription) }
        guard let marks = read, let marksSha = DatasetSplitManifest.sha256(of: marksURL) else {
            throw Failure.marksUnreadable("no rally marks beside the video (\(marksURL.lastPathComponent))")
        }
        return Admission(recording: recording, session: session, contentFingerprint: content, marks: marks, marksSha256: marksSha)
    }

    /// A drawn recording's record as it is on disk, checked against the recording, the draw and the content
    /// fingerprint of the file it must be a record of; nil when there is none yet. A record of another draw,
    /// another recording or another file throws: nothing is merged, and nothing of it counts.
    static func existingRecord(of recording: Draw.Recording, video: URL, contentFingerprint: String, draw: LoadedDraw) throws -> File? {
        let sidecar = url(forVideo: video)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return nil }
        let file = try read(sidecar)
        let name = recording.recordingId
        guard file.recordingId == name else { throw Failure.wrongRecord(expected: name, found: file.recordingId) }
        guard file.drawId == draw.draw.drawId, file.drawSha256 == draw.sha256 else {
            throw Failure.otherDraw(recording: name, recorded: file.drawId, given: draw.draw.drawId)
        }
        guard file.sourceFingerprint == contentFingerprint else {
            throw Failure.sourceChanged(recording: name, draw: file.sourceFingerprint, current: contentFingerprint)
        }
        return file
    }

    /// A person's use of the recording, on the ledger: one row per recording per draw (a repeated one is dropped).
    private static func logUse(of recordingId: String, draw: LoadedDraw, root: URL, now: Date) throws {
        do {
            try ExposureLog.record(videos: [recordingId], kind: .coverageAudit, ref: ledgerRef(draw.draw.drawId),
                                   note: "negative-coverage audit of \(draw.draw.datasetName): a person reviewed the unmarked intervals; no model ran", in: root, now: now)
        } catch { throw Failure.ledgerNotWritten(error.localizedDescription) }
    }

    // MARK: - Opening

    /// Opens a drawn recording for review: admitted, its record read, and the use on the ledger before anything is
    /// returned — so before a frame of it is shown. An unwritable ledger refuses the open.
    static func open(_ recordingId: String, draw: LoadedDraw, root: URL, now: Date = Date()) throws -> Opened {
        let admission = try admit(recordingId, draw: draw, root: root)
        let file = try existingRecord(of: admission.recording, video: admission.video, contentFingerprint: admission.contentFingerprint, draw: draw)
        try logUse(of: recordingId, draw: draw, root: root, now: now)
        return Opened(admission: admission, file: file)
    }

    // MARK: - Saving a verdict

    /// One look's verdict on an interval, whichever pass holds it.
    private struct Look {
        var verdict: Verdict
        var findings: [Finding]
        var reviewer: String
        var at: String
        var playedAllAtMaxRate: Double?
    }

    /// `entry` applied to what a pass holds for `interval` (nil: nothing yet): the look as it becomes, nil when it is
    /// withdrawn. `clean` needs the interval played whole and no findings under it; a finding must be well-formed
    /// and lie in the interval (a second either side allowed, the context the reviewer was shown).
    private static func applied(_ entry: Entry, to existing: Look?, interval: Interval, played: PlayedCoverage, reviewer: String, at: String) throws -> Look? {
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

    /// Records one entry of a reviewer on one interval of a drawn recording and returns the record as written.
    /// Every refusal comes first (the file header lists them); then the ledger row; then the sidecar, atomically.
    @discardableResult
    static func record(_ request: Request, draw: LoadedDraw, root: URL, tool: String, now: Date = Date()) throws -> File {
        let reviewer = request.reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reviewer.isEmpty else { throw Failure.noReviewer }
        let admission = try admit(request.recordingId, draw: draw, root: root)
        let recording = admission.recording
        let index = request.index
        guard let interval = recording.interval(index) else { throw Failure.intervalNotInDraw(recording: request.recordingId, index: index) }
        let adds = request.entry != .withdraw && request.entry != .withdrawLast
        // A verdict is on the interval as drawn: once the marks or cut ranges moved its bounds it is another interval.
        if adds, !admission.currentIntervals.contains(where: { $0.span == interval.span }) {
            throw Failure.marksChanged(recording: request.recordingId, index: index)
        }
        var file = try existingRecord(of: recording, video: admission.video, contentFingerprint: admission.contentFingerprint, draw: draw)
            ?? File(recordingId: request.recordingId, sourceFingerprint: admission.contentFingerprint, drawId: draw.draw.drawId, drawSha256: draw.sha256,
                    datasetName: draw.draw.datasetName, marksSha256: admission.marksSha256, tool: tool)
        let at = EventReview.stamp(now)
        func apply(to existing: Look?) throws -> Look? {
            try applied(request.entry, to: existing, interval: interval, played: request.played, reviewer: reviewer, at: at)
        }

        switch request.pass {
        case .first:
            if file.repeatReview(index) != nil { throw Failure.frozen(index: index, by: "repeat verdict") }
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
            if file.resolution(index) != nil { throw Failure.frozen(index: index, by: "resolution") }
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

        file.marksSha256 = admission.marksSha256
        file.tool = tool
        try validate(file)
        try logUse(of: request.recordingId, draw: draw, root: root, now: now)
        try write(file, to: admission.sidecar)
        return file
    }

    // MARK: - The project's sessions

    private static let sessionsLock = NSLock()
    nonisolated(unsafe) private static var keptSessions: [String: (stamps: [String: FileFingerprintCache.Stamp], sessions: [VideoSession])] = [:]

    /// Every session of the project, read strictly (one that can't be read throws: it may be a withheld recording's),
    /// without its frames and tracks — the audit reads a session's name, file, completion and cut ranges only. The
    /// session files are tens of megabytes and a verdict is saved at every key press, so the answer is kept while the
    /// sessions folder holds the same files, each the file it was (size, modification time, file number: a session is
    /// saved by replacing its file); anything else is read again. A read that throws is never kept.
    static func sessions(in root: URL) throws -> [VideoSession] {
        let dir = root.appendingPathComponent("sessions", isDirectory: true)
        let key = dir.standardizedFileURL.path
        // Stamped before they are read: a file that changes meanwhile is read again on the next call.
        let stamps = sessionStamps(dir)
        sessionsLock.lock()
        let hit = keptSessions[key]
        sessionsLock.unlock()
        if let stamps, let hit, hit.stamps == stamps { return hit.sessions }
        let sessions = try DatasetStore(root: root).loadSessionsStrict().map { session -> VideoSession in
            var slim = session
            slim.frames = []
            slim.tracks = nil
            slim.rejected = nil
            return slim
        }
        sessionsLock.lock()
        keptSessions[key] = stamps.map { ($0, sessions) }
        sessionsLock.unlock()
        return sessions
    }

    /// Each session file by name with what identifies its content on disk; nil when the folder or a file can't be read.
    private static func sessionStamps(_ dir: URL) -> [String: FileFingerprintCache.Stamp]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        var stamps: [String: FileFingerprintCache.Stamp] = [:]
        for name in names where name.hasSuffix(".json") {
            guard let stamp = FileFingerprintCache.stamp(ofResolvedPath: dir.appendingPathComponent(name).path) else { return nil }
            stamps[name] = stamp
        }
        return stamps
    }
}
