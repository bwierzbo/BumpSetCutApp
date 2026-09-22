//
//  RotationGeometryTests.swift
//  BumpSetCutTests
//
//  Fit/fill sizing that the rally player's pan is normalized against.
//

import XCTest
@testable import BumpSetCut

final class RotationGeometryTests: XCTestCase {

    private let wideVideo = CGSize(width: 1920, height: 1080)
    private let portraitCard = CGSize(width: 393, height: 852)
    private let landscapeCard = CGSize(width: 852, height: 393)

    func testAspectFillCoversBoundsAndKeepsAspect() {
        let fill = RotationGeometry.aspectFillSize(content: wideVideo, in: landscapeCard)
        XCTAssertGreaterThanOrEqual(fill.width, landscapeCard.width)
        XCTAssertGreaterThanOrEqual(fill.height, landscapeCard.height)
        XCTAssertEqual(fill.width / fill.height, wideVideo.width / wideVideo.height, accuracy: 0.001)
        // A 16:9 clip on a 19.5:9 screen is width-bound: it overflows vertically.
        XCTAssertEqual(fill.width, landscapeCard.width, accuracy: 0.001)
        XCTAssertGreaterThan(fill.height, landscapeCard.height)
    }

    func testAspectFillOfWideContentInTallCardOverflowsHorizontally() {
        let fill = RotationGeometry.aspectFillSize(content: wideVideo, in: portraitCard)
        XCTAssertEqual(fill.height, portraitCard.height, accuracy: 0.001)
        XCTAssertGreaterThan(fill.width, portraitCard.width)
    }

    func testFitIsInsideBoundsAndFillIsOutside() {
        let fit = RotationGeometry.aspectFitSize(content: wideVideo, in: portraitCard)
        let fill = RotationGeometry.aspectFillSize(content: wideVideo, in: portraitCard)
        XCTAssertLessThanOrEqual(fit.width, portraitCard.width)
        XCTAssertLessThanOrEqual(fit.height, portraitCard.height)
        XCTAssertGreaterThanOrEqual(fill.width, portraitCard.width)
        XCTAssertGreaterThanOrEqual(fill.height, portraitCard.height)
    }

    /// The point of normalizing pan to the rendered video: the same fraction
    /// lands on the same spot of the footage whether the video is letterboxed
    /// (portrait, fit) or overflowing (landscape, fill).
    func testPanFractionMapsToSameVideoPointInBothOrientations() {
        let pan = CGSize(width: 0.12, height: -0.3)
        let fit = RotationGeometry.aspectFitSize(content: wideVideo, in: portraitCard)
        let fill = RotationGeometry.aspectFillSize(content: wideVideo, in: landscapeCard)

        // Points on screen differ…
        let portraitOffset = CGSize(width: pan.width * fit.width, height: pan.height * fit.height)
        let landscapeOffset = CGSize(width: pan.width * fill.width, height: pan.height * fill.height)
        XCTAssertNotEqual(portraitOffset, landscapeOffset)

        // …but in source pixels they are the same shift.
        let portraitPixels = CGSize(
            width: portraitOffset.width * wideVideo.width / fit.width,
            height: portraitOffset.height * wideVideo.height / fit.height
        )
        let landscapePixels = CGSize(
            width: landscapeOffset.width * wideVideo.width / fill.width,
            height: landscapeOffset.height * wideVideo.height / fill.height
        )
        XCTAssertEqual(portraitPixels.width, landscapePixels.width, accuracy: 0.001)
        XCTAssertEqual(portraitPixels.height, landscapePixels.height, accuracy: 0.001)
    }

    func testDegenerateInputsFallBackToBounds() {
        XCTAssertEqual(RotationGeometry.aspectFillSize(content: .zero, in: portraitCard), portraitCard)
        XCTAssertEqual(RotationGeometry.aspectFillSize(content: wideVideo, in: .zero), .zero)
    }
}
