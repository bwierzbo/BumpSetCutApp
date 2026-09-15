//
//  VideoExporterStitchTests.swift
//  BumpSetCutTests
//
//  buildStitchComposition: multi-source highlight reels — per-clip
//  instructions, render size from the first clip, trim ranges, frame rate
//  clamping, and silent-clip audio handling.
//

import XCTest
import AVFoundation
@testable import BumpSetCut

final class VideoExporterStitchTests: XCTestCase {

    var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoExporterStitchTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    private func makeClip(name: String, duration: Double, size: CGSize) throws -> URL {
        try TestVideoFactory.writeVideo(
            to: tempDirectory.appendingPathComponent("\(name).mp4"),
            duration: duration, size: size, fps: 30
        )
    }

    func testStitchBuildsOneInstructionPerClip() async throws {
        let a = try makeClip(name: "a", duration: 1.0, size: CGSize(width: 320, height: 240))
        let b = try makeClip(name: "b", duration: 1.0, size: CGSize(width: 320, height: 240))

        let build = try await VideoExporter().buildStitchComposition(clips: [
            .init(url: a), .init(url: b)
        ])

        XCTAssertEqual(build.videoComposition.instructions.count, 2)
        XCTAssertEqual(CMTimeGetSeconds(build.composition.duration), 2.0, accuracy: 0.15)

        // Instructions must tile the timeline contiguously from zero.
        let first = build.videoComposition.instructions[0]
        let second = build.videoComposition.instructions[1]
        XCTAssertEqual(CMTimeGetSeconds(first.timeRange.start), 0, accuracy: 0.01)
        XCTAssertEqual(
            CMTimeGetSeconds(first.timeRange.end),
            CMTimeGetSeconds(second.timeRange.start),
            accuracy: 0.01
        )
    }

    func testStitchRenderSizeComesFromFirstClip() async throws {
        // Landscape first, portrait-shaped second: reel renders at the first
        // clip's size; the second aspect-fits into it.
        let landscape = try makeClip(name: "landscape", duration: 0.5, size: CGSize(width: 320, height: 240))
        let portrait = try makeClip(name: "portrait", duration: 0.5, size: CGSize(width: 240, height: 320))

        let build = try await VideoExporter().buildStitchComposition(clips: [
            .init(url: landscape), .init(url: portrait)
        ])

        XCTAssertEqual(build.videoComposition.renderSize, CGSize(width: 320, height: 240))
    }

    func testStitchRespectsClipTimeRange() async throws {
        let clip = try makeClip(name: "trimmed", duration: 2.0, size: CGSize(width: 320, height: 240))
        let range = CMTimeRange(
            start: CMTime(seconds: 0.5, preferredTimescale: 600),
            end: CMTime(seconds: 1.5, preferredTimescale: 600)
        )

        let build = try await VideoExporter().buildStitchComposition(clips: [
            .init(url: clip, timeRange: range)
        ])

        XCTAssertEqual(CMTimeGetSeconds(build.composition.duration), 1.0, accuracy: 0.15)
    }

    func testStitchSilentClipsProduceNoAudioTrack() async throws {
        // TestVideoFactory clips carry no audio; a reel of them must not keep
        // an audio track made purely of empty ranges.
        let a = try makeClip(name: "silent1", duration: 0.5, size: CGSize(width: 320, height: 240))
        let b = try makeClip(name: "silent2", duration: 0.5, size: CGSize(width: 320, height: 240))

        let build = try await VideoExporter().buildStitchComposition(clips: [
            .init(url: a), .init(url: b)
        ])

        XCTAssertTrue(build.composition.tracks(withMediaType: .audio).isEmpty)
        XCTAssertEqual(build.composition.tracks(withMediaType: .video).count, 1)
    }

    func testStitchFrameRateMatchesSourceWithinClamp() async throws {
        let clip = try makeClip(name: "fps", duration: 0.5, size: CGSize(width: 320, height: 240))

        let build = try await VideoExporter().buildStitchComposition(clips: [.init(url: clip)])

        // 30fps source → 1/30 frame duration (not the pre-fix hardcoded value
        // by accident: the clamp keeps it within 24–60).
        let timescale = build.videoComposition.frameDuration.timescale
        XCTAssertGreaterThanOrEqual(timescale, 24)
        XCTAssertLessThanOrEqual(timescale, 60)
        XCTAssertEqual(timescale, 30)
    }

    func testStitchClipRangesAlignWithInputAndTileOutput() async throws {
        let a = try makeClip(name: "ranges1", duration: 1.0, size: CGSize(width: 320, height: 240))
        let b = try makeClip(name: "ranges2", duration: 0.5, size: CGSize(width: 320, height: 240))

        let build = try await VideoExporter().buildStitchComposition(clips: [
            .init(url: a), .init(url: b)
        ])

        XCTAssertEqual(build.clipRanges.count, 2)
        let first = try XCTUnwrap(build.clipRanges[0])
        let second = try XCTUnwrap(build.clipRanges[1])
        XCTAssertEqual(CMTimeGetSeconds(first.start), 0, accuracy: 0.01)
        XCTAssertEqual(CMTimeGetSeconds(first.duration), 1.0, accuracy: 0.15)
        XCTAssertEqual(
            CMTimeGetSeconds(second.start),
            CMTimeGetSeconds(first.end),
            accuracy: 0.01
        )
        XCTAssertEqual(
            CMTimeGetSeconds(second.end),
            CMTimeGetSeconds(build.composition.duration),
            accuracy: 0.05
        )
    }

    func testStitchEmptyClipListThrows() async {
        do {
            _ = try await VideoExporter().buildStitchComposition(clips: [])
            XCTFail("Expected buildStitchComposition to throw for empty clips")
        } catch {
            // expected
        }
    }

    func testStitchedExportProducesPlayableFile() async throws {
        let a = try makeClip(name: "exp1", duration: 0.5, size: CGSize(width: 320, height: 240))
        let b = try makeClip(name: "exp2", duration: 0.5, size: CGSize(width: 240, height: 320))

        let url = try await VideoExporter().exportStitchedClips([.init(url: a), .init(url: b)])
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        XCTAssertEqual(duration, 1.0, accuracy: 0.25)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let size = try await videoTracks[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 240))
    }
}
