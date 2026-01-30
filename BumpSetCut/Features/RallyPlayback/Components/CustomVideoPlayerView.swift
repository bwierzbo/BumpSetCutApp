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

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = gravity
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
