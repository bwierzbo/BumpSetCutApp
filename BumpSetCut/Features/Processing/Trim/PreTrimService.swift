//
//  PreTrimService.swift
//  BumpSetCut
//
//  Standalone export service for pre-processing video trimming.
//  Tries passthrough (no re-encoding) first, falls back to composition-based export.
//

import AVFoundation

final class PreTrimService: Sendable {

    /// Export a trimmed portion of the source video.
    /// - Parameters:
    ///   - sourceURL: Original video file URL
    ///   - startTime: Start of the desired region (seconds)
    ///   - endTime: End of the desired region (seconds)
    ///   - rotationDegrees: Rotation to bake into the output (0 = passthrough eligible)
    ///   - progressHandler: Optional callback for export progress (0.0–1.0)
    /// - Returns: Temp URL of the trimmed file
    func exportTrimmedVideo(
        sourceURL: URL,
        startTime: Double,
        endTime: Double,
        rotationDegrees: Double = 0,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let end = CMTime(seconds: endTime, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: start, end: end)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pretrim_\(UUID().uuidString).mp4")

        // Rotation forces the composition path (need a videoComposition to apply transforms)
        if abs(rotationDegrees) < 0.01 {
            // Try passthrough first (fast, no re-encoding)
            if let result = try? await exportPassthrough(asset: asset, timeRange: timeRange, to: outURL, progressHandler: progressHandler) {
                return result
            }
        }

        // Composition path (re-encoded). Applies rotation when non-zero.
        return try await exportWithComposition(
            asset: asset,
            timeRange: timeRange,
            rotationDegrees: rotationDegrees,
            to: outURL,
            progressHandler: progressHandler
        )
    }

    // MARK: - Passthrough Export

    private func exportPassthrough(
        asset: AVAsset,
        timeRange: CMTimeRange,
        to outURL: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw PreTrimError.exportSessionUnavailable
        }

        exporter.timeRange = timeRange

        try await exporter.export(to: outURL, as: .mp4, progress: progressHandler)
        return outURL
    }

    // MARK: - Composition-based Export

    private func exportWithComposition(
        asset: AVAsset,
        timeRange: CMTimeRange,
        rotationDegrees: Double,
        to outURL: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        // Clean up partial file from failed passthrough
        try? FileManager.default.removeItem(at: outURL)

        let comp = AVMutableComposition()
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw PreTrimError.noVideoTrack
        }
        let aTrack = try? await asset.loadTracks(withMediaType: .audio).first

        guard let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PreTrimError.compositionFailed
        }
        let compA = aTrack != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        try compV.insertTimeRange(timeRange, of: vTrack, at: .zero)
        if let srcA = aTrack, let dstA = compA {
            try dstA.insertTimeRange(timeRange, of: srcA, at: .zero)
        }

        // Preserve source orientation on the composition track
        let preferred = (try? await vTrack.load(.preferredTransform)) ?? .identity
        compV.preferredTransform = preferred

        // Build a videoComposition only when we need to bake in a rotation.
        // Without one, the exporter honors the track's preferredTransform directly.
        var videoComposition: AVMutableVideoComposition?
        if abs(rotationDegrees) >= 0.01 {
            let naturalSize = try await vTrack.load(.naturalSize)
            // Render size = the upright (post-preferredTransform) frame size
            let renderSize = RotationGeometry.uprightSize(naturalSize: naturalSize, preferredTransform: preferred)

            let radians = CGFloat(rotationDegrees * .pi / 180.0)
            let scale = RotationGeometry.coverScale(angleDegrees: rotationDegrees, size: renderSize)
            let center = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)

            // Honor source orientation first (`preferred`), then rotate+scale around the
            // upright render-frame center. CGAffineTransform builder post-multiplies, so the
            // sequence below produces: preferred * T(-c) * R * S * T(+c).
            let layerTransform = preferred
                .translatedBy(x: -center.x, y: -center.y)
                .rotated(by: radians)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: center.x, y: center.y)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compV)
            layerInstruction.setTransform(layerTransform, at: .zero)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            instruction.layerInstructions = [layerInstruction]

            let vc = AVMutableVideoComposition()
            vc.renderSize = renderSize
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            vc.instructions = [instruction]
            videoComposition = vc
        }

        guard let exporter = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw PreTrimError.exportSessionUnavailable
        }
        exporter.videoComposition = videoComposition

        try await exporter.export(to: outURL, as: .mp4, progress: progressHandler)
        return outURL
    }
}

// MARK: - Errors

enum PreTrimError: LocalizedError {
    case exportSessionUnavailable
    case noVideoTrack
    case compositionFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .exportSessionUnavailable: return "Export session unavailable"
        case .noVideoTrack: return "No video track found"
        case .compositionFailed: return "Failed to create composition"
        case .exportFailed(let msg): return msg
        }
    }
}
