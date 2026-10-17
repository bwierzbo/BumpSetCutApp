//
//  LabelTrimView.swift
//  RallyLab
//
//  Set a rally's start and end the way BumpSetCut trims a rally: the video
//  over a filmstrip of a few seconds either side of it, with handles you
//  drag to the serve and to the dead ball — the video follows the handle.
//  Let go of a handle at the strip's edge and that side widens by 3 s.
//  Space plays the selection, ↩ confirms it.
//

import AVFoundation
import SwiftUI

struct LabelTrimView: View {
    let session: VideoSession
    let rally: LabelRally
    let isActive: Bool
    let confirmTitle: String
    let onConfirm: (LabelRally) -> Void
    let onCancel: () -> Void
    /// Shown when the rally came from RallyLab's finder: it isn't one.
    var onNotARally: (() -> Void)?

    @State private var player = AVPlayer()
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var duration = 0.0
    @State private var time = 0.0
    @State private var observer: Any?
    @State private var stopAt: Any?

    /// Letting go of a handle at the strip's edge widens that side by this.
    @State private var reachBefore = TrimFilmstrip.reach
    @State private var reachAfter = TrimFilmstrip.reach

    private var window: ClosedRange<Double> {
        let d = duration > 0 ? duration : rally.end + reachAfter
        return max(0, rally.start - reachBefore)...min(d, rally.end + reachAfter)
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ReviewStyle.stage
                LabPlayerView(player: player, showsControls: false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            TrimFilmstrip(asset: player.currentItem?.asset, window: window, start: $start, end: $end, time: time,
                           onScrub: { show($0) },
                           onEdge: { isStart in if isStart { reachBefore += TrimFilmstrip.reach } else { reachAfter += TrimFilmstrip.reach } })
                .frame(height: 64)
            HStack(spacing: 12) {
                Button { playSelection() } label: { Label("Play", systemImage: "play.fill") }
                    .help("Play the selection (Space)")
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(TrackLabelModel.clock(start)) – \(TrackLabelModel.clock(end))").font(.callout.monospacedDigit())
                    Text(String(format: "%.1f s · drag the handles to the serve and the dead ball", end - start))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let onNotARally {
                    Button(role: .destructive, action: onNotARally) { Label("Not a rally", systemImage: "xmark") }
                        .tint(.red)
                        .help("Not a rally (X)")
                }
                Button { confirm() } label: { Label(confirmTitle, systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .help("\(confirmTitle) (↩)")
            }
            .controlSize(.large)
        }
        .padding(16)
        .onAppear(perform: load)
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer) }
            if let stopAt { player.removeTimeObserver(stopAt) }
            observer = nil
            stopAt = nil
            player.replaceCurrentItem(with: nil)
        }
        .labelKeys(isActive: isActive) { event in
            switch event.keyCode {
            case 49: player.rate > 0 ? player.pause() : playSelection(); return true
            case 36, 76: confirm(); return true
            default: break
            }
            if event.charactersIgnoringModifiers?.lowercased() == "x", let onNotARally { onNotARally(); return true }
            return false
        }
    }

    private func load() {
        start = rally.start
        end = rally.end
        let item = AVPlayerItem(url: URL(fileURLWithPath: session.sourcePath))
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
            MainActor.assumeIsolated { time = t.seconds }
        }
        Task {
            duration = (try? await item.asset.load(.duration).seconds) ?? 0
            playSelection()
        }
    }

    private func confirm() {
        player.pause()
        onConfirm(LabelRally(start: start, end: end))
    }

    private func show(_ t: Double) {
        player.pause()
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Play the selection once, from just before it.
    private func playSelection() {
        if let stopAt { player.removeTimeObserver(stopAt) }
        stopAt = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end + 0.3, preferredTimescale: 600))],
                                                queue: .main) { [player] in player.pause() }
        player.seek(to: CMTime(seconds: max(0, start - 0.5), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}
