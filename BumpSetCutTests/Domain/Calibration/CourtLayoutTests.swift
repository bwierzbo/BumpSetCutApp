//
//  CourtLayoutTests.swift
//  BumpSetCutTests
//
//  court_geometry_v1: the perspective maps of each court half, points outside the frame,
//  points nobody could place, and the shapes that are refused.
//

import XCTest
@testable import BumpSetCut

final class CourtLayoutTests: XCTestCase {
    private let court = CalibrationFixtures.court
    private func point(_ x: Double, _ y: Double, _ s: CourtPoint.Status = .seen) -> CourtPoint { CalibrationFixtures.point(x, y, s) }

    func testEachHalfMapsItsCornersExactly() throws {
        XCTAssertTrue(court.isUsable, "\(court.problems)")
        for role in CourtLayout.Role.allCases {
            let image = try XCTUnwrap(court.image(u: role.court.u, v: role.court.v))
            XCTAssertEqual(image.x, court[role].x, accuracy: 1e-9, role.rawValue)
            XCTAssertEqual(image.y, court[role].y, accuracy: 1e-9, role.rawValue)
        }
    }

    func testPerspectiveIsNotLinearAlongTheCourt() throws {
        // Halfway along the near half on the ground is nearer the net on screen than the screen midpoint is.
        let mid = try XCTUnwrap(court.image(u: 0.5, v: 0.25))
        XCTAssertEqual(mid.x, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(mid.y, (0.10 + 0.45) / 2 + 0.01)
    }

    func testImagePointsRoundTripThroughCourtCoordinates() throws {
        for (u, v) in [(0.2, 0.1), (0.8, 0.4), (0.5, 0.5), (0.3, 0.7), (0.9, 0.95)] {
            let image = try XCTUnwrap(court.image(u: u, v: v))
            let back = try XCTUnwrap(court.courtCoordinates(image.x, image.y))
            XCTAssertEqual(back.u, u, accuracy: 1e-7)
            XCTAssertEqual(back.v, v, accuracy: 1e-7)
        }
    }

    func testAStronglyTaperedFarHalfStillMapsBothWays() throws {
        // The far end line a fifth as wide as the net line: the far half's map, fitted with its free term fixed at the
        // court's near-left corner (outside that half), comes out with negative weights all over the half.
        var steep = court
        steep.farLeft = point(0.45, 0.65)
        steep.farRight = point(0.55, 0.65)
        XCTAssertEqual(steep.problems, [])
        for role in CourtLayout.Role.allCases {
            let image = try XCTUnwrap(steep.image(u: role.court.u, v: role.court.v), role.rawValue)
            XCTAssertEqual(image.x, steep[role].x, accuracy: 1e-9, role.rawValue)
            XCTAssertEqual(image.y, steep[role].y, accuracy: 1e-9, role.rawValue)
        }
        let farLeft = try XCTUnwrap(steep.courtCoordinates(0.45, 0.65))
        XCTAssertEqual(farLeft.u, 0, accuracy: 1e-7)
        XCTAssertEqual(farLeft.v, 1, accuracy: 1e-7)
        let inside = try XCTUnwrap(steep.image(u: 0.3, v: 0.8))
        let back = try XCTUnwrap(steep.courtCoordinates(inside.x, inside.y))
        XCTAssertEqual(back.u, 0.3, accuracy: 1e-7)
        XCTAssertEqual(back.v, 0.8, accuracy: 1e-7)
        XCTAssertEqual(steep.outline([(0, 0), (1, 0), (1, 1), (0, 1)], steps: 4).count, 16)
        // Each half's map has a positive weight across its own half.
        for (near, vs) in [(true, [0.0, 0.25, 0.5]), (false, [0.5, 0.75, 1.0])] {
            let map = try XCTUnwrap(steep.map(near: near))
            for v in vs { for u in [0.0, 0.5, 1.0] { XCTAssertGreaterThan(map.apply(u, v).w, 0, "near \(near) u \(u) v \(v)") } }
        }
    }

    func testAFarHalfTaperingToHalfItsWidthMaps() throws {
        // Far end line half as wide as the net line: fitted about the court's corner, this half's map has a zero
        // free coefficient and could not be solved at all.
        var half = court
        half.farLeft = point(0.375, 0.65)
        half.farRight = point(0.625, 0.65)
        XCTAssertEqual(half.problems, [])
        XCTAssertNotNil(half.map(near: false))
        for role in CourtLayout.Role.allCases {
            let image = try XCTUnwrap(half.image(u: role.court.u, v: role.court.v), role.rawValue)
            XCTAssertEqual(image.x, half[role].x, accuracy: 1e-9, role.rawValue)
            XCTAssertEqual(image.y, half[role].y, accuracy: 1e-9, role.rawValue)
        }
        let farLeft = try XCTUnwrap(half.courtCoordinates(0.375, 0.65))
        XCTAssertEqual(farLeft.u, 0, accuracy: 1e-7)
        XCTAssertEqual(farLeft.v, 1, accuracy: 1e-7)
    }

    func testTapersOfEveryWidthMapTheirFarCorners() throws {
        // From a far line as wide as the net line down to a tenth of it, in fine steps: no width is a gap.
        for step in 10...100 {
            let halfWidth = 0.25 * Double(step) / 100
            var g = court
            g.farLeft = point(0.5 - halfWidth, 0.65)
            g.farRight = point(0.5 + halfWidth, 0.65)
            let image = try XCTUnwrap(g.image(u: 0, v: 1), "half-width \(halfWidth)")
            XCTAssertEqual(image.x, 0.5 - halfWidth, accuracy: 1e-9, "half-width \(halfWidth)")
            XCTAssertEqual(image.y, 0.65, accuracy: 1e-9, "half-width \(halfWidth)")
            let map = try XCTUnwrap(g.map(near: false))
            XCTAssertGreaterThan(map.apply(0.5, 0.75).w, 0)
        }
    }

    func testThePointsOfTheNetLineRoundTripOnACourtThatIsNotSymmetric() throws {
        // The far-right corner pulled out and up: along the net line the far half counts u differently from the
        // near half, so a point of the line answered by the far half's inverse comes back somewhere else.
        var skew = court
        skew.farRight = point(0.7, 0.8)
        XCTAssertEqual(skew.problems, [])
        for step in 0...20 {
            let u = Double(step) / 20
            let onLine = try XCTUnwrap(skew.image(u: u, v: 0.5))
            let back = try XCTUnwrap(skew.courtCoordinates(onLine.x, onLine.y), "u \(u)")
            XCTAssertEqual(back.u, u, accuracy: 1e-7, "u \(u)")
            XCTAssertEqual(back.v, 0.5, accuracy: 1e-9, "u \(u)")
        }
        // Either side of the line each half still answers for its own points.
        for (u, v) in [(0.5, 0.49), (0.2, 0.499999), (0.5, 0.51), (0.8, 0.500001), (0.3, 0.9)] {
            let image = try XCTUnwrap(skew.image(u: u, v: v))
            let back = try XCTUnwrap(skew.courtCoordinates(image.x, image.y), "\(u), \(v)")
            XCTAssertEqual(back.u, u, accuracy: 1e-6, "\(u), \(v)")
            XCTAssertEqual(back.v, v, accuracy: 1e-6, "\(u), \(v)")
        }
    }

    func testOutlineFollowsTheBoundaryThroughBothHalves() {
        let outline = court.outline([(0, 0), (1, 0), (1, 1), (0, 1)], steps: 4)
        XCTAssertEqual(outline.count, 16)
        // The right sideline's midpoint is the net post foot, as placed — not the corner-to-corner midpoint.
        XCTAssertEqual(outline[6].0, court.netRight.x, accuracy: 1e-9)
        XCTAssertEqual(outline[6].1, court.netRight.y, accuracy: 1e-9)
    }

    func testANearEndLineBelowThePictureIsUsableAndStaysEstimated() {
        var g = court
        g.nearLeft = point(-0.05, -0.40, .estimated)
        g.nearRight = point(1.05, -0.40, .estimated)
        XCTAssertTrue(g.isUsable, "\(g.problems)")
        XCTAssertEqual(g.nearLeft.status, .estimated)
        XCTAssertNotNil(g.map(near: true))
    }

    func testAPointTooFarOutsideIsRefused() {
        var g = court
        g.nearLeft = point(-0.05, -3.0, .estimated)
        XCTAssertEqual(g.problems, ["near left is too far outside the frame"])
    }

    func testUnknownFarCornersLeaveOnlyTheNearHalfMapped() {
        var g = court
        g.farLeft = point(0, 0, .unknown)
        g.farRight = point(0, 0, .unknown)
        XCTAssertTrue(g.isUsable, "\(g.problems)")
        XCTAssertNotNil(g.map(near: true))
        XCTAssertNil(g.map(near: false))
        XCTAssertNotNil(g.image(u: 0.5, v: 0.2))
    }

    func testNoPointsPlacedIsNotUsable() {
        let unknown = point(0, 0, .unknown)
        let g = CourtLayout(nearLeft: unknown, nearRight: unknown, netRight: unknown, netLeft: unknown, farLeft: unknown, farRight: unknown)
        XCTAssertEqual(g.problems, ["neither court half forms a convex four-sided region"])
    }

    func testAFoldedHalfHasNoMap() {
        var g = court
        // The near corners swapped: the near half crosses itself.
        g.nearLeft = court.nearRight
        g.nearRight = court.nearLeft
        XCTAssertNil(g.map(near: true))
        XCTAssertNotNil(g.map(near: false))
    }

    func testHalvesOnTheSameSideOfTheNetLineAreRefused() {
        var g = court
        g.farLeft = point(0.20, 0.30)
        g.farRight = point(0.80, 0.30)
        XCTAssertTrue(g.problems.contains("the near and far halves overlap across the net line"), "\(g.problems)")
    }

    func testMovingAnUnknownPointPlacesItAndKeepsItInReach() {
        var g = court
        g.farLeft = point(0, 0, .unknown)
        let moved = g.moving(.farLeft, to: 0.3, 9)
        XCTAssertEqual(moved.farLeft, point(0.3, CourtLayout.placeableRange.upperBound, .seen))
        XCTAssertEqual(moved.changedRoles(from: g), [.farLeft])
        XCTAssertEqual(court.moving(.netLeft, to: 0.26, 0.45, status: .estimated).netLeft.status, .estimated)
    }

    func testTheSixPointsAreStoredUnderTheirRoleNames() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(court)) as? [String: [String: Any]])
        XCTAssertEqual(Set(json.keys), ["nearLeft", "nearRight", "netRight", "netLeft", "farLeft", "farRight"])
        XCTAssertEqual(json["netLeft"]?["status"] as? String, "seen")
        XCTAssertEqual(json["netLeft"]?["x"] as? Double, 0.25)
        XCTAssertEqual(try JSONDecoder().decode(CourtLayout.self, from: JSONEncoder().encode(court)), court)
    }

    func testCourtSizeFollowsThePersonsAnswers() {
        XCTAssertNil(CourtSetup().spec)
        XCTAssertEqual(CourtSetup(surface: .beach, format: .twos).spec, .beach)
        XCTAssertEqual(CourtSetup(surface: .indoor, format: .sixes).spec, .indoor)
        XCTAssertEqual(CourtSetup(surface: .grass, format: .twos).spec?.lengthM, 16)
        XCTAssertEqual(CourtSetup(surface: .grass, format: .fours).spec?.widthM, 9)
    }
}
