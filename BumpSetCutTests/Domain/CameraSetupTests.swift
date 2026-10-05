//
//  CameraSetupTests.swift
//  BumpSetCutTests
//
//  Camera position picked before processing: zone from the viewing angle,
//  pin placement, the angle-dependent rule changes, and backwards-compatible
//  decoding of the places it's stored.
//

import XCTest
import CoreGraphics
@testable import BumpSetCut

final class CameraSetupTests: XCTestCase {

    func testRecommendedIsAnEndLineViewStraightDownTheCourt() {
        XCTAssertEqual(CameraSetup.recommended.zone, .endline)
        XCTAssertEqual(CameraSetup.recommended.viewingAngleDegrees, 0, accuracy: 0.001)
        XCTAssertEqual(CameraSetup.recommended.height, .raised)
    }

    func testZoneFollowsTheViewingAngle() {
        // Off-centre behind the end line is still an end-line view.
        XCTAssertEqual(CameraSetup(position: CGPoint(x: 0.6, y: -1.3), height: .ground).zone, .endline)
        // Level with the net, beside the court: side-on.
        let side = CameraSetup(position: CGPoint(x: 1.7, y: 0), height: .raised)
        XCTAssertEqual(side.zone, .sideline)
        XCTAssertEqual(side.viewingAngleDegrees, 90, accuracy: 0.001)
        // Off a corner: diagonal.
        XCTAssertEqual(CameraSetup(position: CGPoint(x: 1.4, y: -1.25), height: .raised).zone, .corner)
    }

    func testEachPresetLandsInItsZone() {
        for zone in CameraZone.allCases {
            XCTAssertEqual(CameraSetup(position: zone.presetPosition, height: .raised).zone, zone)
        }
    }

    func testAngleUsesTheCourtsRealProportions() {
        // One half-width across and one half-length along is 1 : 2 in metres,
        // so the angle is atan(1/2) ≈ 26.6°, not 45°.
        let setup = CameraSetup(position: CGPoint(x: 1.2, y: 1.2), height: .raised)
        XCTAssertEqual(setup.viewingAngleDegrees, atan2(1.2, 2.4) * 180 / .pi, accuracy: 0.001)
    }

    func testPinOnTheCourtMovesOutThroughTheNearerEdge() {
        // Near a sideline (in metres): out through the sideline.
        let nearSide = CameraSetup(position: CGPoint(x: 0.9, y: 0.2), height: .raised).position
        XCTAssertGreaterThan(abs(nearSide.x), 1)
        XCTAssertEqual(nearSide.y, 0.2, accuracy: 0.001)
        // Near an end line: out through the end line.
        let nearEnd = CameraSetup(position: CGPoint(x: 0.1, y: -0.95), height: .raised).position
        XCTAssertLessThan(nearEnd.y, -1)
        XCTAssertEqual(nearEnd.x, 0.1, accuracy: 0.001)
    }

    func testPinFarAwayIsBroughtBackWithinReach() {
        let far = CameraSetup(position: CGPoint(x: 9, y: -9), height: .raised).position
        XCTAssertEqual(far.x, CameraSetup.maxReach.width, accuracy: 0.001)
        XCTAssertEqual(far.y, -CameraSetup.maxReach.height, accuracy: 0.001)
    }

    // MARK: - Angle-dependent rules

    func testEndLineAndUnknownKeepTheRulesAsTheyAre() {
        let base = ProcessorConfig()
        for setup in [nil, CameraSetup.recommended] {
            var config = ProcessorConfig()
            config.applyCamera(setup)
            XCTAssertEqual(config.enableOffCourtRejection, base.enableOffCourtRejection)
            XCTAssertEqual(config.multiCourtSpatialLockEnabled, base.multiCourtSpatialLockEnabled)
            XCTAssertEqual(config.multiCourtMaxLateralDistance, base.multiCourtMaxLateralDistance)
        }
    }

    func testCornerAndSidelineDropTheNetWidthRules() {
        var corner = ProcessorConfig()
        corner.applyCamera(CameraSetup(position: CameraZone.corner.presetPosition, height: .raised))
        XCTAssertFalse(corner.enableOffCourtRejection)
        XCTAssertTrue(corner.multiCourtSpatialLockEnabled)
        XCTAssertGreaterThan(corner.multiCourtMaxLateralDistance, ProcessorConfig().multiCourtMaxLateralDistance)

        var side = ProcessorConfig()
        side.applyCamera(CameraSetup(position: CameraZone.sideline.presetPosition, height: .raised))
        XCTAssertFalse(side.enableOffCourtRejection)
        XCTAssertFalse(side.multiCourtSpatialLockEnabled)
        // Height comparisons still hold side-on.
        XCTAssertTrue(side.enableAboveNetRequirement)
        XCTAssertTrue(side.enableUnderNetRejection)
    }

    func testCameraIsPartOfTheCheckpointHash() {
        var side = ProcessorConfig()
        side.applyCamera(CameraSetup(position: CameraZone.sideline.presetPosition, height: .raised))
        XCTAssertNotEqual(ProcessingCheckpoint.hash(of: side), ProcessingCheckpoint.hash(of: ProcessorConfig()))
    }

    // MARK: - Stored forms

    func testSetupRoundTrips() throws {
        let setup = CameraSetup(position: CGPoint(x: -1.5, y: 0.4), height: .ground)
        let decoded = try JSONDecoder().decode(CameraSetup.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(decoded, setup)
    }

    func testRallySegmentWithoutServeBallXStillDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","startTime":1,"endTime":5,"confidence":0.8,"quality":0.7,"detectionCount":12,"averageTrajectoryLength":1.5,"ballSizeTrend":0.2}"#
        let segment = try JSONDecoder().decode(RallySegment.self, from: Data(json.utf8))
        XCTAssertNil(segment.serveBallX)
        XCTAssertEqual(segment.ballSizeTrend, 0.2)
    }

    func testRallySegmentKeepsServeBallXThroughRetiming() {
        let segment = RallySegment(startTimeSeconds: 1, endTimeSeconds: 5, confidence: 0.8, quality: 0.7,
                                   detectionCount: 12, averageTrajectoryLength: 1.5,
                                   ballSizeTrend: nil, serveBallX: 0.31)
        XCTAssertEqual(segment.withAdjustedTimes(startSeconds: 2, endSeconds: 6).serveBallX, 0.31)
    }
}
