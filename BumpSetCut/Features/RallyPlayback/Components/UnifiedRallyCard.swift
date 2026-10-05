//
//  UnifiedRallyCard.swift
//  BumpSetCut
//

import SwiftUI
import AVFoundation

// MARK: - Unified Rally Card

/// Single card component using custom AVPlayerLayer for smooth transitions
/// Adjacent players stay mounted, thumbnail visible until video playing
struct UnifiedRallyCard: View {
    let url: URL
    let rallyIndex: Int
    let size: CGSize
    let position: Int  // -1 = previous, 0 = current, 1+ = next
    let previousRallyIndex: Int?  // Track which rally was just current (for seamless transitions)
    let playerCache: RallyPlayerCache
    let thumbnailCache: RallyThumbnailCache
    var videoDisplaySize: CGSize?
    var rotationDegrees: Double = 0
    var zoomScale: CGFloat = 1.0
    var zoomOffset: CGSize = .zero
    var onDoubleTap: (() -> Void)?
    /// Enters trim mode — the accessible equivalent of the long-press.
    var onTrim: (() -> Void)?

    @State private var thumbnail: UIImage?
    // First video frame rendered — the thumbnail then unmounts. Keeping it
    // mounted behind a live video causes rotation artifacts: the SwiftUI image
    // animates with the rotation while the AVPlayerLayer resizes on UIKit's
    // schedule, so the mismatched thumbnail peeks out around the video.
    @State private var isVideoReady = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    private var isCurrent: Bool { position == 0 }
    private var isPreviousRally: Bool {
        guard let prevIndex = previousRallyIndex else { return false }
        return rallyIndex == prevIndex
    }
    private var isPreloaded: Bool { position >= -1 && position <= 1 }

    /// Clamp the pan offset to the current zoom so the video can never be pushed
    /// off-screen (which would expose the black background — the "zoom-out went
    /// black" bug). At zoom 1.0 the max is 0, forcing a centered frame.
    private var safeZoomOffset: CGSize {
        let maxX = max(0, (size.width * zoomScale - size.width) / 2)
        let maxY = max(0, (size.height * zoomScale - size.height) / 2)
        return CGSize(
            width: min(max(zoomOffset.width, -maxX), maxX),
            height: min(max(zoomOffset.height, -maxY), maxY)
        )
    }

    /// The rectangle the video content occupies. In portrait a non-square video
    /// is letterboxed, so rotation must happen inside this fitted rect (filled,
    /// not the whole screen-shaped card) to crop & scale like Apple's editor
    /// instead of tilting the letterbox bars. In landscape the video already
    /// fills the card, so the rect is the full card.
    private var videoRect: CGSize {
        if isPortrait {
            // Prefer the source video's true display size (reliable, available
            // immediately); fall back to the thumbnail's size, then the card.
            let content = videoDisplaySize ?? thumbnail?.size ?? size
            return RotationGeometry.aspectFitSize(content: content, in: size)
        }
        return size
    }

    var body: some View {
        let rect = videoRect
        return ZStack {
            Color.bscMediaBackground

            // Content layer (thumbnail + video) — rotated within the video rect.
            ZStack {
                // Thumbnail fallback behind the video layer.
                if let thumbnail = thumbnail, showThumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }

                // Video player layer - always at full opacity for preloaded cards.
                // AVPlayerLayer has clear background, so it's transparent when no content
                // and shows the video frame when content is rendered. No opacity toggling
                // eliminates any flash from layer compositing delays.
                if isPreloaded, let player = playerCache.getPlayer(for: url) {
                    CustomVideoPlayerView(
                        player: player,
                        gravity: .resizeAspectFill,
                        onReadyForDisplay: { ready in
                            guard ready != isVideoReady else { return }
                            // Async: updateUIView reports synchronously during view updates
                            DispatchQueue.main.async { isVideoReady = ready }
                        }
                    )
                    .allowsHitTesting(isCurrent)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .rotationEffect(.degrees(rotationDegrees))
            .scaleEffect(RotationGeometry.coverScale(angleDegrees: rotationDegrees, size: rect))
            .frame(width: rect.width, height: rect.height)
            .clipped()
        }
        .scaleEffect(zoomScale)
        .offset(safeZoomOffset)
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if isCurrent {
                onDoubleTap?()
            }
        }
        .onTapGesture(count: 1) {
            if isCurrent {
                playerCache.togglePlayPause()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Rally \(rallyIndex + 1) video")
        .accessibilityAction(named: "Play or pause") {
            if isCurrent {
                playerCache.togglePlayPause()
            }
        }
        .accessibilityAction(named: "Toggle zoom") {
            if isCurrent {
                onDoubleTap?()
            }
        }
        .accessibilityAction(named: "Trim rally") {
            onTrim?()
        }
        .task(id: url) {
            isVideoReady = false
            thumbnail = await thumbnailCache.getThumbnailAsync(for: url)
        }
    }

    private var showThumbnail: Bool {
        // Only until the player has rendered its first frame — after that the
        // video fully covers the card and the thumbnail must not linger behind it.
        guard !isVideoReady else { return false }
        if isCurrent { return true }
        return isPreviousRally || position == 1
    }
}
