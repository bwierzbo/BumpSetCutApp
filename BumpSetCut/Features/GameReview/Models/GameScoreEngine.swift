//
//  GameScoreEngine.swift
//  BumpSetCut
//
//  Pure value-type state machine for volleyball score tracking.
//

import Foundation

// MARK: - Game Score Engine

struct GameScoreEngine {
    private let setup: GameSetup
    private(set) var score: GameScore = GameScore()
    private(set) var currentServer: CourtSide
    private(set) var nearMappedTo: CourtSide = .near // Tracks side switches
    private(set) var totalPointsAwarded: Int = 0

    init(setup: GameSetup) {
        self.setup = setup
        self.currentServer = setup.firstServer
    }

    // MARK: - Point Awarding

    /// Award a point to the winner. Returns the updated score.
    @discardableResult
    mutating func awardPoint(to winner: CourtSide, server: CourtSide) -> GameScore {
        switch setup.scoringMode {
        case .rallyScoring:
            score.increment(side: winner)
            currentServer = winner

        case .sideoutScoring:
            if winner == server {
                // Serving team wins: they score
                score.increment(side: winner)
            } else {
                // Receiving team wins: sideout, no score
                currentServer = winner
            }
        }

        totalPointsAwarded += 1

        // Check for side switch
        if shouldSwitchSides {
            nearMappedTo = nearMappedTo.opposite
        }

        return score
    }

    // MARK: - Side Switching

    var shouldSwitchSides: Bool {
        guard setup.switchEnabled, setup.switchInterval > 0 else { return false }
        return score.totalPoints > 0 && score.totalPoints % setup.switchInterval == 0
    }

    // MARK: - Replay

    /// Rebuild engine state from a history of decisions.
    static func replay(decisions: [RallyScoringDecision], setup: GameSetup) -> GameScoreEngine {
        var engine = GameScoreEngine(setup: setup)
        for decision in decisions {
            engine.awardPoint(to: decision.pointWinner, server: decision.server)
        }
        return engine
    }
}
