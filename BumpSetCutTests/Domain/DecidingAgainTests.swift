//
//  DecidingAgainTests.swift
//  BumpSetCutTests
//
//  Deciding a video's rallies again from the balls an earlier run found (D-044): the saved frames give
//  rallies without the video being read, the answer is saved as a run's is and is the same every time, a net
//  that was not there before changes it, a person's own segments stay, and balls found in another file or
//  under the other frame rotation are refused with nothing changed.
//

import AVFoundation
import XCTest
@testable import BumpSetCut

@MainActor
final class DecidingAgainTests: XCTestCase {
    private var dir: URL!
    private var video: URL!
    private let videoId = UUID()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DecidingAgainTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = dir
        video = try TestVideoFactory.writeVideo(to: dir.appendingPathComponent("clip.mp4"), duration: 14, size: CGSize(width: 160, height: 90))
    }

    override func tearDownWithError() throws {
        StorageManager.storageDirectoryOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// Thirty frames a second for 14 s. From 1 s to 9 s one ball goes over the middle of the frame and back in
    /// one-second arcs; before and after there is none. No model found these: they are written here.
    private func savedBalls(of file: URL? = nil, upright: Bool = ProcessorConfig().applyVideoRotation) -> BallDetectionLog {
        let frames: [BallDetectionLog.Frame] = (0..<420).map { i in
            let t = Double(i) / 30
            guard t >= 1, t < 9 else { return .init(time: CMTime(value: Int64(i) * 20, timescale: 600), detections: [], singleFrameCount: 0) }
            let arc = Int(t - 1), u = (t - 1) - Double(arc)
            let across = arc % 2 == 0 ? u : 1 - u
            let box = CGRect(x: 0.3 + 0.4 * across - 0.015, y: 0.45 + 1.4 * u * (1 - u) - 0.015, width: 0.03, height: 0.03)
            return .init(time: CMTime(value: Int64(i) * 20, timescale: 600), detections: [.init(bbox: box, confidence: 0.9)], singleFrameCount: 0)
        }
        return BallDetectionLog(header: .init(sourceFingerprint: FileFingerprint.read(atPath: (file ?? video).path), durationSec: 14, upright: upright,
                                              finder: "written by the test", decodedFrameCount: 840, skippedFrameCount: 420, resumedAtSec: []),
                                frames: frames)
    }

    private func processor(net: NetGeometry = .unavailable(reason: "none marked")) -> VideoProcessor {
        let processor = VideoProcessor()
        processor.netSource = FixedNetSource(net)
        processor.collectFrameEvidence = true
        return processor
    }

    private func spans(_ metadata: ProcessingMetadata) -> [String] {
        metadata.rallySegments.map { String(format: "%.3f…%.3f", $0.startTime, $0.endTime) }
    }

    func testTheSavedBallsGiveTheRalliesAndTheAnswerIsSavedAsARunsIs() async throws {
        let log = savedBalls()
        let logFile = MetadataStore.shared.ballDetectionsFileURL(for: videoId)
        XCTAssertTrue(log.write(to: logFile))
        let bytes = try Data(contentsOf: logFile)

        let processor = processor()
        let metadata = try await processor.decideRalliesAgain(from: log, forVideoAt: video, videoId: videoId)
        print("DecidingAgainTests: rallies \(spans(metadata))")
        XCTAssertEqual(metadata.rallySegments.count, 1, "\(spans(metadata))")
        let rally = try XCTUnwrap(metadata.rallySegments.first)
        XCTAssertLessThan(rally.startTime, 2.5)
        XCTAssertGreaterThan(rally.endTime, 8.5)
        XCTAssertLessThan(rally.endTime, 13)

        XCTAssertEqual(spans(try MetadataStore.shared.loadMetadata(for: videoId)), spans(metadata), "saved where a run's answer is")
        XCTAssertEqual(metadata.processingStats.totalFrames, 840, "the run's own count of decoded frames")
        XCTAssertEqual(metadata.processingStats.processedFrames, 420)
        XCTAssertEqual(processor.frameEvidence.count, 420, "every saved frame was decided")
        XCTAssertEqual(metadata.spatialChecks?.underNetRejection, .noNetGeometry)
        XCTAssertFalse(processor.isProcessing)
        XCTAssertEqual(processor.progress, 1)
        XCTAssertEqual(try Data(contentsOf: logFile), bytes, "the saved balls are left as they were")
    }

    func testTheSameBallsGiveTheSameAnswerEveryTime() async throws {
        let first = try await processor().decideRalliesAgain(from: savedBalls(), forVideoAt: video, videoId: videoId, persist: false)
        let second = try await processor().decideRalliesAgain(from: savedBalls(), forVideoAt: video, videoId: videoId, persist: false)
        XCTAssertEqual(spans(first), spans(second))
        XCTAssertEqual(first.processingStats.totalDetections, second.processingStats.totalDetections)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MetadataStore.shared.metadataDirectory.appendingPathComponent("\(videoId.uuidString).json").path))
    }

    func testANetMarkedSinceChangesTheAnswerAndAnAnswerOfNoRalliesLeavesTheSavedOneAlone() async throws {
        let before = try await processor().decideRalliesAgain(from: savedBalls(), forVideoAt: video, videoId: videoId)

        // A net over the ball's whole path: the rules that need one now run, and say so.
        let over = DetectedNet(box: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.08), confidence: 1)
        let withNet = processor(net: .confirmed(over))
        let after = try await withNet.decideRalliesAgain(from: savedBalls(), forVideoAt: video, videoId: videoId, persist: false)
        XCTAssertEqual(after.spatialChecks?.underNetRejection, .ran)
        XCTAssertEqual(after.netCenterX ?? 0, 0.5, accuracy: 0.001)
        XCTAssertTrue(withNet.frameEvidence.allSatisfy { $0.detectedNet?.box == over.box })

        // A net far to one side: every ball is off its court, so there is no rally — and the saved answer stays.
        let aside = DetectedNet(box: CGRect(x: 0.85, y: 0.4, width: 0.1, height: 0.08), confidence: 1)
        let offCourt = processor(net: .confirmed(aside))
        do {
            _ = try await offCourt.decideRalliesAgain(from: savedBalls(), forVideoAt: video, videoId: videoId)
            XCTFail("balls off the court made a rally")
        } catch ProcessingError.noRalliesDetected {}
        XCTAssertTrue(offCourt.frameEvidence.flatMap(\.detections).allSatisfy(\.isOffCourt))
        XCTAssertFalse(offCourt.isProcessing)
        XCTAssertEqual(spans(try MetadataStore.shared.loadMetadata(for: videoId)), spans(before))
    }

    func testAPersonsOwnSegmentStaysAndTheDetectedOneUnderItGoes() async throws {
        let store = MetadataStore.shared
        let first = try await processor().decideRalliesAgain(from: savedBalls(), forVideoAt: video, videoId: videoId)
        let own = RallySegment(id: UUID(), startTimeSeconds: 3, endTimeSeconds: 5, confidence: 1, quality: 1, detectionCount: 0,
                               averageTrajectoryLength: 0, ballSizeTrend: nil, serveBallX: nil, isManual: true)
        try store.saveMetadata(first.withRallySegments([own]))

        let again = try await processor().decideRalliesAgain(from: savedBalls(), forVideoAt: video, videoId: videoId)
        XCTAssertEqual(again.rallySegments.map(\.id), [own.id], "\(spans(again))")
        XCTAssertEqual(spans(try store.loadMetadata(for: videoId)), ["3.000…5.000"])
    }

    func testBallsFoundInAnotherFileOrUnderTheOtherRotationAreRefusedAndNothingChanges() async throws {
        let other = try TestVideoFactory.writeVideo(to: dir.appendingPathComponent("other.mp4"), duration: 13, size: CGSize(width: 160, height: 90))
        var unread = savedBalls()
        unread.header.sourceFingerprint = nil
        for (name, log) in [("another file", savedBalls(of: other)), ("the other rotation", savedBalls(upright: !ProcessorConfig().applyVideoRotation)),
                            ("a file that could not be read", unread)] {
            let processor = processor()
            do {
                _ = try await processor.decideRalliesAgain(from: log, forVideoAt: video, videoId: videoId)
                XCTFail("decided from \(name)")
            } catch ProcessingError.savedDetectionsNotOfThisVideo {}
            XCTAssertFalse(processor.isProcessing, name)
            XCTAssertEqual(processor.frameEvidence.count, 0, name)
            XCTAssertEqual((processor.netSource as? FixedNetSource)?.asked, 0, name)
        }
        XCTAssertThrowsError(try MetadataStore.shared.loadMetadata(for: videoId), "nothing was saved")
    }
}
