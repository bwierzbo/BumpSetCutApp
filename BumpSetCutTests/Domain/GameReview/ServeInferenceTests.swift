//
//  ServeInferenceTests.swift
//  BumpSetCutTests
//

import XCTest
import CoreMedia
@testable import BumpSetCut

final class ServeInferenceTests: XCTestCase {

    private let defaultSetup = GameSetup(
        firstServer: .near, switchInterval: 7,
        switchEnabled: true, scoringMode: .rallyScoring
    )

    private func makeSegment(start: Double, end: Double, trend: Double? = nil) -> RallySegment {
        RallySegment(
            startTimeSeconds: start, endTimeSeconds: end,
            confidence: 0.9, quality: 0.8,
            detectionCount: 10, averageTrajectoryLength: 5.0,
            ballSizeTrend: trend
        )
    }

    // MARK: - First Rally Uses Setup Server

    func testFirstRally_UsesSetupServer() {
        let segments = [makeSegment(start: 0, end: 5)]
        let inferences = ServeInferenceService.inferServes(segments: segments, setup: defaultSetup)

        XCTAssertEqual(inferences.count, 1)
        XCTAssertEqual(inferences[0].inferredServer, .near)
        XCTAssertEqual(inferences[0].method, .firstRallySetup)
        XCTAssertEqual(inferences[0].confidence, 1.0)
    }

    func testFirstRally_UsesSetupServer_Far() {
        let farSetup = GameSetup(firstServer: .far, switchInterval: 7, switchEnabled: true, scoringMode: .rallyScoring)
        let segments = [makeSegment(start: 0, end: 5)]
        let inferences = ServeInferenceService.inferServes(segments: segments, setup: farSetup)

        XCTAssertEqual(inferences[0].inferredServer, .far)
    }

    // MARK: - Previous Winner Serves

    func testSubsequentRallies_UsePreviousWinner() {
        let segments = [
            makeSegment(start: 0, end: 5),
            makeSegment(start: 10, end: 15),
            makeSegment(start: 20, end: 25)
        ]

        let decisions = [
            RallyScoringDecision(
                rallyIndex: 0, pointWinner: .far, server: .near,
                serveInference: ServeInference(rallyIndex: 0, bboxSizeSlope: 0, sampleCount: 0, inferredServer: .near, confidence: 1.0, method: .firstRallySetup),
                isManuallyOverridden: false, scoreAfter: GameScore(near: 0, far: 1)
            )
        ]

        let inferences = ServeInferenceService.inferServes(segments: segments, setup: defaultSetup, decisions: decisions)

        XCTAssertEqual(inferences[0].inferredServer, .near) // setup
        XCTAssertEqual(inferences[1].inferredServer, .far)  // previous winner
        XCTAssertEqual(inferences[1].method, .previousPointWinner)
    }

    // MARK: - Bbox Trend Fallback

    func testBboxTrend_PositiveSlope_FarServed() {
        let segments = [
            makeSegment(start: 0, end: 5),
            makeSegment(start: 10, end: 15, trend: 0.05) // positive = approaching = far served
        ]

        let inferences = ServeInferenceService.inferServes(segments: segments, setup: defaultSetup)

        XCTAssertEqual(inferences[1].inferredServer, .far)
        XCTAssertEqual(inferences[1].method, .bboxTrend)
    }

    func testBboxTrend_NegativeSlope_NearServed() {
        let segments = [
            makeSegment(start: 0, end: 5),
            makeSegment(start: 10, end: 15, trend: -0.03) // negative = receding = near served
        ]

        let inferences = ServeInferenceService.inferServes(segments: segments, setup: defaultSetup)

        XCTAssertEqual(inferences[1].inferredServer, .near)
        XCTAssertEqual(inferences[1].method, .bboxTrend)
    }

    // MARK: - Edge Cases

    func testEmptySegments() {
        let inferences = ServeInferenceService.inferServes(segments: [], setup: defaultSetup)
        XCTAssertTrue(inferences.isEmpty)
    }

    func testSingleRally() {
        let segments = [makeSegment(start: 0, end: 5)]
        let inferences = ServeInferenceService.inferServes(segments: segments, setup: defaultSetup)
        XCTAssertEqual(inferences.count, 1)
    }

    func testZeroSlope_FallsThroughToDefault() {
        let segments = [
            makeSegment(start: 0, end: 5),
            makeSegment(start: 10, end: 15, trend: 0.0) // zero slope
        ]

        let inferences = ServeInferenceService.inferServes(segments: segments, setup: defaultSetup)

        // Should fall through to default (previous inference's server or setup default)
        XCTAssertEqual(inferences[1].method, .bboxTrend)
        XCTAssertEqual(inferences[1].confidence, 0.3) // Low confidence fallback
    }

    func testMissingTrend_FallsThroughToDefault() {
        let segments = [
            makeSegment(start: 0, end: 5),
            makeSegment(start: 10, end: 15, trend: nil) // no trend data
        ]

        let inferences = ServeInferenceService.inferServes(segments: segments, setup: defaultSetup)

        XCTAssertEqual(inferences[1].method, .bboxTrend)
        XCTAssertEqual(inferences[1].confidence, 0.3)
    }
}
