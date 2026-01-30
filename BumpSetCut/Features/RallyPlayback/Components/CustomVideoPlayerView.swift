//
//  CustomVideoPlayerView.swift
//  BumpSetCut
//
//  Custom video player using AVPlayerLayer for TikTok-smooth playback
//

import SwiftUI
import AVFoundation

// MARK: - Custom Video Player View

/// Custom video player using AVPlayerLayer instead of SwiftUI VideoPlayer
/// Provides more control over rendering and eliminates black flash issues
struct CustomVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let onReadyForDisplay: (Bool) -> Void

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        view.onReadyForDisplay = onReadyForDisplay

        // Immediately report current state (in case already ready)
        onReadyForDisplay(view.playerLayer.isReadyForDisplay)

        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = gravity
        uiView.onReadyForDisplay = onReadyForDisplay

        // Check current state on update (critical for when player changes)
        onReadyForDisplay(uiView.playerLayer.isReadyForDisplay)
    }
}

// MARK: - Player UI View

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    var onReadyForDisplay: ((Bool) -> Void)?
    private var readyObserver: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear  // Transparent so thumbnail shows through
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.clear.cgColor  // Also clear layer background

        // Observe isReadyForDisplay - this is the KEY to eliminating black flash
        // isReadyForDisplay becomes true when first video frame is rendered
        readyObserver = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, change in
            if let isReady = change.newValue {
                self?.onReadyForDisplay?(isReady)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        readyObserver?.invalidate()
    }
}
