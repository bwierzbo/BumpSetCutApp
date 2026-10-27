//
//  FrameCanvasZoomTests.swift
//  RallyLabTests
//
//  The zoom geometry shared by the frame canvas and the phone's zoomed boundary player: a picture of the
//  content's proportions fitted to the view and magnified, its centre kept so the picture covers the view.
//

import CoreGraphics
import XCTest
@testable import RallyLab

final class FrameCanvasZoomTests: XCTestCase {
    private let view = CGSize(width: 400, height: 225)   // a 16:9 box, as the phone's player area

    func testLandscapeFitsTheBoxAndScalesWithZoom() {
        let video = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(FrameCanvas.shown(content: video, zoom: 1, view: view), CGSize(width: 400, height: 225))
        XCTAssertEqual(FrameCanvas.shown(content: video, zoom: 3, view: view), CGSize(width: 1200, height: 675))
    }

    func testPortraitFitsByHeightSoTheBarsAreNotPartOfThePicture() {
        let portrait = CGSize(width: 1080, height: 1920)
        let shown = FrameCanvas.shown(content: portrait, zoom: 1, view: view)
        XCTAssertEqual(shown.height, 225, accuracy: 1e-9)
        XCTAssertEqual(shown.width, 225 * 1080 / 1920, accuracy: 1e-9)
    }

    func testTheImageVersionIsTheContentVersion() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(ctx.makeImage())
        XCTAssertEqual(FrameCanvas.shown(image: image, zoom: 2.5, view: view),
                       FrameCanvas.shown(content: CGSize(width: 64, height: 36), zoom: 2.5, view: view))
    }

    func testAnEmptyContentSizeFallsBackToTheView() {
        XCTAssertEqual(FrameCanvas.shown(content: .zero, zoom: 4, view: view), view)
    }

    func testAZoomedCentreIsClampedSoThePictureStillCoversTheView() {
        let shown = FrameCanvas.shown(content: CGSize(width: 1920, height: 1080), zoom: 4, view: view)
        // Asking for the far corner stops where the picture's edge meets the view's edge.
        let c = FrameCanvas.clampedCentre(CGPoint(x: 5, y: -5), shown: shown, view: view)
        XCTAssertEqual(c.x, 1 - 0.5 / 4, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.5 / 4, accuracy: 1e-9)
        let o = FrameCanvas.origin(shown: shown, centre: c, view: view)
        XCTAssertEqual(o.x + shown.width, view.width, accuracy: 1e-9)
        XCTAssertEqual(o.y, 0, accuracy: 1e-9)
    }
}
