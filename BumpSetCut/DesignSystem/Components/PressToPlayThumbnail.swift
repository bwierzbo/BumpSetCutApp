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

    // Muted: these sit in grids browsed quickly, where a burst of court
    // audio on every press would be jarring.
    @State private var preview = LoopingPlayerPool<URL>(isMuted: true)

    var body: some View {
        GeometryReader { geo in
            VideoThumbnailView(thumbnailURL: nil, videoURL: videoURL, time: timeRange?.start ?? .zero)
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
        guard preview.player(for: videoURL) == nil else { return }

        let player = preview.player(
            for: videoURL, url: videoURL,
            loopStart: timeRange?.start ?? .zero,
            loopEnd: timeRange.map { CMTimeAdd($0.start, $0.duration) }
        )
        player.play()
        onPreviewChanged(player)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func stopPreview() {
        guard preview.player(for: videoURL) != nil else { return }
        preview.teardownAll()
        onPreviewChanged(nil)
    }
}
