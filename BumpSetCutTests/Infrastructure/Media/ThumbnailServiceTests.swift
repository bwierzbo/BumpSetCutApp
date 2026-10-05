//
//  ThumbnailServiceTests.swift
//  BumpSetCutTests
//
//  Still caching (per file, moment and size) and filmstrip generation of
//  ThumbnailService, against real clips from TestVideoFactory.
//

import XCTest
import AVFoundation
@testable import BumpSetCut

final class ThumbnailServiceTests: XCTestCase {

    private var clip: URL!

    override func setUpWithError() throws {
        clip = try TestVideoFactory.makeTempVideo(duration: 2.0, size: CGSize(width: 640, height: 360))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: clip)
    }

    func testStillIsCachedAfterFirstGeneration() async throws {
        let service = ThumbnailService()
        XCTAssertNil(service.cachedStill(url: clip))

        let first = try await service.still(url: clip)
        let cached = try XCTUnwrap(service.cachedStill(url: clip))
        let second = try await service.still(url: clip)

        XCTAssertTrue(cached === first)
        XCTAssertTrue(second === first, "a repeat request must come from the cache")
    }

    func testCacheIsKeyedByMomentAndSize() async throws {
        let service = ThumbnailService()
        let later = CMTime(seconds: 1.5, preferredTimescale: 600)

        let start = try await service.still(url: clip)
        let atLater = try await service.still(url: clip, at: later)
        let small = try await service.still(url: clip, maxSize: 100)

        XCTAssertFalse(start === atLater)
        XCTAssertFalse(start === small)
        XCTAssertTrue(service.cachedStill(url: clip, at: later) === atLater)
        XCTAssertNil(service.cachedStill(url: clip, at: CMTime(seconds: 0.5, preferredTimescale: 600)))
    }

    func testStillRespectsMaxSize() async throws {
        let image = try await ThumbnailService().still(url: clip, maxSize: 100)
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 100)
    }

    func testUnreadableFileThrowsAndIsNotCached() async throws {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("not_a_video_\(UUID()).mp4")
        try Data("not a video".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        let service = ThumbnailService()

        do {
            _ = try await service.still(url: bogus)
            XCTFail("expected a decode failure")
        } catch {
            XCTAssertNil(service.cachedStill(url: bogus))
        }
    }

    func testFilmstripReturnsRequestedFrameCount() async {
        let frames = await ThumbnailService().filmstrip(url: clip, start: 0, duration: 2.0, count: 6, maxSize: 120)

        XCTAssertEqual(frames.count, 6)
        for frame in frames {
            XCTAssertLessThanOrEqual(max(frame.size.width, frame.size.height), 120)
        }
    }

    func testFilmstripWithZeroCountIsEmpty() async {
        let frames = await ThumbnailService().filmstrip(url: clip, start: 0, duration: 2.0, count: 0)
        XCTAssertTrue(frames.isEmpty)
    }
}
