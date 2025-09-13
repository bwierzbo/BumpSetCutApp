//
//  VideoExporter.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import AVFoundation

final class VideoExporter {

    /// Exports a composition of keep ranges from the source asset, preserving orientation and audio.
    func exportTrimmed(asset: AVAsset, keepRanges: [CMTimeRange]) async throws -> URL {
        let outURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("auto_cut_\(UUID().uuidString).mp4")

        let comp = AVMutableComposition()
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.exportFailed
        }
        let aTrack = try? await asset.loadTracks(withMediaType: .audio).first

        let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
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
            throw ProcessingError.exportFailed
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
                    throw ProcessingError.exportFailed
                }
                return outURL
            case .failed:
                throw exporter.error ?? ProcessingError.exportFailed
            case .cancelled:
                throw ProcessingError.exportCancelled
            default:
                throw ProcessingError.exportFailed
            }
        }
    }
}
