//
//  ProcessingCheckpointTests.swift
//  BumpSetCutTests
//
//  Resumable processing: checkpoint coding, config-hash guards, validity
//  rules, evidence round-trip, and the segment-builder seeding equivalence
//  the resume path depends on.
//

import XCTest
import CoreMedia
@testable import BumpSetCut

final class ProcessingCheckpointTests: XCTestCase {

    private func makeCheckpoint(resumeTime: Double = 120, videoId: UUID = UUID()) -> ProcessingCheckpoint {
        ProcessingCheckpoint(
            videoId: videoId,
            configHash: ProcessingCheckpoint.hash(of: ProcessorConfig()),
            videoDurationSec: 600,
            collectEvidence: true,
            resumeTime: resumeTime,
            rawSegments: [.init(start: 10, end: 22), .init(start: 45, end: 61)],
            ballHeights: [.init(t: 10.5, y: 0.8), .init(t: 11.0, y: 0.6)],
            ballSizes: [.init(t: 10.5, area: 0.0012)],
            evidence: [],
            physics: [.init(t: 11.2, isValid: true, rSquared: 0.91, confidenceLevel: 0.8)],
            trajectorySpans: [.init(start: 10.4, end: 12.1)],
            counters: .init(
                rawFrameIndex: 3600, skippedFrames: 2400, frameCount: 1200,
                totalDetections: 900, detectionFrameCount: 800, trackingFrameCount: 700,
                rallyFrameCount: 300, physicsValidFrameCount: 250,
                confidenceSum: 640.5, rSquaredSum: 210.2, rSquaredCount: 260
            ),
            net: .init(DetectedNet(box: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1), confidence: 0.9)),
            savedAt: Date()
        )
    }

    func testCheckpointRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp_\(UUID().uuidString).json")
        defer { ProcessingCheckpoint.delete(at: url) }

        let original = makeCheckpoint()
        original.write(to: url)

        let loaded = try XCTUnwrap(ProcessingCheckpoint.load(from: url))
        XCTAssertEqual(loaded.videoId, original.videoId)
        XCTAssertEqual(loaded.resumeTime, original.resumeTime)
        XCTAssertEqual(loaded.rawSegments.count, 2)
        XCTAssertEqual(loaded.rawSegments[1].start, 45)
        XCTAssertEqual(loaded.counters.rawFrameIndex, 3600)
        XCTAssertEqual(loaded.physics.first?.rSquared ?? 0, 0.91, accuracy: 0.0001)
        let net = try XCTUnwrap(loaded.net?.detectedNet)
        XCTAssertEqual(net.box.minX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(net.confidence, 0.9, accuracy: 0.0001)

        ProcessingCheckpoint.delete(at: url)
        XCTAssertNil(ProcessingCheckpoint.load(from: url))
    }

    func testConfigHashIsStableAndSensitive() {
        let base = ProcessorConfig()
        XCTAssertEqual(ProcessingCheckpoint.hash(of: base), ProcessingCheckpoint.hash(of: ProcessorConfig()),
                       "Identical configs must hash identically")

        var changed = ProcessorConfig()
        changed.detectionConfidence = base.detectionConfidence + 0.05
        XCTAssertNotEqual(ProcessingCheckpoint.hash(of: base), ProcessingCheckpoint.hash(of: changed),
                          "A tuned config must invalidate old checkpoints")
    }

    func testValidityGuards() {
        let videoId = UUID()
        let hash = ProcessingCheckpoint.hash(of: ProcessorConfig())
        let checkpoint = makeCheckpoint(videoId: videoId)

        XCTAssertTrue(checkpoint.isValid(for: videoId, configHash: hash, durationSec: 600, collectEvidence: true))
        XCTAssertFalse(checkpoint.isValid(for: UUID(), configHash: hash, durationSec: 600, collectEvidence: true),
                       "Different video must not resume")
        XCTAssertFalse(checkpoint.isValid(for: videoId, configHash: "other", durationSec: 600, collectEvidence: true),
                       "Different config must not resume")
        XCTAssertFalse(checkpoint.isValid(for: videoId, configHash: hash, durationSec: 300, collectEvidence: true),
                       "Different source duration must not resume")
        XCTAssertFalse(checkpoint.isValid(for: videoId, configHash: hash, durationSec: 600, collectEvidence: false),
                       "Evidence-collection mismatch must not resume")

        let nearEnd = makeCheckpoint(resumeTime: 599.8, videoId: videoId)
        XCTAssertFalse(nearEnd.isValid(for: videoId, configHash: hash, durationSec: 600, collectEvidence: true),
                       "A checkpoint at the very end has nothing to resume")
    }

    func testEvidenceBackConversionRoundTrips() {
        let evidence = VideoProcessor.FrameEvidence(
            time: 42.5, hasBall: true, isProjectile: true,
            detections: [.init(bbox: CGRect(x: 0.4, y: 0.5, width: 0.02, height: 0.03),
                               confidence: 0.87, isOffCourt: false)],
            trackPoint: CGPoint(x: 0.41, y: 0.52),
            rSquared: 0.93, gravitySignature: 0.7,
            movementType: nil, rejectionReason: nil,
            candidates: [], detectedNet: nil
        )

        let stored = StoredFrameEvidence(evidence)
        let restored = VideoProcessor.FrameEvidence(stored)
        let restoredStored = StoredFrameEvidence(restored)

        // The stored form is what the flywheel uploads — it must survive the
        // restore → re-store cycle exactly.
        XCTAssertEqual(restoredStored.time, stored.time)
        XCTAssertEqual(restoredStored.hasBall, stored.hasBall)
        XCTAssertEqual(restoredStored.detections.count, 1)
        XCTAssertEqual(restoredStored.detections[0].confidence, stored.detections[0].confidence, accuracy: 0.0001)
        XCTAssertEqual(restoredStored.trackX ?? 0, stored.trackX ?? -1, accuracy: 0.0001)
        XCTAssertEqual(restoredStored.rSquared ?? 0, 0.93, accuracy: 0.0001)
    }

    /// End-to-end resume: a seeded checkpoint makes processVideoMetadata start
    /// mid-video, carry the checkpointed rally into the final metadata, and
    /// delete the checkpoint on completion.
    @MainActor
    func testProcessingResumesFromSeededCheckpoint() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckpointResume_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = tempDirectory
        defer {
            StorageManager.storageDirectoryOverride = nil
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let videoURL = tempDirectory.appendingPathComponent("resume.mp4")
        try TestVideoFactory.writeVideo(to: videoURL, duration: 8.0, size: CGSize(width: 160, height: 120), fps: 5)
        let videoId = UUID()

        let processor = VideoProcessor()
        let config = processor.config
        let durationSec = 8.0

        // A prior "interrupted run" left one closed rally and stopped at 6s.
        let checkpointURL = MetadataStore().processingCheckpointFileURL(for: videoId)
        ProcessingCheckpoint(
            videoId: videoId,
            configHash: ProcessingCheckpoint.hash(of: config),
            videoDurationSec: durationSec,
            collectEvidence: false,
            resumeTime: 6.0,
            rawSegments: [.init(start: 1.0, end: 6.0)],
            ballHeights: [], ballSizes: [], evidence: [],
            physics: [.init(t: 2.0, isValid: true, rSquared: 0.9, confidenceLevel: 0.85)],
            trajectorySpans: [.init(start: 1.2, end: 5.5)],
            counters: .init(
                rawFrameIndex: 30, skippedFrames: 10, frameCount: 20,
                totalDetections: 15, detectionFrameCount: 12, trackingFrameCount: 10,
                rallyFrameCount: 8, physicsValidFrameCount: 6,
                confidenceSum: 9.0, rSquaredSum: 5.4, rSquaredCount: 6
            ),
            net: nil,
            savedAt: Date()
        ).write(to: checkpointURL)

        // A synthetic video has no real ball, so the resumed tail detects
        // nothing new — the checkpointed rally alone must carry the run.
        let metadata = try await processor.processVideo(videoURL, videoId: videoId)

        XCTAssertEqual(metadata.rallySegments.count, 1, "The checkpointed rally must survive the resume")
        let rally = try XCTUnwrap(metadata.rallySegments.first)
        XCTAssertEqual(rally.startTime, 1.0, accuracy: 1.0, "Rally start should track the checkpointed raw range (± padding)")
        XCTAssertGreaterThan(rally.endTime, 5.5, "Rally end should reach the checkpointed raw end")
        XCTAssertGreaterThan(rally.confidence, 0, "Restored physics readouts must feed the rally's confidence")

        XCTAssertNil(ProcessingCheckpoint.load(from: checkpointURL),
                     "A completed run must consume its checkpoint")
    }

    /// The resume path seeds a fresh SegmentBuilder with the checkpoint's raw
    /// ranges. That only works if seeding reproduces the original builder's
    /// finalized output exactly — padding must derive deterministically.
    func testSegmentBuilderSeedingReproducesFinalize() {
        let config = ProcessorConfig()
        let t = { (s: Double) in CMTime(seconds: s, preferredTimescale: 600) }

        let original = SegmentBuilder(config: config)
        // Two rallies, closed by idle observations.
        original.observe(isActive: true, at: t(10))
        original.observe(isActive: false, at: t(24))
        original.observe(isActive: true, at: t(60))
        original.observe(isActive: false, at: t(75))

        let rawRanges = original.closedRawRanges
        XCTAssertEqual(rawRanges.count, 2)

        let seeded = SegmentBuilder(config: config)
        for range in rawRanges {
            seeded.appendRaw(start: range.start, end: CMTimeRangeGetEnd(range))
        }

        let duration = t(600)
        let a = original.finalizeWithRaw(until: duration)
        let b = seeded.finalizeWithRaw(until: duration)

        XCTAssertEqual(a.count, b.count)
        for (lhs, rhs) in zip(a, b) {
            XCTAssertEqual(CMTimeGetSeconds(lhs.padded.start), CMTimeGetSeconds(rhs.padded.start), accuracy: 0.001)
            XCTAssertEqual(CMTimeGetSeconds(lhs.padded.end), CMTimeGetSeconds(rhs.padded.end), accuracy: 0.001)
            XCTAssertEqual(CMTimeGetSeconds(lhs.raw.start), CMTimeGetSeconds(rhs.raw.start), accuracy: 0.001)
            XCTAssertEqual(CMTimeGetSeconds(lhs.raw.end), CMTimeGetSeconds(rhs.raw.end), accuracy: 0.001)
        }
    }
}
