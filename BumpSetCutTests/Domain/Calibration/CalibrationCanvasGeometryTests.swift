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

    func testACourtSavedWithoutAPointIsNotAskedForItAndIsNoWholeCourt() {
        var s = CalibrationWorkingShapes(court: { var c = F.court; c.farLeft = F.point(0, 0, .unknown); return c }(), net: nil)
        XCTAssertNil(s.position(.court(.farLeft)))
        XCTAssertNil(s.nextToPlace(.court))
        XCTAssertFalse(s.isWholeCourt)
        XCTAssertTrue(s.court.isUsable, "the near half still maps")
        s.set(.court(.farLeft), x: 0.33, y: 0.62)
        XCTAssertEqual(s.court, F.court)
        XCTAssertTrue(s.isWholeCourt)
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
        s.removeNetCorner(1)
        XCTAssertNil(s.netQuad)
        XCTAssertEqual(s.nextToPlace(.net), .net(1))
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

    // MARK: - The court as an outline

    private func onSideline(_ s: CalibrationWorkingShapes, left: Bool) -> Double {
        let (n, c, f) = left ? (s.court.nearLeft, s.court.netLeft, s.court.farLeft) : (s.court.nearRight, s.court.netRight, s.court.farRight)
        // Twice the area of the triangle near–centre–far: zero when the centre-line point is on the sideline.
        return abs((n.x - f.x) * (c.y - f.y) - (n.y - f.y) * (c.x - f.x))
    }

    func testTheOfferedOutlineIsAWholeCourtWithItsNearCornersOffThePicture() {
        let outline = CalibrationWorkingShapes.courtOutline
        XCTAssertTrue(outline.isWholeCourt)
        XCTAssertTrue(outline.courtReachesOutsideFrame)
        XCTAssertEqual(outline.court.nearLeft.status, .estimated)
        XCTAssertEqual(outline.court.farRight.status, .seen)
        XCTAssertLessThan(outline.court.nearLeft.y, 0)
        XCTAssertEqual(onSideline(outline, left: true), 0, accuracy: 1e-12)
        XCTAssertEqual(onSideline(outline, left: false), 0, accuracy: 1e-12)
        XCTAssertFalse(outline.hasNetCorners)
        XCTAssertFalse(CalibrationWorkingShapes().isWholeCourt)
        XCTAssertFalse(CalibrationWorkingShapes().courtReachesOutsideFrame)
    }

    func testACornerMovesAloneAndItsCentreLinePointKeepsItsPlaceAlongTheSideline() {
        let start = CalibrationWorkingShapes.courtOutline
        var moved = start
        moved.moveOutline(.handle(.court(.farLeft)), from: start, dx: 0.05, dy: 0.04)
        XCTAssertEqual(moved.court.farLeft.x, start.court.farLeft.x + 0.05, accuracy: 1e-12)
        XCTAssertEqual(moved.court.farLeft.y, start.court.farLeft.y + 0.04, accuracy: 1e-12)
        for role in [CourtLayout.Role.nearLeft, .nearRight, .farRight, .netRight] { XCTAssertEqual(moved.court[role], start.court[role], "\(role)") }
        XCTAssertEqual(onSideline(moved, left: true), 0, accuracy: 1e-12, "still on the sideline")
        // Three tenths of the way down, as it was: it took seven tenths of the far corner's move.
        XCTAssertEqual(moved.court.netLeft.x, start.court.netLeft.x + 0.7 * 0.05, accuracy: 1e-12)
        XCTAssertEqual(moved.court.netLeft.y, start.court.netLeft.y + 0.7 * 0.04, accuracy: 1e-12)
    }

    func testACentreLinePointSlidesAlongItsSidelineAndNowhereElse() {
        let start = CalibrationWorkingShapes.courtOutline
        var moved = start
        // Dragged straight across the picture: only the part of that along the sideline counts.
        moved.moveOutline(.handle(.court(.netRight)), from: start, dx: 0.10, dy: 0)
        XCTAssertNotEqual(moved.court.netRight.x, start.court.netRight.x)
        XCTAssertEqual(onSideline(moved, left: false), 0, accuracy: 1e-12)
        for role in CourtLayout.Role.allCases where role != .netRight { XCTAssertEqual(moved.court[role], start.court[role], "\(role)") }
        // Dragged far past the near corner: it stops short of it.
        moved.moveOutline(.handle(.court(.netRight)), from: start, dx: 5, dy: -5)
        XCTAssertEqual(onSideline(moved, left: false), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(moved.court.netRight.y, start.court.nearRight.y)
        XCTAssertLessThan(moved.court.netRight.x, start.court.nearRight.x)
    }

    func testLinesMoveTheOutlineAsLines() {
        let start = CalibrationWorkingShapes.courtOutline
        // The far end line: both far corners, and both centre-line points follow their sidelines.
        var moved = start
        moved.moveOutline(.edge(.court(.farLeft), .court(.farRight)), from: start, dx: 0, dy: 0.05)
        XCTAssertEqual(moved.court.farLeft.y, start.court.farLeft.y + 0.05, accuracy: 1e-12)
        XCTAssertEqual(moved.court.farRight.y, start.court.farRight.y + 0.05, accuracy: 1e-12)
        XCTAssertEqual(moved.court.nearLeft, start.court.nearLeft)
        XCTAssertEqual(onSideline(moved, left: true), 0, accuracy: 1e-12)
        XCTAssertEqual(onSideline(moved, left: false), 0, accuracy: 1e-12)
        // Half a sideline taken hold of: the whole sideline moves, the other one stays.
        moved = start
        moved.moveOutline(.edge(.court(.netLeft), .court(.farLeft)), from: start, dx: -0.04, dy: 0.01)
        for role in [CourtLayout.Role.nearLeft, .netLeft, .farLeft] {
            XCTAssertEqual(moved.court[role].x, start.court[role].x - 0.04, accuracy: 1e-12, "\(role)")
            XCTAssertEqual(moved.court[role].y, start.court[role].y + 0.01, accuracy: 1e-12, "\(role)")
        }
        for role in [CourtLayout.Role.nearRight, .netRight, .farRight] { XCTAssertEqual(moved.court[role], start.court[role], "\(role)") }
        // The centre line: both its points slide, each along its own sideline.
        moved = start
        moved.moveOutline(.edge(.court(.netLeft), .court(.netRight)), from: start, dx: 0, dy: -0.05)
        XCTAssertLessThan(moved.court.netLeft.y, start.court.netLeft.y)
        XCTAssertLessThan(moved.court.netRight.y, start.court.netRight.y)
        XCTAssertEqual(onSideline(moved, left: true), 0, accuracy: 1e-12)
        XCTAssertEqual(onSideline(moved, left: false), 0, accuracy: 1e-12)
        for role in [CourtLayout.Role.nearLeft, .nearRight, .farLeft, .farRight] { XCTAssertEqual(moved.court[role], start.court[role], "\(role)") }
        // The whole outline: every point by the same amount.
        moved = start
        moved.moveOutline(.shape, from: start, dx: 0.03, dy: 0.02)
        for role in CourtLayout.Role.allCases {
            XCTAssertEqual(moved.court[role].x, start.court[role].x + 0.03, accuracy: 1e-12, "\(role)")
            XCTAssertEqual(moved.court[role].y, start.court[role].y + 0.02, accuracy: 1e-12, "\(role)")
        }
    }

    func testACentreLinePointThatWasNotQuiteOnItsSidelineKeepsThatWhenACornerMoves() {
        // A court marked point by point before the outline: its centre-line points are near the sidelines, not on them.
        let start = CalibrationWorkingShapes(court: CalibrationFixtures.court)
        let off = onSideline(start, left: false)
        XCTAssertGreaterThan(off, 1e-4)
        var moved = start
        moved.moveOutline(.shape, from: start, dx: 0.02, dy: 0.01)
        XCTAssertEqual(onSideline(moved, left: false), off, accuracy: 1e-12, "moved whole, it is as far off as it was")
        XCTAssertEqual(moved.court.netRight.x, start.court.netRight.x + 0.02, accuracy: 1e-12)
    }

    func testANetCornerBeingPutDownIsNoPointToMoveAndThePictureIsNotPanned() {
        XCTAssertEqual(CalibrationWorkingShapes.handles(moved: .place(.net(2)), target: .net), [])
    }
}
