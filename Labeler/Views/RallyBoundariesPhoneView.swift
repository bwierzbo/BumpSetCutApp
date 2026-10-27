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
    /// The video's displayed proportions (rotation applied), so a zoomed picture pans over the video, not its bars.
    private(set) var videoSize = CGSize(width: 16, height: 9)
    /// The magnification of the shown frame and the point of it in the middle (top-down fractions). It stays while
    /// frames step and play — only the display changes, never which frame is shown or marked — and is kept per
    /// recording on this phone, so reopening the recording comes back to the same view.
    private(set) var zoom: CGFloat = 1
    private(set) var centre = CGPoint(x: 0.5, y: 0.5)
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
        if let v = UserDefaults.standard.array(forKey: zoomKey) as? [Double], v.count == 3, v[0] >= 1 {
            zoom = v[0]; centre = CGPoint(x: v[1], y: v[2])
        }
    }

    private var zoomKey: String { "rallyBoundaries.zoom." + video.id.uuidString }

    static let maxZoom: CGFloat = 8

    /// Sets the view: magnification clamped to 1…maxZoom, the centre clamped so the picture keeps covering the view.
    func setView(zoom z: CGFloat, centre c: CGPoint, in view: CGSize) {
        zoom = min(max(z, 1), Self.maxZoom)
        centre = zoom == 1 ? CGPoint(x: 0.5, y: 0.5)
            : FrameCanvas.clampedCentre(c, shown: FrameCanvas.shown(content: videoSize, zoom: zoom, view: view), view: view)
    }

    /// Keeps the current view for this recording.
    func keepView() {
        if zoom == 1 { UserDefaults.standard.removeObject(forKey: zoomKey) }
        else { UserDefaults.standard.set([Double(zoom), Double(centre.x), Double(centre.y)], forKey: zoomKey) }
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
            let track = try? await asset.loadTracks(withMediaType: .video).first
            let rate = Double((try? await track?.load(.nominalFrameRate)) ?? 30)
            if let track, let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let shown = natural.applying(transform)
                if abs(shown.width) > 0, abs(shown.height) > 0 { videoSize = CGSize(width: abs(shown.width), height: abs(shown.height)) }
            }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, !self.seeking else { return }
                    self.playhead = t.seconds
                    self.isPlaying = self.player.rate > 0
                }
            }
            // The record: the server's (or the pending edit's), else a fresh one naming the ORIGINAL.
            if let existing = model.rallyEvents(for: video) {
                editor = BoundaryEditor(file: existing.record, annotator: annotator, tool: tool)
                revision = existing.revision
            } else {
                // A fresh record names the original: its published duration, never the copy's (a copy can keep
                // every frame start and still end earlier).
                let fresh = EventReview.File(video: video.sessionName ?? video.name, sourceFingerprint: video.sourceFingerprint, frameRate: rate > 0 ? rate : 30,
                                             durationSec: video.duration > 0 ? video.duration : duration, tool: tool, frameTimesDigest: video.frameTimesDigest)
                editor = BoundaryEditor(file: fresh, annotator: annotator, tool: tool)
                revision = 0
            }
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
        if let r = editor?.selectedRally, let t = r.contact?.earliest ?? r.dead?.earliest { seek(to: t) }
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
    @State private var pinchBase: CGFloat?
    @State private var panBase: CGPoint?

    init(model: LabelerModel, video: LabelVideo) {
        _m = State(initialValue: PhoneBoundaryModel(model: model, video: video))
    }

    var body: some View {
        VStack(spacing: 0) {
            picture
                .aspectRatio(16 / 9, contentMode: .fit)
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

    /// The frame, pinch to zoom and drag to look around; the view stays while frames step and play. Double-tap
    /// goes back to the whole frame. Only the display changes: marks land on the frame shown, as without zoom.
    private var picture: some View {
        GeometryReader { geo in
            let shown = FrameCanvas.shown(content: m.videoSize, zoom: m.zoom, view: geo.size)
            let o = FrameCanvas.origin(shown: shown, centre: m.centre, view: geo.size)
            PlayerLayer(player: m.player)
                .frame(width: shown.width, height: shown.height)
                .offset(x: o.x, y: o.y)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background(.black)
                .clipped()
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        guard m.zoom > 1 else { return }
                        let base = panBase ?? m.centre
                        if panBase == nil { panBase = base }
                        m.setView(zoom: m.zoom, centre: CGPoint(x: base.x - g.translation.width / shown.width,
                                                                y: base.y - g.translation.height / shown.height), in: geo.size)
                    }
                    .onEnded { _ in panBase = nil; m.keepView() })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { g in
                        let base = pinchBase ?? m.zoom
                        if pinchBase == nil { pinchBase = base }
                        m.setView(zoom: base * g.magnification, centre: m.centre, in: geo.size)
                    }
                    .onEnded { _ in pinchBase = nil; m.keepView() })
                .onTapGesture(count: 2) { m.setView(zoom: 1, centre: m.centre, in: geo.size); m.keepView() }
                .overlay(alignment: .topTrailing) {
                    if m.zoom > 1 {
                        Text(String(format: "%.1f×", m.zoom)).font(.caption2.monospacedDigit()).padding(4)
                            .background(.black.opacity(0.5)).foregroundStyle(.white).padding(6)
                    }
                }
        }
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
                                    legacyMarks: m.model.rallyTimes(for: m.video).rallies.map { ($0.start, $0.end) }, showLegacy: showLegacy,
                                    draft: draft, openSpanStart: e?.openSpan?.start, selected: e?.selected,
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

    /// The marking controls: the two events and Commit always in view, everything else under More. Holding an
    /// event button marks the LATEST frame it could be (an uncertain event); a tap marks the earliest.
    private var marking: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                eventButton("Serve contact", .contact)
                eventButton("Ball dead", .dead)
            }
            HStack(spacing: 8) {
                Button { m.perform(.commit) } label: { Text("Commit rally").font(.callout.bold()).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button { m.perform(.undo) } label: { Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly).frame(minWidth: 28) }
                    .buttonStyle(.bordered).controlSize(.large)
                more
            }
            HStack(spacing: 8) {
                Button { m.selectAdjacent(forward: false) } label: { Label("Previous", systemImage: "chevron.left") }
                Button { m.selectAdjacent(forward: true) } label: { Label("Next", systemImage: "chevron.right") }
                Spacer()
                Toggle("legacy", isOn: $showLegacy).toggleStyle(.switch).controlSize(.mini)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func eventButton(_ title: String, _ event: BoundaryEditor.Event) -> some View {
        Menu {
            Button { m.perform(.mark(event, .latest)) } label: { Label("Latest possible frame here", systemImage: "arrow.right.to.line") }
        } label: {
            Text(title).font(.callout.bold()).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
        } primaryAction: {
            m.perform(.mark(event, .earliest))
        }
        .buttonStyle(.bordered).controlSize(.large)
    }

    private var more: some View {
        Menu {
            Section("This event") {
                Button { m.perform(.toggleOccluded) } label: { Label("Occluded", systemImage: "eye.slash") }
                Button { m.perform(.toggleFlag("ambiguous")) } label: { Label("Ambiguous", systemImage: "questionmark") }
                Button { m.perform(.cycleKind) } label: { Label("Kind: \(m.editor?.draft.kind.rawValue ?? "rally") (change)", systemImage: "tag") }
                Button { m.perform(.cycleEdge) } label: { Label("Edge: \(m.editor?.draft.edge?.rawValue ?? "none") (change)", systemImage: "rectangle.portrait.and.arrow.right") }
            }
            Section("Spans (tap at start and end)") {
                Button { m.perform(.span(.nonRallyActivity)) } label: { Label("Non-rally span", systemImage: "figure.walk") }
                Button { m.perform(.span(.transition)) } label: { Label("Transition", systemImage: "arrow.left.arrow.right") }
                Button { m.perform(.span(.uncertain)) } label: { Label("Uncertain", systemImage: "questionmark.circle") }
            }
            Section("Review") {
                Button { m.perform(.reviewedThrough) } label: { Label("Reviewed through here", systemImage: "checkmark.circle") }
                Button { m.perform(.cancel) } label: { Label("Cancel draft", systemImage: "xmark") }
                Button(role: .destructive) { m.perform(.withdraw) } label: { Label("Withdraw rally", systemImage: "delete.left") }
                Button { m.perform(.complete) } label: { Label("Complete recording", systemImage: "flag.checkered") }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly).frame(minWidth: 28)
        }
        .buttonStyle(.bordered).controlSize(.large)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = m.editor {
                Text(e.draft.rallyId == nil ? "New rally" : "Editing rally \(e.draft.rallyId!.uuidString.prefix(8))").font(.caption.bold())
                Text(draftLine(e.draft)).font(.caption)
                if let s = e.openSpan { Text("\(s.kind.rawValue) open from \(BoundaryEditor.clock(s.start))").font(.caption).foregroundStyle(.orange) }
                let reviewed = e.reviewedRallies
                Text("\(reviewed.count) rallies · \(e.file.rallies.count - reviewed.count) withdrawn · \(e.file.spans.count) spans").font(.caption.bold()).padding(.top, 4)
                ForEach(reviewed, id: \.rallyId) { r in
                    Button { m.select(r.rallyId) } label: {
                        Text("\(r.kind.rawValue) \(r.contact.map { BoundaryEditor.clock($0.earliest) } ?? "?") → \(r.dead.map { BoundaryEditor.clock($0.earliest) } ?? "?")" + (r.flags.isEmpty ? "" : " ⚑"))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(r.rallyId == e.selected ? Color.accentColor : Color.primary)
                    }.buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
