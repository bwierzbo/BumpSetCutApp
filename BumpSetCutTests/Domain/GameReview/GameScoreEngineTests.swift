//
//  GameScoreEngineTests.swift
//  BumpSetCutTests
//

import XCTest
@testable import BumpSetCut

final class GameScoreEngineTests: XCTestCase {

    // MARK: - Rally Scoring Mode

    func testRallyScoring_BothTeamsCanScore() {
        let setup = GameSetup(firstServer: .near, switchInterval: 5, switchEnabled: false, scoringMode: .rallyScoring)
        var engine = GameScoreEngine(setup: setup)

        // Near serves and wins
        let s1 = engine.awardPoint(to: .near, server: .near)
        XCTAssertEqual(s1.near, 1)
        XCTAssertEqual(s1.far, 0)

        // Far wins (even though near is serving) — in rally scoring, anyone scores
        let s2 = engine.awardPoint(to: .far, server: .near)
        XCTAssertEqual(s2.near, 1)
        XCTAssertEqual(s2.far, 1)
    }

    func testRallyScoring_ServerChangesToWinner() {
        let setup = GameSetup(firstServer: .near, switchInterval: 5, switchEnabled: false, scoringMode: .rallyScoring)
        var engine = GameScoreEngine(setup: setup)

        XCTAssertEqual(engine.currentServer, .near)

        engine.awardPoint(to: .far, server: .near)
        XCTAssertEqual(engine.currentServer, .far)

        engine.awardPoint(to: .far, server: .far)
        XCTAssertEqual(engine.currentServer, .far)

        engine.awardPoint(to: .near, server: .far)
        XCTAssertEqual(engine.currentServer, .near)
    }

    // MARK: - Sideout Scoring Mode

    func testSideoutScoring_OnlyServerScores() {
        let setup = GameSetup(firstServer: .near, switchInterval: 5, switchEnabled: false, scoringMode: .sideoutScoring)
        var engine = GameScoreEngine(setup: setup)

        // Server wins: they score
        let s1 = engine.awardPoint(to: .near, server: .near)
        XCTAssertEqual(s1.near, 1)
        XCTAssertEqual(s1.far, 0)

        // Receiver wins: no score, just sideout
        let s2 = engine.awardPoint(to: .far, server: .near)
        XCTAssertEqual(s2.near, 1)
        XCTAssertEqual(s2.far, 0) // No score for sideout
        XCTAssertEqual(engine.currentServer, .far) // Server switches
    }

    func testSideoutScoring_SideoutChangesServer() {
        let setup = GameSetup(firstServer: .near, switchInterval: 5, switchEnabled: false, scoringMode: .sideoutScoring)
        var engine = GameScoreEngine(setup: setup)

        XCTAssertEqual(engine.currentServer, .near)

        // Sideout: far wins while near serves
        engine.awardPoint(to: .far, server: .near)
        XCTAssertEqual(engine.currentServer, .far)
        XCTAssertEqual(engine.score.far, 0) // No point scored on sideout

        // Now far serves and wins
        engine.awardPoint(to: .far, server: .far)
        XCTAssertEqual(engine.score.far, 1)
    }

    // MARK: - Side Switching

    func testSideSwitching() {
        let setup = GameSetup(firstServer: .near, switchInterval: 5, switchEnabled: true, scoringMode: .rallyScoring)
        var engine = GameScoreEngine(setup: setup)

        XCTAssertEqual(engine.nearMappedTo, .near)

        // Score 5 points
        for _ in 0..<5 {
            engine.awardPoint(to: .near, server: .near)
        }
        // After 5 total points, sides should switch
        XCTAssertEqual(engine.nearMappedTo, .far)
    }

    func testSideSwitching_Disabled() {
        let setup = GameSetup(firstServer: .near, switchInterval: 5, switchEnabled: false, scoringMode: .rallyScoring)
        var engine = GameScoreEngine(setup: setup)

        for _ in 0..<10 {
            engine.awardPoint(to: .near, server: .near)
        }
        XCTAssertEqual(engine.nearMappedTo, .near) // No switch
    }

    // MARK: - Replay

    func testReplay_MatchesSequential() {
        let setup = GameSetup(firstServer: .near, switchInterval: 7, switchEnabled: true, scoringMode: .rallyScoring)

        // Build decisions
        var engine1 = GameScoreEngine(setup: setup)
        var decisions: [RallyScoringDecision] = []

        let plays: [(winner: CourtSide, server: CourtSide)] = [
            (.near, .near), (.far, .near), (.near, .far), (.near, .near), (.far, .near)
        ]

        for (i, play) in plays.enumerated() {
            let score = engine1.awardPoint(to: play.winner, server: play.server)
            decisions.append(RallyScoringDecision(
                rallyIndex: i,
                pointWinner: play.winner,
                server: play.server,
                serveInference: ServeInference(
                    rallyIndex: i, bboxSizeSlope: 0, sampleCount: 0,
                    inferredServer: play.server, confidence: 1.0, method: .firstRallySetup
                ),
                isManuallyOverridden: false,
                scoreAfter: score
            ))
        }

        // Replay should match
        let engine2 = GameScoreEngine.replay(decisions: decisions, setup: setup)
        XCTAssertEqual(engine1.score, engine2.score)
        XCTAssertEqual(engine1.currentServer, engine2.currentServer)
    }

    // MARK: - Standard Game Scenarios

    func testFullGame_15Points() {
        let setup = GameSetup(firstServer: .near, switchInterval: 5, switchEnabled: true, scoringMode: .rallyScoring)
        var engine = GameScoreEngine(setup: setup)

        for _ in 0..<15 {
            engine.awardPoint(to: .near, server: .near)
        }
        XCTAssertEqual(engine.score.near, 15)
        XCTAssertEqual(engine.score.far, 0)
        XCTAssertEqual(engine.totalPointsAwarded, 15)
    }

    func testFullGame_AlternatingScores() {
        let setup = GameSetup(firstServer: .near, switchInterval: 7, switchEnabled: true, scoringMode: .rallyScoring)
        var engine = GameScoreEngine(setup: setup)

        for _ in 0..<20 {
            engine.awardPoint(to: .near, server: .near)
            engine.awardPoint(to: .far, server: .far)
        }
        XCTAssertEqual(engine.score, GameScore(near: 20, far: 20))
        XCTAssertEqual(engine.totalPointsAwarded, 40)
    }
}
