//
//  ZoomablePlayerView.swift
//  RallyLab
//
//  A player picture that zooms: the AVPlayerLayer is laid out larger than
//  the view, around a centre point, and the view clips it. `zoom` 1 = the
//  whole frame fitted; `center` is the picture point (0–1, top-left) kept
//  in the middle of the view.
//

import AVFoundation
import AppKit
import SwiftUI

struct ZoomablePlayerView: NSViewRepresentable {
    let player: AVPlayer
    let zoom: CGFloat
    let center: CGPoint

    final class Container: NSView {
        let playerLayer = AVPlayerLayer()
        var zoom: CGFloat = 1 { didSet { needsLayout = true } }
        var center = CGPoint(x: 0.5, y: 0.5) { didSet { needsLayout = true } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            // The fitted picture, scaled, placed so `center` sits mid-view.
            let size = playerLayer.player?.currentItem?.presentationSize ?? .zero
            let fit = OverlayGeometry.fittedRect(content: size == .zero ? bounds.size : size, in: bounds.size)
            let w = fit.width * zoom, h = fit.height * zoom
            // AppKit layers are y-up; `center` is top-left based.
            let frame = CGRect(x: bounds.midX - center.x * w, y: bounds.midY - (1 - center.y) * h, width: w, height: h)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = zoom <= 1.001 ? bounds : frame
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Container {
        let view = Container()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: Container, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.zoom = zoom
        view.center = center
    }
}
