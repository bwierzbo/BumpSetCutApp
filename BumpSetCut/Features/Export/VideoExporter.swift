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
    /// already applied at export time) and an optional framing: a rotation
    /// about the center (scaled up just enough to hide the corners, like the
    /// player), then a zoom around center and a pan normalized as a fraction
    /// of the render size. Pan and rotation are in the composition's own
    /// coordinate space — see `StitchClip.init(url:timeRange:crop:)` for the
    /// conversion from what the screen showed.
    struct StitchClip {
        let url: URL
        let timeRange: CMTimeRange?
        let rotationDegrees: Double
        let zoom: CGFloat
        let panX: CGFloat
        let panY: CGFloat

        init(url: URL, timeRange: CMTimeRange? = nil, rotationDegrees: Double = 0,
             zoom: CGFloat = 1, panX: CGFloat = 0, panY: CGFloat = 0) {
            self.url = url
            self.timeRange = timeRange
            self.rotationDegrees = rotationDegrees
            self.zoom = zoom
            self.panX = panX
            self.panY = panY
        }

        var hasFraming: Bool {
            abs(rotationDegrees) >= 0.01 || zoom > 1.001 || panX != 0 || panY != 0
        }
    }

    /// Composition + per-clip video instructions for a reel. The video
    /// composition carries one instruction per clip so mixed orientations all
    /// render upright, aspect-fit into the first clip's display size.
    struct StitchBuild {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        /// Output-timeline range of each INPUT clip, aligned by index
        /// (nil = that clip resolved to zero duration and was skipped).
        let clipRanges: [CMTimeRange?]
    }

    /// Stitch multiple source files into one reel. Every clip gets its own
    /// composition instruction: its preferred transform normalized to upright,
    /// then aspect-fit into the render size (the first clip's upright size,
    /// scaled down when its long edge exceeds `maxLongEdge` — posts don't
    /// need 4K, and the upload is the slow part). Clips without audio insert
    /// an empty audio range so later clips stay in sync. Separated from
    /// export so tests can inspect the build.
    func buildStitchComposition(clips: [StitchClip], maxLongEdge: CGFloat? = nil) async throws -> StitchBuild {
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
        var clipRanges: [CMTimeRange?] = []

        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw ProcessingError.noVideoTrack
            }
            let aTrack = try? await asset.loadTracks(withMediaType: .audio).first

            let fullRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            let range = clip.timeRange.map { CMTimeRangeGetIntersection($0, otherRange: fullRange) } ?? fullRange
            guard range.duration > .zero else {
                clipRanges.append(nil)
                continue
            }
            clipRanges.append(CMTimeRange(start: currentTime, duration: range.duration))

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
            if renderSize == .zero { renderSize = Self.capped(uprightSize, maxLongEdge: maxLongEdge) }
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

            // Optional framing, all about the render center: rotate (scaled to
            // cover the frame, so no corner goes black), then zoom, then pan.
            if clip.hasFraming {
                let center = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
                var framing = CGAffineTransform(translationX: -center.x, y: -center.y)
                if abs(clip.rotationDegrees) >= 0.01 {
                    // The rotated rect is the fitted content, whose aspect is
                    // what the cover scale depends on.
                    let fitted = CGSize(width: uprightSize.width * scale, height: uprightSize.height * scale)
                    let cover = RotationGeometry.coverScale(angleDegrees: clip.rotationDegrees, size: fitted)
                    framing = framing
                        .concatenating(CGAffineTransform(rotationAngle: CGFloat(clip.rotationDegrees * .pi / 180)))
                        .concatenating(CGAffineTransform(scaleX: cover, y: cover))
                }
                let zoom = max(1, clip.zoom)
                framing = framing
                    .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                    .concatenating(CGAffineTransform(
                        translationX: center.x + clip.panX * renderSize.width,
                        y: center.y + clip.panY * renderSize.height
                    ))
                transform = transform.concatenating(framing)
            }

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

        return StitchBuild(composition: composition, videoComposition: videoComposition, clipRanges: clipRanges)
    }

    /// Scale a frame size down so its long edge is at most `maxLongEdge`,
    /// keeping the aspect and even dimensions (encoders want them even).
    static func capped(_ size: CGSize, maxLongEdge: CGFloat?) -> CGSize {
        guard let maxLongEdge, maxLongEdge > 0, max(size.width, size.height) > maxLongEdge else { return size }
        let scale = maxLongEdge / max(size.width, size.height)
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// Export multiple source clips as ONE stitched reel to a tmp file
    /// (`stitched_rallies_` prefix — covered by the existing tmp sweeper).
    func exportStitchedClips(_ clips: [StitchClip], addWatermark: Bool = false, maxLongEdge: CGFloat? = nil,
                             progressHandler: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let build = try await buildStitchComposition(clips: clips, maxLongEdge: maxLongEdge)
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

    // MARK: - Scored Game Export

    /// Scoreboard shown during one clip of a scored game export.
    struct GameScoreOverlay {
        let teamAName: String
        let teamBName: String
        let teamAColor: UIColor
        let teamBColor: UIColor
        let state: GameScoreState
        /// Show the sets line (any set has been played or is configured).
        let showsSets: Bool
    }

    /// Where the burned-in scoreboard sits on the exported video.
    enum ScoreboardPosition: String, CaseIterable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    /// Stitch a full game into ONE video with a running scoreboard burned in.
    /// `overlays` aligns with `clips` by index (nil = no scoreboard for that
    /// clip). Uses the same Core Animation mechanism as the watermark.
    func exportScoredGame(
        clips: [StitchClip],
        overlays: [GameScoreOverlay?],
        scoreboardPosition: ScoreboardPosition = .topLeft,
        scoreboardScale: CGFloat = 1.0,
        addWatermark: Bool = false,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let build = try await buildStitchComposition(clips: clips)
        let videoSize = build.videoComposition.renderSize

        // The watermark occupies the bottom-right corner — lift a bottom-right
        // scoreboard above it so the two never stack.
        let watermarkClearance: CGFloat
        if addWatermark, scoreboardPosition == .bottomRight {
            let watermarkFontSize = min(max(videoSize.height * 0.028, 13), 44)
            watermarkClearance = ceil(watermarkFontSize * 2.2)
        } else {
            watermarkClearance = 0
        }

        var overlayLayers: [CALayer] = []
        for (index, range) in build.clipRanges.enumerated() {
            guard let range, index < overlays.count, let overlay = overlays[index] else { continue }
            overlayLayers.append(makeScoreboardLayer(
                overlay, timeRange: range, videoSize: videoSize,
                position: scoreboardPosition, scale: scoreboardScale,
                bottomClearance: watermarkClearance
            ))
        }
        if addWatermark {
            overlayLayers.append(createWatermarkLayer(videoSize: videoSize, videoDuration: build.composition.duration))
        }
        attachOverlayTool(to: build.videoComposition, videoSize: videoSize, overlayLayers: overlayLayers)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stitched_rallies_game_\(UUID().uuidString).mp4")
        return try await exportComposition(
            build.composition,
            videoComposition: build.videoComposition,
            to: outputURL,
            progressHandler: progressHandler
        )
    }

    @discardableResult
    func exportScoredGameToPhotoLibrary(
        clips: [StitchClip],
        overlays: [GameScoreOverlay?],
        scoreboardPosition: ScoreboardPosition = .topLeft,
        scoreboardScale: CGFloat = 1.0,
        addWatermark: Bool = false,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let url = try await exportScoredGame(
            clips: clips, overlays: overlays,
            scoreboardPosition: scoreboardPosition, scoreboardScale: scoreboardScale,
            addWatermark: addWatermark, progressHandler: progressHandler
        )
        try await saveVideoToPhotoLibrary(url: url)
        return url
    }

    /// One scoreboard pill, visible only during its clip's output range.
    /// Video-composition layer space has its origin at the BOTTOM-left.
    private func makeScoreboardLayer(_ overlay: GameScoreOverlay, timeRange: CMTimeRange, videoSize: CGSize, position: ScoreboardPosition, scale: CGFloat, bottomClearance: CGFloat = 0) -> CALayer {
        let fontSize = min(max(videoSize.height * 0.034 * scale, 14), 64)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let subFont = UIFont.systemFont(ofSize: fontSize * 0.62, weight: .semibold)

        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: "● ", attributes: [.font: font, .foregroundColor: overlay.teamAColor]))
        line.append(NSAttributedString(string: "\(overlay.teamAName)  \(overlay.state.scoreA)",
                                       attributes: [.font: font, .foregroundColor: UIColor.white]))
        line.append(NSAttributedString(string: " – ",
                                       attributes: [.font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.6)]))
        line.append(NSAttributedString(string: "\(overlay.state.scoreB)  \(overlay.teamBName)",
                                       attributes: [.font: font, .foregroundColor: UIColor.white]))
        line.append(NSAttributedString(string: " ●", attributes: [.font: font, .foregroundColor: overlay.teamBColor]))

        if overlay.showsSets {
            line.append(NSAttributedString(
                string: "   Sets \(overlay.state.setsA)–\(overlay.state.setsB)",
                attributes: [.font: subFont, .foregroundColor: UIColor.white.withAlphaComponent(0.75)]
            ))
        }

        let textSize = line.size()
        let hPadding = fontSize * 0.7
        let vPadding = fontSize * 0.42
        let pillSize = CGSize(width: ceil(textSize.width) + hPadding * 2,
                              height: ceil(textSize.height) + vPadding * 2)

        let textLayer = CATextLayer()
        textLayer.string = line
        textLayer.alignmentMode = .center
        textLayer.contentsScale = 2
        textLayer.frame = CGRect(x: hPadding, y: vPadding, width: ceil(textSize.width), height: ceil(textSize.height))

        let margin = fontSize * 0.6
        let originX: CGFloat
        switch position {
        case .topLeft, .bottomLeft:
            originX = margin
        case .topRight, .bottomRight:
            originX = videoSize.width - pillSize.width - margin
        }
        let originY: CGFloat
        switch position {
        case .topLeft, .topRight:
            originY = videoSize.height - pillSize.height - margin
        case .bottomLeft, .bottomRight:
            originY = margin + bottomClearance
        }
        let pill = CALayer()
        pill.frame = CGRect(x: originX, y: originY, width: pillSize.width, height: pillSize.height)
        pill.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
        pill.cornerRadius = pillSize.height / 2
        pill.masksToBounds = true
        pill.addSublayer(textLayer)

        // Visible only during this clip: model opacity 0, a held animation
        // raises it for [start, start+duration] on the export timeline.
        pill.opacity = 0
        let visibility = CABasicAnimation(keyPath: "opacity")
        visibility.fromValue = 1
        visibility.toValue = 1
        let start = CMTimeGetSeconds(timeRange.start)
        // beginTime 0 means "now" to Core Animation — nudge it.
        visibility.beginTime = start == 0 ? AVCoreAnimationBeginTimeAtZero : start
        visibility.duration = CMTimeGetSeconds(timeRange.duration)
        visibility.isRemovedOnCompletion = false
        visibility.fillMode = .removed
        pill.add(visibility, forKey: "scoreboardVisibility")

        return pill
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

    /// Same-source trim: keep only `ranges` (in order) of the file at `url`,
    /// preserving quality via passthrough when the codec allows, re-encoding
    /// otherwise. Powers "Free Up Space" — the trimmed file replaces the
    /// original, with rally segment times remapped onto the new timeline.
    func exportKeepRanges(
        from url: URL,
        ranges: [CMTimeRange],
        to outputURL: URL,
        fileType: AVFileType,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard !ranges.isEmpty else { throw ProcessingError.compositionFailed }

        let asset = AVURLAsset(url: url)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        let aTrack = try? await asset.loadTracks(withMediaType: .audio).first

        let composition = AVMutableComposition()
        guard let compV = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessingError.compositionFailed
        }
        let compA = aTrack != nil ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        var currentTime = CMTime.zero
        for range in ranges {
            try compV.insertTimeRange(range, of: vTrack, at: currentTime)
            if let aTrack, let compA {
                try compA.insertTimeRange(range, of: aTrack, at: currentTime)
            }
            currentTime = CMTimeAdd(currentTime, range.duration)
        }
        compV.preferredTransform = (try? await vTrack.load(.preferredTransform)) ?? .identity

        // Passthrough first (no quality loss, dramatically faster).
        do {
            try? FileManager.default.removeItem(at: outputURL)
            return try await exportComposition(
                composition, videoComposition: nil, to: outputURL,
                preset: AVAssetExportPresetPassthrough, fileType: fileType,
                progressHandler: progressHandler
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            return try await exportComposition(
                composition, videoComposition: nil, to: outputURL,
                preset: AVAssetExportPresetHighestQuality, fileType: fileType,
                progressHandler: progressHandler
            )
        }
    }

    /// Shared progress-reporting export for stitched compositions
    /// (iOS-18 async export vs. the legacy polling path).
    private func exportComposition(
        _ composition: AVMutableComposition,
        videoComposition: AVVideoComposition?,
        to outputURL: URL,
        preset: String = AVAssetExportPresetHighestQuality,
        fileType: AVFileType = .mp4,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
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
            try await exporter.export(to: outputURL, as: fileType)
            pollTask.cancel()
            progressHandler?(1.0)
            return outputURL
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = fileType
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

    /// Creates a watermark text layer for video compositions. Layer space is
    /// in PIXELS of the render size — sizes must scale with the video or the
    /// mark is microscopic on 1080p+ footage (tester-reported).
    func createWatermarkLayer(videoSize: CGSize, videoDuration: CMTime) -> CALayer {
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
        attachOverlayTool(
            to: videoComposition,
            videoSize: videoSize,
            overlayLayers: [createWatermarkLayer(videoSize: videoSize, videoDuration: .zero)]
        )
    }

    /// Attaches arbitrary overlay layers (scoreboards, watermark) over the
    /// video via one Core Animation tool — a composition supports only one.
    private func attachOverlayTool(to videoComposition: AVMutableVideoComposition, videoSize: CGSize, overlayLayers: [CALayer]) {
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
    func exportClip(asset: AVAsset, timeRange: CMTimeRange, to outputURL: URL, addWatermark: Bool = false) async throws -> URL {
        if addWatermark {
            return try await exportWithReencoding(asset: asset, timeRange: timeRange, to: outputURL, rallyIndex: 0, addWatermark: true)
        }
        return try await exportPassthrough(asset: asset, timeRange: timeRange, to: outputURL)
    }
}
