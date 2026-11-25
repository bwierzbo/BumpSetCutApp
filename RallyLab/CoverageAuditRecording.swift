//
//  CoverageAuditRecording.swift
//  RallyLab
//
//  The only ways a recording is opened for the negative-coverage audit and its record
//  changed (CLAUDE.md: guards live in the shared function, ledgers fail closed). Every
//  caller — the Audit tab, a test, a later command — comes through `open` and
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
//  a new draw is needed); `clean` for an interval not played whole at 3× or slower, or
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
    // MARK: - Unmarked intervals

    /// The maximal intervals of `0 ..< durationTicks` that no mark of any kind and no cut range covers: the marks
    /// as RallyTruth keeps them (every kind, outside the cuts; a rally from where the dataset starts it) and the
    /// cut ranges, each `tick(start) ..< tick(end)`, clamped to the recording, overlapping or touching ones merged
    /// — the dataset's rallies, excluded spans and cut ranges. Every interval counts, whatever its length.
    static func unmarkedIntervals(marks: [RallyMarkRecord], cuts: [CutRange], durationTicks: Int) -> [Interval] {
        guard durationTicks > 0 else { return [] }
        let truth = RallyTruth(marks: marks.map(RallyTruth.Mark.init), cuts: cuts, complete: true)
        let covered = truth.pieces.map { piece in
            (tick(RallyTruth.isRally(piece.kind) ? RallyClassifierExporter.rallyStart(piece, in: marks) : piece.start), tick(piece.end))
        }
        let taken = (covered + truth.cuts.map { (tick($0.start), tick($0.end)) })
            .map { (max(0, $0.0), min(durationTicks, $0.1)) }
            .filter { $0.0 < $0.1 }
            .sorted { $0.0 < $1.0 }
        var out: [Interval] = []
        var cursor = 0
        for (start, end) in taken {
            if start > cursor { out.append(Interval(index: out.count, startTick: cursor, endTick: start)) }
            cursor = max(cursor, end)
        }
        if cursor < durationTicks { out.append(Interval(index: out.count, startTick: cursor, endTick: durationTicks)) }
        return out
    }

    /// The ledger reference of one draw's audit.
    static func ledgerRef(_ drawId: String) -> String { "coverage-audit \(drawId)" }

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

    /// A person's use of the recording, on the ledger: one row per recording per draw. Once the row is there the
    /// ledger is left alone — a verdict is saved at every key press, and the ledger is one file every other
    /// operation's uses are appended to as well, so it is not rewritten for nothing.
    static func logUse(of recordingId: String, draw: LoadedDraw, root: URL, now: Date) throws {
        let ref = ledgerRef(draw.draw.drawId)
        if let rows = try? ExposureLog.readStrict(in: root), rows.contains(where: { $0.video == recordingId && $0.kind == .coverageAudit && $0.ref == ref }) { return }
        do {
            try ExposureLog.record(videos: [recordingId], kind: .coverageAudit, ref: ref,
                                   note: "negative-coverage audit of \(draw.draw.datasetName): a person reviewed the unmarked intervals; no model ran", in: root, now: now)
        } catch { throw Failure.ledgerNotWritten(error.localizedDescription) }
    }

    // MARK: - Opening

    /// Opens a drawn recording for review: admitted, its record read, and the use on the ledger before anything is
    /// returned — so before a frame of it is shown. An unwritable ledger refuses the open.
    static func open(_ recordingId: String, draw: LoadedDraw, root: URL, now: Date = Date()) throws -> Opened {
        let admission = try admit(recordingId, draw: draw, root: root)
        try setAsideSupersededRecord(video: admission.video, draw: draw)
        let file = try existingRecord(of: admission.recording, video: admission.video, contentFingerprint: admission.contentFingerprint, draw: draw)
        try logUse(of: recordingId, draw: draw, root: root, now: now)
        return Opened(admission: admission, file: file)
    }

    /// A recording opened under a draw that replaces the one its record belongs to (protocol §8: after a failed
    /// pilot the changed intervals are audited again under a new draw, with its reason): the old record is kept
    /// whole beside the video (`supersededURL`) and the replacement starts a fresh record — none of the old verdicts
    /// is reused. A record of any draw this one does not name in `supersedes` is left where it is (and refused).
    private static func setAsideSupersededRecord(video: URL, draw: LoadedDraw) throws {
        let sidecar = url(forVideo: video), fm = FileManager.default
        guard fm.fileExists(atPath: sidecar.path), let file = try? read(sidecar), file.drawId != draw.draw.drawId,
              draw.draw.supersedes?.contains(file.drawId) == true else { return }
        let kept = supersededURL(forVideo: video, drawId: file.drawId)
        guard !fm.fileExists(atPath: kept.path) else { throw Failure.supersededRecordKept(path: kept.path) }
        try fm.moveItem(at: sidecar, to: kept)
    }

    // MARK: - Saving a verdict

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
        // A verdict is on the interval as drawn: once the marks or cut ranges moved its bounds it is another interval.
        if request.entry.adds, !admission.currentIntervals.contains(where: { $0.span == interval.span }) {
            throw Failure.marksChanged(recording: request.recordingId, index: index)
        }
        sidecarLock.lock()
        defer { sidecarLock.unlock() }
        var file = try existingRecord(of: recording, video: admission.video, contentFingerprint: admission.contentFingerprint, draw: draw)
            ?? File(recordingId: request.recordingId, sourceFingerprint: admission.contentFingerprint, drawId: draw.draw.drawId, drawSha256: draw.sha256,
                    datasetName: draw.draw.datasetName, marksSha256: admission.marksSha256, tool: tool)
        file = try applying(request, reviewer: reviewer, to: file, interval: interval, recording: recording, now: now)
        file.marksSha256 = admission.marksSha256
        file.tool = tool
        try validate(file)
        try logUse(of: request.recordingId, draw: draw, root: root, now: now)
        try write(file, to: admission.sidecar)
        return file
    }

    // MARK: - A record from the other device

    /// Every change of a sidecar — a verdict here, a record synchronised from the server — reads and writes it under this.
    static let sidecarLock = NSLock()

    /// Where this Mac keeps a draw's record as it last agreed with the server (LabelingSync's shadow; never read as a
    /// record). One per draw: a replacement draw's audit of the same video never meets another draw's shadow.
    static func syncedURL(forVideo video: URL, drawId: String) -> URL {
        video.deletingPathExtension().appendingPathExtension("coverageaudit.\(drawId).synced.json")
    }

    /// Where a look this Mac gave is kept when the phone changed the same look meanwhile (the server's stays in the record).
    static func conflictURL(forVideo video: URL, drawId: String, serverRevision: Int) -> URL {
        video.deletingPathExtension().appendingPathExtension("coverageaudit.\(drawId).conflict-r\(serverRevision).json")
    }

    /// The local record changed while a synchronised one was being prepared: nothing was written.
    struct LocalChanged: Error {}

    /// A record merged with the server's (CoverageAuditSync) taken as this recording's, by the rules a verdict given here
    /// is held to: the recording admitted now (`admit`: the draw's, not withheld, complete, its original here and
    /// unchanged), the record of this draw, recording and file, valid (`validate`: clean only played whole, the 24-hour
    /// wait, …), every first look on the bounds the draw gave its interval. Then the ledger row — dated at the earliest
    /// use the server recorded, the review having happened on the other device — and only then the sidecar, whole and
    /// atomically, and only while it still is `expectedLocal` (`LocalChanged` otherwise: a verdict here came first).
    static func adoptSynced(_ file: File, draw: LoadedDraw, root: URL, firstUse: Date?, expectedLocal: File?, now: Date = Date()) throws {
        let admission = try admit(file.recordingId, draw: draw, root: root)
        let recording = admission.recording
        guard file.drawId == draw.draw.drawId, file.drawSha256 == draw.sha256 else {
            throw Failure.otherDraw(recording: file.recordingId, recorded: file.drawId, given: draw.draw.drawId)
        }
        guard file.sourceFingerprint == admission.contentFingerprint else {
            throw Failure.sourceChanged(recording: file.recordingId, draw: file.sourceFingerprint, current: admission.contentFingerprint)
        }
        try validate(file)
        for review in file.intervals where recording.interval(review.index)?.span != review.span {
            throw Failure.invalid("interval \(review.index) is not on the bounds the draw gave it")
        }
        sidecarLock.lock()
        defer { sidecarLock.unlock() }
        guard try existingRecord(of: recording, video: admission.video, contentFingerprint: admission.contentFingerprint, draw: draw) == expectedLocal else {
            throw LocalChanged()
        }
        try logUse(of: file.recordingId, draw: draw, root: root, now: min(firstUse ?? now, now))
        try write(file, to: admission.sidecar)
    }

    // MARK: - The project's sessions

    private static let sessionsLock = NSLock()
    nonisolated(unsafe) private static var keptSessions: [String: (stamps: [String: FileFingerprintCache.Stamp], sessions: [VideoSession])] = [:]

    /// Every session of the project, read strictly (one that can't be read throws: it may be a withheld recording's),
    /// without its frames, tracks and net box — the audit reads a session's name, file, completion and cut ranges
    /// only, and holds nothing a model produced. The
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
            slim.netBox = nil
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
