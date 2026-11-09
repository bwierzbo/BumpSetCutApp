//
//  PlayerVisionExtractorTests.swift
//  RallyLabTests
//
//  The extractor on a synthetic portrait video (stored landscape with a 90°
//  rotation flag, as an iPhone writes it): the upright size and orientation,
//  one sampled frame per 0.2 s on the presentation timeline, Vision actually
//  run on each (an empty frame has nobody in it), excluded time not analysed,
//  and the overlay image upright.
//

import AVFoundation
import XCTest
@testable import RallyLab

final class PlayerVisionExtractorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("player-vision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// 2 s at 30 fps, 320×180 stored, rotated 90° (upright 180×320).
    private func portraitVideo() async throws -> URL {
        let url = dir.appendingPathComponent("portrait.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), Int32(40 + i), CVPixelBufferGetDataSize(pb!))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            XCTAssertTrue(adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    func testPortraitVideoIsSampledOnItsTimelineAndAnalysedUpright() async throws {
        let url = try await portraitVideo()
        let facts = try await PlayerVisionExtractor.facts(of: url)
        XCTAssertEqual(facts.orientation, .right)
        XCTAssertEqual(facts.uprightWidth, 180)
        XCTAssertEqual(facts.uprightHeight, 320)
        let interval = PlayerFeatures.Interval(name: "all", kind: .activePlay, startSec: 0, endSec: 2, selection: "test")
        let frames = try await PlayerVisionExtractor.run(url: url, facts: facts, interval: interval, hz: 5,
                                                         detector: VisionPlayerDetector(), tiling: PlayerTiling(), excluded: { $0 >= 1.0 && $0 < 1.4 ? "cut" : nil }, wantsImage: { $0 == 0 })
        XCTAssertEqual(frames.map { PlayerFeatures.tick($0.t) }, [0, 120, 240, 360, 480, 600, 720, 840, 960, 1080])
        XCTAssertEqual(frames.map(\.skipped), [nil, nil, nil, nil, nil, "cut", "cut", nil, nil, nil])
        for f in frames where f.skipped == nil {
            XCTAssertFalse(f.detections.rectFailed)
            XCTAssertFalse(f.detections.poseFailed)
            XCTAssertTrue(f.detections.persons.isEmpty, "a flat grey frame has nobody in it")
            XCTAssertEqual(f.thumb.count, 32 * 18)
            XCTAssertNotNil(f.ms["rect"])
            XCTAssertNotNil(f.ms["pose"])
            XCTAssertNotNil(f.ms["image"])
        }
        XCTAssertEqual(frames[0].image?.width, 180, "the overlay image is the upright frame")
        XCTAssertEqual(frames[0].image?.height, 320)
        XCTAssertNil(frames[1].image)
    }
}
