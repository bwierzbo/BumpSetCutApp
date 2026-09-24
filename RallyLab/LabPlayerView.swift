//
//  LabPlayerView.swift
//  RallyLab
//
//  AppKit AVPlayerView hosted in SwiftUI. Used instead of SwiftUI's
//  `VideoPlayer` on purpose: that lives in the `_AVKit_SwiftUI` overlay,
//  whose class metadata aborts at launch when the binary's SDK is newer
//  than the running macOS (SDK 26.5 on macOS 26.4 crashed every launch in
//  getSuperclassMetadata). AVPlayerView itself has no such dependency.
//  Default video gravity is aspect-fit, which is what OverlayGeometry
//  assumes when it maps detections onto the picture.
//

import AVKit
import SwiftUI

struct LabPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
