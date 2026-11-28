//
//  BallDetectionLogTests.swift
//  BumpSetCutTests
//
//  The file of a run's ball detections (D-044): what is read back is exactly what was written; a file that is
//  not one, is of another version or is cut short is refused; a run in the library writes one that covers
//  every processed frame; an interrupted run's frames are put back on a resume, and a resume that can't put
//  them back keeps no log; a reprocess and Free Up Space's clean-up remove it.
//

import AVFoundation
import XCTest
@testable import BumpSetCut

@MainActor
final class BallDetectionLogTests: XCTestCase {
    private var dir: URL!
    private var video: URL!
    private let videoId = UUID()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BallDetectionLogTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = dir
        video = try TestVideoFactory.writeVideo(to: dir.appendingPathComponent("clip.mp4"), duration: 4.5, size: CGSize(width: 320, height: 180))
    }

    override func tearDownWithError() throws {
        StorageManager.storageDirectoryOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func header(checkpoint: Double? = nil, resumed: [Double] = []) -> BallDetectionLog.Header {
        .init(sourceFingerprint: FileFingerprint.read(atPath: video.path), durationSec: 4.5, upright: ProcessorConfig().applyVideoRotation,
              finder: "test", decodedFrameCount: 135, skippedFrameCount: 0, resumedAtSec: resumed, checkpointTimeSec: checkpoint)
    }

    private func sample() -> BallDetectionLog {
        BallDetectionLog(header: header(resumed: [12.5]), frames: [
            .init(time: CMTime(value: 1001, timescale: 30000), detections: [], singleFrameCount: 0),
            .init(time: CMTime(value: 2002, timescale: 30000), detections: [
                .init(bbox: CGRect(x: 0.1234567890123, y: 0.9, width: 0.0123, height: 0.0219999999), confidence: 0.61803399),
                .init(bbox: CGRect(x: -0.25, y: 1.5, width: 0, height: 1e-12), confidence: 1)
            ], singleFrameCount: 1),
            .init(time: CMTime(value: 7, timescale: 600), detections: [.init(bbox: .zero, confidence: 0)], singleFrameCount: 0)
        ])
    }

    // MARK: The format

    func testWhatIsReadBackIsWhatWasWritten() throws {
        let log = sample()
        let read = try BallDetectionLog(data: try log.encoded())
        XCTAssertEqual(read, log)
        XCTAssertEqual(read.frames[1].time.value, 2002)
        XCTAssertEqual(read.frames[1].time.timescale, 30000)
        XCTAssertEqual(read.frames[1].detections[0].bbox.origin.x, 0.1234567890123, "a box comes back to the last bit")
        XCTAssertEqual(read.frames[1].detections[0].confidence, 0.61803399)
    }

    func testALogWithNoFramesReadsBack() throws {
        let log = BallDetectionLog(header: header(), frames: [])
        XCTAssertEqual(try BallDetectionLog(data: try log.encoded()), log)
    }

    func testBytesThatAreNotALogAreRefused() throws {
        XCTAssertThrowsError(try BallDetectionLog(data: Data("{ not a log }".utf8))) { XCTAssertEqual($0 as? BallDetectionLog.ReadError, .notADetectionLog) }
        XCTAssertThrowsError(try BallDetectionLog(data: Data())) { XCTAssertNotNil($0 as? BallDetectionLog.ReadError) }
    }

    func testAnotherVersionIsRefused() throws {
        var data = try sample().encoded()
        // Version 1 had no frame counts in its header: a file of it is no log, and its video is processed again.
        for version: UInt8 in [1, 3] {
            data.replaceSubrange(4..<8, with: [version, 0, 0, 0])
            XCTAssertThrowsError(try BallDetectionLog(data: data)) { XCTAssertEqual($0 as? BallDetectionLog.ReadError, .unsupportedVersion(UInt32(version))) }
        }
    }

    func testAFileCutShortIsRefusedWhereverItIsCut() throws {
        let data = try sample().encoded()
        for length in stride(from: 0, to: data.count, by: 7) {
            XCTAssertThrowsError(try BallDetectionLog(data: data.prefix(length)), "cut at \(length) of \(data.count)")
        }
    }

    func testAFileThatCannotBeReadIsNoLog() throws {
        let url = dir.appendingPathComponent("x_detections.bsd")
        XCTAssertNil(BallDetectionLog.load(from: url))
        try Data("garbage".utf8).write(to: url)
        XCTAssertNil(BallDetectionLog.load(from: url))
        XCTAssertTrue(sample().write(to: url))
        XCTAssertEqual(BallDetectionLog.load(from: url), sample())
    }

    // MARK: A frame read again

    func testAFrameOfTheSameTimeTakesThePlaceOfTheLastAndALaterOneFollowsIt() {
        var frames = Array(keptFrames().prefix(3))
        let checkpointFrame = frames[2]
        // The resumed run's stride skips the checkpoint's frame: the kept one stays, the next follows.
        let next = BallDetectionLog.Frame(time: CMTime(value: 240, timescale: 600), detections: [], singleFrameCount: 0)
        BallDetectionLog.record(next, in: &frames)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[2], checkpointFrame, "a processed frame is not lost")

        // The resumed run reads the checkpoint's frame again: its reading takes the kept one's place.
        var again = Array(keptFrames().prefix(3))
        let reread = BallDetectionLog.Frame(time: CMTime(value: 4, timescale: 20), detections: [], singleFrameCount: 0)
        XCTAssertEqual(CMTimeCompare(reread.time, checkpointFrame.time), 0, "the same time, written with another timescale")
        BallDetectionLog.record(reread, in: &again)
        XCTAssertEqual(again.count, 3, "never there twice")
        XCTAssertEqual(again[2], reread)

        var empty: [BallDetectionLog.Frame] = []
        BallDetectionLog.record(next, in: &empty)
        XCTAssertEqual(empty, [next])
    }

    // MARK: A run

    private func run(_ processor: VideoProcessor = VideoProcessor(), persist: Bool = true) async throws -> VideoProcessor {
        processor.collectFrameEvidence = true
        do {
            if persist { _ = try await processor.processVideo(video, videoId: videoId) } else { _ = try await processor.analyzeVideo(video) }
        } catch ProcessingError.noRalliesDetected {}
        return processor
    }

    func testARunInTheLibraryKeepsEveryProcessedFrameEvenWhenNoRallyIsFound() async throws {
        let processor = try await run()
        let store = MetadataStore.shared
        let onFile = try XCTUnwrap(BallDetectionLog.load(from: store.ballDetectionsFileURL(for: videoId)))
        XCTAssertEqual(onFile, processor.detectionLog)
        XCTAssertGreaterThan(onFile.frames.count, 100)
        XCTAssertEqual(onFile.frames.map { CMTimeGetSeconds($0.time) }, processor.frameEvidence.map(\.time), "one frame of the log for each frame decided, in order")
        XCTAssertEqual(onFile.header.sourceFingerprint, FileFingerprint.read(atPath: video.path))
        XCTAssertEqual(onFile.header.durationSec, 4.5, accuracy: 0.1)
        XCTAssertEqual(onFile.header.resumedAtSec, [])
        XCTAssertNil(onFile.header.checkpointTimeSec)
        XCTAssertEqual(onFile.header.decodedFrameCount, 135, "4.5 s at 30 frames a second")
        XCTAssertEqual(onFile.header.decodedFrameCount - onFile.header.skippedFrameCount, onFile.frames.count, "every frame not skipped is in the log")
        XCTAssertTrue(onFile.header.finder.contains("ball_heat"), onFile.header.finder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.ballDetectionsPartialFileURL(for: videoId).path))
    }

    func testARunOutsideTheLibraryWritesNoFile() async throws {
        let processor = try await run(persist: false)
        XCTAssertGreaterThan(processor.detectionLog?.frames.count ?? 0, 100, "the run still has its log in memory")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: MetadataStore.shared.metadataDirectory.path)) ?? []
        XCTAssertEqual(names.filter { $0.contains("_detections") }, [])
    }

    // MARK: An interrupted run

    private let resumeTime = 2.0

    private func leaveCheckpoint(for processor: VideoProcessor) async throws {
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: video).load(.duration))
        let url = MetadataStore.shared.processingCheckpointFileURL(for: videoId)
        ProcessingCheckpoint(
            videoId: videoId, configHash: ProcessingCheckpoint.hash(of: processor.config), videoDurationSec: duration,
            collectEvidence: true, resumeTime: resumeTime, rawSegments: [], ballHeights: [], ballSizes: [], evidence: [],
            physics: [], trajectorySpans: [],
            counters: .init(rawFrameIndex: 60, skippedFrames: 0, frameCount: 60, totalDetections: 0, detectionFrameCount: 0,
                            trackingFrameCount: 0, rallyFrameCount: 0, physicsValidFrameCount: 0, confidenceSum: 0,
                            rSquaredSum: 0, rSquaredCount: 0),
            net: nil, savedAt: Date()
        ).write(to: url)
        XCTAssertNotNil(ProcessingCheckpoint.load(from: url), "the checkpoint is in place")
    }

    /// The interrupted run's frames: one each 0.1 s up to and including the checkpoint's own frame, each with a ball
    /// no real run of this clip would find.
    private func keptFrames() -> [BallDetectionLog.Frame] {
        (0...20).map { i in
            .init(time: CMTime(value: Int64(i) * 60, timescale: 600),
                  detections: [.init(bbox: CGRect(x: 0.5, y: 0.5, width: 0.02, height: 0.02), confidence: 0.99)], singleFrameCount: 0)
        }
    }

    func testAResumedRunPutsTheInterruptedRunsFramesBack() async throws {
        let processor = VideoProcessor()
        processor.netSource = FixedNetSource(.unavailable(reason: "none"))
        try await leaveCheckpoint(for: processor)
        let store = MetadataStore.shared
        XCTAssertTrue(BallDetectionLog(header: header(checkpoint: resumeTime), frames: keptFrames()).write(to: store.ballDetectionsPartialFileURL(for: videoId)))

        _ = try await run(processor)
        let log = try XCTUnwrap(BallDetectionLog.load(from: store.ballDetectionsFileURL(for: videoId)))
        let times = log.frames.map { CMTimeGetSeconds($0.time) }
        XCTAssertEqual(log.header.resumedAtSec, [resumeTime])
        XCTAssertEqual(Array(log.frames.prefix(20)), Array(keptFrames().prefix(20)), "the frames before the resume point are the interrupted run's")
        XCTAssertEqual(log.frames[20].time, keptFrames()[20].time, "the checkpoint's frame is where it was")
        XCTAssertEqual(log.frames[20].detections, [], "and is this run's reading of it: the multi-frame model reads every frame again")
        XCTAssertEqual(times, times.sorted(), "in order")
        XCTAssertEqual(Set(times).count, times.count, "the frame at the resume point is there once, as this run read it")
        XCTAssertTrue(log.frames.dropFirst(20).allSatisfy { $0.detections.isEmpty && CMTimeGetSeconds($0.time) >= resumeTime })
        XCTAssertGreaterThan(log.frames.count, 20 + 60)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.ballDetectionsPartialFileURL(for: videoId).path), "nothing unfinished is left")
    }

    func testAResumeWithoutTheInterruptedRunsFramesKeepsNoLog() async throws {
        let processor = VideoProcessor()
        processor.netSource = FixedNetSource(.unavailable(reason: "none"))
        try await leaveCheckpoint(for: processor)
        _ = try await run(processor)
        XCTAssertNil(processor.detectionLog)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MetadataStore.shared.ballDetectionsFileURL(for: videoId).path))
    }

    func testFramesKeptForAnotherCheckpointAreNotUsed() async throws {
        let processor = VideoProcessor()
        processor.netSource = FixedNetSource(.unavailable(reason: "none"))
        try await leaveCheckpoint(for: processor)
        XCTAssertTrue(BallDetectionLog(header: header(checkpoint: 1.0), frames: Array(keptFrames().prefix(11)))
            .write(to: MetadataStore.shared.ballDetectionsPartialFileURL(for: videoId)))
        _ = try await run(processor)
        XCTAssertNil(processor.detectionLog, "frames from 1 s to the checkpoint at 2 s would be missing")
    }

    // MARK: Clean-up

    func testAReprocessAndDeletingTheVideoRemoveTheLog() async throws {
        _ = try await run()
        let store = MetadataStore.shared
        let whole = store.ballDetectionsFileURL(for: videoId), partial = store.ballDetectionsPartialFileURL(for: videoId)
        XCTAssertTrue(sample().write(to: partial))
        store.deleteSidecarsForReprocess(videoId: videoId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: whole.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))

        XCTAssertTrue(sample().write(to: whole))
        XCTAssertTrue(sample().write(to: partial))
        store.deleteAllSidecars(for: videoId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: whole.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }
}
