//
//  VideoExporter+ScoredGame.swift
//  BumpSetCut
//
//  Exporting a scored game: stitched rallies with a burned-in scoreboard.
//

import AVFoundation
import QuartzCore
import UIKit

extension VideoExporter {
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
            overlayLayers.append(VideoWatermark.layer(videoSize: videoSize, videoDuration: build.composition.duration))
        }
        VideoWatermark.attachOverlayTool(to: build.videoComposition, videoSize: videoSize, overlayLayers: overlayLayers)

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
}
