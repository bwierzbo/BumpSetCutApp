//
//  LiveTagView.swift
//  RallyLab
//
//  Mark every rally in a video in one pass, live: watch at 1–4× and press
//  one key per event as it happens. S at the serve starts a rally; P pass,
//  T set, A attack, B block, F free ball tag its touches; D at the dead
//  ball ends it. N ends it as not a rally (a missed serve when nothing
//  followed the serve). ⇧ far and ⌥ near say the side when the net guess
//  is wrong; Z takes back the last press. The rules are LiveTagger's,
//  shared with the phone.
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
    let isActive: Bool
    let onClose: () -> Void
    let onDone: () -> Void

    @State private var tagger: LiveTagger
    @State private var findingNet = false
    @State private var speed: Float = 2

    private static let speeds: [Float] = [1, 2, 3, 4]

    init(session: VideoSession, marker: RallyMarkModel, review: ProjectReviewStore, isActive: Bool,
         onClose: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.session = session
        self.marker = marker
        self.review = review
        self.isActive = isActive
        self.onClose = onClose
        self.onDone = onDone
        _tagger = State(initialValue: LiveTagger(tracks: session.tracks ?? [], net: session.netBox?.rect,
                                                 store: ProjectLiveTagStore(session: session, marker: marker, review: review)))
    }

    var body: some View {
        VStack(spacing: 0) {
            LabelTaskHeader(title: "Mark the rallies", subtitle: session.name, onClose: onClose) {
                Picker("Speed", selection: $speed) {
                    ForEach(Self.speeds, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Playback speed (1–4)")
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
        }
        .task { await findNet() }
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
                          current: nil, pending: tagger.open?.first?.time,
                          ticks: (tagger.open ?? marker.rallies.first { $0.contains(marker.playhead) }?.contacts ?? []).map(\.time))
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

    /// Dead or in a rally, the touches so far, and the last press.
    private var state: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let open = tagger.open {
                    Circle().fill(.orange).frame(width: 9, height: 9)
                    Text("Rally · \(clockText(open[0].time)) · \(open.count) \(open.count == 1 ? "touch" : "touches")")
                } else {
                    Circle().fill(.secondary).frame(width: 9, height: 9)
                    Text("Dead ball · S at the serve")
                }
            }
            .font(.callout.weight(.semibold).monospacedDigit())
            if let open = tagger.open {
                HStack(spacing: 6) {
                    ForEach(Array(open.enumerated()), id: \.offset) { _, c in chip(c) }
                }
            }
            if let note = tagger.recentNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }

    private func chip(_ c: RallyContact) -> some View {
        Text(c.kind.name + (c.side.map { " · \($0 == .near ? "near" : "far")" } ?? ""))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(c.kind == .serve ? Color.orange.opacity(0.35) : Color.white.opacity(0.15), in: Capsule())
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                key("S", "Serve", .orange) { tagger.serve(press()) }
                key("P", "Pass") { tagger.touch(.pass, press()) }
                key("T", "Set") { tagger.touch(.set, press()) }
                key("A", "Attack") { tagger.touch(.attack, press()) }
                key("B", "Block") { tagger.touch(.block, press()) }
                key("F", "Free ball") { tagger.touch(.freeBall, press()) }
                Divider().frame(height: 24)
                key("D", "Dead ball", .green) { tagger.close(as: .rally, press()) }
                key("N", "Not a rally", .red) { tagger.close(as: nil, press()) }
            }
            .controlSize(.large)
            HStack(spacing: 14) {
                Button { marker.togglePlay() } label: { Image(systemName: marker.isPlaying ? "pause.fill" : "play.fill") }
                    .help("Play / pause (Space)")
                Text(clockText(marker.playhead)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if findingNet { ProgressView().controlSize(.mini); Text("Finding the net…").font(.caption).foregroundStyle(.secondary) }
                else if tagger.net == nil { Text("No net found · sides are up to ⇧ far and ⌥ near").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("⇧ far · ⌥ near · Z takes back a press · ←/→ 2 s · ⌫ removes the rally here")
                    .font(.caption).foregroundStyle(.secondary)
                Button { finish() } label: { Label("That's every rally", systemImage: "flag.checkered") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(tagger.open != nil)
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
            if marker.rallies.isEmpty {
                Text("Rallies you mark show here.\nDouble-click one to watch it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
    }

    // MARK: - Presses

    private func press(_ flags: NSEvent.ModifierFlags = []) -> LiveTagger.Press {
        LiveTagger.Press(now: marker.now, playing: marker.isPlaying, rate: marker.rate,
                         side: flags.contains(.shift) ? .far : flags.contains(.option) ? .near : nil)
    }

    /// Everything you didn't mark isn't a rally: pre-tracked rallies are
    /// turned down, found rallies dropped; the video is finished.
    private func finish() {
        guard tagger.open == nil else { return }
        if marker.isPlaying { marker.togglePlay() }
        let marks = marker.rallies
        func covered(_ a: Double, _ b: Double) -> Bool { marks.contains { min($0.end, b) - max($0.start, a) > 0.5 * (b - a) } }
        for t in session.tracks ?? [] where t.awaitsRallyCheck && !covered(t.start, t.end) {
            review.setIsRally(false, AnnotationReview.RallyCheck(video: session.name, track: t.id, start: t.start, end: t.end))
        }
        for g in marker.openGuesses where !(session.notRallies ?? []).contains(where: { abs($0 - g.start) < 0.05 }) {
            marker.sampler.addNotRally(start: g.start, session: session.name)
        }
        marker.wholeVideoMarked = true
        onDone()
    }

    private func play(from t: Double) {
        marker.seek(to: max(0, t))
        if !marker.isPlaying { marker.togglePlay() }
    }

    /// The net, once per video, from the review copy; kept on the session.
    private func findNet() async {
        guard session.netBox == nil, tagger.net == nil, !findingNet,
              let url = session.playbackURL(in: marker.sampler.datasetRoot) else { return }
        findingNet = true
        defer { findingNet = false }
        guard let found = await LiveTagger.findNet(in: url) else { return }
        tagger.net = found.rect
        marker.sampler.setNetBox(found, session: session.name)
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
        if let n = Int(ch), let s = Self.speeds.first(where: { Int($0) == n }) { speed = s; return true }
        switch ch {
        case "s": tagger.serve(press(flags))
        case "p": tagger.touch(.pass, press(flags))
        case "t": tagger.touch(.set, press(flags))
        case "a": tagger.touch(.attack, press(flags))
        case "b": tagger.touch(.block, press(flags))
        case "f": tagger.touch(.freeBall, press(flags))
        case "d": tagger.close(as: .rally, press())
        case "n": tagger.close(as: nil, press())
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

    func mark(start: Double, end: Double, kind: RallyKind, contacts: [RallyContact]) -> AnyHashable {
        marker.mark(start: start, end: end, kind: kind, contacts: contacts).id
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
}
