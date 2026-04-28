//
//  GameExportService.swift
//  BumpSetCut
//
//  Exports Game Review video with score overlay burned in.
//

import AVFoundation
import UIKit
import Photos

final class GameExportService {

    /// Export a stitched video of rally segments with per-rally score overlay.
    func exportGameVideo(
        asset: AVAsset,
        rallies: [RallySegment],
        decisions: [RallyScoringDecision],
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("game_review_\(UUID().uuidString).mp4")

        // Build composition
        let composition = AVMutableComposition()

        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        let aTrack = try? await asset.loadTracks(withMediaType: .audio).first

        guard let compV = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessingError.compositionFailed
        }
        let compA = aTrack != nil ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        // Track per-rally timing in the composition timeline
        var rallyTimings: [(start: CMTime, duration: CMTime)] = []
        var currentTime = CMTime.zero

        let ralliesCount = min(rallies.count, decisions.count)
        for i in 0..<ralliesCount {
            let rally = rallies[i]
            let startTime = CMTime(seconds: rally.startTime, preferredTimescale: 600)
            let endTime = CMTime(seconds: rally.endTime, preferredTimescale: 600)
            let duration = CMTimeSubtract(endTime, startTime)
            let timeRange = CMTimeRange(start: startTime, duration: duration)

            try compV.insertTimeRange(timeRange, of: vTrack, at: currentTime)
            if let srcA = aTrack, let dstA = compA {
                try dstA.insertTimeRange(timeRange, of: srcA, at: currentTime)
            }

            rallyTimings.append((start: currentTime, duration: duration))
            currentTime = CMTimeAdd(currentTime, duration)
        }

        let preferredTransform = (try? await vTrack.load(.preferredTransform)) ?? .identity
        let naturalSize = try await vTrack.load(.naturalSize)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let videoSize = CGSize(width: abs(rect.width), height: abs(rect.height))

        // Build video composition with score overlay
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = videoSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        if let videoTrack = composition.tracks(withMediaType: .video).first {
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(preferredTransform, at: .zero)
            instruction.layerInstructions = [layerInstruction]
        }
        videoComposition.instructions = [instruction]

        // Create overlay layers
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoSize)
        videoLayer.frame = CGRect(origin: .zero, size: videoSize)
        parentLayer.addSublayer(videoLayer)

        // Add score text layers for each rally
        for (i, timing) in rallyTimings.enumerated() {
            guard i < decisions.count else { break }
            let decision = decisions[i]

            let scoreText = "Near \(decision.scoreAfter.near) — \(decision.scoreAfter.far) Far"
            let textLayer = CATextLayer()
            textLayer.string = scoreText
            textLayer.font = UIFont.systemFont(ofSize: 24, weight: .bold)
            textLayer.fontSize = 24
            textLayer.foregroundColor = UIColor.white.cgColor
            textLayer.alignmentMode = .center
            textLayer.shadowColor = UIColor.black.cgColor
            textLayer.shadowOpacity = 0.8
            textLayer.shadowOffset = CGSize(width: 1, height: 1)
            textLayer.shadowRadius = 3

            let textWidth: CGFloat = 300
            let textHeight: CGFloat = 36
            // Position at top center (CoreAnimation uses bottom-left origin)
            textLayer.frame = CGRect(
                x: (videoSize.width - textWidth) / 2,
                y: videoSize.height - textHeight - 40,
                width: textWidth,
                height: textHeight
            )

            // Show only during this rally's time range
            textLayer.opacity = 0
            let showAnim = CABasicAnimation(keyPath: "opacity")
            showAnim.fromValue = 1.0
            showAnim.toValue = 1.0
            showAnim.beginTime = CMTimeGetSeconds(timing.start)
            showAnim.duration = CMTimeGetSeconds(timing.duration)
            showAnim.isRemovedOnCompletion = false
            showAnim.fillMode = .forwards
            textLayer.add(showAnim, forKey: "show_\(i)")

            parentLayer.addSublayer(textLayer)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        // Export
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProcessingError.exportSessionFailed("Game export session unavailable")
        }

        exporter.videoComposition = videoComposition

        if #available(iOS 18.0, *) {
            let pollTask = Task.detached { [weak exporter] in
                while let exp = exporter, exp.progress < 1.0 {
                    progressHandler?(Double(exp.progress))
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            try await exporter.export(to: outputURL, as: .mp4)
            pollTask.cancel()
            progressHandler?(1.0)
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = .mp4
            exporter.shouldOptimizeForNetworkUse = true
            exporter.exportAsynchronously(completionHandler: {})

            while exporter.status == .exporting {
                progressHandler?(Double(exporter.progress))
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            switch exporter.status {
            case .completed:
                progressHandler?(1.0)
            case .failed:
                throw exporter.error ?? ProcessingError.exportSessionFailed("Game export failed")
            case .cancelled:
                throw ProcessingError.exportCancelled
            default:
                throw ProcessingError.exportSessionFailed("Unexpected game export status: \(exporter.status.rawValue)")
            }
        }

        return outputURL
    }

    /// Save a video URL to the Photos library.
    func saveToPhotoLibrary(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
