//
//  UprightBoxTests.swift
//  BumpSetCutTests
//
//  The multi-frame model reads frames as stored; its boxes are turned into
//  the upright space YOLO's are in. Checked against the rotation flags
//  phones actually write, through the same orientation(for:) the pipeline uses.
//

import XCTest
import CoreGraphics
@testable import BumpSetCut

final class UprightBoxTests: XCTestCase {

    /// A 1920×1080 stored frame and the preferredTransforms that display it
    /// upright: portrait (90°), portrait upside down (−90°), landscape flipped (180°).
    private let stored = CGSize(width: 1920, height: 1080)
    private lazy var transforms: [CGAffineTransform] = [
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: stored.height, ty: 0),
        CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: stored.width),
        CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: stored.width, ty: stored.height),
    ]

    func testBoxCentreLandsWhereTheTransformPutsThePixel() {
        let box = CGRect(x: 0.15, y: 0.6, width: 0.02, height: 0.04)   // Vision, bottom-left origin
        for t in transforms {
            // The box centre as a stored pixel (top-left origin), through the transform.
            let pixel = CGPoint(x: box.midX * stored.width, y: (1 - box.midY) * stored.height).applying(t)
            let shown = CGRect(origin: .zero, size: stored).applying(t).size
            let expected = CGPoint(x: pixel.x / shown.width, y: 1 - pixel.y / shown.height)

            let upright = VideoFrameGeometry.upright(box, from: VideoFrameGeometry.orientation(for: t))
            XCTAssertEqual(upright.midX, expected.x, accuracy: 1e-9, "\(t)")
            XCTAssertEqual(upright.midY, expected.y, accuracy: 1e-9, "\(t)")
        }
    }

    func testQuarterTurnsSwapTheBoxSides() {
        let box = CGRect(x: 0.4, y: 0.4, width: 0.02, height: 0.05)
        for orientation in [CGImagePropertyOrientation.right, .left] {
            let upright = VideoFrameGeometry.upright(box, from: orientation)
            XCTAssertEqual(upright.width, box.height, accuracy: 1e-12)
            XCTAssertEqual(upright.height, box.width, accuracy: 1e-12)
        }
        XCTAssertEqual(VideoFrameGeometry.upright(box, from: .down).size, box.size)
    }

    func testOppositeQuarterTurnsUndoEachOther() {
        let box = CGRect(x: 0.7, y: 0.1, width: 0.03, height: 0.06)
        let back = VideoFrameGeometry.upright(VideoFrameGeometry.upright(box, from: .right), from: .left)
        XCTAssertEqual(back.midX, box.midX, accuracy: 1e-12)
        XCTAssertEqual(back.midY, box.midY, accuracy: 1e-12)
        XCTAssertEqual(back.size.width, box.size.width, accuracy: 1e-12)
    }

    func testUprightVideoIsUntouched() {
        let box = CGRect(x: 0.3, y: 0.5, width: 0.02, height: 0.03)
        XCTAssertEqual(VideoFrameGeometry.upright(box, from: .up), box)
    }
}
