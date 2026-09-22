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
            // Composition space is bottom-left origin — flip the preview's Y pan.
            return try await VideoExporter().exportStitchedClips(
                [VideoExporter.StitchClip(
                    url: url,
                    timeRange: range,
                    zoom: crop.zoom,
                    panX: crop.offsetXNorm,
                    panY: -crop.offsetYNorm
                )],
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
