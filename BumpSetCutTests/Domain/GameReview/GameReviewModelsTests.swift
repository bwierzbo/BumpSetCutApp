//
//  GameReviewModelsTests.swift
//  BumpSetCutTests
//

import XCTest
@testable import BumpSetCut

final class GameReviewModelsTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - CourtSide

    func testCourtSide_Opposite() {
        XCTAssertEqual(CourtSide.near.opposite, .far)
        XCTAssertEqual(CourtSide.far.opposite, .near)
    }

    func testCourtSide_DisplayName() {
        XCTAssertEqual(CourtSide.near.displayName, "Near")
        XCTAssertEqual(CourtSide.far.displayName, "Far")
    }

    // MARK: - GameScore

    func testGameScore_Increment() {
        var score = GameScore()
        score.increment(side: .near)
        XCTAssertEqual(score.near, 1)
        XCTAssertEqual(score.far, 0)

        score.increment(side: .far)
        score.increment(side: .far)
        XCTAssertEqual(score.far, 2)
    }

    func testGameScore_Computed() {
        let score = GameScore(near: 15, far: 12)
        XCTAssertEqual(score.totalPoints, 27)
        XCTAssertEqual(score.maxScore, 15)
        XCTAssertEqual(score.lead, 3)
        XCTAssertEqual(score.score(for: .near), 15)
        XCTAssertEqual(score.score(for: .far), 12)
    }

    // MARK: - JSON Round-Trip

    func testGameSetup_JSONRoundTrip() throws {
        let setup = GameSetup(firstServer: .far, switchInterval: 7, switchEnabled: true, scoringMode: .sideoutScoring)
        let data = try encoder.encode(setup)
        let decoded = try decoder.decode(GameSetup.self, from: data)
        XCTAssertEqual(decoded, setup)
    }

    func testGameScore_JSONRoundTrip() throws {
        let score = GameScore(near: 10, far: 8)
        let data = try encoder.encode(score)
        let decoded = try decoder.decode(GameScore.self, from: data)
        XCTAssertEqual(decoded, score)
    }

    func testServeInference_JSONRoundTrip() throws {
        let inference = ServeInference(
            rallyIndex: 3, bboxSizeSlope: 0.025,
            sampleCount: 12, inferredServer: .far,
            confidence: 0.85, method: .bboxTrend
        )
        let data = try encoder.encode(inference)
        let decoded = try decoder.decode(ServeInference.self, from: data)
        XCTAssertEqual(decoded, inference)
    }

    func testRallyScoringDecision_JSONRoundTrip() throws {
        let decision = RallyScoringDecision(
            rallyIndex: 0,
            pointWinner: .near,
            server: .near,
            serveInference: ServeInference(
                rallyIndex: 0, bboxSizeSlope: 0, sampleCount: 0,
                inferredServer: .near, confidence: 1.0, method: .firstRallySetup
            ),
            isManuallyOverridden: false,
            scoreAfter: GameScore(near: 1, far: 0)
        )
        let data = try encoder.encode(decision)
        let decoded = try decoder.decode(RallyScoringDecision.self, from: data)
        XCTAssertEqual(decoded, decision)
    }

    func testGameReviewState_JSONRoundTrip() throws {
        let state = GameReviewState(
            videoId: UUID(),
            setup: GameSetup(firstServer: .near, switchInterval: 7, switchEnabled: true, scoringMode: .rallyScoring),
            decisions: [],
            currentRallyIndex: 5,
            createdDate: Date(),
            lastModifiedDate: Date()
        )
        let data = try encoder.encode(state)
        let decoded = try decoder.decode(GameReviewState.self, from: data)
        XCTAssertEqual(decoded.videoId, state.videoId)
        XCTAssertEqual(decoded.currentRallyIndex, 5)
        XCTAssertEqual(decoded.setup, state.setup)
    }

    // MARK: - RallySegment Backward Compatibility

    func testRallySegment_BackwardCompat_NoBallSizeTrend() throws {
        // Simulate old JSON without ballSizeTrend
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789abc",
            "startTime": 10.5,
            "endTime": 15.2,
            "confidence": 0.9,
            "quality": 0.8,
            "detectionCount": 25,
            "averageTrajectoryLength": 5.0
        }
        """.data(using: .utf8)!

        let segment = try decoder.decode(RallySegment.self, from: json)
        XCTAssertNil(segment.ballSizeTrend)
        XCTAssertEqual(segment.startTime, 10.5)
        XCTAssertEqual(segment.endTime, 15.2)
    }

    func testRallySegment_WithBallSizeTrend() throws {
        let segment = RallySegment(
            startTimeSeconds: 10.0, endTimeSeconds: 15.0,
            confidence: 0.9, quality: 0.8,
            detectionCount: 20, averageTrajectoryLength: 4.0,
            ballSizeTrend: 0.035
        )
        let data = try encoder.encode(segment)
        let decoded = try decoder.decode(RallySegment.self, from: data)
        XCTAssertEqual(decoded.ballSizeTrend, 0.035)
    }
}
