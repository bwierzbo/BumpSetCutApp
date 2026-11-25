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
