//
//  LabelTrimView.swift
//  RallyLab
//
//  Set a rally's start and end the way BumpSetCut trims a rally: the video
//  over a filmstrip of a few seconds either side of it, with handles you
//  drag to the serve and to the dead ball — the video follows the handle.
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

    /// The filmstrip covers this much either side of the rally.
    static let reach = 3.0

    private var window: ClosedRange<Double> {
        let d = duration > 0 ? duration : rally.end + Self.reach
        return max(0, rally.start - Self.reach)...min(d, rally.end + Self.reach)
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ReviewStyle.stage
                LabPlayerView(player: player, showsControls: false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            TrimFilmstrip(asset: player.currentItem?.asset, window: window, start: $start, end: $end, time: time) { show($0) }
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

/// Thumbnails across `window` with the selection bright between two
/// handles and the rest dimmed; click to show a moment, drag a handle to
/// move that end.
private struct TrimFilmstrip: View {
    let asset: AVAsset?
    let window: ClosedRange<Double>
    @Binding var start: Double
    @Binding var end: Double
    let time: Double
    let onScrub: (Double) -> Void
    @State private var thumbs: [CGImage] = []
    @State private var dragging: Bool?

    private static let count = 12
    private static let minLength = 0.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, span = max(window.upperBound - window.lowerBound, 0.1)
            let x = { (t: Double) in CGFloat((t - window.lowerBound) / span) * w }
            let t = { (x: CGFloat) in window.lowerBound + Double(min(max(x, 0), w) / w) * span }
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(thumbs.indices, id: \.self) { i in
                        Image(decorative: thumbs[i], scale: 1)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: w / CGFloat(Self.count), height: geo.size.height).clipped()
                    }
                }
                .frame(width: w, height: geo.size.height, alignment: .leading)
                .background(Color.black)
                Color.black.opacity(0.6).frame(width: max(0, x(start)))
                Color.black.opacity(0.6).frame(width: max(0, w - x(end))).offset(x: x(end))
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange, lineWidth: 3)
                    .frame(width: max(8, x(end) - x(start))).offset(x: x(start))
                    .allowsHitTesting(false)
                Rectangle().fill(.white).frame(width: 2).offset(x: x(time) - 1).allowsHitTesting(false)
                handle.offset(x: x(start) - 7)
                handle.offset(x: x(end) - 7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    // The handle nearest where the drag began moves; a click
                    // away from both just shows that moment.
                    if dragging == nil {
                        let a = abs(drag.startLocation.x - x(start)), b = abs(drag.startLocation.x - x(end))
                        dragging = min(a, b) < 18 ? (a <= b) : nil
                        if dragging == nil { onScrub(t(drag.location.x)); return }
                    }
                    guard let isStart = dragging else { return }
                    let v = t(drag.location.x)
                    if isStart { start = min(v, end - Self.minLength) } else { end = max(v, start + Self.minLength) }
                    onScrub(isStart ? start : end)
                }
                .onEnded { _ in dragging = nil })
        }
        // Again once the clip's length is known (the window widens to it).
        .task(id: "\(asset != nil) \(window)") { await loadThumbs() }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.orange)
            .frame(width: 14)
            .overlay(Capsule().fill(.white.opacity(0.85)).frame(width: 3, height: 18))
            .allowsHitTesting(false)
    }

    private func loadThumbs() async {
        guard let asset else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let step = (window.upperBound - window.lowerBound) / Double(Self.count)
        var images: [CGImage] = []
        for i in 0..<Self.count {
            let at = CMTime(seconds: window.lowerBound + (Double(i) + 0.5) * step, preferredTimescale: 600)
            guard let image = try? await generator.image(at: at).image else { continue }
            images.append(image)
        }
        thumbs = images
    }
}
