//
//  CalibrationCanvasGeometryTests.swift
//  BumpSetCutTests
//
//  The Court & Net editor's geometry: the frame on the canvas at a zoom and pan, the
//  shapes while they are being placed, and what a touch takes hold of.
//

import XCTest
@testable import BumpSetCut

final class CalibrationCanvasGeometryTests: XCTestCase {
    private typealias F = CalibrationFixtures
    private let phone = CGSize(width: 390, height: 480)

    // MARK: Viewport

    func testALandscapeFrameFitsThePortraitCanvasAcross() {
        let v = CalibrationViewport(canvas: phone, frameAspect: 16.0 / 9)
        XCTAssertEqual(v.frameRect.width, 390, accuracy: 1e-6)
        XCTAssertEqual(v.frameRect.height, 390 * 9 / 16, accuracy: 1e-6)
        XCTAssertEqual(v.frameRect.midY, 240, accuracy: 1e-6)
    }

    func testAPortraitFrameFitsTheCanvasInHeight() {
        let v = CalibrationViewport(canvas: phone, frameAspect: 9.0 / 16)
        XCTAssertEqual(v.frameRect.height, 480, accuracy: 1e-6)
        XCTAssertEqual(v.frameRect.width, 270, accuracy: 1e-6)
        XCTAssertEqual(v.frameRect.midX, 195, accuracy: 1e-6)
    }

    func testFramePointsAreBottomLeftOriginAndRoundTrip() {
        let v = CalibrationViewport(canvas: phone, frameAspect: 16.0 / 9, scale: 2.5, offset: CGSize(width: 30, height: -12))
        let r = v.frameRect
        XCTAssertEqual(v.point(x: 0, y: 0), CGPoint(x: r.minX, y: r.maxY))
        XCTAssertEqual(v.point(x: 1, y: 1), CGPoint(x: r.maxX, y: r.minY))
        let back = v.normalized(v.point(x: 0.31, y: 0.77))
        XCTAssertEqual(back.x, 0.31, accuracy: 1e-9)
        XCTAssertEqual(back.y, 0.77, accuracy: 1e-9)
    }

    func testZoomKeepsWhatIsUnderTheFingersAndStaysInRange() {
        let v = CalibrationViewport(canvas: phone, frameAspect: 16.0 / 9)
        let anchor = CGPoint(x: 300, y: 200)
        let under = v.normalized(anchor)
        let zoomed = v.zoomed(to: 3, keeping: anchor)
        XCTAssertEqual(zoomed.scale, 3)
        let after = zoomed.normalized(anchor)
        XCTAssertEqual(after.x, under.x, accuracy: 1e-9)
        XCTAssertEqual(after.y, under.y, accuracy: 1e-9)
        XCTAssertEqual(v.zoomed(to: 100, keeping: anchor).scale, CalibrationViewport.scaleRange.upperBound)
        XCTAssertEqual(v.zoomed(to: 0.01, keeping: anchor).scale, CalibrationViewport.scaleRange.lowerBound)
    }

    func testZoomedOutATouchBesideThePictureIsOutsideTheFrame() {
        let v = CalibrationViewport(canvas: phone, frameAspect: 16.0 / 9).zoomed(to: 0.5, keeping: CGPoint(x: 195, y: 240))
        let below = v.normalized(CGPoint(x: 195, y: v.frameRect.maxY + 40))
        XCTAssertLessThan(below.y, 0)
        XCTAssertTrue(CourtLayout.placeableRange.contains(below.y))
    }

    func testPanningNeverLosesThePictureAndReachesItsCornersWhenZoomedIn() {
        let v = CalibrationViewport(canvas: phone, frameAspect: 16.0 / 9).panned(by: CGSize(width: 5000, height: -5000))
        XCTAssertEqual(v.frameRect.minX, 390 - 60, accuracy: 1e-6)
        XCTAssertEqual(v.frameRect.maxY, 60, accuracy: 1e-6)
        // At full zoom the frame's top-right corner can sit in the middle of the canvas.
        let zoomed = CalibrationViewport(canvas: phone, frameAspect: 16.0 / 9, scale: 8)
        let corner = zoomed.point(x: 1, y: 1)
        let centred = zoomed.panned(by: CGSize(width: 195 - corner.x, height: 240 - corner.y))
        XCTAssertEqual(centred.point(x: 1, y: 1).x, 195, accuracy: 1e-6)
        XCTAssertEqual(centred.point(x: 1, y: 1).y, 240, accuracy: 1e-6)
    }

    func testTheLoupeCentresThePointAndMagnifies() {
        let v = CalibrationViewport(canvas: phone, frameAspect: 16.0 / 9, scale: 1.5)
        let loupe = v.loupe(onX: 0.2, y: 0.9, side: 132, magnification: 2.5)
        let centre = loupe.point(x: 0.2, y: 0.9)
        XCTAssertEqual(centre.x, 66, accuracy: 1e-6)
        XCTAssertEqual(centre.y, 66, accuracy: 1e-6)
        XCTAssertEqual(loupe.frameRect.height, v.frameRect.height * 2.5, accuracy: 1e-6)
    }

    // MARK: Placing

    func testPointsAreAskedForInOrderAndNothingIsPlacedAtFirst() {
        var s = CalibrationWorkingShapes()
        XCTAssertFalse(s.hasCourtPoints)
        XCTAssertFalse(s.hasNetCorners)
        XCTAssertNil(s.netQuad)
        var asked: [CalibrationHandle] = []
        while let next = s.nextToPlace(.court) {
            asked.append(next)
            s.set(next, x: 0.5, y: 0.5)
        }
        XCTAssertEqual(asked, [.court(.nearLeft), .court(.nearRight), .court(.netLeft), .court(.netRight), .court(.farLeft), .court(.farRight)])
        XCTAssertEqual(s.nextToPlace(.net), .net(0))
    }

    func testACourtPointOutsideTheFrameIsEstimatedAndSeenAgainInside() {
        var s = CalibrationWorkingShapes()
        s.set(.court(.nearLeft), x: 0.1, y: -0.3)
        XCTAssertEqual(s.court.nearLeft.status, .estimated)
        s.set(.court(.nearLeft), x: 0.1, y: 0.1)
        XCTAssertEqual(s.court.nearLeft.status, .seen)
        s.setEstimated(true, .nearLeft)
        s.set(.court(.nearLeft), x: 0.12, y: 0.1)
        XCTAssertEqual(s.court.nearLeft.status, .estimated, "what the person said of a point in the frame is kept when it moves")
        s.set(.court(.nearLeft), x: 0.12, y: -0.2)
        s.setEstimated(false, .nearLeft)
        XCTAssertEqual(s.court.nearLeft.status, .estimated, "a point outside the frame is never seen")
        s.set(.court(.nearLeft), x: 0.1, y: -9)
        XCTAssertEqual(s.court.nearLeft.y, CourtLayout.placeableRange.lowerBound)
    }

    func testAPointThePersonCannotPlaceIsUnknownAndNotAskedForAgain() {
        var s = CalibrationWorkingShapes(court: F.court, net: nil)
        s.remove(.court(.farLeft))
        XCTAssertEqual(s.court.farLeft.status, .unknown)
        XCTAssertNil(s.position(.court(.farLeft)))
        XCTAssertNil(s.nextToPlace(.court))
        XCTAssertTrue(s.court.isUsable, "the near half still maps")
        s.set(.court(.farLeft), x: 0.33, y: 0.62)
        XCTAssertEqual(s.court, F.court)

        let reopened = CalibrationWorkingShapes(court: { var c = F.court; c.farRight = F.point(0, 0, .unknown); return c }(), net: nil)
        XCTAssertNil(reopened.nextToPlace(.court))
    }

    func testTheNetIsAQuadOnlyWithFourCornersAndStaysInTheFrame() {
        var s = CalibrationWorkingShapes()
        for (i, p) in [(0.24, 0.60), (0.76, 0.61), (0.76, 0.50)].enumerated() { s.set(.net(i), x: p.0, y: p.1) }
        XCTAssertNil(s.netQuad)
        XCTAssertEqual(s.nextToPlace(.net), .net(3))
        s.set(.net(3), x: 0.24, y: 0.49)
        XCTAssertEqual(s.netQuad, F.net)
        s.set(.net(1), x: 1.4, y: -0.2)
        XCTAssertEqual(s.net[1], NetQuad.Point(x: 1, y: 0))
        s.remove(.net(1))
        XCTAssertNil(s.netQuad)
        XCTAssertEqual(CalibrationWorkingShapes(court: nil, net: F.net).netQuad, F.net)
    }

    // MARK: Moving

    func testALineMovesBothItsEndsAndNothingElse() {
        let start = CalibrationWorkingShapes(court: F.court, net: F.net)
        var s = start
        s.translate([.court(.nearLeft), .court(.nearRight)], from: start, dx: 0.02, dy: -0.05)
        XCTAssertEqual(s.court.nearLeft.x, 0.12, accuracy: 1e-9)
        XCTAssertEqual(s.court.nearRight.y, 0.05, accuracy: 1e-9)
        XCTAssertEqual(s.court.netLeft, start.court.netLeft)
        XCTAssertEqual(s.net, start.net)
    }

    func testAWholeNetStopsAtTheFramesEdgeWithItsShapeKept() {
        let start = CalibrationWorkingShapes(court: nil, net: F.net)
        var s = start
        s.translate(CalibrationWorkingShapes.handles(of: .net), from: start, dx: 0.9, dy: 0.9)
        let moved = try! XCTUnwrap(s.netQuad)
        XCTAssertEqual(moved.bounds.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(moved.bounds.maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(moved.bounds.width, F.net.bounds.width, accuracy: 1e-9)
        XCTAssertEqual(moved.topRight.y - moved.topLeft.y, F.net.topRight.y - F.net.topLeft.y, accuracy: 1e-9)
    }

    func testAWholeCourtMovesOnlyItsPlacedPoints() {
        var court = F.court
        court.farLeft = F.point(0, 0, .unknown)
        let start = CalibrationWorkingShapes(court: court, net: nil)
        var s = start
        s.translate(CalibrationWorkingShapes.handles(of: .court), from: start, dx: 0.01, dy: 0.01)
        XCTAssertEqual(s.court.farLeft.status, .unknown)
        XCTAssertEqual(s.court.farRight.x, 0.68, accuracy: 1e-9)
        XCTAssertEqual(s.court.changedRoles(from: court).count, 5)
    }

    // MARK: Touches

    func testATouchTakesTheNearestPointWithinReachOfTheShapeBeingEdited() {
        let v = CalibrationViewport(canvas: phone, frameAspect: 16.0 / 9)
        let s = CalibrationWorkingShapes(court: F.court, net: F.net)
        let nearLeft = v.point(x: 0.10, y: 0.10)
        XCTAssertEqual(s.handle(near: CGPoint(x: nearLeft.x + 12, y: nearLeft.y - 9), in: v, target: .court, radius: 30), .court(.nearLeft))
        XCTAssertNil(s.handle(near: CGPoint(x: nearLeft.x + 40, y: nearLeft.y), in: v, target: .court, radius: 30))
        // Net left (0.25, 0.45) and the net's bottom-left corner (0.24, 0.49) are close: the target decides.
        let between = v.point(x: 0.245, y: 0.47)
        XCTAssertEqual(s.handle(near: between, in: v, target: .court, radius: 30), .court(.netLeft))
        XCTAssertEqual(s.handle(near: between, in: v, target: .net, radius: 30), .net(3))
    }

    func testADragStartsOnAPointThenALineThenThePicture() {
        let v = CalibrationViewport(canvas: phone, frameAspect: 16.0 / 9)
        let s = CalibrationWorkingShapes(court: F.court, net: nil)
        func action(_ x: Double, _ y: Double, whole: Bool = false, target: CalibrationTarget = .court) -> CalibrationDragAction {
            s.dragAction(at: v.point(x: x, y: y), in: v, target: target, wholeShape: whole, handleRadius: 30, edgeTolerance: 16)
        }
        XCTAssertEqual(action(0.10, 0.10), .handle(.court(.nearLeft)))
        XCTAssertEqual(action(0.50, 0.10), .edge(.court(.nearLeft), .court(.nearRight)))
        XCTAssertEqual(action(0.50, 0.45), .edge(.court(.netLeft), .court(.netRight)))
        XCTAssertEqual(action(0.50, 0.28), .pan)
        XCTAssertEqual(action(0.50, 0.28, whole: true), .shape)
        XCTAssertEqual(action(0.10, 0.10, whole: true), .handle(.court(.nearLeft)))
        XCTAssertEqual(action(0.50, 0.28, whole: true, target: .net), .pan, "nothing of the net is placed")
        XCTAssertEqual(CalibrationWorkingShapes.handles(moved: .edge(.net(0), .net(1)), target: .net), [.net(0), .net(1)])
        XCTAssertEqual(CalibrationWorkingShapes.handles(moved: .shape, target: .net).count, 4)
        XCTAssertTrue(CalibrationWorkingShapes.handles(moved: .pan, target: .court).isEmpty)
    }
}
