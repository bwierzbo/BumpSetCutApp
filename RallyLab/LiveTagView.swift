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
//  the found rallies you passed over, and marks the video finished, so it
//  counts in rally scoring and the decision model's training.
//

import AVFoundation
import SwiftUI

struct LiveTagView: View {
    let session: VideoSession
    @Bindable var marker: RallyMarkModel
    let review: ProjectReviewStore
    let paths: BallPathBuilder
    let isActive: Bool
    let onClose: () -> Void
    let onDone: () -> Void

    @State private var tagger: LiveTagger
    @State private var speed: Float = 1

    private static let speeds: [Float] = [0.5, 1, 2, 3, 4]

    init(session: VideoSession, marker: RallyMarkModel, review: ProjectReviewStore, paths: BallPathBuilder, isActive: Bool,
         onClose: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.session = session
        self.marker = marker
        self.review = review
        self.paths = paths
        self.isActive = isActive
        self.onClose = onClose
        self.onDone = onDone
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
        .labelKeys(isActive: isActive, handleKey)
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
                        Color.clear.contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                marker.seek(to: tap.location.x / max(geo.size.width, 1) * marker.duration)
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
                key("N", "Not a rally", .red) { tagger.close(as: .other, press()) }
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
                if paths.building == session.name {
                    ProgressView().controlSize(.mini)
                    Text("Finding the ball… \(Int(paths.fraction * 100))%").font(.caption).foregroundStyle(.secondary)
                        .help("The pipeline is running over the video; once it's done, presses snap to where the ball changed course")
                } else if let why = paths.refused[session.name] {
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
                Button { finish() } label: { Label("That's every rally", systemImage: "flag.checkered") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(tagger.open != nil || tagger.cutFrom != nil)
                    .help("Every rally is marked — the video then counts in rally scoring (⌘↩)")
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

    /// Everything you didn't mark isn't a rally: pre-tracked rallies are
    /// turned down, found rallies dropped — except inside a cut range, which
    /// is not footage and is left alone (D-030); the video is finished.
    private func finish() {
        guard tagger.open == nil, tagger.cutFrom == nil else { return }
        if marker.isPlaying { marker.togglePlay() }
        let marks = marker.rallies
        let cuts = marker.cuts.normalised()
        func covered(_ a: Double, _ b: Double) -> Bool { marks.contains { min($0.end, b) - max($0.start, a) > 0.5 * (b - a) } }
        for t in session.tracks ?? [] where t.awaitsRallyCheck && !covered(t.start, t.end) && !cuts.overlaps(t.start, t.end) {
            review.setIsRally(false, AnnotationReview.RallyCheck(video: session.name, track: t.id, start: t.start, end: t.end))
        }
        for g in marker.openGuesses where !(session.notRallies ?? []).contains(where: { abs($0 - g.start) < 0.05 }) && !cuts.overlaps(g.start, g.end) {
            marker.sampler.addNotRally(start: g.start, session: session.name)
        }
        marker.wholeVideoMarked = true
        onDone()
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
        case "n": tagger.close(as: .other, press())
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

    func confirmPretracked(start: Double, end: Double) -> [TrackedRally] {
        var before: [TrackedRally] = []
        for t in session.tracks ?? [] where t.isMachine && min(t.end, end) - max(t.start, start) > 0.5 * (t.end - t.start) {
            before.append(t)
            let check = AnnotationReview.RallyCheck(video: session.name, track: t.id, start: t.start, end: t.end)
            review.replace(check, with: t.trimmed(start: start, end: end))
            review.setIsRally(true, check)
        }
        return before
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
