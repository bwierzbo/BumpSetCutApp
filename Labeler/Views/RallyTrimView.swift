//
//  RallyTrimView.swift
//  RallyLab (iPhone)
//
//  Set a rally's start and end the way BumpSetCut trims a rally: the video
//  with BumpSetCut's own filmstrip trim bar (RallyTrimOverlay) over it — a
//  few seconds either side of the rally, handles you drag to the serve and
//  to the dead ball, the video following the handle. Confirm returns the
//  trimmed rally.
//

import AVFoundation
import SwiftUI

struct RallyTrimView: View {
    let video: LabelVideo
    let rally: LabelRally
    /// The clip to show: on the phone or streamed.
    let url: URL
    let onConfirm: (LabelRally) -> Void
    let onCancel: () -> Void
    /// Shown when the rally came from RallyLab's finder: it isn't one.
    var onNotARally: (() -> Void)?

    @State private var player = AVPlayer()
    @State private var trimBefore = 0.0
    @State private var trimAfter = 0.0
    @State private var rotation = 0.0
    @State private var zoom = 1.0
    @State private var looping: Any?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayer(player: player).ignoresSafeArea()
            RallyTrimOverlay(
                trimBefore: $trimBefore,
                trimAfter: $trimAfter,
                trimRotation: $rotation,
                trimZoom: $zoom,
                rallyStartTime: rally.start,
                rallyEndTime: rally.end,
                videoURL: url,
                videoDuration: video.duration,
                onScrub: { show($0) },
                onConfirm: {
                    onConfirm(LabelRally(start: max(0, rally.start - trimBefore), end: min(video.duration, rally.end + trimAfter)))
                },
                onCancel: onCancel,
                onExtendPlaybackStart: { t in show(t); player.play() },
                onExtendPlaybackEnd: { t in player.pause(); show(t) },
                showsAngleControl: false
            )
        }
        .overlay(alignment: .top) {
            HStack {
                Button { playSelection() } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                Spacer()
                if let onNotARally {
                    Button(role: .destructive, action: onNotARally) { Label("Not a rally", systemImage: "xmark") }
                        .buttonStyle(.bordered).tint(.red)
                }
            }
            .padding()
        }
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            playSelection()
        }
        .onDisappear {
            player.pause()
            if let looping { player.removeTimeObserver(looping) }
            player.replaceCurrentItem(with: nil)
        }
    }

    private func show(_ t: Double) {
        player.pause()
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Play the selection once, from just before it.
    private func playSelection() {
        let start = max(0, rally.start - trimBefore - 0.5), end = rally.end + trimAfter
        if let looping { player.removeTimeObserver(looping) }
        looping = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end + 0.3, preferredTimescale: 600))],
                                                 queue: .main) { [player] in player.pause() }
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}

/// A track task: trim the rally to the serve and the dead ball, then track
/// its ball (frames a little past it each side). Trimming streams the clip
/// right away; tracking needs it on the phone, so it downloads meanwhile.
/// A rally you started tracking and left reopens in tracking, as you left it.
struct TrackTaskView: View {
    let model: LabelerModel
    let video: LabelVideo
    let span: LabelRally
    @Environment(\.dismiss) private var dismiss
    @State private var playback: URL?
    @State private var clip: URL?
    @State private var trimmed: LabelRally?
    @State private var failure: String?

    /// The found rally this task started from, if any.
    private var found: [Double]? {
        video.ralliesFound.first { abs($0[0] - span.start) < 0.05 && abs($0[1] - span.end) < 0.05 }
    }

    var body: some View {
        Group {
            if let track = model.unfinishedTrack(of: span, in: video) {
                TrackReviewView(model: model, video: video, track: track)
            } else if let trimmed, clip != nil {
                TrackReviewView(model: model, video: video, span: trimmed, found: found)
            } else if trimmed != nil, let failure {
                ContentUnavailableView("Couldn't get the clip", systemImage: "wifi.slash", description: Text(failure))
            } else if trimmed != nil {
                VStack(spacing: 14) {
                    ProgressView(value: model.downloads[video.id] ?? 0)
                    Text("Getting the clip for tracking… \(Int((model.downloads[video.id] ?? 0) * 100))%")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(40)
            } else if let playback {
                RallyTrimView(video: video, rally: span, url: playback, onConfirm: { trimmed = $0 }, onCancel: { dismiss() },
                              onNotARally: found.map { f in { model.rejectFound(f, in: video); dismiss() } })
                    .toolbar(.hidden, for: .navigationBar, .tabBar)
            } else if let failure {
                ContentUnavailableView("Couldn't get the clip", systemImage: "wifi.slash", description: Text(failure))
            } else {
                ProgressView("Opening the video…")
            }
        }
        .task {
            guard playback == nil, model.unfinishedTrack(of: span, in: video) == nil else { return }
            do {
                playback = try await model.playbackURL(for: video)
                clip = try await model.localClip(for: video)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
