//
//  AuditModel.swift
//  Labeler
//
//  The phone's Audit mode (owner, 2026-11-17): the frozen coverage-audit pilot reviewed on the
//  iPhone, one logical audit with RallyLab's. Leads only in this release (the server's rule too).
//
//  What it holds to, besides the shared rules (CoverageAudit.applying):
//   - a recording is played only from its downloaded copy, and only after the copy's own frame
//     times reproduce the original's published identity (FrameIdentity / CommitGate, as Stage 1
//     review does) — a streamed, re-timed, trimmed or other file is never reviewed;
//   - the account's use of the recording is on the server's ledger (coverage_audit_open) before a
//     frame of it is shown; with no connection the first time, nothing is shown;
//   - viewing credit comes only from the player's clock moving forward at 2× or slower while it
//     plays (CoverageAudit.PlayTracker): a seek, a pause, leaving the app or a jump earns nothing;
//   - every verdict is written to the phone before anything else (an unwritable store refuses it),
//     then sent at the revision it was merged on; the server's looks come back the same way.
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AuditModel {
    let labeler: LabelerModel
    private let client = LabelingClient.shared
    static let tool = "Labeler " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
        + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
    private static let storeName = "coverage-audit.json"

    /// The pilot as kept on this phone; nil before one was loaded.
    private(set) var audit: CoverageAuditPhone?
    private(set) var pass: CoverageAudit.Pass = .first
    private(set) var position: CoverageAuditPhone.Position?
    private(set) var reviewer: String?
    private(set) var syncing = false
    private(set) var syncNote: String?
    /// The last refusal or confirmation, for the screen.
    private(set) var message: String?
    private(set) var refused = false

    // The open recording.
    private(set) var footage: Footage = .none
    let player = AVPlayer()
    private(set) var playhead = 0.0
    private(set) var isPlaying = false
    private(set) var rate: Float = 2
    private(set) var tracker = CoverageAudit.PlayTracker()
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var endObserver: Any?
    @ObservationIgnored private var openedRecording: String?
    /// Copies checked against the original's frame identity in this run (file path → verdict).
    @ObservationIgnored private var checked: [String: CommitGate] = [:]
    /// What this phone gave, newest last, for Undo.
    private(set) var undoStack: [CoverageAuditPhone.Position] = []

    enum Footage: Equatable {
        case none
        /// Can't be reviewed here (why).
        case unavailable(String)
        /// The copy is not on the phone: Download fetches it.
        case needsDownload
        case downloading(Double)
        case checking
        /// Verified and loaded: `duration` is the copy's.
        case ready(duration: Double)
    }

    init(labeler: LabelerModel) {
        self.labeler = labeler
        audit = Self.loadStore()
        if let audit { pass = audit.position?.pass ?? .first; position = audit.position }
    }

    // MARK: - The store

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RallyLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(storeName)
    }

    private static func loadStore() -> CoverageAuditPhone? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return try? JSONDecoder().decode(CoverageAuditPhone.self, from: data)
    }

    /// Writes the store now; a failure is said and thrown — a verdict that is not on the phone is not taken.
    private func persist(_ audit: CoverageAuditPhone) throws {
        let data = try JSONEncoder().encode(audit)
        try data.write(to: Self.storeURL, options: .atomic)
        self.audit = audit
    }

    // MARK: - Loading and synchronising

    /// The newest frozen draw the Mac published for a project on this phone, what it published for its recordings,
    /// and every record merged with the server's. Offline: what is on the phone, said so.
    func refresh() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        reviewer = await Self.signedInAccount()
        do {
            var current = audit
            let projects = Set(labeler.snapshot.videos.compactMap(\.project)).sorted()
            var rows: [LabelCoverageAuditDraw] = []
            for project in projects { rows += try await client.coverageAuditDraws(project: project) }
            if let have = current, !rows.contains(where: { $0.project == have.project && $0.drawId == have.drawId && $0.drawSha256 == have.drawSha256 }) {
                // The draw this phone holds is no longer served (withdrawn, or superseded): kept while it holds verdicts the
                // server doesn't have, so nothing given here is lost; otherwise it gives way to the newest.
                if have.local.contains(where: { have.shadow[$0.key] != $0.value }) {
                    syncNote = "Draw \(have.drawId) is no longer published; \(have.local.count) record(s) kept on this phone."
                    return
                }
                current = nil
            }
            if current == nil, let newest = rows.max(by: { $0.drawId < $1.drawId }) {
                current = try CoverageAuditPhone(row: newest)
            }
            guard var a = current else { audit = nil; syncNote = "No coverage-audit draw is published."; return }
            a.recordings = Dictionary(try await client.coverageAuditRecordings(project: a.project, drawId: a.drawId).map { ($0.recordingId, $0) },
                                      uniquingKeysWith: { x, _ in x })
            try persist(a)
            try await sendAndReceive()
            syncNote = nil
        } catch LabelingClient.Failure.server(_, let message) where CoverageAuditSync.refusal(in: message) == .notLead {
            syncNote = "Audit mode is for the project lead in this release."
        } catch LabelingClient.Failure.server(404, _) {
            syncNote = "The labeling server has no coverage audit yet (its update, migration 054, is not applied)."
        } catch {
            syncNote = "Offline — working from this phone. \(error.localizedDescription.prefix(160))"
        }
        if position == nil { position = audit?.resume(reviewable: isReviewable, reviewer: reviewer ?? "", now: Date()) }
    }

    /// The signed-in account's id, restoring a kept session first (a token refresh) when this run has not used it yet.
    private static func signedInAccount() async -> String? {
        let client = LabelingClient.shared
        if let id = await client.userId { return id.uuidString.lowercased() }
        guard await client.hasSession else { return nil }
        _ = try? await client.liveToken()
        return await client.userId?.uuidString.lowercased()
    }

    /// Every recording's record merged with the server's; this phone's new looks sent at the revision they were
    /// merged on. A stale revision is merged again (once); a refusal keeps the record here and says why.
    private func sendAndReceive() async throws {
        guard var a = audit else { return }
        let project = a.project, drawId = a.drawId
        let remote = Dictionary(try await client.coverageAudits(project: a.project, drawId: a.drawId).map { ($0.recordingId, $0) }, uniquingKeysWith: { x, _ in x })
        // A recording withheld, or whose list is not known here, is not merged or sent: its record stays on the phone.
        for name in Set(a.local.keys).union(remote.keys).sorted() where withheld(name) == false {
            var server = remote[name]
            for _ in 0..<2 {
                // A verdict given while a send was in flight is in `audit`: always merge from the newest.
                a = audit ?? a
                guard a.project == project, a.drawId == drawId else { return }
                switch a.merge(name, server: server) {
                case .upToDate:
                    try persist(a)
                case .refused(let why):
                    a.refusals[name] = why
                    try persist(a)
                case .push(let record, let expected):
                    try persist(a)
                    do {
                        let saved = try await client.saveCoverageAudit(project: a.project, drawId: a.drawId, expected: expected, record: record)
                        a = audit ?? a
                        a.pushed(record, saved: saved)
                        try persist(a)
                    } catch LabelingClient.Failure.server(_, let message) {
                        if case .conflict = CoverageAuditSync.refusal(in: message) {
                            server = try await client.coverageAudits(project: a.project, drawId: a.drawId).first { $0.recordingId == name }
                            a = audit ?? a
                            continue
                        }
                        a = audit ?? a
                        a.refusals[name] = message
                        try persist(a)
                    }
                }
                break
            }
        }
    }

    // MARK: - Recordings

    func video(_ recordingId: String) -> LabelVideo? {
        guard let published = audit?.recordings[recordingId] else { return nil }
        return labeler.snapshot.videos.first { $0.id == published.videoId }
    }

    /// Whether the project's withheld list names the recording; nil when it is not known here.
    private func withheld(_ recordingId: String) -> Bool? {
        guard let project = audit?.project, let list = labeler.snapshot.withheld[project] else { return nil }
        return list.contains(recordingId)
    }

    func unavailable(_ recordingId: String) -> String? {
        audit?.unavailable(recordingId, video: video(recordingId), withheld: withheld(recordingId))
    }

    func isReviewable(_ recordingId: String) -> Bool { unavailable(recordingId) == nil }

    var totals: CoverageAuditPhone.Totals? { audit?.totals(pass, reviewable: isReviewable) }

    /// The interval on screen.
    var interval: CoverageAudit.Interval? {
        guard let position else { return nil }
        return audit?.draw.draw.recording(position.recordingId)?.interval(position.index)
    }

    /// What is played: the interval with a second either side, clamped to the copy.
    var shown: ClosedRange<Double>? {
        guard let interval, case .ready(let duration) = footage else { return nil }
        let a = max(0, CoverageAudit.seconds(interval.startTick) - CoverageAudit.contextSec)
        let b = min(duration, CoverageAudit.seconds(interval.endTick) + CoverageAudit.contextSec)
        return a...max(a, b)
    }

    /// How much of the interval is still to be played at 2× or slower before Clean is offered, in seconds.
    var leftToPlay: Double? {
        guard let interval else { return nil }
        let span = interval.span
        return CoverageAudit.seconds(span.ticks - tracker.played.playedTicks(in: span))
    }

    // MARK: - Moving

    func setPass(_ pass: CoverageAudit.Pass) {
        guard pass != self.pass else { return }
        self.pass = pass
        message = nil
        go(to: audit?.next(after: nil, pass: pass, reviewable: isReviewable, reviewer: reviewer ?? "", now: Date()), play: false)
    }

    /// The next interval this pass owes a look.
    func next(play: Bool = true) {
        go(to: audit?.next(after: position, pass: pass, reviewable: isReviewable, reviewer: reviewer ?? "", now: Date()), play: play)
    }

    /// Opens `target`: its recording's use on the server's ledger first, then its copy checked, then the interval.
    func go(to target: CoverageAuditPhone.Position?, play: Bool) {
        pause()
        tracker = CoverageAudit.PlayTracker()
        position = target
        if var a = audit { a.position = target; try? persist(a) }
        guard let target else {
            footage = .none
            message = "Nothing left to review in this pass."
            return
        }
        Task { await open(target, play: play) }
    }

    private func open(_ target: CoverageAuditPhone.Position, play: Bool) async {
        let name = target.recordingId
        if let why = unavailable(name) { footage = .unavailable(why); return }
        guard let video = video(name), var a = audit else { return }
        guard let reviewer else { footage = .unavailable("Sign in: the audit's ledger records who opened the recording."); return }
        let use = reviewer + "|" + name
        if !a.opened.contains(use) {
            do {
                try await client.openCoverageAudit(project: a.project, drawId: a.drawId, recordingId: name)
                a = audit ?? a
                a.opened.insert(use)
                try persist(a)
            } catch {
                footage = .unavailable("Opening \(name) for review needs a connection the first time (it goes on the audit's ledger before a frame is shown): \(error.localizedDescription)")
                return
            }
        }
        guard LocalStore.hasClip(video) else { footage = .needsDownload; unload(); return }
        await load(video, recordingId: name)
        guard position == target, case .ready = footage, let shown else { return }
        if let interval, CoverageAudit.seconds(interval.endTick) > shown.upperBound + 0.001 {
            footage = .unavailable("The phone's copy ends before this interval does: review it on the Mac.")
            return
        }
        seek(to: shown.lowerBound)
        if play { self.play() }
    }

    /// Downloads the open recording's copy, then checks and opens it.
    func download() async {
        guard let position, let video = video(position.recordingId) else { return }
        footage = .downloading(0)
        do {
            _ = try await labeler.localClip(for: video)
            await open(position, play: false)
        } catch {
            footage = .unavailable("Download failed: \(error.localizedDescription)")
        }
    }

    private func load(_ video: LabelVideo, recordingId: String) async {
        let file = LocalStore.clip(for: video)
        if openedRecording == recordingId, player.currentItem != nil, case .ready = footage { return }
        unload()
        footage = .checking
        let gate: CommitGate
        if let known = checked[file.path] { gate = known } else {
            let frames: Result<[Double], Error>
            do { frames = .success(try await FrameIdentity.allFrameTimes(of: file)) } catch { frames = .failure(error) }
            gate = CommitGate.decide(reviewable: withheld(recordingId) == false, publishedDigest: video.frameTimesDigest, copyFrames: frames)
            checked[file.path] = gate
        }
        guard gate.allowed else { footage = .unavailable("The copy can't stand in for the original: \(gate.reason)."); return }
        let item = AVPlayerItem(url: file)
        player.replaceCurrentItem(with: item)
        let duration = (try? await item.asset.load(.duration).seconds) ?? 0
        openedRecording = recordingId
        footage = .ready(duration: duration)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        // The copy played to its end (an interval that ends the recording): what was shown up to the end counts.
        let durationTicks = audit?.draw.draw.recording(recordingId)?.durationTicks ?? 0
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.tracker.reachedEnd(durationTicks: durationTicks, rate: Double(self.rate))
                self.isPlaying = false
            }
        }
    }

    func unload() {
        pause()
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        openedRecording = nil
    }

    // MARK: - Playback (what earns viewing credit)

    private func tick(_ t: Double) {
        playhead = t
        guard isPlaying else { return }
        tracker.observed(t, rate: Double(rate))
        if let shown, t >= shown.upperBound - 0.001 { pause() }
    }

    func play() {
        guard case .ready = footage, let shown else { return }
        if playhead < shown.lowerBound - 0.05 || playhead >= shown.upperBound - 0.05 { seek(to: shown.lowerBound) }
        player.playImmediately(atRate: rate)
        isPlaying = true
        tracker.began(at: player.currentTime().seconds)
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        tracker.stopped(at: player.currentTime().seconds, rate: Double(rate))
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func setRate(_ rate: Float) {
        guard rate != self.rate else { return }
        // What played so far counts at the old rate; from here at the new one.
        if isPlaying { tracker.stopped(at: player.currentTime().seconds, rate: Double(self.rate)) }
        self.rate = rate
        if isPlaying { player.rate = rate; tracker.began(at: player.currentTime().seconds) }
    }

    /// A jump: nothing is credited across it.
    func seek(to t: Double) {
        tracker.jumped()
        playhead = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in if let self, self.isPlaying { self.tracker.began(at: self.player.currentTime().seconds) } }
        }
    }

    func back(_ seconds: Double) { seek(to: max(shown?.lowerBound ?? 0, playhead - seconds)) }

    /// The app left the screen: playback stops, and nothing after counts.
    func leftApp() { pause() }

    // MARK: - Verdicts

    /// The looks the reviewer may see on the interval in this pass (the blind repeat hides the first verdict).
    var looks: [CoverageAuditSync.Look] {
        guard let position else { return [] }
        return audit?.shown(pass, recordingId: position.recordingId, index: position.index) ?? []
    }

    var conflicts: [CoverageAuditSync.Conflict] {
        guard let position else { return [] }
        return audit?.conflicts[position.recordingId] ?? []
    }

    /// Gives `entry` on the interval on screen: written to the phone first, then sent. Clean moves on to the next interval.
    func give(_ entry: CoverageAudit.Entry, note: String? = nil) {
        guard var a = audit, let position else { return }
        guard let reviewer, !reviewer.isEmpty else { say("Sign in again: the reviewer must be this phone's signed-in account.", refused: true); return }
        if isPlaying { tracker.stopped(at: player.currentTime().seconds, rate: Double(rate)); tracker.began(at: player.currentTime().seconds) }
        do {
            try a.give(entry, pass: pass, recordingId: position.recordingId, index: position.index, played: tracker.played, reviewer: reviewer, note: note, tool: Self.tool)
            try persist(a)
        } catch {
            say(error.localizedDescription, refused: true)
            return
        }
        if entry.adds { undoStack.append(position) }
        switch entry {
        case .clean:
            say("Interval \(position.index): clean.")
            next(play: true)
        case .finding(let f):
            say("Interval \(position.index): \(f.kind.rawValue) saved." + (leftToPlay ?? 0 > 0.05 ? " Keep watching — the interval completes when it has played to its end." : ""))
        case .playedWhole:
            say("Interval \(position.index): played whole, with its findings.")
        case .withdrawLast, .withdraw:
            say("Interval \(position.index): taken back.")
        }
        Task { try? await sendAndReceive() }
    }

    /// The interval just played to its end under a look with findings from a partial look: that look is now whole.
    var canComplete: Bool {
        guard let leftToPlay, leftToPlay <= 0.05, let position, let file = audit?.local[position.recordingId] else { return false }
        switch pass {
        case .first: return file.review(position.index).map { $0.verdict == .notClean && $0.playedAllAtMaxRate == nil } ?? false
        case .repeatLook: return file.repeatReview(position.index).map { $0.verdict == .notClean && $0.playedAllAtMaxRate == nil } ?? false
        case .resolution: return file.resolution(position.index).map { $0.verdict == .notClean && $0.playedAllAtMaxRate == nil } ?? false
        }
    }

    /// Takes back the last thing given on the most recent interval this phone gave a verdict on (and goes there).
    func undo() {
        guard let last = undoStack.popLast() else { return }
        if last != position { go(to: last, play: false) }
        guard var a = audit, let reviewer else { return }
        do {
            try a.give(.withdrawLast, pass: last.pass, recordingId: last.recordingId, index: last.index, played: .init(), reviewer: reviewer, tool: Self.tool)
            try persist(a)
            say("Interval \(last.index): last verdict taken back.")
            Task { try? await sendAndReceive() }
        } catch { say(error.localizedDescription, refused: true) }
    }

    func resolve(_ conflict: CoverageAuditSync.Conflict, keepMine: Bool) {
        guard var a = audit, let position else { return }
        a.resolve(conflict, recordingId: position.recordingId, keep: keepMine)
        try? persist(a)
        Task { try? await sendAndReceive() }
    }

    private func say(_ text: String, refused: Bool = false) {
        message = text
        self.refused = refused
    }
}
