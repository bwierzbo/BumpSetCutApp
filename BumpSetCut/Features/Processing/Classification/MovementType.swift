//
//  MovementType.swift
//  BumpSetCut
//
//  Created for Enhanced Trajectory Physics Engine - Issue #21
//

import Foundation

/// Represents different types of volleyball movement patterns
enum MovementType: String, CaseIterable, Codable {
    case airborne = "airborne"
    case carried = "carried"
    case rolling = "rolling"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .airborne: return "Airborne"
        case .carried: return "Carried"
        case .rolling: return "Rolling"
        case .unknown: return "Unknown"
        }
    }
    
    /// Whether this movement type represents valid volleyball projectile motion
    var isValidProjectile: Bool {
        return self == .airborne
    }
}

/// Classification result with confidence scoring
struct MovementClassification {
    let movementType: MovementType
    let confidence: Double  // 0.0 - 1.0
    let details: ClassificationDetails
    
    /// Whether this classification indicates valid projectile motion
    var isValidProjectile: Bool {
        return movementType.isValidProjectile && confidence >= 0.7
    }
}

/// Detailed metrics used for movement classification
struct ClassificationDetails: Codable {
    let velocityConsistency: Double      // Lower = more consistent
    let accelerationPattern: Double      // Higher = more parabolic
    let smoothnessScore: Double          // Higher = smoother trajectory
    let verticalMotionScore: Double      // Higher = more vertical motion
    let timeSpan: TimeInterval           // Duration of trajectory
    
    /// Overall physics score combining all metrics
    var physicsScore: Double {
        let consistencyScore = max(0, 1.0 - velocityConsistency)
        let combinedScore = (consistencyScore + accelerationPattern + smoothnessScore + verticalMotionScore) / 4.0
        return max(0.0, min(1.0, combinedScore))
    }
}