//
//  RallyClipExporter.swift
//  BumpSetCut
//
//  Exports one rally — a time range of a source file — to a standalone .mp4
//  in the temporary directory for community posting. Always re-encodes,
//  capped at 1080p-class: the feed is watched on phones and Mux transcodes
//  on arrival, so a 4K passthrough only made the upload four to six times
//  larger for nothing. Watermarks the free tier.
//

import AVFoundation
import Foundation

struct RallyClipExporter {

    /// Long edge of a posted clip. 1920 keeps 1080p sources untouched and
    /// brings 4K down to the same size.
    static let postMaxLongEdge: CGFloat = 1920

    /// Export `timeRange` of `url` (the whole file when nil), burning in
    /// `crop` when one is set.
    func export(
        url: URL,
        timeRange: CMTimeRange?,
        crop: ShareCrop? = nil,
        addWatermark: Bool,
        fileTag: String = "rally"
    ) async throws -> URL {
        let clip: VideoExporter.StitchClip
        if let crop, !crop.isIdentity {
            clip = VideoExporter.StitchClip(url: url, timeRange: timeRange, crop: crop)
        } else {
            clip = VideoExporter.StitchClip(url: url, timeRange: timeRange)
        }
        return try await VideoExporter().exportStitchedClips(
            [clip], addWatermark: addWatermark, maxLongEdge: Self.postMaxLongEdge
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
