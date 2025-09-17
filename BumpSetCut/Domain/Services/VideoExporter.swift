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
    func exportRallySegments(asset: AVAsset, rallies: [RallySegment]) async throws -> [URL] {
        var exportedURLs: [URL] = []

        for (index, rally) in rallies.enumerated() {
            let startTime = CMTime(seconds: rally.startTime, preferredTimescale: 600)
            let endTime = CMTime(seconds: rally.endTime, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: startTime, end: endTime)
            let url = try await exportSingleRally(asset: asset, timeRange: timeRange, rallyIndex: index)
            exportedURLs.append(url)
        }

        return exportedURLs
    }

    /// Exports a single rally segment as an individual video file
    private func exportSingleRally(asset: AVAsset, timeRange: CMTimeRange, rallyIndex: Int) async throws -> URL {
        let outURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rally_\(rallyIndex)_\(UUID().uuidString).mp4")

        let comp = AVMutableComposition()
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.exportFailed
        }
        let aTrack = try? await asset.loadTracks(withMediaType: .audio).first

        let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let compA = aTrack != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        // Insert the single rally time range
        try compV.insertTimeRange(timeRange, of: vTrack, at: .zero)
        if let srcA = aTrack, let dstA = compA {
            try dstA.insertTimeRange(timeRange, of: srcA, at: .zero)
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

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously {
                    cont.resume()
                }
            }

            if exporter.status == .failed {
                throw exporter.error ?? ProcessingError.exportFailed
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

    // MARK: - Photo Library Export

    /// Export a single rally segment to the photo library
    func exportRallyToPhotoLibrary(asset: AVAsset, rally: RallySegment, index: Int) async throws {
        // Create time range from rally segment
        let startTime = CMTime(seconds: rally.startTime, preferredTimescale: 600)
        let endTime = CMTime(seconds: rally.endTime, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        // Export rally segment to temporary file
        let exportedURL = try await exportSingleRally(asset: asset, timeRange: timeRange, rallyIndex: index)

        // Save to photo library
        try await saveVideoToPhotoLibrary(url: exportedURL)

        // Cleanup temporary file
        try? FileManager.default.removeItem(at: exportedURL)
    }

    /// Export multiple rally segments stitched together to the photo library
    func exportStitchedRalliesToPhotoLibrary(asset: AVAsset, rallies: [RallySegment]) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stitched_rallies_\(UUID().uuidString).mp4")

        // Create stitched video
        let exportedURL = try await createStitchedVideo(
            asset: asset,
            rallies: rallies,
            outputURL: tempURL
        )

        // Save to photo library
        try await saveVideoToPhotoLibrary(url: exportedURL)

        // Cleanup temporary file
        try? FileManager.default.removeItem(at: exportedURL)
    }

    // MARK: - Private Helpers

    private func saveVideoToPhotoLibrary(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    private func createStitchedVideo(asset: AVAsset, rallies: [RallySegment], outputURL: URL) async throws -> URL {
        let composition = AVMutableComposition()

        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first,
              let aTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ProcessingError.exportFailed
        }

        let compV = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let compA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var currentTime = CMTime.zero

        // Add each rally segment to the composition
        for rally in rallies {
            let startTime = CMTime(seconds: rally.startTime, preferredTimescale: 600)
            let endTime = CMTime(seconds: rally.endTime, preferredTimescale: 600)
            let duration = CMTimeSubtract(endTime, startTime)

            let timeRange = CMTimeRange(start: startTime, duration: duration)

            try compV?.insertTimeRange(timeRange, of: vTrack, at: currentTime)
            try compA?.insertTimeRange(timeRange, of: aTrack, at: currentTime)

            currentTime = CMTimeAdd(currentTime, duration)
        }

        // Keep orientation
        if let pref = try? await vTrack.load(.preferredTransform) {
            compV?.preferredTransform = pref
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProcessingError.exportFailed
        }

        if #available(iOS 18.0, *) {
            try await exporter.export(to: outputURL, as: .mp4)
            return outputURL
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = .mp4
            exporter.shouldOptimizeForNetworkUse = true
            exporter.exportAsynchronously(completionHandler: {})

            while exporter.status == .exporting {
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            switch exporter.status {
            case .completed:
                return outputURL
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
