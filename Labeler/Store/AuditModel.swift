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
//   - viewing credit comes only from the player's clock moving forward at 3× or slower while it
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
    /// The finding being placed by scrubbing (nil: none). Its note and edge are the screen's to edit.
    var marking: CoverageAuditPhone.Marking?
    /// The newest place a scrub asked for while the player was still seeking to an earlier one.
    @ObservationIgnored private var scrubTarget: Double?
    @ObservationIgnored private var scrubSeeking = false
    /// Jumps the player has not landed yet, and whether Play was asked for meanwhile. Playback starts only where the
    /// last jump lands: started sooner, the step from the old frame to the new one would be credited as watched.
    @ObservationIgnored private var seeksInFlight = 0
    @ObservationIgnored private var playWhenLanded = false
    private var seekPending: Bool { scrubSeeking || seeksInFlight > 0 }
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var endObserver: Any?
    @ObservationIgnored private var openedRecording: String?
    /// Bumped by every move to another interval and by leaving the tab: an open still in flight for an older one stops
    /// at its next step and never touches the player.
    @ObservationIgnored private var generation = 0
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
        switch CoverageAuditPhone.load(from: Self.storeURL) {
        case .none: audit = nil
        case .store(let kept): audit = kept
        case .setAside(let url, _): syncNote = "The audit store on this phone could not be read; it is kept as \(url.lastPathComponent) and a new one starts."
        case .blocked(let why): storeBlocked = why; syncNote = "The audit store on this phone could not be read, and nothing is written over it: \(why.prefix(160))"
        }
        if let audit { pass = audit.position?.pass ?? .first; position = audit.position }
    }

    // MARK: - The store

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RallyLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(storeName)
    }

    /// Why nothing may be written to the store: it is there but could neither be read nor set aside.
    private var storeBlocked: String?

    /// Writes the store now; a failure is said and thrown — a verdict that is not on the phone is not taken.
    private func persist(_ audit: CoverageAuditPhone) throws {
        if let storeBlocked { throw CoverageAudit.Failure.unreadable("the audit store on this phone: \(storeBlocked)") }
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
            // Everything is fetched first; what is fetched is then applied to the audit as it is after the fetches (a
            // verdict given meanwhile is in it, and is never replaced by an older copy).
            let projects = Set(labeler.snapshot.videos.compactMap(\.project)).sorted()
            var rows: [LabelCoverageAuditDraw] = []
            for project in projects { rows += try await client.coverageAuditDraws(project: project) }
            switch CoverageAuditPhone.choose(held: audit, published: rows) {
            case .nothing:
                audit = nil
                syncNote = "No coverage-audit draw is published."
                return
            case .keepUnsettled(let why):
                // Unsettled work of the held draw is sent and received as ever; nothing of it is dropped for another draw.
                syncNote = why
                try await sendAndReceive()
                return
            case .keep:
                try await sendAndReceive()
            case .start(let row):
                // Chosen from the audit as it was after the fetch: still nothing unsettled to lose.
                guard audit?.holdsUnsettled != true else { return }
                generation += 1
                unload()
                footage = .none
                undoStack = []
                try persist(try CoverageAuditPhone(row: row))
                try await sendAndReceive()
                go(to: audit?.resume(reviewable: isReviewable, reviewer: reviewer ?? "", now: Date()), play: false)
            }
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

    /// The account a kept session was last confirmed as (offline after a relaunch, the session can't be restored, but
    /// it is still that account's): set on every confirmation, cleared on sign-out (`LabelerModel.signOut`). The server
    /// takes a verdict only from the account it names (054), so a wrong one is refused there, never counted.
    static let confirmedAccountKey = "Labeler.audit.confirmedAccount"

    /// The signed-in account's id: as confirmed now (restoring a kept session first, a token refresh, when this run
    /// has not used it yet), else — offline, a session still kept — the account it was last confirmed as.
    private static func signedInAccount() async -> String? {
        let client = LabelingClient.shared
        guard await client.hasSession else { UserDefaults.standard.removeObject(forKey: confirmedAccountKey); return nil }
        if await client.userId == nil { _ = try? await client.liveToken() }
        if let id = await client.userId?.uuidString.lowercased() {
            UserDefaults.standard.set(id, forKey: confirmedAccountKey)
            return id
        }
        return UserDefaults.standard.string(forKey: confirmedAccountKey)
    }

    /// The labeling app's automatic sync (coming back to the app, a live notice, every half minute): this phone's unsent
    /// verdicts go up and the other device's come down. Nothing when no audit is held or a sync is running.
    func sync() async {
        guard audit != nil, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await sendAndReceive()
            syncNote = nil
        } catch {
            syncNote = "Offline — working from this phone. \(error.localizedDescription.prefix(160))"
        }
    }

    /// The exchange with the server running now, and whether another was asked for while it ran.
    @ObservationIgnored private var exchange: Task<Void, Error>?
    @ObservationIgnored private var exchangeAgain = false

    /// One exchange with the server at a time, whoever asks (a verdict, Undo, a conflict decided, a refresh, the app's
    /// automatic sync): a reply read before another exchange moved the shadow on is never merged against the newer
    /// shadow (it would read verdicts already acknowledged as deleted on the server). A request made while an exchange
    /// runs waits for it, and the running one goes round once more so what was given meanwhile goes up too.
    private func sendAndReceive() async throws {
        if let running = exchange {
            exchangeAgain = true
            try await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.exchangeAgain = false
                try await self.exchangeOnce()
            } while self.exchangeAgain
        }
        exchange = task
        defer { exchange = nil }
        try await task.value
    }

    /// Every recording's record merged with the server's; this phone's new looks sent at the revision they were
    /// merged on. A stale revision is merged again (once); a refusal keeps the record here and says why.
    private func exchangeOnce() async throws {
        guard var a = audit else { return }
        let project = a.project, drawId = a.drawId
        // What the Mac publishes of the recordings now (marks hash, intervals still as drawn, newly offered ones) comes
        // first: verdicts are stamped and checked against it, so a stale copy here would only be refused by the server.
        let published = try await client.coverageAuditRecordings(project: project, drawId: drawId)
        a = audit ?? a
        guard a.project == project, a.drawId == drawId else { return }
        a.recordings = Dictionary(published.map { ($0.recordingId, $0) }, uniquingKeysWith: { x, _ in x })
        try persist(a)
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

    /// How much of the interval is still to be played at 3× or slower before Clean is offered, in seconds.
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
        generation += 1
        // The pass on screen is always the opened look's: what is shown and given next is that look's.
        if let target, target.pass != pass { pass = target.pass }
        pause()
        marking = nil
        tracker = CoverageAudit.PlayTracker()
        // Another recording: the one in the player is let go now, so nothing of it plays, or earns credit, or takes a
        // verdict under the new one's name while that opens.
        if target?.recordingId != openedRecording {
            unload()
            footage = target == nil ? .none : .checking
        }
        position = target
        if var a = audit { a.position = target; try? persist(a) }
        guard let target else {
            footage = .none
            message = "Nothing left to review in this pass."
            return
        }
        let mine = generation
        Task { await open(target, play: play, generation: mine) }
    }

    /// The tab left the screen: the player is let go, and the interval reopens when it comes back.
    func leave() {
        generation += 1
        unload()
        footage = .none
    }

    private func open(_ target: CoverageAuditPhone.Position, play: Bool, generation mine: Int) async {
        let name = target.recordingId
        guard mine == generation else { return }
        if let why = unavailable(name) { unload(); footage = .unavailable(why); return }
        guard let video = video(name), var a = audit else { return }
        guard let reviewer else { footage = .unavailable("Sign in: the audit's ledger records who opened the recording."); return }
        let use = reviewer + "|" + name
        if !a.opened.contains(use) {
            do {
                try await client.openCoverageAudit(project: a.project, drawId: a.drawId, recordingId: name)
                guard mine == generation else { return }
                a = audit ?? a
                a.opened.insert(use)
                try persist(a)
            } catch {
                guard mine == generation else { return }
                footage = .unavailable("Opening \(name) for review needs a connection the first time (it goes on the audit's ledger before a frame is shown): \(error.localizedDescription)")
                return
            }
        }
        guard LocalStore.hasClip(video) else { unload(); footage = .needsDownload; return }
        guard await load(video, recordingId: name, generation: mine), mine == generation, position == target, case .ready = footage, let shown else { return }
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
        let mine = generation
        footage = .downloading(0)
        do {
            _ = try await labeler.localClip(for: video)
            await open(position, play: false, generation: mine)
        } catch {
            guard mine == generation else { return }
            footage = .unavailable("Download failed: \(error.localizedDescription)")
        }
    }

    /// Checks the copy against the original's frame identity and puts it in the player. False when the copy can't
    /// stand in for the original, or when another interval was opened meanwhile (nothing of the player is touched then).
    private func load(_ video: LabelVideo, recordingId: String, generation mine: Int) async -> Bool {
        let file = LocalStore.clip(for: video)
        if openedRecording == recordingId, player.currentItem != nil, case .ready = footage { return true }
        unload()
        footage = .checking
        let gate: CommitGate
        let key = file.path + "|" + (video.frameTimesDigest ?? "")
        if let known = checked[key] { gate = known } else {
            let frames: Result<[Double], Error>
            do { frames = .success(try await FrameIdentity.allFrameTimes(of: file)) } catch { frames = .failure(error) }
            guard mine == generation else { return false }
            gate = CommitGate.decide(reviewable: true, publishedDigest: video.frameTimesDigest, copyFrames: frames)
            checked[key] = gate
        }
        guard gate.allowed else { footage = .unavailable("The copy can't stand in for the original: \(gate.reason)."); return false }
        let asset = AVURLAsset(url: file)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        // The recording may have been withheld, or another interval opened, while the copy was read.
        guard mine == generation else { return false }
        if let why = unavailable(recordingId) { footage = .unavailable(why); return false }
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
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
        return true
    }

    func unload() {
        pause()
        marking = nil
        scrubTarget = nil
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        openedRecording = nil
    }

    // MARK: - Playback (what earns viewing credit)

    private func tick(_ t: Double) {
        // While a scrub is being chased the playhead is the finger's, not the frame the player last reached.
        guard !scrubSeeking else { return }
        playhead = t
        guard isPlaying else { return }
        tracker.observed(t, rate: Double(rate))
        if let shown, t >= shown.upperBound - 0.001 { pause() }
    }

    /// The player holds the recording on screen (and only then may it play, or a verdict be given on what it showed).
    private var playerHoldsPosition: Bool {
        guard case .ready = footage, let position else { return false }
        return openedRecording == position.recordingId && player.currentItem != nil
    }

    func play() {
        guard playerHoldsPosition, let shown else { return }
        guard recheck() else { return }
        if playhead < shown.lowerBound - 0.05 || playhead >= shown.upperBound - 0.05 { seek(to: shown.lowerBound) }
        if seekPending { playWhenLanded = true; return }
        player.playImmediately(atRate: rate)
        isPlaying = true
        tracker.began(at: player.currentTime().seconds)
    }

    func pause() {
        playWhenLanded = false
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        tracker.stopped(at: player.currentTime().seconds, rate: Double(rate))
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// A jump landed: with none left in flight, the Play asked for meanwhile starts here.
    private func landed() {
        guard !seekPending, playWhenLanded else { return }
        playWhenLanded = false
        play()
    }

    /// Whether the open recording may still be reviewed here, as the phone knows now (the withheld list is pulled in the
    /// background): when it may not — withheld, its list no longer known, its copy no longer published — playback stops,
    /// the footage is let go, and why is shown. Called before playing, before every verdict, and whenever the list changes.
    @discardableResult
    func recheck() -> Bool {
        guard let position, let why = unavailable(position.recordingId) else { return true }
        generation += 1
        unload()
        footage = .unavailable(why)
        return false
    }

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
        seeksInFlight += 1
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeksInFlight -= 1
                if self.isPlaying { self.tracker.began(at: self.player.currentTime().seconds) }
                self.landed()
            }
        }
    }

    func back(_ seconds: Double) { seek(to: max(shown?.lowerBound ?? 0, playhead - seconds)) }

    /// A finger on the bar while a finding is placed: the footage follows it, paused. A jump like any other, so
    /// nothing is credited; the player is asked for one frame at a time, always the newest place.
    func scrub(to t: Double) {
        guard marking != nil, playerHoldsPosition, let shown else { return }
        pause()
        tracker.jumped()
        playhead = min(max(t, shown.lowerBound), shown.upperBound)
        scrubTarget = playhead
        if !scrubSeeking { chaseScrub() }
    }

    private func chaseScrub() {
        guard let t = scrubTarget else { scrubSeeking = false; landed(); return }
        scrubTarget = nil
        scrubSeeking = true
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.chaseScrub() }
        }
    }

    /// The app left the screen: playback stops, and nothing after counts.
    func leftApp() { pause() }

    // MARK: - Verdicts

    /// The looks the reviewer may see on the interval in this pass (the blind repeat hides the first verdict).
    var looks: [CoverageAuditSync.Look] {
        guard let position else { return [] }
        return audit?.shown(pass, recordingId: position.recordingId, index: position.index) ?? []
    }

    /// The conflicts this pass may show, of every recording (decidable even when nothing is left to review).
    var conflicts: [CoverageAuditPhone.OpenConflict] { audit?.shownConflicts(pass) ?? [] }

    /// Gives `entry` on the interval on screen: written to the phone first, then sent. Clean moves on to the next interval.
    /// Returns whether it was taken.
    @discardableResult
    func give(_ entry: CoverageAudit.Entry, note: String? = nil) -> Bool {
        guard var a = audit, let position else { return false }
        guard let reviewer, !reviewer.isEmpty else { say("Sign in again: the reviewer must be this phone's signed-in account.", refused: true); return false }
        guard recheck() else { say("Not saved: \(position.recordingId) may not be reviewed on this phone now.", refused: true); return false }
        if entry.adds, !playerHoldsPosition { say("Not saved: \(position.recordingId) is not open in the player yet.", refused: true); return false }
        if isPlaying { tracker.stopped(at: player.currentTime().seconds, rate: Double(rate)); tracker.began(at: player.currentTime().seconds) }
        do {
            try a.give(entry, pass: pass, recordingId: position.recordingId, index: position.index, video: video(position.recordingId),
                       withheld: withheld(position.recordingId), played: tracker.played, reviewer: reviewer, note: note, tool: Self.tool)
            try persist(a)
        } catch {
            say(error.localizedDescription, refused: true)
            return false
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
        return true
    }

    /// The boundary errors this pass's look holds on the interval on screen: the stretches trimmed off it.
    var trims: [CoverageAudit.Finding] {
        looks.flatMap { look -> [CoverageAudit.Finding] in
            switch (pass, look) {
            case (.first, .first(let r)): return r.findings
            case (.repeatLook, .repeatLook(let r)): return r.findings
            case (.resolution, .resolution(let r)): return r.findings
            default: return []
            }
        }
        .filter { $0.kind == .boundaryError && $0.edge != nil }
    }

    /// Starts placing a finding of `kind` on the interval on screen, at the playhead: the reviewer scrubs to where it
    /// starts and ends. With `trim` it is the boundary error at that end of the interval — play the neighbouring mark
    /// should have covered, from the interval's start (`.leading`: the rally before was still going) or to its end
    /// (`.trailing`: the serve of the rally after was already hit). Nothing moves a mark here; the finding goes to the
    /// marking pass.
    func beginMarking(_ kind: CoverageAudit.FindingKind, trim: CoverageAudit.Edge? = nil) {
        guard let interval, let shown, playerHoldsPosition else { return }
        pause()
        if let trim, trims.contains(where: { $0.edge == trim }) {
            say("This look already trims the interval's \(trim == .leading ? "start" : "end"). Undo takes it back.", refused: true)
            return
        }
        message = nil
        marking = CoverageAuditPhone.Marking(kind: kind, trim: trim, interval: interval, shown: shown, playhead: playhead)
    }

    /// The finding being placed starts, or ends, where the footage now stands.
    func markStart() { marking?.setStart(playhead) }
    func markEnd() { marking?.setEnd(playhead) }
    func clearMarkEnd() { marking?.clearEnd() }

    /// Gives the finding as placed, and returns to where the reviewer was. Refused, it stays open with why.
    func saveMarking() {
        guard let marking, let finding = marking.finding else { return }
        pause()
        guard give(.finding(finding)) else { return }
        endMarking(marking)
    }

    /// Drops the finding being placed: nothing is given.
    func cancelMarking() {
        guard let marking else { return }
        pause()
        endMarking(marking)
    }

    private func endMarking(_ marking: CoverageAuditPhone.Marking) {
        self.marking = nil
        scrubTarget = nil
        seek(to: marking.resume)
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
            try a.give(.withdrawLast, pass: last.pass, recordingId: last.recordingId, index: last.index, video: video(last.recordingId),
                       withheld: withheld(last.recordingId), played: .init(), reviewer: reviewer, tool: Self.tool)
            try persist(a)
            say("Interval \(last.index): last verdict taken back.")
            Task { try? await sendAndReceive() }
        } catch { say(error.localizedDescription, refused: true) }
    }

    func resolve(_ open: CoverageAuditPhone.OpenConflict, keepMine: Bool) {
        guard var a = audit else { return }
        do {
            try a.resolve(open.conflict, recordingId: open.recordingId, keep: keepMine)
            try persist(a)
        } catch {
            say(error.localizedDescription, refused: true)
            return
        }
        Task { try? await sendAndReceive() }
    }

    private func say(_ text: String, refused: Bool = false) {
        message = text
        self.refused = refused
    }
}
