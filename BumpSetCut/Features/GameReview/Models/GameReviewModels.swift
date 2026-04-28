//
//  GameReviewModels.swift
//  BumpSetCut
//
//  Game Review mode data models for score tracking and rally review.
//

import Foundation

// MARK: - Court Side

enum CourtSide: String, Codable, CaseIterable {
    case near
    case far

    var opposite: CourtSide {
        switch self {
        case .near: return .far
        case .far: return .near
        }
    }

    var displayName: String {
        switch self {
        case .near: return "Near"
        case .far: return "Far"
        }
    }
}

// MARK: - Scoring Mode

enum ScoringMode: String, Codable, CaseIterable {
    case rallyScoring
    case sideoutScoring

    var displayName: String {
        switch self {
        case .rallyScoring: return "Rally Scoring"
        case .sideoutScoring: return "Sideout Scoring"
        }
    }
}

// MARK: - Game Setup

struct GameSetup: Codable, Equatable {
    let firstServer: CourtSide
    let switchInterval: Int
    let switchEnabled: Bool
    let scoringMode: ScoringMode

    // Backward-compatible decoding: old saved states may contain gameToScore
    init(firstServer: CourtSide, switchInterval: Int, switchEnabled: Bool, scoringMode: ScoringMode) {
        self.firstServer = firstServer
        self.switchInterval = switchInterval
        self.switchEnabled = switchEnabled
        self.scoringMode = scoringMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firstServer = try container.decode(CourtSide.self, forKey: .firstServer)
        switchInterval = try container.decode(Int.self, forKey: .switchInterval)
        switchEnabled = try container.decode(Bool.self, forKey: .switchEnabled)
        scoringMode = try container.decode(ScoringMode.self, forKey: .scoringMode)
        // gameToScore silently ignored if present
    }

    private enum CodingKeys: String, CodingKey {
        case firstServer, switchInterval, switchEnabled, scoringMode
    }
}

// MARK: - Inference Method

enum InferenceMethod: String, Codable {
    case bboxTrend
    case previousPointWinner
    case manualOverride
    case firstRallySetup
}

// MARK: - Serve Inference

struct ServeInference: Codable, Equatable {
    let rallyIndex: Int
    let bboxSizeSlope: Double
    let sampleCount: Int
    let inferredServer: CourtSide
    let confidence: Double
    let method: InferenceMethod
}

// MARK: - Game Score

struct GameScore: Codable, Equatable {
    var near: Int = 0
    var far: Int = 0

    func score(for side: CourtSide) -> Int {
        switch side {
        case .near: return near
        case .far: return far
        }
    }

    mutating func increment(side: CourtSide) {
        switch side {
        case .near: near += 1
        case .far: far += 1
        }
    }

    var totalPoints: Int { near + far }
    var maxScore: Int { max(near, far) }
    var lead: Int { abs(near - far) }
}

// MARK: - Rally Scoring Decision

struct RallyScoringDecision: Codable, Equatable {
    let rallyIndex: Int
    let pointWinner: CourtSide
    let server: CourtSide
    let serveInference: ServeInference
    let isManuallyOverridden: Bool
    let scoreAfter: GameScore
}

// MARK: - Game Review State

struct GameReviewState: Codable {
    let videoId: UUID
    let setup: GameSetup
    var decisions: [RallyScoringDecision]
    var currentRallyIndex: Int
    let createdDate: Date
    var lastModifiedDate: Date
}
