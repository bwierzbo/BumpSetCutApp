//
//  VideoExporter.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import AVFoundation
import UIKit
import Photos

final class VideoExporter {

    /// Exports individual rally segments as separate video files
    func exportRallySegments(asset: AVAsset, rallies: [RallySegment], addWatermark: Bool = false) async throws -> [URL] {
        var exportedURLs: [URL] = []

        for (index, rally) in rallies.enumerated() {
            let startTime = CMTime(seconds: rally.startTime, preferredTimescale: 600)
            let endTime = CMTime(seconds: rally.endTime, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: startTime, end: endTime)
            let url = try await exportSingleRally(asset: asset, timeRange: timeRange, rallyIndex: index, addWatermark: addWatermark)
            exportedURLs.append(url)
        }

        return exportedURLs
    }

    /// Exports a single rally segment as an individual video file.
    /// Uses passthrough (no re-encoding) when possible, falls back to re-encoding if needed.
    private func exportSingleRally(asset: AVAsset, timeRange: CMTimeRange, rallyIndex: Int, addWatermark: Bool = false) async throws -> URL {
        let outURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rally_\(rallyIndex)_\(UUID().uuidString).mp4")

        // Watermark requires composition-based export (can't overlay on passthrough)
        if addWatermark {
            return try await exportWithReencoding(asset: asset, timeRange: timeRange, to: outURL, rallyIndex: rallyIndex, addWatermark: true)
        }

        // Try passthrough first: extract the time range directly from the source asset
        // without re-encoding. This preserves original quality and is dramatically faster.
        if let passthroughResult = try? await exportPassthrough(asset: asset, timeRange: timeRange, to: outURL) {
            return passthroughResult
        }

        // Fallback: use composition + re-encoding if passthrough failed
        return try await exportWithReencoding(asset: asset, timeRange: timeRange, to: outURL, rallyIndex: rallyIndex)
    }

    /// Export a time range using passthrough (no re-encoding).
    /// Returns the output URL on success, or throws on failure.
    private func exportPassthrough(asset: AVAsset, timeRange: CMTimeRange, to outURL: URL) async throws -> URL {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ProcessingError.exportSessionFailed("Passthrough export session unavailable")
        }

        exporter.timeRange = timeRange

        if #available(iOS 18.0, *) {
            try await exporter.export(to: outURL, as: .mp4)
            return outURL
        } else {
            exporter.outputURL = outURL
            exporter.outputFileType = .mp4

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously {
                    cont.resume()
                }
            }

            if exporter.status == .failed {
                throw exporter.error ?? ProcessingError.exportSessionFailed("Passthrough export failed")
            }
            return outURL
        }
    }

    /// Export a time range using composition + re-encoding (HighestQuality).
    /// Used as fallback when passthrough is not supported for the source codec.
    private func exportWithReencoding(asset: AVAsset, timeRange: CMTimeRange, to outURL: URL, rallyIndex: Int, addWatermark: Bool = false) async throws -> URL {
        // Clean up any partial file from failed passthrough attempt
        try? FileManager.default.removeItem(at: outURL)

        let comp = AVMutableComposition()
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        let aTrack = try? await asset.loadTracks(withMediaType: .audio).first

        guard let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessingError.compositionFailed
        }
        let compA = aTrack != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        try compV.insertTimeRange(timeRange, of: vTrack, at: .zero)
        if let srcA = aTrack, let dstA = compA {
            try dstA.insertTimeRange(timeRange, of: srcA, at: .zero)
        }

        let preferredTransform = (try? await vTrack.load(.preferredTransform)) ?? .identity
        if !addWatermark {
            compV.preferredTransform = preferredTransform
        }

        guard let exporter = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProcessingError.exportSessionFailed("Re-encoding export session unavailable")
        }

        if addWatermark {
            let naturalSize = try await vTrack.load(.naturalSize)
            let videoSize = videoSizeAfterTransform(naturalSize: naturalSize, transform: preferredTransform)
            exporter.videoComposition = applyWatermark(to: comp, videoSize: videoSize, transform: preferredTransform)
        }

        if #available(iOS 18.0, *) {
            try await exporter.export(to: outURL, as: .mp4)
            return outURL
        } else {
            exporter.outputURL = outURL
            exporter.outputFileType = .mp4
            exporter.shouldOptimizeForNetworkUse = true

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously {
                    cont.resume()
                }
            }

            if exporter.status == .failed {
                throw exporter.error ?? ProcessingError.exportSessionFailed("Re-encoding export failed")
            }
            return outURL
        }
    }

    /// Exports a composition of keep ranges from the source asset, preserving orientation and audio.
    func exportTrimmed(asset: AVAsset, keepRanges: [CMTimeRange]) async throws -> URL {
        let outURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("auto_cut_\(UUID().uuidString).mp4")

        let comp = AVMutableComposition()
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        let aTrack = try? await asset.loadTracks(withMediaType: .audio).first

        guard let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessingError.compositionFailed
        }
        let compA = aTrack != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        var cursor: CMTime = .zero
        for r in keepRanges {
            try compV.insertTimeRange(r, of: vTrack, at: cursor)
            if let srcA = aTrack, let dstA = compA {
                try dstA.insertTimeRange(r, of: srcA, at: cursor)
            }
            cursor = CMTimeAdd(cursor, r.duration)
        }

        // Keep orientation
        if let pref = try? await vTrack.load(.preferredTransform) {
            compV.preferredTransform = pref
        }

        guard let exporter = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProcessingError.exportSessionFailed("Trimmed export session unavailable")
        }

        if #available(iOS 18.0, *) {
            try await exporter.export(to: outURL, as: .mp4)
            return outURL
        } else {
            exporter.outputURL = outURL
            exporter.outputFileType = .mp4
            exporter.shouldOptimizeForNetworkUse = true
            exporter.exportAsynchronously(completionHandler: {})

            while exporter.status == .exporting {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            
            // Check export session status before returning
            switch exporter.status {
            case .completed:
                // Verify the file was actually created
                guard FileManager.default.fileExists(atPath: outURL.path) else {
                    throw ProcessingError.exportSessionFailed("Output file not created")
                }
                return outURL
            case .failed:
                throw exporter.error ?? ProcessingError.exportSessionFailed("Trimmed export failed")
            case .cancelled:
                throw ProcessingError.exportCancelled
            default:
                throw ProcessingError.exportSessionFailed("Unexpected export status: \(exporter.status.rawValue)")
            }
        }
    }

    // MARK: - Photo Library Export

    /// Export a single rally segment to the photo library, returning the temp file URL for sharing.
    /// Caller is responsible for cleaning up the returned URL when done.
    @discardableResult
    func exportRallyToPhotoLibrary(asset: AVAsset, rally: RallySegment, index: Int, addWatermark: Bool = false) async throws -> URL {
        // Create time range from rally segment
        let startTime = CMTime(seconds: rally.startTime, preferredTimescale: 600)
        let endTime = CMTime(seconds: rally.endTime, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        // Export rally segment to temporary file
        let exportedURL = try await exportSingleRally(asset: asset, timeRange: timeRange, rallyIndex: index, addWatermark: addWatermark)

        // Save to photo library
        try await saveVideoToPhotoLibrary(url: exportedURL)

        return exportedURL
    }

    /// Export multiple rally segments stitched together to the photo library, returning the temp file URL for sharing.
    /// Caller is responsible for cleaning up the returned URL when done.
    @discardableResult
    func exportStitchedRalliesToPhotoLibrary(asset: AVAsset, rallies: [RallySegment], addWatermark: Bool = false, progressHandler: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stitched_rallies_\(UUID().uuidString).mp4")

        // Create stitched video
        let exportedURL = try await createStitchedVideo(
            asset: asset,
            rallies: rallies,
            outputURL: tempURL,
            addWatermark: addWatermark,
            progressHandler: progressHandler
        )

        // Save to photo library
        try await saveVideoToPhotoLibrary(url: exportedURL)

        return exportedURL
    }

    // MARK: - Private Helpers

    private func saveVideoToPhotoLibrary(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    private func createStitchedVideo(asset: AVAsset, rallies: [RallySegment], outputURL: URL, addWatermark: Bool = false, progressHandler: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let composition = AVMutableComposition()

        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        let aTrack = try? await asset.loadTracks(withMediaType: .audio).first

        guard let compV = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessingError.compositionFailed
        }
        let compA = aTrack != nil ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        var currentTime = CMTime.zero

        // Add each rally segment to the composition
        for rally in rallies {
            let startTime = CMTime(seconds: rally.startTime, preferredTimescale: 600)
            let endTime = CMTime(seconds: rally.endTime, preferredTimescale: 600)
            let duration = CMTimeSubtract(endTime, startTime)

            let timeRange = CMTimeRange(start: startTime, duration: duration)

            try compV.insertTimeRange(timeRange, of: vTrack, at: currentTime)
            if let srcA = aTrack, let dstA = compA {
                try dstA.insertTimeRange(timeRange, of: srcA, at: currentTime)
            }

            currentTime = CMTimeAdd(currentTime, duration)
        }

        // Keep orientation
        let preferredTransform = (try? await vTrack.load(.preferredTransform)) ?? .identity
        if !addWatermark {
            compV.preferredTransform = preferredTransform
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProcessingError.exportSessionFailed("Stitched export session unavailable")
        }

        if addWatermark {
            let naturalSize = try await vTrack.load(.naturalSize)
            let videoSize = videoSizeAfterTransform(naturalSize: naturalSize, transform: preferredTransform)
            exporter.videoComposition = applyWatermark(to: composition, videoSize: videoSize, transform: preferredTransform)
        }

        if #available(iOS 18.0, *) {
            // Poll progress on a background task while awaiting export
            let pollTask = Task.detached { [weak exporter] in
                while let exp = exporter, exp.progress < 1.0 {
                    progressHandler?(Double(exp.progress))
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }
            try await exporter.export(to: outputURL, as: .mp4)
            pollTask.cancel()
            progressHandler?(1.0)
            return outputURL
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = .mp4
            exporter.shouldOptimizeForNetworkUse = true
            exporter.exportAsynchronously(completionHandler: {})

            while exporter.status == .exporting {
                progressHandler?(Double(exporter.progress))
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            switch exporter.status {
            case .completed:
                progressHandler?(1.0)
                return outputURL
            case .failed:
                throw exporter.error ?? ProcessingError.exportSessionFailed("Stitched export failed")
            case .cancelled:
                throw ProcessingError.exportCancelled
            default:
                throw ProcessingError.exportSessionFailed("Unexpected stitched export status: \(exporter.status.rawValue)")
            }
        }
    }

    // MARK: - Watermark

    /// Compute the rendered video size after applying the preferred transform
    private func videoSizeAfterTransform(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Creates a watermark text layer for video compositions
    func createWatermarkLayer(videoSize: CGSize, videoDuration: CMTime) -> CALayer {
        let watermarkText = "Made with BumpSetCut"

        // Create text layer
        let textLayer = CATextLayer()
        textLayer.string = watermarkText
        textLayer.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        textLayer.fontSize = 14
        textLayer.foregroundColor = UIColor.white.withAlphaComponent(0.6).cgColor
        textLayer.alignmentMode = .right
        textLayer.shadowColor = UIColor.black.cgColor
        textLayer.shadowOpacity = 0.5
        textLayer.shadowOffset = CGSize(width: 1, height: 1)
        textLayer.shadowRadius = 2

        // Position in bottom-right corner with padding
        let padding: CGFloat = 16
        let textWidth: CGFloat = 180
        let textHeight: CGFloat = 20

        textLayer.frame = CGRect(
            x: videoSize.width - textWidth - padding,
            y: padding,
            width: textWidth,
            height: textHeight
        )

        // Create parent layer
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoSize)
        parentLayer.addSublayer(textLayer)

        return parentLayer
    }

    /// Applies watermark to a composition
    func applyWatermark(to composition: AVMutableComposition, videoSize: CGSize, transform: CGAffineTransform = .identity) -> AVMutableVideoComposition {
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

        // Add watermark as animation layer
        let watermarkLayer = createWatermarkLayer(videoSize: videoSize, videoDuration: composition.duration)

        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoSize)
        videoLayer.frame = CGRect(origin: .zero, size: videoSize)
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(watermarkLayer)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        return videoComposition
    }

    /// Export a single time range to a URL, optionally with watermark overlay.
    /// Used by ShareRallyViewModel for community posts.
    func exportClip(asset: AVAsset, timeRange: CMTimeRange, to outputURL: URL, addWatermark: Bool = false) async throws -> URL {
        if addWatermark {
            return try await exportWithReencoding(asset: asset, timeRange: timeRange, to: outputURL, rallyIndex: 0, addWatermark: true)
        }
        return try await exportPassthrough(asset: asset, timeRange: timeRange, to: outputURL)
    }
}
