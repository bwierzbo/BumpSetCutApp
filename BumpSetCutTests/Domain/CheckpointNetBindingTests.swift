//
//  CheckpointNetBindingTests.swift
//  BumpSetCutTests
//
//  A run interrupted and started again resumes from its checkpoint only when the net is the
//  one the checkpoint was written with. A net confirmed, corrected or withdrawn in between
//  starts the run again from the first frame: what the checkpoint holds was decided
//  against the other net.
//

import AVFoundation
import XCTest
@testable import BumpSetCut

@MainActor
final class CheckpointNetBindingTests: XCTestCase {
    private var dir: URL!
    private var video: URL!
    private let videoId = UUID()
    private let resumeTime = 2.0
    private let net = DetectedNet(box: CGRect(x: 0.24, y: 0.49, width: 0.52, height: 0.12), confidence: 1)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CheckpointNetBindingTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = dir
        video = try TestVideoFactory.writeVideo(to: dir.appendingPathComponent("clip.mp4"), duration: 4.5, size: CGSize(width: 320, height: 180))
    }

    override func tearDownWithError() throws {
        StorageManager.storageDirectoryOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// Leaves a checkpoint at 2 s, written with writtenWith as its net, then runs with source. Returns how many
    /// frames the run looked at before the checkpoint's resume point: none when it resumed.
    private func framesBeforeResumePoint(checkpointNet writtenWith: (DetectedNet, String)?, runWith source: FixedNetSource) async throws -> Int {
        let processor = VideoProcessor()
        processor.collectFrameEvidence = true
        processor.netSource = source
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: video).load(.duration))
        let url = MetadataStore.shared.processingCheckpointFileURL(for: videoId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        ProcessingCheckpoint(
            videoId: videoId, configHash: ProcessingCheckpoint.hash(of: processor.config), videoDurationSec: duration,
            collectEvidence: true, resumeTime: resumeTime, rawSegments: [], ballHeights: [], ballSizes: [], evidence: [],
            physics: [], trajectorySpans: [],
            counters: .init(rawFrameIndex: 60, skippedFrames: 0, frameCount: 60, totalDetections: 0, detectionFrameCount: 0,
                            trackingFrameCount: 0, rallyFrameCount: 0, physicsValidFrameCount: 0, confidenceSum: 0,
                            rSquaredSum: 0, rSquaredCount: 0),
            net: writtenWith.map { .init($0.0, origin: $0.1) }, savedAt: Date()
        ).write(to: url)
        XCTAssertNotNil(ProcessingCheckpoint.load(from: url), "the checkpoint is in place")
        do { _ = try await processor.processVideo(video, videoId: videoId) } catch ProcessingError.noRalliesDetected {}
        XCTAssertEqual(source.asked, 1, "the net is asked for on a resume too")
        return processor.frameEvidence.filter { $0.time < resumeTime - 0.2 }.count
    }

    func testTheSameNetResumes() async throws {
        let before = try await framesBeforeResumePoint(checkpointNet: (net, NetGeometry.personConfirmed), runWith: FixedNetSource(.confirmed(net)))
        XCTAssertEqual(before, 0)
    }

    func testNoNetThenAndNowResumes() async throws {
        let before = try await framesBeforeResumePoint(checkpointNet: nil, runWith: FixedNetSource(.unavailable(reason: "the net is not confirmed")))
        XCTAssertEqual(before, 0)
    }

    func testACorrectedNetStartsAgainFromTheFirstFrame() async throws {
        let corrected = DetectedNet(box: net.box.offsetBy(dx: 0, dy: 0.05), confidence: 1)
        let before = try await framesBeforeResumePoint(checkpointNet: (net, NetGeometry.personConfirmed), runWith: FixedNetSource(.confirmed(corrected)))
        XCTAssertGreaterThan(before, 20)
    }

    func testANetConfirmedSinceStartsAgain() async throws {
        let before = try await framesBeforeResumePoint(checkpointNet: nil, runWith: FixedNetSource(.confirmed(net)))
        XCTAssertGreaterThan(before, 20)
    }

    func testANetWithdrawnSinceStartsAgain() async throws {
        let before = try await framesBeforeResumePoint(checkpointNet: (net, NetGeometry.personConfirmed),
                                                       runWith: FixedNetSource(.unavailable(reason: "the calibration is for another version of the video")))
        XCTAssertGreaterThan(before, 20)
    }
}
