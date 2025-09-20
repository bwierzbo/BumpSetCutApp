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
    func exportSingleRally(asset: AVAsset, timeRange: CMTimeRange, rallyIndex: Int) async throws -> URL {
        // Create deterministic filename based on source video and time range for caching
        let sourceURL = (asset as? AVURLAsset)?.url
        let sourceHash = sourceURL?.lastPathComponent.hashValue ?? 0
        let timeHash = "\(timeRange.start.seconds)_\(timeRange.duration.seconds)".hashValue
        let cacheKey = "rally_\(sourceHash)_\(rallyIndex)_\(abs(timeHash))"

        let outURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(cacheKey).mp4")

        // Check if cached rally already exists and is valid
        if FileManager.default.fileExists(atPath: outURL.path) {
            // Validate cache file integrity
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: outURL.path)
                let fileSize = attributes[.size] as? Int ?? 0

                // Basic validation - file should be larger than 1KB for a valid video
                if fileSize > 1024 {
                    // Additional validation - ensure it's a valid video file
                    let asset = AVURLAsset(url: outURL)
                    if await isValidVideoAsset(asset) {
                        print("📁 Using cached rally: \(outURL.lastPathComponent) (\(String(format: "%.1f", Double(fileSize) / 1024 / 1024)) MB)")
                        return outURL
                    } else {
                        print("⚠️ Corrupted cache file detected: \(outURL.lastPathComponent)")
                        try? FileManager.default.removeItem(at: outURL)
                    }
                } else {
                    print("⚠️ Invalid cache file size: \(outURL.lastPathComponent) (\(fileSize) bytes)")
                    try? FileManager.default.removeItem(at: outURL)
                }
            } catch {
                print("⚠️ Cannot validate cache file: \(outURL.lastPathComponent) - \(error)")
                try? FileManager.default.removeItem(at: outURL)
            }
        }

        print("🎬 Creating new rally: \(outURL.lastPathComponent)")

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

    // MARK: - Background Rally Export Support

    /// Export a rally segment with custom output URL for cache management
    func exportRallySegmentToURL(asset: AVAsset, rallySegment: RallySegment, outputURL: URL) async throws -> URL {
        let timeRange = CMTimeRange(
            start: CMTime(seconds: rallySegment.startTime, preferredTimescale: 600),
            end: CMTime(seconds: rallySegment.endTime, preferredTimescale: 600)
        )

        return try await exportRallyToCustomURL(asset: asset, timeRange: timeRange, outputURL: outputURL)
    }

    /// Export rally segment to custom URL with composition
    private func exportRallyToCustomURL(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL) async throws -> URL {
        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

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
            try await exporter.export(to: outputURL, as: .mp4)
            return outputURL
        } else {
            exporter.outputURL = outputURL
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
            return outputURL
        }
    }

    /// Generate a deterministic cache key for a rally segment
    func generateRallyCacheKey(asset: AVAsset, rallyIndex: Int, rallySegment: RallySegment) -> String {
        let sourceURL = (asset as? AVURLAsset)?.url
        let sourceHash = sourceURL?.lastPathComponent.hashValue ?? 0
        let timeHash = "\(rallySegment.startTime)_\(rallySegment.endTime)".hashValue
        return "rally_\(sourceHash)_\(rallyIndex)_\(abs(timeHash))"
    }

    /// Check if a rally segment is already cached
    func isRallyCached(cacheKey: String) -> Bool {
        let outURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(cacheKey).mp4")
        return FileManager.default.fileExists(atPath: outURL.path)
    }

    /// Get cached rally URL
    func getCachedRallyURL(cacheKey: String) -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(cacheKey).mp4")
    }

    // MARK: - Rally Cache Management

    /// Clean up old cached rally files to prevent excessive disk usage
    func cleanupRallyCache(maxAge: TimeInterval = 7 * 24 * 60 * 60) { // 7 days default
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: [.creationDateKey],
                options: []
            )

            let rallyFiles = files.filter { $0.lastPathComponent.hasPrefix("rally_") }
            let cutoffDate = Date().addingTimeInterval(-maxAge)

            for file in rallyFiles {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    if let creationDate = attributes[.creationDate] as? Date,
                       creationDate < cutoffDate {
                        try FileManager.default.removeItem(at: file)
                        print("🗑️ Cleaned up old rally cache: \(file.lastPathComponent)")
                    }
                } catch {
                    print("⚠️ Failed to clean up rally file \(file.lastPathComponent): \(error)")
                }
            }
        } catch {
            print("⚠️ Failed to enumerate rally cache files: \(error)")
        }
    }

    /// Get cache statistics for debugging
    func getCacheInfo() -> (count: Int, totalSize: Int64) {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: []
            )

            let rallyFiles = files.filter { $0.lastPathComponent.hasPrefix("rally_") }
            var totalSize: Int64 = 0

            for file in rallyFiles {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    if let size = attributes[.size] as? Int64 {
                        totalSize += size
                    }
                } catch {
                    print("⚠️ Failed to get size for \(file.lastPathComponent): \(error)")
                }
            }

            return (count: rallyFiles.count, totalSize: totalSize)
        } catch {
            print("⚠️ Failed to get cache info: \(error)")
            return (count: 0, totalSize: 0)
        }
    }

    /// Validate if an asset is a playable video file
    private func isValidVideoAsset(_ asset: AVURLAsset) async -> Bool {
        do {
            // Check if asset is playable
            let isPlayable = try await asset.load(.isPlayable)
            if !isPlayable {
                return false
            }

            // Check if it has video tracks
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if videoTracks.isEmpty {
                return false
            }

            // Check duration - should be greater than 0
            let duration = try await asset.load(.duration)
            if duration == .zero || duration == .indefinite {
                return false
            }

            return true
        } catch {
            print("⚠️ Video validation failed: \(error)")
            return false
        }
    }
}
