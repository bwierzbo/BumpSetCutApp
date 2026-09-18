//
//  PressToPlayThumbnail.swift
//  BumpSetCut
//
//  A clip thumbnail that plays while pressed and held — the way a Live Photo
//  does in Photos — and returns to the still frame on release. Used by the
//  pickers, where seeing the rally move is the whole point of deciding
//  whether to post it.
//
//  The clip plays at full size rather than in the cell: a grid cell is barely
//  big enough to judge a rally by, and a cell can't draw outside the scroll
//  view that clips it. So this owns the player's lifecycle and hands it to the
//  container through `onPreviewChanged`, which presents it above the grid.
//

import SwiftUI
import AVFoundation
import UIKit

struct PressToPlayThumbnail: View {
    let videoURL: URL
    /// The slice of `videoURL` this clip covers; nil plays the whole file.
    var timeRange: CMTimeRange?
    /// Hands over the playing clip when the hold starts, and nil when it ends.
    /// The container presents it at full size and dims its own chrome.
    var onPreviewChanged: (AVPlayer?) -> Void = { _ in }

    @State private var player: AVPlayer?
    @State private var isPreviewing = false
    @State private var boundaryObserver: Any?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        GeometryReader { geo in
            VideoThumbnailView(thumbnailURL: nil, videoURL: videoURL)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
        .onLongPressGesture(minimumDuration: 0.3) {
            startPreview()
        } onPressingChanged: { pressing in
            if !pressing { stopPreview() }
        }
        .onDisappear { stopPreview() }
    }

    private func startPreview() {
        guard !isPreviewing else { return }

        let item = AVPlayerItem(url: videoURL)
        let preview = AVPlayer(playerItem: item)
        // Muted: these sit in grids browsed quickly, where a burst of court
        // audio on every press would be jarring.
        preview.isMuted = true
        preview.actionAtItemEnd = .none

        if let timeRange {
            preview.seek(to: timeRange.start, toleranceBefore: .zero, toleranceAfter: .zero)
            let end = CMTimeAdd(timeRange.start, timeRange.duration)
            boundaryObserver = preview.addBoundaryTimeObserver(
                forTimes: [NSValue(time: end)], queue: .main
            ) {
                preview.seek(to: timeRange.start, toleranceBefore: .zero, toleranceAfter: .zero)
                preview.play()
            }
        } else {
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { _ in
                preview.seek(to: .zero)
                preview.play()
            }
        }

        player = preview
        preview.play()
        isPreviewing = true
        onPreviewChanged(preview)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func stopPreview() {
        guard player != nil else { return }
        if let boundaryObserver {
            player?.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        loopObserver = nil
        player?.pause()
        player = nil
        isPreviewing = false
        onPreviewChanged(nil)
    }
}
