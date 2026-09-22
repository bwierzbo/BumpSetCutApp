//
//  RallyClipExporter.swift
//  BumpSetCut
//
//  Exports one rally — a time range of a source file — to a standalone .mp4
//  in the temporary directory. Shared by community posting (which watermarks
//  on the free tier) and private sending to a friend (which never does:
//  a 1:1 message isn't distribution, and the recipient can't save or
//  re-share it).
//

import AVFoundation
import Foundation

struct RallyClipExporter {

    /// Export `timeRange` of `url` (the whole file when nil), applying `crop`
    /// when one is set. Passthrough when nothing needs re-encoding; a crop or
    /// watermark forces the composition path.
    func export(
        url: URL,
        timeRange: CMTimeRange?,
        crop: ShareCrop? = nil,
        addWatermark: Bool,
        fileTag: String = "rally"
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let range: CMTimeRange
        if let timeRange {
            range = timeRange
        } else {
            range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        }

        if let crop, !crop.isIdentity {
            return try await VideoExporter().exportStitchedClips(
                [VideoExporter.StitchClip(url: url, timeRange: range, crop: crop)],
                addWatermark: addWatermark
            )
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(fileTag)_\(UUID().uuidString).mp4")
        return try await VideoExporter().exportClip(
            asset: asset,
            timeRange: range,
            to: outURL,
            addWatermark: addWatermark
        )
    }
}

extension VideoExporter.StitchClip {
    /// A clip framed the way the screen showed it. Layer-instruction
    /// transforms run in the same +Y-down, clockwise space as SwiftUI —
    /// VideoExporterFramingTests pins this with rendered pixels, after an
    /// earlier "bottom-left origin" flip here had been inverting vertical
    /// pans. Pan fractions carry over directly: on screen they are relative
    /// to the rendered video rect, in the composition to the render size —
    /// the same rectangle.
    init(url: URL, timeRange: CMTimeRange?, crop: ShareCrop) {
        self.init(
            url: url,
            timeRange: timeRange,
            rotationDegrees: crop.rotation,
            zoom: crop.zoom,
            panX: crop.offsetXNorm,
            panY: crop.offsetYNorm
        )
    }
}
