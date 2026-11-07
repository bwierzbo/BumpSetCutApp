//
//  LiveTagView.swift
//  RallyLab
//
//  Mark every rally in a video in one pass, live: watch at ½–4× and press
//  one key per event as it happens. S at the serve starts a rally; D at
//  the dead ball ends it; M ends it as a missed serve, N as not a rally;
//  X cuts out a stretch that is not footage (an instant replay), from one
//  press to the next, and ⇧X cuts from the clip's start to the next serve
//  for a clip that begins mid-rally (D-030); Z takes back the last press.
//  The touches inside a rally are advanced marking, not part of this pass
//  (D-028). The rules are LiveTagger's, shared with the phone.
//
//  Pre-tracked rallies inside a rally you mark are confirmed and trimmed to
//  it; "That's every rally" turns down the ones you never marked, drops
//  the found rallies you passed over, ends a cut still open at the
//  recording's end, and marks the video finished, so it counts in rally
//  scoring and the decision model's training. Then the footage-type step
//  (FootageTypeSheet, D-032): what the recording is — continuous, edited
//  or unknown — is the person's call, kept apart from the pass being
//  complete; "Footage type…" opens the same step any time.
//

import AVFoundation
import SwiftUI

struct LiveTagView: View {
    let session: VideoSession
    @Bindable var marker: RallyMarkModel
    let review: ProjectReviewStore
    let paths: BallPathBuilder
    let projects: ProjectsModel
    let isActive: Bool
    let onClose: () -> Void
    let onDone: () -> Void
    /// Skip this recording: set aside with the reason (the backlog), then on to the next task.
    let onSkip: (String) -> Void

    @State private var tagger: LiveTagger
    @State private var speed: Float = 1
    /// The footage-type step on screen, under the opening the recording is marked in.
    @State private var footageType: FootageTypeStep?
    /// Dragging the timeline: paused meanwhile, playing on again when the drag ends if it was.
    @State private var scrubbing = false
    @State private var playingBeforeScrub = false

    private struct FootageTypeStep: Identifiable {
        let id = UUID()
        /// Right after the pass (going on to the next task when it closes), or opened to change the type.
        let afterPass: Bool
        let opening: ProjectsModel.Opening
    }

    private static let speeds: [Float] = [0.5, 1, 2, 3, 4]

    init(session: VideoSession, marker: RallyMarkModel, review: ProjectReviewStore, paths: BallPathBuilder, projects: ProjectsModel, isActive: Bool,
         onClose: @escaping () -> Void, onDone: @escaping () -> Void, onSkip: @escaping (String) -> Void = { _ in }) {
        self.session = session
        self.marker = marker
        self.review = review
        self.paths = paths
        self.projects = projects
        self.isActive = isActive
        self.onClose = onClose
        self.onDone = onDone
        self.onSkip = onSkip
        _tagger = State(initialValue: LiveTagger(tracks: session.tracks ?? [],
                                                 store: ProjectLiveTagStore(session: session, marker: marker, review: review)))
    }

    var body: some View {
        VStack(spacing: 0) {
            LabelTaskHeader(title: "Mark the rallies", subtitle: session.name, onClose: onClose) {
                Picker("Speed", selection: $speed) {
                    ForEach(Self.speeds, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Playback speed (1–4; 0 for ½×)")
                Text("\(marker.rallies.count) marked").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button { showFootageType(afterPass: false) } label: { Label("Footage type…", systemImage: "film.stack") }
                    .help("What the recording is — continuous, edited or unknown — as confirmed in its footage-properties record; change it any time")
            }
            Divider()
            if marker.footageMissing {
                FootageMissingView(session: session, datasetRoot: marker.sampler.datasetRoot,
                                   reason: "It has no review copy here either.") { marker.reopen() }
            } else {
                HStack(spacing: 0) {
                    stage
                    Divider()
                    rallies
                }
            }
        }
        .onAppear {
            marker.open(sessionName: session.name)
            marker.rate = speed
            paths.ensure([session])
            loadPath()
        }
        .onChange(of: paths.finished) { loadPath() }
        .onDisappear { if marker.isPlaying { marker.togglePlay() } }
        .onChange(of: speed) { _, s in marker.rate = s }
        .onChange(of: marker.playhead) { _, t in
            if marker.isPlaying, marker.duration > 0, t >= marker.duration - 0.05 { marker.togglePlay() }
        }
        .labelKeys(isActive: isActive && footageType == nil, handleKey)
        .sheet(item: $footageType) { step in
            FootageTypeSheet(recording: FootageTypeConfirmation.Recording(name: session.name, sourcePath: session.sourcePath,
                                                                          cuts: marker.cuts.normalised(), ralliesMarked: marker.wholeVideoMarked),
                             opening: step.opening, projects: projects, duration: marker.duration > 0 ? marker.duration : nil, afterPass: step.afterPass) {
                footageType = nil
                if step.afterPass { onDone() }
            }
        }
    }

    // MARK: - The picture and the live state

    private var stage: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                ReviewStyle.stage
                if let player = marker.player { LabPlayerView(player: player, showsControls: false) }
                state.padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            RallyTimesBar(time: marker.playhead, duration: marker.duration, found: marker.guesses.map { [$0.start, $0.end] },
                          marked: marker.rallies.map { LabelRally(start: $0.start, end: $0.end) },
                          current: nil, pending: tagger.open,
                          ticks: marker.rallies.first { $0.contains(marker.playhead) }?.contacts.map(\.time) ?? [],
                          cuts: marker.cuts.map { [$0.start, $0.end] }, pendingCut: tagger.cutFrom)
                .frame(height: 22)
                .overlay {
                    GeometryReader { geo in
                        // A click lands exactly; a drag scrubs — the marker chases the pointer loosely (one seek
                        // in flight, a frame within a tenth of a second) and lands exactly when the drag ends.
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    if !scrubbing {
                                        scrubbing = true
                                        playingBeforeScrub = marker.isPlaying
                                        if marker.isPlaying { marker.togglePlay() }
                                    }
                                    marker.seek(to: drag.location.x / max(geo.size.width, 1) * marker.duration, exact: false)
                                }
                                .onEnded { drag in
                                    scrubbing = false
                                    marker.seek(to: drag.location.x / max(geo.size.width, 1) * marker.duration)
                                    if playingBeforeScrub, !marker.isPlaying { marker.togglePlay() }
                                })
                    }
                }
            controls
        }
        .padding(16)
    }

    /// Dead or in a rally, and the last press.
    private var state: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let from = tagger.cutFrom {
                    Circle().fill(.black).frame(width: 9, height: 9)
                    Text("Cut from \(from == 0 ? "the start" : clockText(from)) · X ends it, S at the next serve")
                } else if let open = tagger.open {
                    Circle().fill(.orange).frame(width: 9, height: 9)
                    Text("Rally · served at \(clockText(open))")
                } else {
                    Circle().fill(.secondary).frame(width: 9, height: 9)
                    Text("Dead ball · S at the serve")
                }
            }
            .font(.callout.weight(.semibold).monospacedDigit())
            if let note = tagger.recentNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                key("S", "Serve", .orange) { tagger.serve(press()) }
                key("D", "Dead ball", .green) { tagger.close(as: .rally, press()) }
                Divider().frame(height: 24)
                key("M", "Missed serve", .red) { tagger.close(as: .missedServe, press()) }
                    .help("A serve nothing followed — into the net, long, wide: no rally there; an excluded span for scoring and training")
                Divider().frame(height: 24)
                key("X", "Cut", .gray) { tagger.cut(press()) }
                    .help("Cut out footage: X where a replay starts, X again where it ends")
                key("⇧X", "Starts mid-rally", .gray) { tagger.cutFromStart() }
                    .help("The clip begins inside a rally: cut from its start up to the next serve (S)")
            }
            .controlSize(.large)
            HStack(spacing: 14) {
                Button { marker.togglePlay() } label: { Image(systemName: marker.isPlaying ? "pause.fill" : "play.fill") }
                    .help("Play / pause (Space)")
                Text(clockText(marker.playhead)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if paths.isBuilding(session) {
                    ProgressView().controlSize(.mini)
                    Text("Finding the ball… \(Int(paths.fraction * 100))%").font(.caption).foregroundStyle(.secondary)
                        .help("The pipeline is running over the video; once it's done, presses snap to where the ball changed course")
                } else if let why = paths.refusal(for: session) {
                    Text(why).font(.caption).foregroundStyle(.secondary)
                } else if marker.duration > 0 {
                    let covered = tagger.path.stretches.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
                    Text("Snaps to the ball on \(Int(min(1, covered / marker.duration) * 100))% of the video")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Where the ball was seen; a press within 0.4 s of it changing course moves to that moment")
                }
                Spacer()
                Text("Z takes back a press · ←/→ 2 s · ⌫ removes the rally here · X cuts out footage")
                    .font(.caption).foregroundStyle(.secondary)
                Menu {
                    ForEach(BacklogReason.allCases, id: \.self) { reason in
                        Button(reason.title) { if marker.isPlaying { marker.togglePlay() }; onSkip(reason.rawValue) }
                    }
                } label: { Label("Skip…", systemImage: "arrow.uturn.forward") }
                    .fixedSize()
                    .help("Not a good one to mark: set it aside (the backlog) with a reason and go on to the next; the marks made so far stay")
                Button { finish() } label: { Label("That's every rally", systemImage: "flag.checkered") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(tagger.open != nil || (tagger.cutFrom != nil && marker.duration <= 0))
                    .help("Every rally is marked — a cut still open ends at the recording's end, the video counts in rally scoring, and then you say what the footage is (⌘↩)")
            }
            .buttonStyle(.borderless)
        }
    }

    private func key(_ k: String, _ name: String, _ tint: Color = .accentColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(k).font(.headline)
                Text(name).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(tint)
        .buttonStyle(.bordered)
    }

    // MARK: - The marked rallies

    private var rallies: some View {
        List(selection: $marker.selectedId) {
            if !marker.cuts.isEmpty {
                Section("Cut out") {
                    ForEach(marker.cuts, id: \.self) { c in
                        HStack(spacing: 8) {
                            Image(systemName: "scissors").foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(clockText(c.start)) – \(clockText(c.end))").font(.callout.monospacedDigit())
                                Text(String(format: "%.1f s not footage", c.end - c.start)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { play(from: c.start - 1) }
                        .contextMenu {
                            Button("Play from here") { play(from: c.start - 1) }
                            Button("Remove", role: .destructive) { marker.setCuts(marker.cuts.filter { $0 != c }) }
                        }
                    }
                }
            }
            ForEach(marker.rallies) { r in
                HStack(spacing: 8) {
                    Image(systemName: r.kind == .rally ? "figure.volleyball" : r.kind == .missedServe ? "xmark.circle" : "minus.circle")
                        .foregroundStyle(r.kind == .rally ? Color.orange : Color.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(clockText(r.start)) – \(clockText(r.end))").font(.callout.monospacedDigit())
                        Text(r.kind == .rally ? (r.contacts.isEmpty ? String(format: "%.1f s", r.end - r.start)
                                                    : "\(r.contacts.count) touches") : r.kind.name)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(r.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { play(from: r.start - 1) }
                .contextMenu {
                    Button("Play from here") { play(from: r.start - 1) }
                    Button("Remove", role: .destructive) { marker.delete(r.id) }
                }
            }
        }
        .listStyle(.inset)
        .frame(width: 230)
        .overlay {
            if marker.rallies.isEmpty && marker.cuts.isEmpty {
                Text("Rallies you mark show here.\nDouble-click one to watch it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
    }

    // MARK: - Presses

    private func press() -> LiveTagger.Press {
        LiveTagger.Press(now: marker.now, playing: marker.isPlaying, rate: marker.rate)
    }

    /// Everything you didn't mark as a rally isn't one: pre-tracked rallies
    /// not mostly inside a marked rally are turned down, found rallies not
    /// touching one are dropped — a missed serve covers nothing (RallyTruth) —
    /// except inside a cut range, which is not footage and is left alone
    /// (D-030); the video is finished. Then the footage-type step: what the
    /// recording is, is the person's call, asked now and kept apart from the
    /// completion (D-032).
    private func finish() {
        guard tagger.open == nil else { return }
        if tagger.cutFrom != nil {
            // The rest of the recording is not footage: the open cut ends where the recording does (D-030).
            guard marker.duration > 0 else { return }
            tagger.finishCut(atEnd: marker.duration)
        }
        if marker.isPlaying { marker.togglePlay() }
        let truth = RallyTruth(marks: marker.rallies.map { RallyTruth.Mark(start: $0.start, end: $0.end, kind: $0.kind) },
                               cuts: marker.cuts, complete: true)
        let cuts = truth.cuts
        for t in session.tracks ?? [] where t.awaitsRallyCheck && !truth.coveredByRally(t.start, t.end) && !cuts.overlaps(t.start, t.end) {
            review.setIsRally(false, AnnotationReview.RallyCheck(video: session.name, track: t.id, start: t.start, end: t.end))
        }
        for g in marker.guesses where truth.rallySeconds(within: g.start, g.end) <= 0.3
            && !(session.notRallies ?? []).contains(where: { abs($0 - g.start) < 0.05 }) && !cuts.overlaps(g.start, g.end) {
            marker.sampler.addNotRally(start: g.start, session: session.name)
        }
        marker.wholeVideoMarked = true
        showFootageType(afterPass: true)
    }

    /// The footage-type step, under the project open now — the one the recording is marked in. With no project
    /// open there is nothing to confirm into: after the pass, straight on to the next task.
    private func showFootageType(afterPass: Bool) {
        guard let opening = projects.opening else { if afterPass { onDone() }; return }
        if marker.isPlaying { marker.togglePlay() }
        footageType = FootageTypeStep(afterPass: afterPass, opening: opening)
    }

    private func play(from t: Double) {
        marker.seek(to: max(0, t))
        if !marker.isPlaying { marker.togglePlay() }
    }

    /// The ball's path: the rallies tracked by hand, and the pipeline's
    /// sightings over the rest of the video once BallPathBuilder has them.
    private func loadPath() {
        tagger.path = BallPath(tracks: session.tracks ?? [], seen: paths.samples(for: session) ?? [])
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !marker.footageMissing else { return false }
        let flags = event.modifierFlags.intersection([.shift, .option, .command])
        switch event.keyCode {
        case 49: marker.togglePlay(); return true
        case 123: marker.skip(by: flags.contains(.shift) ? -10 : -2); return true
        case 124: marker.skip(by: flags.contains(.shift) ? 10 : 2); return true
        case 51, 117:
            if let r = marker.rallies.first(where: { $0.contains(marker.playhead) }) { marker.delete(r.id) }
            return true
        case 53: return tagger.cancel()
        default: break
        }
        guard let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if let n = Int(ch), let s = Self.speeds.first(where: { $0 == (n == 0 ? 0.5 : Float(n)) }) { speed = s; return true }
        switch ch {
        case "s": tagger.serve(press())
        case "d": tagger.close(as: .rally, press())
        case "m": tagger.close(as: .missedServe, press())
        case "x": if flags.contains(.shift) { tagger.cutFromStart() } else { tagger.cut(press()) }
        case "z": tagger.undo()
        default: return false
        }
        return true
    }
}

/// The Mac's marks: the rally mark model's rallies, and the project's
/// pre-tracked rallies through the review store.
@MainActor
final class ProjectLiveTagStore: LiveTagStore {
    let session: VideoSession
    let marker: RallyMarkModel
    let review: ProjectReviewStore

    init(session: VideoSession, marker: RallyMarkModel, review: ProjectReviewStore) {
        self.session = session
        self.marker = marker
        self.review = review
    }

    func mark(start: Double, end: Double, kind: RallyKind) -> AnyHashable {
        marker.mark(start: start, end: end, kind: kind).id
    }

    func delete(_ mark: AnyHashable) {
        if let id = mark as? UUID { marker.delete(id) }
    }

    func confirmPretracked(start: Double, end: Double, kind: RallyKind) -> [TrackedRally] {
        RallyTruth.pretrackedChanges(session.tracks ?? [], start: start, end: end, kind: kind).map { change in
            let check = AnnotationReview.RallyCheck(video: session.name, track: change.before.id, start: change.before.start, end: change.before.end)
            if change.after != change.before { review.replace(check, with: change.after) }
            review.setIsRally(change.isRally, check)
            return change.before
        }
    }

    func restore(_ rallies: [TrackedRally]) {
        for t in rallies {
            let check = AnnotationReview.RallyCheck(video: session.name, track: t.id, start: t.start, end: t.end)
            review.replace(check, with: t)
            review.setIsRally(t.isRally, check)
        }
    }

    func marks(overlapping start: Double, _ end: Double) -> [LiveTagger.ExistingMark] {
        marker.rallies.filter { min($0.end, end) - max($0.start, start) > 0 }.map {
            LiveTagger.ExistingMark(handle: $0.id, start: $0.start, end: $0.end, kind: $0.kind, contacts: $0.contacts.isEmpty ? nil : $0.contacts)
        }
    }

    func restoreMark(_ mark: LiveTagger.ExistingMark) -> AnyHashable {
        marker.mark(start: mark.start, end: mark.end, kind: mark.kind ?? .rally, contacts: mark.contacts ?? []).id
    }

    func cut(start: Double, end: Double) -> AnyHashable {
        let range = CutRange(start: start, end: end)
        marker.setCuts(marker.cuts + [range])
        return range
    }

    func uncut(_ cut: AnyHashable) {
        guard let range = cut as? CutRange, let i = marker.cuts.firstIndex(of: range) else { return }
        var cuts = marker.cuts
        cuts.remove(at: i)
        marker.setCuts(cuts)
    }
}
