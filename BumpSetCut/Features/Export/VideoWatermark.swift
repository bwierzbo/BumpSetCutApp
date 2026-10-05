//
//  VideoWatermark.swift
//  BumpSetCut
//
//  The BumpSetCut watermark and overlay layers burned into exported video.
//

import AVFoundation
import QuartzCore
import UIKit

enum VideoWatermark {

    /// Creates a watermark text layer for video compositions. Layer space is
    /// in PIXELS of the render size — sizes must scale with the video or the
    /// mark is microscopic on 1080p+ footage (tester-reported).
    static func layer(videoSize: CGSize, videoDuration: CMTime) -> CALayer {
        let watermarkText = "Made with BumpSetCut"
        let fontSize = min(max(videoSize.height * 0.028, 13), 44)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)

        let attributed = NSAttributedString(string: watermarkText, attributes: [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(0.7)
        ])
        let textSize = attributed.size()

        let textLayer = CATextLayer()
        textLayer.string = attributed
        textLayer.contentsScale = 2
        textLayer.alignmentMode = .right
        textLayer.shadowColor = UIColor.black.cgColor
        textLayer.shadowOpacity = 0.6
        textLayer.shadowOffset = CGSize(width: 0, height: fontSize * 0.06)
        textLayer.shadowRadius = fontSize * 0.15

        // Bottom-right corner with padding (layer origin is bottom-left)
        let padding = fontSize * 0.9
        textLayer.frame = CGRect(
            x: videoSize.width - ceil(textSize.width) - padding,
            y: padding,
            width: ceil(textSize.width),
            height: ceil(textSize.height)
        )

        // Create parent layer
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoSize)
        parentLayer.addSublayer(textLayer)

        return parentLayer
    }

    /// Applies watermark to a composition
    static func applied(to composition: AVMutableComposition, videoSize: CGSize, transform: CGAffineTransform = .identity) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = videoSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        // Create instruction for the full duration
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        // Add layer instruction for the video track
        if let videoTrack = composition.tracks(withMediaType: .video).first {
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(transform, at: .zero)
            instruction.layerInstructions = [layerInstruction]
        }

        videoComposition.instructions = [instruction]

        attachTool(to: videoComposition, videoSize: videoSize)

        return videoComposition
    }

    /// Adds the watermark overlay as a Core Animation tool on an existing
    /// video composition. Shared by single-source and stitched exports.
    static func attachTool(to videoComposition: AVMutableVideoComposition, videoSize: CGSize) {
        attachOverlayTool(
            to: videoComposition,
            videoSize: videoSize,
            overlayLayers: [layer(videoSize: videoSize, videoDuration: .zero)]
        )
    }

    /// Attaches arbitrary overlay layers (scoreboards, watermark) over the
    /// video via one Core Animation tool — a composition supports only one.
    static func attachOverlayTool(to videoComposition: AVMutableVideoComposition, videoSize: CGSize, overlayLayers: [CALayer]) {
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoSize)
        videoLayer.frame = CGRect(origin: .zero, size: videoSize)
        parentLayer.addSublayer(videoLayer)
        for layer in overlayLayers {
            parentLayer.addSublayer(layer)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
    }

    /// Export a single time range to a URL, optionally with watermark overlay.
}
