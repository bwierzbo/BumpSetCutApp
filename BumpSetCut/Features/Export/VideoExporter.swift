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

    // MARK: - Multi-Source Stitching (highlight reels)

    /// One clip of a stitched highlight reel: a source file plus an optional
    /// sub-range (nil = the whole clip, e.g. a favorites clip with its trim
    /// already applied at export time).
    struct StitchClip {
        let url: URL
        let timeRange: CMTimeRange?

        init(url: URL, timeRange: CMTimeRange? = nil) {
            self.url = url
            self.timeRange = timeRange
        }
    }

    /// Composition + per-clip video instructions for a reel. The video
    /// composition carries one instruction per clip so mixed orientations all
    /// render upright, aspect-fit into the first clip's display size.
    struct StitchBuild {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
    }

    /// Stitch multiple source files into one reel. Every clip gets its own
    /// composition instruction: its preferred transform normalized to upright,
    /// then aspect-fit into the render size (the first clip's upright size).
    /// Clips without audio insert an empty audio range so later clips stay in
    /// sync. Separated from export so tests can inspect the build.
    func buildStitchComposition(clips: [StitchClip]) async throws -> StitchBuild {
        guard !clips.isEmpty else {
            throw ProcessingError.compositionFailed
        }

        let composition = AVMutableComposition()
        guard let compV = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessingError.compositionFailed
        }

        var renderSize = CGSize.zero
        var maxFrameRate: Float = 0
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var currentTime = CMTime.zero
        var insertedAnyAudio = false

        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw ProcessingError.noVideoTrack
            }
            let aTrack = try? await asset.loadTracks(withMediaType: .audio).first

            let fullRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            let range = clip.timeRange.map { CMTimeRangeGetIntersection($0, otherRange: fullRange) } ?? fullRange
            guard range.duration > .zero else { continue }

            try compV.insertTimeRange(range, of: vTrack, at: currentTime)
            if let aTrack {
                try compA.insertTimeRange(range, of: aTrack, at: currentTime)
                insertedAnyAudio = true
            } else {
                // Keep the audio timeline aligned with video for later clips.
                compA.insertEmptyTimeRange(CMTimeRange(start: currentTime, duration: range.duration))
            }

            let naturalSize = try await vTrack.load(.naturalSize)
            let preferredTransform = (try? await vTrack.load(.preferredTransform)) ?? .identity
            let uprightSize = videoSizeAfterTransform(naturalSize: naturalSize, transform: preferredTransform)
            if renderSize == .zero { renderSize = uprightSize }
            maxFrameRate = max(maxFrameRate, (try? await vTrack.load(.nominalFrameRate)) ?? 0)

            // Normalize the transform so the upright video starts at the origin,
            // then aspect-fit + center it in the render size.
            let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            var transform = preferredTransform.concatenating(
                CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY)
            )
            let scale = min(renderSize.width / uprightSize.width, renderSize.height / uprightSize.height)
            transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            transform = transform.concatenating(CGAffineTransform(
                translationX: (renderSize.width - uprightSize.width * scale) / 2,
                y: (renderSize.height - uprightSize.height * scale) / 2
            ))

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: currentTime, duration: range.duration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compV)
            layerInstruction.setTransform(transform, at: currentTime)
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)

            currentTime = CMTimeAdd(currentTime, range.duration)
        }

        guard !instructions.isEmpty else {
            throw ProcessingError.compositionFailed
        }

        // A track of nothing but empty ranges buys nothing — drop it.
        if !insertedAnyAudio {
            composition.removeTrack(compA)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        // Match the fastest source, clamped to a sane range (never hardcode 30).
        let frameRate = Int32(min(max(maxFrameRate.rounded(), 24), 60))
        videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
        videoComposition.instructions = instructions

        return StitchBuild(composition: composition, videoComposition: videoComposition)
    }

    /// Export multiple source clips as ONE stitched reel to a tmp file
    /// (`stitched_rallies_` prefix — covered by the existing tmp sweeper).
    func exportStitchedClips(_ clips: [StitchClip], addWatermark: Bool = false, progressHandler: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let build = try await buildStitchComposition(clips: clips)
        if addWatermark {
            attachWatermarkTool(to: build.videoComposition, videoSize: build.videoComposition.renderSize)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stitched_rallies_\(UUID().uuidString).mp4")
        return try await exportComposition(
            build.composition,
            videoComposition: build.videoComposition,
            to: outputURL,
            progressHandler: progressHandler
        )
    }

    /// Stitch multiple source clips into one reel and save it to Photos,
    /// returning the temp file URL for sharing. Caller cleans up the URL.
    @discardableResult
    func exportStitchedClipsToPhotoLibrary(_ clips: [StitchClip], addWatermark: Bool = false, progressHandler: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let exportedURL = try await exportStitchedClips(clips, addWatermark: addWatermark, progressHandler: progressHandler)
        try await saveVideoToPhotoLibrary(url: exportedURL)
        return exportedURL
    }

    /// Exports a single rally segment as an individual video file.
    /// Uses passthrough (no re-encoding) when possible, falls back to re-encoding if needed.
    /// Output goes to tmp: these are share-then-delete files and must not land in
    /// Documents, which is iCloud-backed.
    private func exportSingleRally(asset: AVAsset, timeRange: CMTimeRange, rallyIndex: Int, addWatermark: Bool = false) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
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

        var videoComposition: AVMutableVideoComposition?
        if addWatermark {
            let naturalSize = try await vTrack.load(.naturalSize)
            let videoSize = videoSizeAfterTransform(naturalSize: naturalSize, transform: preferredTransform)
            videoComposition = applyWatermark(to: composition, videoSize: videoSize, transform: preferredTransform)
        }

        return try await exportComposition(
            composition,
            videoComposition: videoComposition,
            to: outputURL,
            progressHandler: progressHandler
        )
    }

    /// Shared progress-reporting export for stitched compositions
    /// (iOS-18 async export vs. the legacy polling path).
    private func exportComposition(_ composition: AVMutableComposition, videoComposition: AVVideoComposition?, to outputURL: URL, progressHandler: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProcessingError.exportSessionFailed("Stitched export session unavailable")
        }
        exporter.videoComposition = videoComposition

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

        attachWatermarkTool(to: videoComposition, videoSize: videoSize)

        return videoComposition
    }

    /// Adds the watermark overlay as a Core Animation tool on an existing
    /// video composition. Shared by single-source and stitched exports.
    private func attachWatermarkTool(to videoComposition: AVMutableVideoComposition, videoSize: CGSize) {
        let watermarkLayer = createWatermarkLayer(videoSize: videoSize, videoDuration: .zero)

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
