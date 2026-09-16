//
//  RallySpaceSaver.swift
//  BumpSetCut
//
//  "Free Up Space": replace a processed video's file with a rallies-only
//  version — the dead time between rallies is removed and every rally
//  segment is remapped onto the new, shorter timeline. The library keeps ONE
//  source video plus segment metadata (the architecture is unchanged); the
//  rally player, trims, favorites, scoring and timeline editor keep working
//  because indices and segment ids are preserved.
//
//  Each kept range includes 3s of headroom beyond the padded rally bounds so
//  the trim feature's ±3s extensions still have footage to reach into.
//

import AVFoundation
import Foundation

enum RallySpaceSaver {

    /// Extra footage kept around each rally so trim extensions still work.
    static let headroomSec = 3.0
    /// Don't offer the action for token savings.
    static let minSavedSeconds = 20.0
    static let minSavedFraction = 0.10

    struct Estimate {
        let keepRanges: [CMTimeRange]
        let totalSeconds: Double
        let savedSeconds: Double
        let savedBytes: Int64
    }

    enum SpaceSaverError: LocalizedError {
        case noMetadata
        case nothingToSave
        case replaceFailed

        var errorDescription: String? {
            switch self {
            case .noMetadata: return "This video hasn't been processed yet."
            case .nothingToSave: return "There isn't enough dead time between rallies to make trimming worthwhile."
            case .replaceFailed: return "The trimmed video couldn't be installed. The original is untouched."
            }
        }
    }

    /// What trimming would save. Nil when the video has no rallies or the
    /// savings are too small to bother.
    @MainActor
    static func estimate(for video: VideoMetadata, metadataStore: MetadataStore) async -> Estimate? {
        let videoId = video.originalVideoId ?? video.id
        guard let metadata = try? metadataStore.loadMetadata(for: videoId),
              !metadata.rallySegments.isEmpty else { return nil }

        let asset = AVURLAsset(url: video.originalURL)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds > 0 else { return nil }

        let ranges = mergedKeepRanges(segments: metadata.rallySegments, totalSeconds: totalSeconds)
        let keptSeconds = ranges.reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
        let savedSeconds = totalSeconds - keptSeconds
        guard savedSeconds >= minSavedSeconds, savedSeconds / totalSeconds >= minSavedFraction else {
            return nil
        }

        let savedBytes = Int64(Double(video.fileSize) * savedSeconds / totalSeconds)
        return Estimate(keepRanges: ranges, totalSeconds: totalSeconds,
                        savedSeconds: savedSeconds, savedBytes: savedBytes)
    }

    /// Perform the trim: export the kept ranges (passthrough where possible),
    /// remap rally segments and evidence onto the new timeline, and replace
    /// the original file. Returns the bytes actually freed.
    @MainActor
    static func trim(
        video: VideoMetadata,
        estimate: Estimate,
        mediaStore: MediaStore,
        metadataStore: MetadataStore,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Int64 {
        let videoId = video.originalVideoId ?? video.id
        guard let metadata = try? metadataStore.loadMetadata(for: videoId) else {
            throw SpaceSaverError.noMetadata
        }

        let oldSize = StorageChecker.getFileSize(at: video.originalURL)
        let fileType: AVFileType = video.fileName.lowercased().hasSuffix(".mov") ? .mov : .mp4
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacesaver_\(UUID().uuidString).\(video.fileName.lowercased().hasSuffix(".mov") ? "mov" : "mp4")")

        let exported = try await VideoExporter().exportKeepRanges(
            from: video.originalURL,
            ranges: estimate.keepRanges,
            to: tempURL,
            fileType: fileType,
            progressHandler: progressHandler
        )

        // Remap rally segments onto the trimmed timeline, preserving ids so
        // the timeline editor and thumbnails stay coherent. Sidecars are
        // index-keyed and order is preserved, so they remain valid untouched.
        let remapped = remapSegments(metadata.rallySegments, keepRanges: estimate.keepRanges)
        guard remapped.count == metadata.rallySegments.count else {
            try? FileManager.default.removeItem(at: exported)
            throw SpaceSaverError.nothingToSave
        }

        guard mediaStore.replaceVideoFile(id: video.id, withFileAt: exported) else {
            try? FileManager.default.removeItem(at: exported)
            throw SpaceSaverError.replaceFailed
        }

        try metadataStore.saveMetadata(metadata.withRallySegments(remapped))
        remapEvidence(for: videoId, keepRanges: estimate.keepRanges, metadataStore: metadataStore)
        // Any in-flight processing checkpoint referenced the old timeline.
        ProcessingCheckpoint.delete(at: metadataStore.processingCheckpointFileURL(for: videoId))

        let newSize = StorageChecker.getFileSize(at: video.originalURL)
        return max(0, oldSize - newSize)
    }

    // MARK: - Range math

    /// Padded rally bounds + headroom, clamped and merged into disjoint
    /// ascending ranges.
    static func mergedKeepRanges(segments: [RallySegment], totalSeconds: Double) -> [CMTimeRange] {
        let padded: [(Double, Double)] = segments
            .map { (max(0, $0.startTime - headroomSec), min(totalSeconds, $0.endTime + headroomSec)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }

        var merged: [(Double, Double)] = []
        for range in padded {
            if let last = merged.last, range.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, range.1)
            } else {
                merged.append(range)
            }
        }
        return merged.map {
            CMTimeRange(
                start: CMTime(seconds: $0.0, preferredTimescale: 600),
                end: CMTime(seconds: $0.1, preferredTimescale: 600)
            )
        }
    }

    /// Map each segment's times into the concatenated timeline of the kept
    /// ranges. Segments outside every range are dropped (shouldn't happen —
    /// the ranges are built from them).
    static func remapSegments(_ segments: [RallySegment], keepRanges: [CMTimeRange]) -> [RallySegment] {
        var remapped: [RallySegment] = []
        for segment in segments {
            guard let (offset, range) = offsetAndRange(containing: segment.startTime, keepRanges: keepRanges) else {
                continue
            }
            let rangeStart = CMTimeGetSeconds(range.start)
            let newStart = offset + (segment.startTime - rangeStart)
            let newEnd = offset + (min(segment.endTime, CMTimeGetSeconds(range.end)) - rangeStart)
            remapped.append(RallySegment(
                id: segment.id,
                startTimeSeconds: newStart,
                endTimeSeconds: newEnd,
                confidence: segment.confidence,
                quality: segment.quality,
                detectionCount: segment.detectionCount,
                averageTrajectoryLength: segment.averageTrajectoryLength,
                ballSizeTrend: segment.ballSizeTrend,
                isManual: segment.isManual
            ))
        }
        return remapped
    }

    /// Cumulative new-timeline offset of the kept range containing `time`.
    private static func offsetAndRange(containing time: Double, keepRanges: [CMTimeRange]) -> (Double, CMTimeRange)? {
        var offset = 0.0
        for range in keepRanges {
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(range.end)
            if time >= start - 0.001 && time <= end + 0.001 {
                return (offset, range)
            }
            offset += end - start
        }
        return nil
    }

    /// Shift flywheel evidence timestamps onto the new timeline; entries in
    /// removed dead time are dropped with it.
    @MainActor
    private static func remapEvidence(for videoId: UUID, keepRanges: [CMTimeRange], metadataStore: MetadataStore) {
        let evidence = metadataStore.loadFrameEvidence(for: videoId)
        guard !evidence.isEmpty else { return }
        let remapped: [StoredFrameEvidence] = evidence.compactMap { entry in
            guard let (offset, range) = offsetAndRange(containing: entry.time, keepRanges: keepRanges) else {
                return nil
            }
            return StoredFrameEvidence(
                time: offset + (entry.time - CMTimeGetSeconds(range.start)),
                hasBall: entry.hasBall,
                isProjectile: entry.isProjectile,
                detections: entry.detections,
                trackX: entry.trackX,
                trackY: entry.trackY,
                rSquared: entry.rSquared,
                gravitySignature: entry.gravitySignature,
                movementType: entry.movementType,
                rejectionReason: entry.rejectionReason
            )
        }
        try? metadataStore.saveFrameEvidence(remapped, for: videoId)
    }
}
