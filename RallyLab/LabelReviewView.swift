//
//  LabelReviewView.swift
//  RallyLab
//
//  Finish a video's rally times by confirming instead of marking from
//  scratch, as on the phone. 1) Each rally RallyLab found plays from a
//  second before it, looping: Right (↩) · Adjust (A, the trim filmstrip) ·
//  Not a rally (X). 2) Skim the rest at 2× and press M when a rally starts
//  that wasn't found (it backs up for your reaction), M again when it
//  ends. 3) "That's every rally" marks the video finished — it then counts
//  in rally scoring — and opens the next task.
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
    /// The found rally being trimmed.
    @State private var trimming: RallyMarkModel.Mark?
    @State private var skimming = false
    @State private var pendingStart: Double?
    @State private var rejected: [Double] = []

    private static let reaction = 0.3

    /// Found rallies not yet marked or turned down.
    private var open: [RallyMarkModel.Mark] {
        let no = (session.notRallies ?? []) + rejected
        return marker.openGuesses.filter { g in !no.contains { abs($0 - g.start) < 0.05 } }
    }

    var body: some View {
        VStack(spacing: 0) {
            LabelTaskHeader(title: "Check the rallies", subtitle: session.name, onClose: onClose) {
                Text("\(marker.rallies.count) marked · \(open.count) found to check")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Divider()
            if let trimming {
                LabelTrimView(session: session, rally: LabelRally(start: trimming.start, end: trimming.end), isActive: isActive,
                              confirmTitle: "Mark this rally",
                              onConfirm: { r in
                                  marker.mark(start: r.start, end: r.end)
                                  self.trimming = nil
                                  advance()
                              },
                              onCancel: { self.trimming = nil; replay() })
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
            // Loop the rally being asked about.
            if let c = current, trimming == nil, !skimming, marker.isPlaying, t > c.end + 1 { play(from: c.start - 1) }
        }
        .labelKeys(isActive: isActive && trimming == nil, handleKey)
    }

    private var review: some View {
        VStack(spacing: 14) {
            ZStack {
                ReviewStyle.stage
                if let player = marker.player { LabPlayerView(player: player, showsControls: false) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            RallyTimesBar(time: marker.playhead, duration: marker.duration, found: marker.guesses.map { [$0.start, $0.end] },
                          marked: marker.rallies.map { LabelRally(start: $0.start, end: $0.end) },
                          current: current.map { [$0.start, $0.end] }, pending: pendingStart)
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
            Text("\(TrackLabelModel.clock(found.start)) – \(TrackLabelModel.clock(found.end))")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { reject(found) } label: { Label("Not a rally  X", systemImage: "xmark").frame(maxWidth: .infinity) }
                    .tint(.red)
                Button { adjust(found) } label: { Label("Adjust  A", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }
                Button { accept(found) } label: { Label("Right  ↩", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.green)
            }
            Button("Replay (R)") { replay() }.buttonStyle(.link)
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

    private func accept(_ found: RallyMarkModel.Mark) {
        marker.mark(start: found.start, end: found.end)
        advance()
    }

    private func reject(_ found: RallyMarkModel.Mark) {
        marker.sampler.addNotRally(start: found.start, session: session.name)
        rejected.append(found.start)
        advance()
    }

    private func adjust(_ found: RallyMarkModel.Mark) {
        if marker.isPlaying { marker.togglePlay() }
        trimming = found
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
        if let current { play(from: current.start - 1) } else if marker.isPlaying { marker.togglePlay() }
    }

    private func replay() {
        if let current { play(from: current.start - 1) }
    }

    private func play(from t: Double, rate: Float = 1) {
        marker.rate = rate
        marker.seek(to: t)
        if !marker.isPlaying { marker.togglePlay() }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
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
        if event.keyCode == 36 || event.keyCode == 76 { accept(current); return true }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "x": reject(current)
        case "a": adjust(current)
        case "r": replay()
        default: return false
        }
        return true
    }
}
