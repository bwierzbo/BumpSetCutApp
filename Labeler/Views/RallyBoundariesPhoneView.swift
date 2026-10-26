//
//  RallyBoundariesPhoneView.swift
//  Labeler (iPhone)
//
//  Stage 1 rally-boundary review on the phone (D-024), the same record and the same
//  rules as RallyLab's Review tab (Labeler/Shared: EventReview, BoundaryEditor,
//  FrameIdentity), with touch controls: play and scrub, step by the copy's own frames,
//  mark the serve contact and the ball dead with uncertainty, spans, reviewed-through
//  coverage, commit, withdraw, undo, complete. Playback is always allowed; a commit
//  needs the recording to be reviewable here and the downloaded copy's frames to
//  reproduce the original's digest (CommitGate) — a streamed or unverified copy is
//  playback only. Edits are queued for the Mac through the outbox at the revision they
//  were loaded from; a conflict is shown, never merged over.
//

import AVFoundation
import SwiftUI

@MainActor @Observable
final class PhoneBoundaryModel {
    let model: LabelerModel
    let video: LabelVideo
    private(set) var player = AVPlayer()
    private(set) var editor: BoundaryEditor?
    private(set) var revision = 0
    private(set) var frames = FrameClock(times: [], frameRate: 30)
    private(set) var gate = CommitGate(verdict: .copyNotDownloaded)
    private(set) var playhead = 0.0
    private(set) var duration = 0.0
    private(set) var isPlaying = false
    private(set) var status = ""
    private(set) var lastRefused = false
    private(set) var loadError: String?
    private(set) var isLocal = false
    private(set) var downloading = false
    /// How much of the original lies past the copy's end (a shorter final frame, a lost audio tail): that stretch
    /// cannot be reviewed from this copy and stays unknown here — the Mac reviews it on the original.
    private(set) var unreachableTail = 0.0
    private var observer: Any?
    private var seekClock = SeekClock()
    private var seeking = false
    private var seekTarget: Double?
    private var seekExact = true
    let annotator: String
    let tool = "Labeler " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")

    init(model: LabelerModel, video: LabelVideo) {
        self.model = model
        self.video = video
        self.annotator = model.account ?? "phone"
    }

    var file: EventReview.File? { editor?.file }
    /// The original's published identity: its frame digest, counted only together with its content fingerprint
    /// (the Mac publishes both; a record can be saved only for footage the server knows by fingerprint).
    private var publishedIdentity: String? { video.sourceFingerprint == nil ? nil : video.frameTimesDigest }
    /// A record the sync would not take for this recording (another recording's, or other footage), with why.
    var identityProblem: String? { model.eventIdentityProblems[video.id] }
    var canCommit: Bool { gate.allowed && editor != nil }
    var conflict: LabelRallyEvents? { model.eventConflicts[video.id] }

    // MARK: - Loading

    func load() async {
        guard player.currentItem == nil else { return }
        do {
            let url = try await model.playbackURL(for: video)
            isLocal = LocalStore.hasClip(video)
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            let asset = AVURLAsset(url: url)
            // The player's range is the copy's; the record's duration is the ORIGINAL's (published with the copy).
            duration = (try? await asset.load(.duration).seconds) ?? video.duration
            if video.duration > duration + 1.0 / 30 { unreachableTail = video.duration - duration }
            let rate = Double((try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)) ?? 30)
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, !self.seeking else { return }
                    self.playhead = t.seconds
                    self.isPlaying = self.player.rate > 0
                }
            }
            // The record: the server's (or the pending edit's), else a fresh one naming the ORIGINAL.
            var e: BoundaryEditor
            if let existing = model.rallyEvents(for: video) {
                e = BoundaryEditor(file: existing.record, annotator: annotator, tool: tool)
                revision = existing.revision
            } else {
                // A fresh record names the original: its published duration, never the copy's (a copy can keep
                // every frame start and still end earlier).
                let fresh = EventReview.File(video: video.sessionName ?? video.name, sourceFingerprint: video.sourceFingerprint, frameRate: rate > 0 ? rate : 30,
                                             durationSec: video.duration > 0 ? video.duration : duration, tool: tool, frameTimesDigest: video.frameTimesDigest)
                e = BoundaryEditor(file: fresh, annotator: annotator, tool: tool)
                revision = 0
            }
            e.legacyMarks = model.rallyTimes(for: video).rallies.enumerated().map { BoundaryEditor.LegacyMark(index: $0.offset, start: $0.element.start, end: $0.element.end) }
            editor = e
            await verifyFrames(local: isLocal ? url : nil)
            if let f = editor?.file, let resume = EventReview.firstUnknown(in: f), resume > 0 { seek(to: resume) }
            status = gate.reason + (unreachableTail > 0 ? String(format: " · the copy ends %.2f s before the original: that stretch is reviewed on the Mac", unreachableTail) : "")
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Reads the downloaded copy's own frame times and decides whether commits are allowed here.
    private func verifyFrames(local url: URL?) async {
        let reviewable = model.isReviewable(video)
        guard let url else {
            gate = CommitGate.decide(reviewable: reviewable, publishedDigest: publishedIdentity, copyFrames: nil)
            return
        }
        let result: Result<[Double], Error>
        do { result = .success(try await FrameIdentity.allFrameTimes(of: url)) } catch { result = .failure(error) }
        if case .success(let times) = result, let rate = editor?.file.frameRate { frames = FrameClock(times: times, frameRate: rate) }
        gate = CommitGate.decide(reviewable: reviewable, publishedDigest: publishedIdentity, copyFrames: result)
    }

    /// Downloads the copy (for frame-exact review), then verifies it and plays it from the file.
    func download() async {
        guard !downloading else { return }
        downloading = true
        defer { downloading = false }
        do {
            let file = try await model.localClip(for: video)
            let t = playhead
            player.replaceCurrentItem(with: AVPlayerItem(url: file))
            isLocal = true
            await verifyFrames(local: file)
            seek(to: t)
            status = gate.reason
        } catch {
            status = "download failed: \(error.localizedDescription)"
            lastRefused = true
        }
    }

    func unload() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Playback

    var now: Double {
        guard let t = player.currentItem.map({ _ in player.currentTime().seconds }), t.isFinite else { return playhead }
        return t
    }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.playImmediately(atRate: 1) }
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
        guard !seeking, let target = seekTarget else { return }
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
        guard var e = editor else { return false }
        if isPlaying { togglePlay() }
        // A change to the record needs the gate open; selecting, marking a draft and cancelling never write.
        let writes: Bool
        switch action {
        case .commit, .complete, .withdraw, .undo, .reviewedThrough, .span: writes = true
        default: writes = false
        }
        if writes, !canCommit { status = "commit refused: " + gate.reason; lastRefused = true; return false }
        // An event is a frame of the copy that proved itself: a mark lands on the presentation time of the frame
        // being shown, never on the player's clock between frames; without verified frame times (streamed or
        // unverified copy) nothing is marked. Coverage and spans take the playhead itself.
        var at = now
        if action.landsOnFrame {
            guard let shown = frames.snap(now) else { status = "marking needs the downloaded, verified copy: " + gate.reason; lastRefused = true; return false }
            at = shown
        }
        let outcome = e.apply(action, at: at, now: Date())
        if outcome.changed {
            do { try EventReview.validate(e.file) } catch { status = error.localizedDescription; lastRefused = true; return false }
            guard model.saveRallyEvents(e.file, for: video, expected: revision) else {
                status = "not saved: " + (model.saveRefusal(e.file, for: video) ?? "not reviewable here"); lastRefused = true; return false
            }
        }
        editor = e
        status = outcome.message
        lastRefused = outcome.refused
        return !outcome.refused
    }

    /// The rally under the draft changed elsewhere (a pull): keep mine (commit replaces theirs) or take theirs.
    func resolveDraftConflict(keepMine: Bool) {
        guard var e = editor, e.draftConflict != nil else { return }
        e.resolveDraftConflict(keepMine: keepMine)
        editor = e
        status = keepMine ? "keeping my edits over the other side's version; Commit saves them" : "took the other side's version"
        lastRefused = false
    }

    func select(_ id: UUID?) {
        perform(.select(id))
        guard let r = editor?.selectedRally else { return }
        if secondReview { if let s = r.legacyStart { seek(to: max(0, s - 3)) } } else if let t = r.contact?.earliest ?? r.dead?.earliest { seek(to: t) }
    }

    var secondReview: Bool { editor?.mode == .secondReview }

    /// The blind repeat (protocol §6), the same rule as the Mac: the first result hidden, S and D marked again.
    func setSecondReview(_ on: Bool) {
        guard var e = editor else { return }
        e.setMode(on ? .secondReview : .first)
        editor = e
        status = on ? "second review: pick a rally, mark contact and dead again blind, then Commit" : "review"
        lastRefused = false
    }

    func selectAdjacent(forward: Bool) {
        guard let e = editor, let id = e.adjacentRally(to: now, forward: forward) else { status = forward ? "no rally after here" : "no rally before here"; lastRefused = true; return }
        select(id)
    }

    func selectRally(at t: Double) {
        guard let e = editor else { return }
        let hit = e.file.rallies.first { r in
            guard r.reviewState == .reviewed, let a = r.contact?.earliest ?? r.dead?.earliest, let b = r.dead?.latest ?? r.contact?.latest else { return false }
            return a <= t && t <= b
        }
        if hit?.rallyId != e.draft.rallyId || hit == nil && e.selected != nil { perform(.select(hit?.rallyId)) }
    }

    /// The store's row for this recording changed under the open editor — a flush came back with the server's
    /// revision, or a pull brought the other side's edit: the editor adopts it (draft kept) and the next save
    /// carries that revision. Nothing happens while a conflict is open (the person decides it).
    func storeChanged() {
        guard conflict == nil, var e = editor, let existing = model.rallyEvents(for: video) else { return }
        let changed = e.adopt(existing.record)
        editor = e
        revision = existing.revision
        if changed { status = "record updated from the sync (revision \(existing.revision))" }
    }

    /// The person decided a conflict: take the server's version (and reload it) or keep mine on top of it.
    func resolveConflict(takeServer: Bool) {
        model.resolveEventConflict(video, takeServer: takeServer)
        if takeServer, let existing = model.rallyEvents(for: video) {
            editor = BoundaryEditor(file: existing.record, annotator: annotator, tool: tool)
            revision = existing.revision
        } else if let existing = model.rallyEvents(for: video) {
            revision = existing.revision
        }
        status = takeServer ? "took the server's version" : "kept mine; it saves on top of the server's"
    }
}

struct RallyBoundariesPhoneView: View {
    @State private var m: PhoneBoundaryModel
    @State private var showLegacy = false

    init(model: LabelerModel, video: LabelVideo) {
        _m = State(initialValue: PhoneBoundaryModel(model: model, video: video))
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayer(player: m.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .overlay { if let e = m.loadError { Text(e).foregroundStyle(.white).padding() } }
            readout.padding(.horizontal).padding(.top, 6)
            timeline.frame(height: 44).padding(.horizontal).padding(.top, 4)
            transport.padding(.vertical, 6)
            gateBanner
            if let c = m.conflict { conflictBanner(c) }
            if let why = m.identityProblem {
                Label(why, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.12)).padding(.horizontal)
            }
            if let d = m.editor?.draftConflict { draftConflictBanner(d) }
            ScrollView {
                VStack(spacing: 10) {
                    marking
                    inspector
                }
                .padding(.horizontal)
            }
            Text(m.status).font(.caption).foregroundStyle(m.lastRefused ? .red : .secondary).lineLimit(2).padding(.horizontal).padding(.bottom, 4)
        }
        .navigationTitle(m.video.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await m.load() }
        .onChange(of: m.model.rallyEvents(for: m.video)?.revision) { m.storeChanged() }
        .onChange(of: m.model.rallyEvents(for: m.video)?.record) { m.storeChanged() }
        .onDisappear { m.unload() }
    }

    private var readout: some View {
        HStack {
            Text(m.readout).font(.system(.callout, design: .monospaced))
            Spacer()
            if let f = m.file {
                let reviewed = EventReview.union(f.coverage).reduce(0) { $0 + $1.end - $1.start }
                Text(f.stage1Complete != nil ? "fully reviewed" : String(format: "%.0f %% reviewed · %d gap(s)", reviewed / f.durationSec * 100, EventReview.gaps(in: f).count))
                    .font(.caption).foregroundStyle(f.stage1Complete != nil ? .green : .secondary)
            }
        }
    }

    private var timeline: some View {
        let e = m.editor
        let draft: (start: Double, end: Double)? = {
            guard let d = e?.draft, let a = d.contact?.earliest ?? d.dead?.earliest, let b = d.dead?.latest ?? d.contact?.latest else { return nil }
            return (a, b)
        }()
        return BoundaryTimelineView(file: m.file, duration: m.duration, playhead: m.playhead,
                                    legacyMarks: m.model.rallyTimes(for: m.video).rallies.map { ($0.start, $0.end) }, showLegacy: showLegacy && !m.secondReview,
                                    draft: draft, openSpanStart: e?.openSpan?.start, selected: e?.selected, hideRallyTimes: m.secondReview,
                                    seek: { t, exact in m.seek(to: t, exact: exact) }, select: { t in m.selectRally(at: t) })
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Button { m.skip(seconds: -1) } label: { Image(systemName: "gobackward") }
            Button { m.step(frames: -5) } label: { Image(systemName: "backward.end") }
            Button { m.step(frames: -1) } label: { Image(systemName: "backward.frame") }.buttonRepeatBehavior(.enabled)
            Button { m.togglePlay() } label: { Image(systemName: m.isPlaying ? "pause.fill" : "play.fill").font(.title2) }
            Button { m.step(frames: 1) } label: { Image(systemName: "forward.frame") }.buttonRepeatBehavior(.enabled)
            Button { m.step(frames: 5) } label: { Image(systemName: "forward.end") }
            Button { m.skip(seconds: 1) } label: { Image(systemName: "goforward") }
        }
        .font(.title3)
    }

    @ViewBuilder private var gateBanner: some View {
        if !m.gate.allowed {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text(m.gate.reason).font(.caption)
                Spacer()
                if case .copyNotDownloaded = m.gate.verdict {
                    Button(m.downloading ? "Downloading…" : "Download") { Task { await m.download() } }.disabled(m.downloading).controlSize(.small).buttonStyle(.bordered)
                }
            }
            .padding(8).background(Color.orange.opacity(0.15)).padding(.horizontal)
        }
    }

    private func conflictBanner(_ c: LabelRallyEvents) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This record changed elsewhere (server revision \(c.revision)). Your edits are kept until you decide.").font(.caption)
            HStack {
                Button("Take the server's") { m.resolveConflict(takeServer: true) }
                Button("Keep mine") { m.resolveConflict(takeServer: false) }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(8).background(Color.red.opacity(0.12)).padding(.horizontal)
    }

    private func draftConflictBanner(_ d: BoundaryEditor.DraftConflict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This rally changed on the other side while you were editing it (there: contact \(describe(d.incoming.contact)), dead \(describe(d.incoming.dead))).").font(.caption)
            HStack {
                Button("Keep mine") { m.resolveDraftConflict(keepMine: true) }
                Button("Take theirs") { m.resolveDraftConflict(keepMine: false) }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(8).background(Color.red.opacity(0.12)).padding(.horizontal)
    }

    private var marking: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                action("Serve contact", "s") { m.perform(.mark(.contact, .earliest)) }
                action("…latest", "s") { m.perform(.mark(.contact, .latest)) }
                action("Ball dead", "d") { m.perform(.mark(.dead, .earliest)) }
                action("…latest", "d") { m.perform(.mark(.dead, .latest)) }
            }
            HStack(spacing: 8) {
                action("Occluded", "eye.slash") { m.perform(.toggleOccluded) }
                action("Ambiguous", "questionmark") { m.perform(.toggleFlag("ambiguous")) }
                action("Kind: \(m.editor?.draft.kind.rawValue ?? "rally")", "k") { m.perform(.cycleKind) }
                action("Edge", "e") { m.perform(.cycleEdge) }
            }
            HStack(spacing: 8) {
                action("Non-rally span", "n", tint: .orange) { m.perform(.span(.nonRallyActivity)) }
                action("Transition", "t", tint: .gray) { m.perform(.span(.transition)) }
                action("Uncertain", "u", tint: .purple) { m.perform(.span(.uncertain)) }
            }
            HStack(spacing: 8) {
                action("Reviewed through here", "r", tint: .green) { m.perform(.reviewedThrough) }
                action("Commit rally", "return", prominent: true) { m.perform(.commit) }
            }
            HStack(spacing: 8) {
                action("Withdraw", "delete.left") { m.perform(.withdraw) }
                action("Undo", "arrow.uturn.backward") { m.perform(.undo) }
                action("Cancel", "xmark") { m.perform(.cancel) }
                action("Complete", "flag.checkered", tint: .green) { m.perform(.complete) }
            }
            HStack(spacing: 8) {
                Button { m.selectAdjacent(forward: false) } label: { Label("Previous rally", systemImage: "chevron.left") }
                Button { m.selectAdjacent(forward: true) } label: { Label("Next rally", systemImage: "chevron.right") }
                Spacer()
                Toggle("legacy", isOn: $showLegacy).toggleStyle(.switch).controlSize(.mini).disabled(m.secondReview)
                Toggle("2nd review", isOn: Binding(get: { m.secondReview }, set: { m.setSecondReview($0) })).toggleStyle(.switch).controlSize(.mini)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func action(_ title: String, _ symbol: String, tint: Color? = nil, prominent: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Text(title).font(.caption).lineLimit(1).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered).tint(prominent ? Color.accentColor : tint).controlSize(.regular)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = m.editor {
                Text(e.mode == .secondReview ? "Second review (blind)" + (e.draft.rallyId.map { " of \($0.uuidString.prefix(8))" } ?? ": pick a rally") : e.draft.rallyId == nil ? "New rally" : "Editing rally \(e.draft.rallyId!.uuidString.prefix(8))").font(.caption.bold())
                Text(draftLine(e.draft)).font(.caption)
                if let s = e.openSpan { Text("\(s.kind.rawValue) open from \(BoundaryEditor.clock(s.start))").font(.caption).foregroundStyle(.orange) }
                let reviewed = e.reviewedRallies
                Text("\(reviewed.count) rallies · \(e.file.rallies.count - reviewed.count) withdrawn · \(e.file.spans.count) spans").font(.caption.bold()).padding(.top, 4)
                ForEach(reviewed, id: \.rallyId) { r in
                    Button { m.select(r.rallyId) } label: {
                        Text(rallyLine(r, blind: e.mode == .secondReview))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(r.rallyId == e.selected ? Color.accentColor : Color.primary)
                    }.buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A reviewed rally's line; blind in a second review (the first result is not shown).
    private func rallyLine(_ r: EventReview.Rally, blind: Bool) -> String {
        if blind { return "rally \(r.rallyId.uuidString.prefix(8))" + (r.legacyIndex.map { " (legacy #\($0))" } ?? "") + (r.secondReview == nil ? "" : " ✓✓") }
        return "\(r.kind.rawValue) \(r.contact.map { BoundaryEditor.clock($0.earliest) } ?? "?") → \(r.dead.map { BoundaryEditor.clock($0.earliest) } ?? "?")" + (r.flags.isEmpty ? "" : " ⚑")
    }

    private func draftLine(_ d: BoundaryEditor.Draft) -> String {
        var line = "contact " + describe(d.contact) + " · dead " + describe(d.dead)
        if let edge = d.edge { line += " · edge " + edge.rawValue }
        if !d.flags.isEmpty { line += " · " + d.flags.joined(separator: ", ") }
        return line
    }

    private func describe(_ e: EventReview.EventTime?) -> String {
        guard let e else { return "—" }
        let t = e.earliest == e.latest ? BoundaryEditor.clock(e.earliest) : "\(BoundaryEditor.clock(e.earliest))–\(BoundaryEditor.clock(e.latest))"
        return t + (e.visibility == .occluded ? " (occluded)" : "") + (e.isAmbiguous ? " ambiguous" : "")
    }
}
