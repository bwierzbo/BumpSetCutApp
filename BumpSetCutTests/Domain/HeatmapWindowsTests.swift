//
//  HeatmapWindowsTests.swift
//  BumpSetCutTests
//
//  The multi-frame model over a stream: every frame answered exactly once,
//  in order, from a window with frames on both sides of it, at one run per
//  `hop` frames.
//

import XCTest
@testable import BumpSetCut

final class HeatmapWindowsTests: XCTestCase {

    private var detector: HeatmapBallDetector!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(BallFinder.multiFrameOnly.heatmapModel, "bundled multi-frame model")
        detector = try XCTUnwrap(HeatmapBallDetector(modelURL: url, computeUnits: .cpuOnly))
    }

    private var blank: HeatmapBallDetector.Frame {
        HeatmapBallDetector.Frame(pixels: [Float](repeating: 0, count: detector.width * detector.height), portrait: false)
    }

    func testEveryFrameIsAnsweredOnceInOrder() {
        var windows = HeatmapWindows(detector: detector, hop: 5)
        var answers = 0
        for _ in 0..<23 {
            let got = windows.push(blank)
            answers += got.count
            XCTAssertEqual(answers, windows.answered)
        }
        answers += windows.finish().count
        XCTAssertEqual(answers, 23)
        XCTAssertEqual(windows.answered, windows.pushed)
        XCTAssertTrue(windows.finish().isEmpty, "nothing left once finished")
    }

    func testAFrameIsAnsweredOnlyOnceFramesAfterItAreIn() {
        var windows = HeatmapWindows(detector: detector, hop: 5)
        let seq = detector.seq
        for _ in 0..<(seq - 1) { XCTAssertTrue(windows.push(blank).isEmpty) }
        // The first window answers the stream's start through its middle:
        // the frame after the middle `hop` waits for the next window.
        XCTAssertEqual(windows.push(blank).count, (seq - 5) / 2 + 5)
        for _ in 0..<4 { XCTAssertTrue(windows.push(blank).isEmpty) }
        XCTAssertEqual(windows.push(blank).count, 5)
        // Each answered frame has frames after it in its window.
        XCTAssertLessThanOrEqual(windows.answered, windows.pushed - (seq - 5) / 2)
    }

    func testAStreamShorterThanAWindowFindsNothing() {
        var windows = HeatmapWindows(detector: detector, hop: 5)
        for _ in 0..<4 { _ = windows.push(blank) }
        XCTAssertEqual(windows.finish().map(\.count), [0, 0, 0, 0])
    }

    func testHopOneCentresAWindowOnEveryFrame() {
        var windows = HeatmapWindows(detector: detector, hop: 1)
        var counts: [Int] = []
        for _ in 0..<12 { counts.append(windows.push(blank).count) }
        let half = detector.seq / 2
        XCTAssertEqual(counts, Array(repeating: 0, count: detector.seq - 1) + [half + 1] + Array(repeating: 1, count: 12 - detector.seq))
        XCTAssertEqual(windows.finish().count, half)
    }
}
