//
//  GameScoring.swift
//  BumpSetCut
//
//  Manual game scoring: per-rally point winners, set boundaries, and the
//  deterministic engine that turns them into running scoreboards. Stored as
//  an index-keyed sidecar (like trims/selections) so it survives dismissal
//  and must be remapped through timeline edits. Phase 2 will pre-fill
//  winners from serve-side detection; the manual layer stays as correction.
//

import Foundation

// MARK: - Teams

struct GameTeam: Codable, Equatable {
    var name: String
    /// Hex color ("#RRGGBB") — kept as a string so the model stays UI-framework free.
    var colorHex: String
}

// MARK: - Point Winner

enum GamePointWinner: String, Codable {
    case teamA
    case teamB
}

// MARK: - Game Scoring Sidecar

struct GameScoring: Codable, Equatable {
    var teamA: GameTeam
    var teamB: GameTeam
    /// Rally index → who won that point. Absent = not scored (score carries over).
    var pointWinners: [Int: GamePointWinner]
    /// Rally indices that START a new set (index 0 is implicitly a set start).
    var setBreaks: Set<Int>

    init(
        teamA: GameTeam = GameTeam(name: "Home", colorHex: "#F97316"),
        teamB: GameTeam = GameTeam(name: "Away", colorHex: "#3B82F6"),
        pointWinners: [Int: GamePointWinner] = [:],
        setBreaks: Set<Int> = []
    ) {
        self.teamA = teamA
        self.teamB = teamB
        self.pointWinners = pointWinners
        self.setBreaks = setBreaks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        teamA = try container.decode(GameTeam.self, forKey: .teamA)
        teamB = try container.decode(GameTeam.self, forKey: .teamB)
        pointWinners = try container.decodeIfPresent([Int: GamePointWinner].self, forKey: .pointWinners) ?? [:]
        setBreaks = try container.decodeIfPresent(Set<Int>.self, forKey: .setBreaks) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case teamA, teamB, pointWinners, setBreaks
    }
}

// MARK: - Score State

/// The scoreboard shown DURING a rally: points in the current set and sets
/// won, before that rally's point is decided.
struct GameScoreState: Equatable {
    var scoreA: Int = 0
    var scoreB: Int = 0
    var setsA: Int = 0
    var setsB: Int = 0
}

// MARK: - Score Engine

enum GameScoreEngine {

    /// Scoreboard state during each rally: `states[i]` is what the score reads
    /// while rally `i` plays (its own point hasn't been awarded yet). A set
    /// break before rally `i` awards the finished set to its leader (ties
    /// award nothing) and resets the points.
    static func states(for scoring: GameScoring, rallyCount: Int) -> [GameScoreState] {
        var states: [GameScoreState] = []
        states.reserveCapacity(rallyCount)
        var current = GameScoreState()

        for index in 0..<rallyCount {
            if index != 0 && scoring.setBreaks.contains(index) {
                awardSet(&current)
            }
            states.append(current)
            switch scoring.pointWinners[index] {
            case .teamA: current.scoreA += 1
            case .teamB: current.scoreB += 1
            case nil: break
            }
        }
        return states
    }

    /// Score after the last rally's point (for the viewer's summary and any
    /// export end card).
    static func finalState(for scoring: GameScoring, rallyCount: Int) -> GameScoreState {
        var current = GameScoreState()
        for index in 0..<rallyCount {
            if index != 0 && scoring.setBreaks.contains(index) {
                awardSet(&current)
            }
            switch scoring.pointWinners[index] {
            case .teamA: current.scoreA += 1
            case .teamB: current.scoreB += 1
            case nil: break
            }
        }
        return current
    }

    private static func awardSet(_ state: inout GameScoreState) {
        if state.scoreA > state.scoreB {
            state.setsA += 1
        } else if state.scoreB > state.scoreA {
            state.setsB += 1
        }
        state.scoreA = 0
        state.scoreB = 0
    }
}
