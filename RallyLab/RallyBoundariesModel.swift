//
//  RallyBoundariesModel.swift
//  RallyLab
//
//  The Rally Boundaries tab's state (Stage 1, D-024; S1-b): the eligible recordings
//  with their coverage (EventInventory, read-only), the open recording's record
//  (through EventReview.open — the one guard, which refuses the withheld closure and
//  writes the ledger row), an AVPlayer on the ORIGINAL footage (never the scrub
//  proxy: commits need the exact frame), the video's frame times for stepping, the
//  legacy marks for display only, and the editor. Every commit validates and writes
//  the record atomically through EventReview.write, then reloads what it wrote.
//

import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class RallyBoundariesModel {
    let sampler: SamplerModel
    private(set) var recordings: [EventInventory.Recording] = []
    private(set) var inventoryProblem: String?
    private(set) var session: EventReview.Session?
    private(set) var editor: BoundaryEditor?
    private(set) var player: AVPlayer?
    private(set) var frames = FrameClock(times: [], frameRate: 30)
    private(set) var legacyMarks: [RallyMarkRecord] = []
    var showLegacy = true
    private(set) var playhead = 0.0
    private(set) var duration = 0.0
    private(set) var isPlaying = false
    private(set) var status = "Pick a recording."
    private(set) var lastRefused = false
    private var timeObserver: Any?
    private var seeking = false
    private var seekTarget: Double?
    private var seekExact = true
    /// The position last asked for while seeks are in flight (relative moves count from it).
    private var seekClock = SeekClock()
    private var framesTask: Task<Void, Never>?
    /// Bumped by every open and close: an open that finishes after a newer one (or after a close) is stale and changes nothing.
    private var generation = 0
    /// The dataset root the open recording belongs to; a project change closes it.
    private var openedRoot: URL?
    let annotator: String
    let tool: String

    init(sampler: SamplerModel, annotator: String = NSUserName(), tool: String = "RallyLab " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")) {
        self.sampler = sampler
        self.annotator = annotator
        self.tool = tool
    }

    var root: URL { sampler.datasetRoot }
    var sessionName: String? { session?.session.name }
    var file: EventReview.File? { editor?.file }

    // MARK: - Recordings

    /// The inventory, read-only: eligible recordings with their coverage; withheld ones are listed as such and never opened.
    func refreshRecordings() {
        do {
            recordings = try EventInventory.build(root: root).recordings
            inventoryProblem = nil
        } catch {
            recordings = []
            inventoryProblem = error.localizedDescription
        }
    }

    var eligible: [EventInventory.Recording] { recordings.filter { !$0.withheld } }

    // MARK: - Opening

    func open(_ name: String) async {
        guard name != sessionName else { return }
        guard let video = sampler.sessions.first(where: { $0.name == name }) else { status = "\(name) is not in the project."; return }
        close()
        generation += 1
        let mine = generation
        let root = self.root
        do {
            let opened = try await EventReview.open(video, root: root, tool: tool)
            // Another recording was chosen, or the project changed, while this one was opening: it is stale.
            guard mine == generation else { return }
            openedRoot = root
            session = opened
            var e = BoundaryEditor(file: opened.file, annotator: annotator, tool: tool)
            // A record from before the footage fingerprint was kept: open has just checked the name, so the footage
            // on disk is recorded as its original (written with the next commit; never overwrites one that exists).
            if opened.file.sourceFingerprint == nil, let current = ProjectsModel.fileFingerprint(atPath: video.sourcePath) { e.recordSourceFingerprint(current) }
            editor = e
            legacyMarks = (try? Data(contentsOf: RallyMarkModel.labelsURL(for: video.sourceURL))).flatMap { try? JSONDecoder().decode([RallyMarkRecord].self, from: $0) } ?? []
            duration = opened.file.durationSec
            let player = AVPlayer(url: video.sourceURL)
            player.isMuted = false
            self.player = player
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, !self.seeking else { return }
                    self.playhead = t.seconds
                }
            }
            frames = FrameClock(times: [], frameRate: opened.file.frameRate)
            framesTask = Task { [weak self] in
                let clock = await Self.frameClock(of: video.sourceURL, frameRate: opened.file.frameRate)
                guard let self, !Task.isCancelled, self.sessionName == name else { return }
                self.frames = clock
                // The original's frame identity, recorded once so a copy elsewhere can prove it shows the same
                // frames; written with the next commit (nothing is written on open).
                if !clock.isEmpty, self.editor?.file.frameTimesDigest == nil { self.editor?.recordFrameTimesDigest(clock.digest) }
            }
            let resume = EventReview.firstUnknown(in: opened.file)
            if let resume, resume > 0 { seek(to: resume) }
            status = opened.isNew ? "New record for \(name): review from the start; R marks reviewed through the playhead."
                : (resume.map { "Resumed at \(BoundaryEditor.clock($0)), the first unknown stretch." } ?? "\(name) is fully reviewed.")
        } catch {
            guard mine == generation else { return }
            status = error.localizedDescription
            lastRefused = true
        }
    }

    /// The project (dataset root) changed or closed: nothing of the old one stays open, and an open in flight is discarded.
    func projectChanged() {
        close()
        recordings = []
        inventoryProblem = nil
        status = "Pick a recording."
    }

    func close() {
        generation += 1
        if let player, let timeObserver { player.removeTimeObserver(timeObserver) }
        player?.pause()
        framesTask?.cancel()
        player = nil; timeObserver = nil; session = nil; editor = nil; legacyMarks = []; openedRoot = nil
        seekTarget = nil; seeking = false; seekClock = SeekClock()
        frames = FrameClock(times: [], frameRate: 30)
        playhead = 0; duration = 0; isPlaying = false; lastRefused = false
    }

    /// Every frame's presentation time, from the video track's sample cursor (the original footage).
    nonisolated static func frameClock(of url: URL, frameRate: Double) async -> FrameClock {
        FrameClock(times: (try? await FrameIdentity.allFrameTimes(of: url)) ?? [], frameRate: frameRate)
    }

    // MARK: - Playback

    /// Where playback is this instant: a key press wants the frame it was pressed on.
    var now: Double {
        guard let t = player?.currentTime().seconds, t.isFinite else { return playhead }
        return t
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.rate = 1 }
        isPlaying.toggle()
    }

    func seek(to t: Double, exact: Bool = true) {
        let clamped = max(0, duration > 0 ? min(t, duration) : t)
        playhead = clamped
        seekTarget = clamped
        seekExact = exact
        seekClock.request(clamped)
        chaseSeek()
    }

    private func chaseSeek() {
        guard !seeking, let target = seekTarget, let player else { return }
        seeking = true
        seekTarget = nil
        let tolerance = seekExact ? CMTime.zero : CMTime(value: 1, timescale: 10)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600_000), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if self.seekTarget == nil { self.seekClock.settled() }
                self.chaseSeek()
            }
        }
    }

    /// The time a relative move counts from: the position last asked for while a seek is in flight, else the player's.
    private var moveBase: Double { seekClock.base(playerTime: now) }

    func step(frames count: Int) {
        if isPlaying { togglePlay() }
        seek(to: frames.step(from: moveBase, by: count))
    }

    func skip(seconds: Double) {
        if isPlaying { togglePlay() }
        seek(to: moveBase + seconds)
    }

    var readout: String { frames.label(at: playhead) }

    // MARK: - Editing

    @discardableResult
    func perform(_ action: BoundaryEditor.Action) -> Bool {
        guard var e = editor, let session else { return false }
        // The project moved under an open recording (no project-change signal reached us): refuse to write into the old one.
        guard openedRoot == root else { projectChanged(); status = "The project changed; pick a recording again."; lastRefused = true; return false }
        if isPlaying, action != .select(nil) { togglePlay() }
        let outcome = e.apply(action, at: now, now: Date())
        if outcome.changed {
            do {
                try EventReview.write(e.file, to: session.fileURL)
                let written = try EventReview.read(session.fileURL)
                guard written == e.file else { status = "the record read back differs from what was written"; lastRefused = true; return false }
            } catch {
                status = "not saved: \(error.localizedDescription)"
                lastRefused = true
                return false
            }
        }
        editor = e
        status = outcome.message
        lastRefused = outcome.refused
        if outcome.changed { refreshRecordings() }
        return !outcome.refused
    }

    /// The sync wrote this recording's record (a push's reply or a pull): take it, keeping the draft, so the next
    /// commit carries the server's revision and shows what the server has.
    func recordSynced(root: URL, _ name: String, _ record: EventReview.File) {
        // The same session name exists in other projects: only the record of the project this recording was
        // opened from is taken.
        guard root == openedRoot, name == sessionName, var e = editor else { return }
        let changed = e.adopt(record)
        editor = e
        if changed { status = "record updated from the sync (revision \(record.revision))" }
    }

    /// The rally under the draft changed elsewhere: keep mine (commit replaces theirs, explicitly) or take theirs.
    func resolveDraftConflict(keepMine: Bool) {
        guard var e = editor, e.draftConflict != nil else { return }
        e.resolveDraftConflict(keepMine: keepMine)
        editor = e
        status = keepMine ? "keeping my edits over the other side's version; ⏎ commits them" : "took the other side's version"
        lastRefused = false
    }

    func select(_ id: UUID?) {
        perform(.select(id))
        if let r = editor?.selectedRally, let t = r.contact?.earliest ?? r.dead?.earliest { seek(to: t) }
    }

    /// `[` / `]`: the reviewed rally before or after the playhead (by its start), selected and shown.
    func selectAdjacent(forward: Bool) {
        guard let e = editor, let id = e.adjacentRally(to: now, forward: forward) else { status = forward ? "no rally after here" : "no rally before here"; lastRefused = true; return }
        select(id)
    }

    /// A click on the timeline: the reviewed rally under that moment, if any, else nothing selected.
    func selectRally(at t: Double) {
        guard let e = editor else { return }
        let hit = e.file.rallies.first { r in
            guard r.reviewState == .reviewed, let a = r.contact?.earliest ?? r.dead?.earliest, let b = r.dead?.latest ?? r.contact?.latest else { return false }
            return a <= t && t <= b
        }
        // Select unless the draft already holds this rally (a repeat click must not discard edits in progress).
        if hit?.rallyId != e.draft.rallyId || hit == nil && e.selected != nil { perform(.select(hit?.rallyId)) }
    }
}
