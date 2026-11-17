//
//  CoverageAuditModel.swift
//  RallyLab
//
//  The Audit tab's state: a frozen draw, its recordings with what their records say
//  (CoverageAudit.status, read-only), the open recording (through CoverageAudit.open —
//  the one guard: it refuses the withheld closure and writes the ledger row before a
//  frame is shown), an AVPlayer on the ORIGINAL footage, the interval under review with
//  a second of context either side, what of it has been played at 2× or slower
//  (CoverageAudit.PlayTracker: a seek earns nothing), and the reviewer's keys. Every
//  verdict goes through CoverageAudit.record, off the main actor, and what it wrote is
//  what is shown.
//
//  Blind to the pipeline by construction: this model holds a player, the draw's interval
//  bounds and the audit record — no ball path, no detector, no pipeline clip, no
//  snapping, no session frames or tracks. It reads `SamplerModel` for the project's
//  folder only.
//

import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class CoverageAuditModel {
    /// One look at one interval by one reviewer: what played coverage and undo are kept by. The reviewer is part of
    /// it, so what one person watched never counts for another (a hand-over on a Mac with no labeling session).
    struct LookKey: Hashable {
        var recordingId: String
        var pass: CoverageAudit.Pass
        var index: Int
        var reviewer: String
    }

    /// Who is signed in to labeling on this Mac, as far as it can be told.
    enum SignedIn: Equatable, Sendable {
        case labeler(String)
        /// No labeling session on this Mac: the reviewer types a name.
        case nobody
        /// A session is kept but its account is not confirmed yet (it is being restored, or the Mac is offline).
        case unknown
    }

    static let rates: [Float] = [0.5, 1, 2]
    /// What a record says wrote it, from this Mac (a verdict here, or a record the sync sends).
    nonisolated static let defaultTool = "RallyLab " + (RallyClassifierExporter.buildRevision() ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")

    let sampler: SamplerModel
    let tool: String
    @ObservationIgnored private let lookUpSignedIn: @Sendable () async -> SignedIn

    // The draw and its recordings.
    private(set) var drawFiles: [URL] = []
    private(set) var draw: CoverageAudit.LoadedDraw?
    private(set) var statuses: [CoverageAudit.RecordingStatus] = []
    private(set) var pass: CoverageAudit.Pass = .first

    // The open recording.
    private(set) var admission: CoverageAudit.Admission?
    private(set) var file: CoverageAudit.File?
    /// The draw's intervals of the open recording that its marks or cut ranges have moved since the draw: no
    /// verdict can be given on them (a new draw is needed), so the queue passes them by.
    private(set) var movedIndices: Set<Int> = []
    private(set) var intervalIndex: Int?
    private(set) var player: AVPlayer?
    private(set) var playhead = 0.0
    private(set) var isPlaying = false
    private(set) var rate: Float = 2
    private(set) var trackers: [LookKey: CoverageAudit.PlayTracker] = [:]

    // The reviewer: the signed-in labeler's id when this Mac has a labeling session, else a name typed once. While
    // a session's account is not confirmed there is no reviewer, and no verdict is taken: the same person must
    // never be recorded under an id in one pass and a typed name in the other (the repeat's 24-hour rule and its
    // "second reviewer" go by the id).
    private(set) var signedIn = SignedIn.unknown
    var typedName = ""
    var reviewer: String {
        switch signedIn {
        case .labeler(let id): return id
        case .nobody: return typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        case .unknown: return ""
        }
    }

    // A finding in the making.
    private(set) var markIn: Double?
    private(set) var markOut: Double?
    var note = ""
    /// A finding waiting for its note (U with nothing typed): the note field takes the keys until Return.
    private(set) var awaitingNote: CoverageAudit.FindingKind?

    private(set) var status = "Open a draw."
    private(set) var lastRefused = false
    private(set) var busy = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var seekTarget: Double?
    /// Where the seeks in flight are going; nil once the player has landed.
    @ObservationIgnored private var destination: Double?
    /// Bumped by every open and close: work that finishes after a newer one changes nothing.
    @ObservationIgnored private var generation = 0
    /// The project the draw was opened in; a change of project closes everything.
    @ObservationIgnored private var drawRoot: URL?
    /// The verdicts given in this session, newest last, for undo.
    @ObservationIgnored private var undoStack: [LookKey] = []
    /// What was open when the tab was left, to come back to.
    @ObservationIgnored private var resume: (recordingId: String, index: Int?)?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    init(sampler: SamplerModel,
         tool: String = CoverageAuditModel.defaultTool,
         signedIn: @escaping @Sendable () async -> SignedIn = { await CoverageAuditModel.signedInLabeler() }) {
        self.sampler = sampler
        self.tool = tool
        lookUpSignedIn = signedIn
    }

    /// The labeling account of this Mac: its id once the session is in use; when a session is kept but not yet
    /// restored in this run, it is restored (a token refresh) so the account is known before a verdict is taken.
    nonisolated static func signedInLabeler() async -> SignedIn {
        let client = LabelingClient.shared
        if let id = await client.userId { return .labeler(id.uuidString.lowercased()) }
        guard await client.hasSession else { return .nobody }
        _ = try? await client.liveToken()
        return await client.userId.map { .labeler($0.uuidString.lowercased()) } ?? .unknown
    }

    var root: URL { sampler.datasetRoot }
    var recordingId: String? { admission?.recording.recordingId }
    var recording: CoverageAudit.Draw.Recording? { admission?.recording }

    // MARK: - The draw

    /// The tab came on screen: the draws on disk, who is reviewing, and what was open before.
    func activate() {
        if let drawRoot, drawRoot != root { projectChanged() }
        let dir = CoverageAudit.drawsDirectory(in: root)
        drawFiles = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-draw.json") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        Task { signedIn = await lookUpSignedIn() }
        if draw != nil { refreshStatus() }
        if let resume {
            self.resume = nil
            Task { await open(resume.recordingId, at: resume.index, play: false) }
        }
    }

    /// The tab left the screen: the player and its observers go; the place is remembered.
    func deactivate() {
        if let recordingId { resume = (recordingId, intervalIndex) }
        close()
    }

    func openDraw(_ url: URL) {
        close()
        resume = nil
        trackers = [:]
        undoStack = []
        do {
            draw = try CoverageAudit.loadDraw(url)
            drawRoot = root
            statuses = []
            status = "Draw \(draw?.draw.drawId ?? "") — pick a recording, or Return for the next interval to review."
            lastRefused = false
            refreshStatus()
        } catch {
            draw = nil
            statuses = []
            refuse(error.localizedDescription)
        }
    }

    /// What the records say, read off the main actor (the first read decodes every session file).
    func refreshStatus() {
        guard let draw else { return }
        let root = self.root
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try CoverageAudit.status(draw: draw, root: root) } }.value
            guard let self, !Task.isCancelled, self.draw == draw, self.root == root else { return }
            switch result {
            case .success(let statuses): self.statuses = statuses
            case .failure(let error):
                self.statuses = []
                self.refuse(error.localizedDescription)
            }
        }
    }

    /// The sync wrote a recording's record (looks given on the phone): the counts, and the open recording's record, read again.
    func recordSynced(root: URL, recordingId: String) {
        guard root == self.root, draw != nil else { return }
        refreshStatus()
        guard recordingId == self.recordingId, let draw, let admission else { return }
        let mine = generation
        Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) {
                try? CoverageAudit.existingRecord(of: admission.recording, video: admission.video, contentFingerprint: admission.contentFingerprint, draw: draw)
            }.value
            guard let self, self.generation == mine, self.recordingId == recordingId else { return }
            self.file = read
        }
    }

    func setPass(_ pass: CoverageAudit.Pass) {
        guard pass != self.pass else { return }
        if isPlaying { pause() }
        self.pass = pass
        clearPending()
        intervalIndex = nil
        // Nothing of the last pass's feedback stays on screen: in the blind repeat it would show the first verdict.
        say(Self.opening(pass))
        if let first = firstOpen(after: nil) ?? visibleIntervals.first?.index { select(first, play: false) }
    }

    /// The project (dataset root) changed or closed: nothing of the old one stays.
    func projectChanged() {
        close()
        statusTask?.cancel()
        draw = nil; drawRoot = nil; drawFiles = []; statuses = []; trackers = [:]; undoStack = []; resume = nil
        status = "Open a draw."
        lastRefused = false
    }

    // MARK: - A recording

    /// The open recording's intervals in the pass on screen: every drawn interval; the repeat set; the disagreements.
    var visibleIntervals: [CoverageAudit.Interval] {
        guard let recording else { return [] }
        switch pass {
        case .first: return recording.intervals
        case .repeatLook:
            let set = Set(CoverageAudit.repeatSet(recording, file: file))
            return recording.intervals.filter { set.contains($0.index) }
        case .resolution:
            let set = Set(file.map(CoverageAudit.disagreements) ?? [])
            return recording.intervals.filter { set.contains($0.index) }
        }
    }

    var interval: CoverageAudit.Interval? { intervalIndex.flatMap { recording?.interval($0) } }

    /// The look of the pass on screen at an interval (never another pass's: the repeat is blind to the first
    /// verdict). `playedWhole`: it covered the interval — always, for a clean.
    func look(at index: Int) -> (verdict: CoverageAudit.Verdict, findings: [CoverageAudit.Finding], playedWhole: Bool)? {
        guard let file else { return nil }
        switch pass {
        case .first:
            guard let r = file.review(index), r.span == recording?.interval(index)?.span else { return nil }
            return (r.verdict, r.findings, r.playedAllAtMaxRate != nil)
        case .repeatLook: return file.repeatReview(index).map { ($0.verdict, $0.findings, $0.playedAllAtMaxRate != nil) }
        case .resolution: return file.resolution(index).map { ($0.verdict, $0.findings, $0.playedAllAtMaxRate != nil) }
        }
    }

    var currentLook: (verdict: CoverageAudit.Verdict, findings: [CoverageAudit.Finding], playedWhole: Bool)? { intervalIndex.flatMap(look(at:)) }

    /// Whether the pass on screen still owes the interval a look: no verdict, or findings from a look that did not
    /// cover it. Intervals the marks have moved since the draw are passed by (no verdict can be given on them).
    private func needsLook(_ index: Int) -> Bool {
        !movedIndices.contains(index) && look(at: index)?.playedWhole != true
    }

    func open(_ name: String, at index: Int? = nil, play: Bool = true) async {
        guard let draw, name != recordingId || index != nil else { return }
        if name == recordingId, let index { select(index, play: play); return }
        close()
        let mine = generation
        let root = self.root
        busy = true
        let result = await Task.detached(priority: .userInitiated) { Result { try CoverageAudit.open(name, draw: draw, root: root) } }.value
        guard mine == generation else { return }
        busy = false
        switch result {
        case .failure(let error): refuse(error.localizedDescription)
        case .success(let opened):
            admission = opened.admission
            file = opened.file
            let current = Set(opened.admission.currentIntervals.map(\.span))
            movedIndices = Set(opened.admission.recording.intervals.filter { !current.contains($0.span) }.map(\.index))
            let player = AVPlayer(url: opened.admission.video)
            player.actionAtItemEnd = .pause
            self.player = player
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.observed(time.seconds) }
            }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reachedEnd() }
            }
            status = "\(name): \(opened.admission.recording.intervals.count) unmarked interval(s)."
            lastRefused = false
            if let target = index ?? firstOpen(after: nil) ?? visibleIntervals.first?.index { select(target, play: play) }
            refreshStatus()
        }
    }

    func close() {
        generation += 1
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause()
        player = nil; timeObserver = nil; endObserver = nil
        admission = nil; file = nil; movedIndices = []; intervalIndex = nil
        seeking = false; seekTarget = nil; destination = nil
        playhead = 0; isPlaying = false; busy = false
        clearPending()
    }

    // MARK: - Intervals

    /// What is played for an interval: the interval with a second of context either side, inside the recording.
    func shown(_ interval: CoverageAudit.Interval) -> ClosedRange<Double> {
        let end = CoverageAudit.seconds(recording?.durationTicks ?? interval.endTick)
        return max(0, CoverageAudit.seconds(interval.startTick) - CoverageAudit.contextSec)...min(end, CoverageAudit.seconds(interval.endTick) + CoverageAudit.contextSec)
    }

    private var key: LookKey? {
        guard let recordingId, let intervalIndex else { return nil }
        return LookKey(recordingId: recordingId, pass: pass, index: intervalIndex, reviewer: reviewer)
    }

    /// What of the interval on screen has been played in this look.
    var played: CoverageAudit.PlayedCoverage { key.flatMap { trackers[$0]?.played } ?? CoverageAudit.PlayedCoverage() }

    func select(_ index: Int, play: Bool = true) {
        guard let interval = recording?.interval(index), visibleIntervals.contains(interval) else { return }
        if isPlaying { pause() }
        intervalIndex = index
        clearPending()
        seek(to: shown(interval).lowerBound)
        if play { self.play() }
    }

    func step(forward: Bool) {
        let all = visibleIntervals.map(\.index)
        guard let current = intervalIndex, let at = all.firstIndex(of: current) else {
            if let first = all.first { select(first) }
            return
        }
        let next = at + (forward ? 1 : -1)
        guard all.indices.contains(next) else { say(forward ? "The last interval of this recording (Return: the next one to review)." : "The first interval of this recording."); return }
        select(all[next])
    }

    /// The first interval of the open recording, after `index`, that the pass on screen has no verdict on.
    private func firstOpen(after index: Int?) -> Int? {
        visibleIntervals.map(\.index).first { $0 > (index ?? -1) && needsLook($0) }
    }

    /// Whether the pass on screen has work left in a recording, by its status.
    private func hasWork(_ s: CoverageAudit.RecordingStatus) -> Bool {
        guard s.problem == nil else { return false }
        switch pass {
        case .first: return s.firstLeft > 0
        case .repeatLook: return s.repeatLeft > 0
        case .resolution: return s.resolveLeft > 0
        }
    }

    /// Return: the next interval the pass on screen has no verdict on — in this recording, then in the draw's next.
    func nextToReview() async {
        guard draw != nil else { return }
        // Findings recorded before the interval had played whole, and it has by now: said on the verdict first.
        if let interval, let look = currentLook, look.verdict == .notClean, !look.playedWhole, played.covers(interval.span) { _ = await commit(.playedWhole).value }
        if let next = firstOpen(after: intervalIndex) ?? firstOpen(after: nil), next != intervalIndex { select(next); return }
        let names = statuses.map(\.recordingId)
        let from = recordingId.flatMap(names.firstIndex(of:)).map { $0 + 1 } ?? 0
        let order = Array(statuses[min(from, statuses.count)...] + statuses[..<min(from, statuses.count)])
        guard !statuses.isEmpty else { say("Reading the draw's recordings…"); return }
        guard let target = order.first(where: { $0.recordingId != recordingId && hasWork($0) }) else {
            say(interval.map { needsLook($0.index) } == true ? "This is the last interval to review in this pass: play it whole, then its verdict." : "Nothing left to review in this pass.")
            return
        }
        await open(target.recordingId)
    }

    // MARK: - Playback

    /// Where playback is this instant: where a seek in flight is going, else the player's clock.
    var now: Double {
        if let destination { return destination }
        guard let t = player?.currentTime().seconds, t.isFinite else { return playhead }
        return t
    }

    func togglePlay() { isPlaying ? pause() : play() }

    private func play() {
        guard player != nil, let interval else { return }
        // Played to the end of what is shown: Space plays the interval again from its lead-in.
        if now >= shown(interval).upperBound - 0.05 { seek(to: shown(interval).lowerBound) }
        isPlaying = true
        // A seek in flight starts the player when it lands, so what is credited begins exactly where it landed.
        if destination == nil { startPlayer() }
    }

    /// Starts the player where it stands; what plays from here is credited.
    private func startPlayer() {
        guard let player, let key else { return }
        trackers[key, default: CoverageAudit.PlayTracker()].began(at: now)
        player.rate = rate
    }

    private func pause() {
        guard let player else { return }
        if let key, destination == nil { trackers[key]?.stopped(at: now, rate: Double(rate)) }
        player.pause()
        isPlaying = false
    }

    func setRate(_ value: Float) {
        guard Self.rates.contains(value) else { return }
        let running = isPlaying && destination == nil
        if running, let key { trackers[key]?.observed(now, rate: Double(rate)) }
        rate = value
        if running { player?.rate = value }
    }

    /// The player's clock, thirty times a second of recording time.
    private func observed(_ t: Double) {
        guard destination == nil, t.isFinite else { return }
        playhead = t
        guard isPlaying, let key, let interval else { return }
        trackers[key]?.observed(t, rate: Double(rate))
        if t >= shown(interval).upperBound { pause() }
    }

    private func reachedEnd() {
        guard isPlaying, destination == nil, let key, let recording else { return }
        trackers[key]?.reachedEnd(durationTicks: recording.durationTicks, rate: Double(rate))
        isPlaying = false
    }

    /// Moves the playhead inside what is shown for the interval. Seeking earns no coverage: what played up to
    /// here is credited, the player waits for the seek to land, and credit starts again from where it lands.
    func seek(to t: Double) {
        guard let interval, let player else { return }
        let range = shown(interval)
        let clamped = min(max(t, range.lowerBound), range.upperBound)
        if let key {
            if isPlaying, destination == nil { trackers[key]?.stopped(at: now, rate: Double(rate)) } else { trackers[key]?.jumped() }
        }
        player.pause()
        playhead = clamped
        seekTarget = clamped
        destination = clamped
        chaseSeek()
    }

    func skip(_ seconds: Double) { seek(to: now + seconds) }

    private func chaseSeek() {
        guard !seeking, let target = seekTarget, let player else { return }
        seeking = true
        seekTarget = nil
        let mine = generation
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                self.seeking = false
                if self.seekTarget != nil { self.chaseSeek(); return }
                self.destination = nil
                if self.isPlaying { self.startPlayer() }
            }
        }
    }

    // MARK: - Verdicts

    /// What is being prepared for the look on screen — marks in and out, a finding waiting for its note, the draft
    /// note — is that look's alone: dropped on a change of interval, pass or recording, so no other look (the blind
    /// repeat above all) shows or submits it.
    private func clearPending() {
        markIn = nil; markOut = nil; awaitingNote = nil; note = ""
    }

    private func say(_ text: String) { status = text; lastRefused = false }

    /// What the status line says on entering a pass — nothing of what was said in another.
    static func opening(_ pass: CoverageAudit.Pass) -> String {
        switch pass {
        case .first: return "First look: every drawn interval."
        case .repeatLook: return "Blind repeat: the first look's verdicts are hidden."
        case .resolution: return "Resolution: both looks, where they disagree."
        }
    }
    private func refuse(_ text: String) { status = text; lastRefused = true }

    func setMarkIn() {
        markIn = now
        markOut = nil
        say("Finding from \(clockText(now)) — press its key at its end (or O, then the key).")
    }

    func setMarkOut() {
        guard let markIn, now > markIn else { refuse("Mark where it starts first (I), then where it ends."); return }
        markOut = now
        say("Finding \(clockText(markIn))–\(clockText(now)) — now its key.")
    }

    /// C: nothing was left unmarked in the interval.
    func markClean() {
        let saving = commit(.clean)
        Task { if await saving.value { await nextToReview() } }
    }

    /// A finding's key. Its approximate times are the marked in/out, else the playhead. `alternate` (⇧): a missed
    /// rally clipped by the recording's start or end; for a boundary error, the other neighbouring mark than the
    /// one the time suggests.
    func addFinding(_ kind: CoverageAudit.FindingKind, alternate: Bool = false) {
        guard let interval, let recording else { return }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .uncertain, text.isEmpty {
            awaitingNote = kind
            say("Type what could not be told, then Return.")
            return
        }
        let t = now
        let start = markIn ?? t
        let end = markOut ?? (markIn != nil && t > start ? t : nil)
        let middle = CoverageAudit.seconds(interval.startTick + interval.endTick) / 2
        var edge: CoverageAudit.Edge?
        switch kind {
        case .boundaryError:
            let leading = (start + (end ?? start)) / 2 < middle
            edge = leading != alternate ? .leading : .trailing
        case .missedRally where alternate:
            let atStart = interval.startTick == 0, atEnd = interval.endTick == recording.durationTicks
            guard atStart || atEnd else { refuse("This interval touches neither end of the recording: a rally here is not clipped by it."); return }
            edge = atStart && (!atEnd || start < middle) ? .start : .end
        default: break
        }
        let finding = CoverageAudit.Finding(kind: kind, approxStartSec: start, approxEndSec: end, edge: edge, note: text.isEmpty ? nil : text)
        commit(.finding(finding))
    }

    /// Return in the note field: the finding that was waiting for its note is recorded.
    func noteSubmitted() {
        guard let kind = awaitingNote else { return }
        awaitingNote = nil
        addFinding(kind)
    }

    /// ⌫: the pass's whole verdict on the interval is taken back.
    func withdraw() { commit(.withdraw) }

    /// Z: the last verdict given in this session is taken back — its last finding, or its clean.
    func undo() async {
        guard let last = undoStack.last else { refuse("Nothing to undo in this session."); return }
        guard last.reviewer == reviewer else { refuse("The last verdict in this session is \(last.reviewer)'s: only \(last.reviewer) can undo it."); return }
        if last.recordingId != recordingId { await open(last.recordingId, at: last.index, play: false) }
        guard last.recordingId == recordingId else { return }
        if pass != last.pass { pass = last.pass }
        if intervalIndex != last.index { select(last.index, play: false) }
        _ = await commit(.withdrawLast).value
    }

    /// Sends one entry on the interval on screen through the shared operation (off the main actor) and shows what
    /// it wrote. Refused here, or taken (`busy` from this moment): the task's value is whether it was recorded.
    @discardableResult
    private func commit(_ entry: CoverageAudit.Entry) -> Task<Bool, Never> {
        guard let draw, let key, !busy else { return Task { false } }
        guard drawRoot == root else { projectChanged(); refuse("The project changed; open the draw again."); return Task { false } }
        if signedIn == .unknown {
            refuse("The signed-in labeler is not confirmed yet (the labeling session is being restored, or this Mac is offline). No verdict is taken until it is: one person is never recorded under two names.")
            Task { signedIn = await lookUpSignedIn() }
            return Task { false }
        }
        // What has played up to this key press counts for it.
        if isPlaying, destination == nil { trackers[key]?.observed(now, rate: Double(rate)) }
        let request = CoverageAudit.Request(recordingId: key.recordingId, index: key.index, pass: key.pass, entry: entry, reviewer: reviewer,
                                            played: trackers[key]?.played ?? CoverageAudit.PlayedCoverage(), note: key.pass == .resolution ? note : nil)
        let root = self.root, tool = self.tool, mine = generation
        busy = true
        return Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try CoverageAudit.record(request, draw: draw, root: root, tool: tool) } }.value
            guard mine == generation else { return false }
            busy = false
            // A save made in another pass than the one now on screen is kept, and says nothing: its feedback would be
            // that pass's verdict, shown during this one (the blind repeat).
            let samePass = key.pass == pass
            @MainActor func say(_ text: String) { if samePass { self.say(text) } }
            switch result {
            case .failure(let error):
                if samePass { refuse(error.localizedDescription) } else { self.say(Self.opening(pass) + " (A save of the previous pass was not taken; open it again to see why.)") }
                return false
            case .success(let written):
                file = written
                refreshStatus()
                switch entry {
                case .clean:
                    undoStack.append(key)
                    say("Interval \(key.index): clean.")
                case .finding(let finding):
                    undoStack.append(key)
                    clearPending()
                    note = ""
                    say("Interval \(key.index): \(finding.kind.rawValue)" + (finding.edge.map { " (\($0.rawValue))" } ?? "") + " at \(clockText(finding.approxStartSec ?? 0)) — Return for the next interval.")
                case .playedWhole:
                    say("Interval \(key.index): played whole, with its findings.")
                case .withdrawLast:
                    undoStack.removeLast()
                    say("Interval \(key.index): the last verdict is taken back.")
                case .withdraw:
                    undoStack.removeAll { $0 == key }
                    say("Interval \(key.index): no verdict in this pass.")
                }
                return true
            }
        }
    }

    // MARK: - The findings, for the marking pass

    func exportFindings() {
        guard let draw else { return }
        let root = self.root
        do {
            let list = try CoverageAudit.findingsList(draw: draw, root: root)
            let out = try CoverageAudit.writeFindings(list, in: root, stamp: RallyClassifierExporter.stampFormatter.string(from: Date()))
            say("\(list.findings.count) finding(s) → \(out.text.path) (and .json). The audit wrote no mark.")
        } catch { refuse(error.localizedDescription) }
    }
}
