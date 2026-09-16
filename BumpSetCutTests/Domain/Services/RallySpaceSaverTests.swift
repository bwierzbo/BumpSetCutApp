//
//  RallySpaceSaverTests.swift
//  BumpSetCutTests
//
//  Free Up Space: keep-range math, segment remapping, and an end-to-end
//  trim that replaces a real file and remaps its metadata.
//

import XCTest
import AVFoundation
import CoreMedia
@testable import BumpSetCut

@MainActor
final class RallySpaceSaverTests: XCTestCase {

    private func seconds(_ range: CMTimeRange) -> (Double, Double) {
        (CMTimeGetSeconds(range.start), CMTimeGetSeconds(range.end))
    }

    private func makeSegment(_ start: Double, _ end: Double) -> RallySegment {
        RallySegment(
            startTime: CMTime(seconds: start, preferredTimescale: 600),
            endTime: CMTime(seconds: end, preferredTimescale: 600),
            confidence: 0.9, quality: 0.9, detectionCount: 10, averageTrajectoryLength: 5
        )
    }

    // MARK: - Range math

    func testKeepRangesAddHeadroomClampAndMerge() {
        // First three rallies chain via overlapping headroom windows
        // ((0,7)+(6,15)+(10,19) → one range); the last stands alone.
        let ranges = RallySpaceSaver.mergedKeepRanges(
            segments: [makeSegment(1, 4), makeSegment(9, 12), makeSegment(13, 16), makeSegment(50, 55)],
            totalSeconds: 56
        )

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(seconds(ranges[0]).0, 0, accuracy: 0.01, "Headroom clamps at the file start")
        XCTAssertEqual(seconds(ranges[0]).1, 19, accuracy: 0.01, "Overlapping headroom windows merge")
        XCTAssertEqual(seconds(ranges[1]).0, 47, accuracy: 0.01)
        XCTAssertEqual(seconds(ranges[1]).1, 56, accuracy: 0.01, "Headroom clamps at the file end")
    }

    func testRemapSegmentsOntoConcatenatedTimeline() {
        let segments = [makeSegment(5, 8), makeSegment(40, 44)]
        let keepRanges = RallySpaceSaver.mergedKeepRanges(segments: segments, totalSeconds: 60)
        // [2, 11] and [37, 47]

        let remapped = RallySpaceSaver.remapSegments(segments, keepRanges: keepRanges)

        XCTAssertEqual(remapped.count, 2)
        XCTAssertEqual(remapped[0].startTime, 3, accuracy: 0.01)   // 5 - 2
        XCTAssertEqual(remapped[0].endTime, 6, accuracy: 0.01)
        XCTAssertEqual(remapped[1].startTime, 12, accuracy: 0.01)  // 9 + (40 - 37)
        XCTAssertEqual(remapped[1].endTime, 16, accuracy: 0.01)
        XCTAssertEqual(remapped[0].id, segments[0].id, "Segment ids survive the remap")
        XCTAssertEqual(remapped[1].id, segments[1].id)
    }

    // MARK: - End-to-end trim

    func testTrimReplacesFileAndRemapsMetadata() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceSaver_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = tempDirectory
        defer {
            StorageManager.storageDirectoryOverride = nil
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        // A real 60s video registered in the library
        let videoURL = tempDirectory.appendingPathComponent("game.mp4")
        try TestVideoFactory.writeVideo(to: videoURL, duration: 60, size: CGSize(width: 160, height: 120), fps: 5)
        let mediaStore = MediaStore()
        XCTAssertTrue(mediaStore.addVideo(at: videoURL))
        let video = try XCTUnwrap(mediaStore.getAllVideos().first { $0.fileName == "game.mp4" })

        // Two rallies with lots of dead time between them
        let metadataStore = MetadataStore()
        let segments = [makeSegment(5, 8), makeSegment(40, 44)]
        try metadataStore.saveMetadata(ProcessingMetadata(
            videoId: video.id,
            processingConfig: ProcessorConfig(),
            rallySegments: segments,
            processingStats: ProcessingStats(
                totalFrames: 300, processedFrames: 300, detectionFrames: 100,
                trackingFrames: 80, rallyFrames: 40, physicsValidFrames: 30,
                totalDetections: 200, validTrajectories: 5,
                averageDetectionsPerFrame: 0.7, averageConfidence: 0.8,
                processingDuration: 10, framesPerSecond: 5
            ),
            qualityMetrics: QualityMetrics(
                overallQuality: 0.8, averageRSquared: 0.8, trajectoryConsistency: 0.8,
                physicsValidationRate: 0.8, movementClassificationAccuracy: 0.8,
                confidenceDistribution: ConfidenceDistribution(high: 10, medium: 5, low: 2),
                qualityBreakdown: QualityBreakdown(
                    velocityConsistency: 0.8, accelerationPattern: 0.8,
                    smoothnessScore: 0.8, verticalMotionScore: 0.8, overallCoherence: 0.8
                )
            ),
            performanceMetrics: PerformanceData(
                processingStartTime: Date().addingTimeInterval(-10), processingEndTime: Date(),
                averageFPS: 5, peakMemoryUsageMB: 100, averageMemoryUsageMB: 80,
                cpuUsagePercent: 10, processingOverheadPercent: 1, detectionLatencyMs: 5
            )
        ))

        let oldSize = StorageChecker.getFileSize(at: video.originalURL)

        let maybeEstimate = await RallySpaceSaver.estimate(for: video, metadataStore: metadataStore)
        let estimate = try XCTUnwrap(maybeEstimate)
        XCTAssertEqual(estimate.savedSeconds, 41, accuracy: 1.0)

        let freed = try await RallySpaceSaver.trim(
            video: video, estimate: estimate,
            mediaStore: mediaStore, metadataStore: metadataStore
        )

        // File replaced with a shorter one at the SAME location
        XCTAssertGreaterThan(freed, 0)
        let newSize = StorageChecker.getFileSize(at: video.originalURL)
        XCTAssertLessThan(newSize, oldSize)
        let newDuration = try await CMTimeGetSeconds(AVURLAsset(url: video.originalURL).load(.duration))
        XCTAssertEqual(newDuration, 19, accuracy: 1.0, "Only the kept ranges remain")

        // Metadata remapped onto the new timeline, ids preserved
        let remapped = try XCTUnwrap(try? metadataStore.loadMetadata(for: video.id))
        XCTAssertEqual(remapped.rallySegments.count, 2)
        XCTAssertEqual(remapped.rallySegments[0].startTime, 3, accuracy: 0.2)
        XCTAssertEqual(remapped.rallySegments[1].startTime, 12, accuracy: 0.2)
        XCTAssertEqual(remapped.rallySegments[0].id, segments[0].id)
        XCTAssertLessThan(remapped.rallySegments[1].endTime, newDuration + 0.2,
                          "Every rally must fit inside the trimmed file")
    }
}
