//
//  LabelReviewView.swift
//  RallyLab
//
//  Finish a video's rally times by confirming instead of marking from
//  scratch, as on the phone. 1) Each rally RallyLab found plays looping
//  from a second before it, over a filmstrip with handles on its start and
//  end: drag them (or ←/→ nudge the start, ⇧←/→ the end) to the serve and
//  the dead ball, then Right (↩) marks it as the handles stand · Not a
//  rally (X). 2) Skim the rest at 2× and press M when a rally starts that
//  wasn't found (it backs up for your reaction), M again when it ends.
//  3) "That's every rally" marks the video finished — it then counts in
//  rally scoring — and opens the next task. Footage that lives on the
//  desktop plays from its review copy; without one, fetch it first.
//

import SwiftUI

struct LabelReviewView: View {
    let session: VideoSession
    @Bindable var marker: RallyMarkModel
    let isActive: Bool
    let onClose: () -> Void
    let onDone: () -> Void

    /// The found rally being asked about.
    @State private var current: RallyMarkModel.Mark?
    /// Its start and end as the handles stand.
    @State private var start = 0.0
    @State private var end = 0.0
    /// How far the filmstrip reaches either side of the found rally; a
    /// handle let go at the edge widens that side.
    @State private var reachBefore = TrimFilmstrip.reach
    @State private var reachAfter = TrimFilmstrip.reach
    @State private var skimming = false
    @State private var pendingStart: Double?
    @State private var rejected: [Double] = []

    private static let reaction = 0.3
    private static let nudge = 0.2

    /// Found rallies not yet marked or turned down.
    private var open: [RallyMarkModel.Mark] {
        let no = (session.notRallies ?? []) + rejected
        return marker.openGuesses.filter { g in !no.contains { abs($0 - g.start) < 0.05 } }
    }

    private var window: ClosedRange<Double> {
        guard let current else { return 0...max(marker.duration, 1) }
        let d = marker.duration > 0 ? marker.duration : current.end + reachAfter
        return max(0, current.start - reachBefore)...max(min(d, current.end + reachAfter), current.start + 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            LabelTaskHeader(title: "Check the rallies", subtitle: session.name, onClose: onClose) {
                Text("\(marker.rallies.count) marked · \(open.count) found to check")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Divider()
            if marker.footageMissing {
                FootageMissingView(session: session, datasetRoot: marker.sampler.datasetRoot,
                                   reason: "It has no review copy here either.") {
                    marker.reopen()
                    advance()
                }
            } else {
                review
            }
        }
        .onAppear {
            marker.open(sessionName: session.name)
            advance()
        }
        .onDisappear { if marker.isPlaying { marker.togglePlay() } }
        .onChange(of: marker.playhead) { _, t in
            // Loop the rally being asked about, as the handles stand.
            if current != nil, !skimming, marker.isPlaying, t > end + 1 { play(from: start - 1) }
        }
        .labelKeys(isActive: isActive, handleKey)
    }

    private var review: some View {
        VStack(spacing: 14) {
            ZStack {
                ReviewStyle.stage
                if let player = marker.player { LabPlayerView(player: player, showsControls: false) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if current != nil, !skimming {
                TrimFilmstrip(asset: marker.player?.currentItem?.asset, window: window, start: $start, end: $end, time: marker.playhead,
                              onScrub: { show($0) },
                              onEdge: { isStart in if isStart { reachBefore += TrimFilmstrip.reach } else { reachAfter += TrimFilmstrip.reach } })
                    .frame(height: 64)
            }
            RallyTimesBar(time: marker.playhead, duration: marker.duration, found: marker.guesses.map { [$0.start, $0.end] },
                          marked: marker.rallies.map { LabelRally(start: $0.start, end: $0.end) },
                          current: current.map { _ in [start, end] }, pending: pendingStart)
                .frame(height: 22)
                .overlay {
                    // Click the timeline to go there.
                    GeometryReader { geo in
                        Color.clear.contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                marker.seek(to: tap.location.x / max(geo.size.width, 1) * marker.duration)
                            })
                    }
                }
            Group {
                if skimming { skim } else if let current { ask(current) } else { finished }
            }
            .frame(maxWidth: 640)
            .controlSize(.large)
        }
        .padding(16)
    }

    // MARK: - Steps

    private func ask(_ found: RallyMarkModel.Mark) -> some View {
        let n = marker.guesses.firstIndex { $0.id == found.id }.map { $0 + 1 } ?? 0
        return VStack(spacing: 10) {
            Text("Found rally \(n) of \(marker.guesses.count) · is it a rally?").font(.title3.bold())
            Text("\(TrackLabelModel.clock(start)) – \(TrackLabelModel.clock(end))" + String(format: " · %.1f s", end - start))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { reject(found) } label: { Label("Not a rally  X", systemImage: "xmark").frame(maxWidth: .infinity) }
                    .tint(.red)
                Button { replay() } label: { Label("Replay  R", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity) }
                Button { accept() } label: { Label("Right  ↩", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.green)
            }
            Text("Drag the handles to the serve and the dead ball · ←/→ nudge the start, ⇧←/→ the end · Space pauses")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var finished: some View {
        VStack(spacing: 10) {
            Label(marker.wholeVideoMarked ? "Every rally marked" : "All found rallies checked",
                  systemImage: marker.wholeVideoMarked ? "checkmark.seal.fill" : "checkmark.circle").font(.title3.bold())
            Text("Rallies RallyLab missed aren't in the list. Skim the video at 2× to catch them, or finish if you're sure.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button { startSkim() } label: { Label("Skim at 2×", systemImage: "forward").frame(maxWidth: .infinity) }
                Button { finish() } label: { Label("That's every rally", systemImage: "flag.checkered").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var skim: some View {
        VStack(spacing: 10) {
            HStack(spacing: 22) {
                Button { marker.skip(by: -2) } label: { Image(systemName: "gobackward") }.help("Back 2 s (←)")
                Button { marker.togglePlay() } label: { Image(systemName: marker.isPlaying ? "pause.fill" : "play.fill").font(.title2) }
                    .help("Play / pause (Space)")
                Button { marker.skip(by: 2) } label: { Image(systemName: "goforward") }.help("On 2 s (→)")
                Text(TrackLabelModel.clock(marker.playhead)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).font(.title3)
            if pendingStart != nil {
                Button { missed() } label: { Label("Rally over  M", systemImage: "flag.checkered").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.orange)
            } else {
                Button { missed() } label: { Label("Missed one!  M", systemImage: "exclamationmark.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
            HStack {
                Button("Back to the found rallies") { skimming = false; advance() }
                Spacer()
                Button("That's every rally") { finish() }.bold()
            }
            .buttonStyle(.link)
        }
    }

    // MARK: - Actions

    /// Right: the rally as the handles stand.
    private func accept() {
        guard current != nil else { return }
        marker.mark(start: start, end: end)
        advance()
    }

    private func reject(_ found: RallyMarkModel.Mark) {
        marker.sampler.addNotRally(start: found.start, session: session.name)
        rejected.append(found.start)
        advance()
    }

    /// Move a handle by a step and show the frame it lands on.
    private func nudge(start isStart: Bool, by seconds: Double) {
        guard current != nil else { return }
        if isStart {
            start = min(max(0, start + seconds), end - TrimFilmstrip.minLength)
            show(start)
        } else {
            end = max(min(marker.duration > 0 ? marker.duration : end + seconds, end + seconds), start + TrimFilmstrip.minLength)
            show(end)
        }
    }

    /// Pause on a moment (a handle, or a click on the filmstrip).
    private func show(_ t: Double) {
        if marker.isPlaying { marker.togglePlay() }
        marker.seek(to: t)
    }

    private func startSkim() {
        skimming = true
        current = nil
        marker.rate = 2
        play(from: 0, rate: 2)
    }

    /// M: a missed rally starts (backed up for your reaction), or ends.
    private func missed() {
        if let start = pendingStart {
            marker.mark(start: start, end: max(marker.playhead, start + 0.5))
            pendingStart = nil
        } else {
            pendingStart = max(0, marker.playhead - Self.reaction * Double(max(marker.rate, 1)))
        }
    }

    private func finish() {
        if marker.isPlaying { marker.togglePlay() }
        marker.wholeVideoMarked = true
        onDone()
    }

    private func advance() {
        current = open.first
        if let current {
            start = current.start
            end = current.end
            reachBefore = TrimFilmstrip.reach
            reachAfter = TrimFilmstrip.reach
            play(from: current.start - 1)
        } else if marker.isPlaying {
            marker.togglePlay()
        }
    }

    private func replay() {
        if current != nil { play(from: start - 1) }
    }

    private func play(from t: Double, rate: Float = 1) {
        marker.rate = rate
        marker.seek(to: max(0, t))
        if !marker.isPlaying { marker.togglePlay() }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !marker.footageMissing else { return false }
        if event.keyCode == 49 { marker.togglePlay(); return true }
        if skimming {
            switch event.keyCode {
            case 123: marker.skip(by: -2); return true
            case 124: marker.skip(by: 2); return true
            default: break
            }
            if event.charactersIgnoringModifiers?.lowercased() == "m" { missed(); return true }
            return false
        }
        guard let current else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 36, 76: accept(); return true
        case 123: nudge(start: !shift, by: -Self.nudge); return true
        case 124: nudge(start: !shift, by: Self.nudge); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "x": reject(current)
        case "r": replay()
        default: return false
        }
        return true
    }
}
