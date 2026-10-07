//
//  RallyReviewView.swift
//  RallyLab (iPhone)
//
//  Finish a video's rally times by confirming instead of marking from
//  scratch. 1) Each rally RallyLab found plays from a second before it:
//  Right · Adjust (move the start or end, then confirm) · Not a rally.
//  2) Skim the rest at 2× and tap "Missed one!" when a rally starts that
//  wasn't found (it backs up 0.3 s for your reaction), "Rally over" when it
//  ends. 3) "That's every rally" marks the video finished.
//

import AVFoundation
import SwiftUI

struct RallyReviewView: View {
    let model: LabelerModel
    let video: LabelVideo
    @Environment(\.dismiss) private var dismiss

    @State private var player = AVPlayer()
    @State private var time = 0.0
    @State private var duration = 0.0
    @State private var observer: Any?
    @State private var loadError: String?
    /// The found rally being asked about.
    @State private var current: [Double]?
    /// The found rally being trimmed (BumpSetCut's trim bar).
    @State private var trimming: LabelRally?
    @State private var url: URL?
    @State private var skimming = false
    @State private var pendingStart: Double?

    private var open: [[Double]] { model.openFound(in: video) }
    private var times: LabelRallyTimes { model.rallyTimes(for: video) }
    private static let reaction = 0.3

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .overlay { if let loadError { Text(loadError).foregroundStyle(.white).padding() } }
            RallyTimeline(time: time, duration: duration, found: video.ralliesFound, marked: times.rallies,
                          current: current, pending: pendingStart)
                .frame(height: 22).padding(.horizontal).padding(.top, 8)
            HStack {
                Text(RallyTimesView.clock(time)).monospacedDigit()
                Spacer()
                Text("\(times.rallies.count) rallies marked").foregroundStyle(.secondary)
            }
            .font(.caption).padding(.horizontal)
            Spacer(minLength: 8)
            if skimming { skim } else if let current { ask(current) } else { finished }
            Spacer(minLength: 8)
        }
        .navigationTitle(video.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer) }
            observer = nil
        }
        .sensoryFeedback(.success, trigger: times.rallies.count)
        .fullScreenCover(item: $trimming) { rally in
            if let url {
                RallyTrimView(video: video, rally: rally, url: url, onConfirm: { trimmed in
                    model.update(video) { $0.rallies.append(trimmed) }
                    trimming = nil
                    advance()
                }, onCancel: { trimming = nil })
            }
        }
    }

    // MARK: - Steps

    /// Is this found rally a rally?
    private func ask(_ found: [Double]) -> some View {
        VStack(spacing: 12) {
            Text("Found rally \(video.ralliesFound.firstIndex(of: found).map { $0 + 1 } ?? 0) of \(video.ralliesFound.count) · \(open.count) left to check")
                .font(.headline)
            Text("\(RallyTimesView.clock(found[0])) – \(RallyTimesView.clock(found[1]))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    model.rejectFound(found, in: video)
                    advance()
                } label: { Label("Not a rally", systemImage: "xmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(.red)
                Button {
                    player.pause()
                    trimming = LabelRally(start: found[0], end: found[1])
                } label: {
                    Label("Adjust", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    model.update(video) { $0.rallies.append(LabelRally(start: found[0], end: found[1])) }
                    advance()
                } label: { Label("Right", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.green)
            }
            .controlSize(.large)
            Button("Replay") { play(from: found[0] - 1) }.font(.callout)
        }
        .padding(.horizontal)
    }

    /// Every found rally is checked: skim for missed ones, or finish.
    private var finished: some View {
        VStack(spacing: 12) {
            Label(times.complete ? "Every rally marked" : "All found rallies checked",
                  systemImage: times.complete ? "checkmark.seal.fill" : "checkmark.circle").font(.headline)
            Text("Rallies RallyLab missed won't be in the list. Skim the video at 2× to catch them, or finish if you're sure.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    skimming = true
                    play(from: 0, rate: 2)
                } label: { Label("Skim at 2×", systemImage: "forward").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button {
                    model.update(video) { $0.complete = true }
                    dismiss()
                } label: { Label("That's every rally", systemImage: "flag.checkered").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(.horizontal)
    }

    /// Watching at 2× for rallies that weren't found.
    private var skim: some View {
        VStack(spacing: 12) {
            transport
            if let pendingStart {
                Button {
                    let r = LabelRally(start: pendingStart, end: max(time, pendingStart + 0.5))
                    model.update(video) { $0.rallies.append(r) }
                    self.pendingStart = nil
                } label: { Label("Rally over", systemImage: "flag.checkered").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
            } else {
                Button {
                    pendingStart = max(0, time - Self.reaction * Double(max(player.rate, 1)))
                } label: { Label("Missed one!", systemImage: "exclamationmark.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            HStack {
                Button("Back to the list") { skimming = false; player.pause() }
                Spacer()
                Button("That's every rally") {
                    model.update(video) { $0.complete = true }
                    dismiss()
                }
                .bold()
            }
            .font(.callout)
        }
        .padding(.horizontal)
    }

    private var transport: some View {
        HStack(spacing: 24) {
            Button { seek(time - 2) } label: { Image(systemName: "gobackward") }
            Button { seek(time - 1.0 / 30) } label: { Image(systemName: "backward.frame") }
            Button {
                if player.rate > 0 { player.pause() } else { player.playImmediately(atRate: skimming ? 2 : 1) }
            } label: { Image(systemName: player.rate > 0 ? "pause.fill" : "play.fill").font(.title2) }
            Button { seek(time + 1.0 / 30) } label: { Image(systemName: "forward.frame") }
            Button { seek(time + 2) } label: { Image(systemName: "goforward") }
        }
        .font(.title3)
    }

    // MARK: - Player

    private func load() async {
        guard player.currentItem == nil else { return }
        do {
            let playback = try await model.playbackURL(for: video)
            url = playback
            let item = AVPlayerItem(url: playback)
            player.replaceCurrentItem(with: item)
            duration = (try? await item.asset.load(.duration).seconds) ?? video.duration
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
                time = t.seconds
                // Loop the rally being asked about.
                if let c = current, trimming == nil, !skimming, t.seconds > c[1] + 1 { play(from: c[0] - 1) }
            }
            advance()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func advance() {
        current = open.first
        if let current { play(from: current[0] - 1) } else { player.pause() }
    }

    private func play(from t: Double, rate: Float = 1) {
        seek(t)
        player.playImmediately(atRate: rate)
    }

    private func seek(_ t: Double) {
        let target = min(max(0, t), max(duration, 0))
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// The video's length with found rallies (grey), yours (orange), the one
/// being asked about (blue) and the playhead.
struct RallyTimeline: View {
    let time: Double
    let duration: Double
    let found: [[Double]]
    let marked: [LabelRally]
    let current: [Double]?
    let pending: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(duration, 0.1)
            Canvas { ctx, size in
                func bar(_ a: Double, _ b: Double, _ y: CGFloat, _ h: CGFloat, _ c: Color) {
                    ctx.fill(Path(roundedRect: CGRect(x: a / d * w, y: y, width: max(2, (b - a) / d * w), height: h), cornerRadius: h / 2),
                             with: .color(c))
                }
                ctx.fill(Path(CGRect(x: 0, y: 10, width: w, height: 2)), with: .color(.secondary.opacity(0.3)))
                for f in found { bar(f[0], f[1], 2, 5, .secondary.opacity(0.5)) }
                for r in marked { bar(r.start, r.end, 13, 7, .orange) }
                if let current { bar(current[0], current[1], 0, size.height, .blue.opacity(0.25)) }
                if let pending { bar(pending, max(time, pending), 13, 7, .orange.opacity(0.5)) }
                ctx.fill(Path(CGRect(x: time / d * w - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
            }
        }
    }
}
