//
//  ProcessingQualityMetrics.swift
//  BumpSetCut
//
//  Quality maths over a finished run (tracks, classifications) — no processor state.
//  Compiled into RallyLab too (membershipExceptions).
//

import Foundation
import CoreGraphics
import CoreMedia

enum ProcessingQualityMetrics {
    static func calculateTrackMetrics(_ track: KalmanBallTracker.TrackedBall) -> (rSquared: Double, velocity: Double, acceleration: Double) {
        guard track.positions.count >= 3 else {
            return (0.0, 0.0, 0.0)
        }

        // Calculate velocity from last few points
        let recent = track.positions.suffix(3)
        var velocitySum = 0.0
        let accelerationSum = 0.0

        if recent.count >= 2 {
            let positions = Array(recent)
            for i in 1..<positions.count {
                let dt = CMTimeGetSeconds(positions[i].1) - CMTimeGetSeconds(positions[i-1].1)
                if dt > 0 {
                    let dx = positions[i].0.x - positions[i-1].0.x
                    let dy = positions[i].0.y - positions[i-1].0.y
                    let velocity = sqrt(dx*dx + dy*dy) / dt
                    velocitySum += Double(velocity)
                }
            }

            // Simple R² calculation based on trajectory linearity (simplified)
            let rSquared = calculateSimpleRSquared(positions: track.positions.map { $0.0 })
            return (rSquared, velocitySum / Double(recent.count - 1), accelerationSum)
        }

        return (0.0, 0.0, 0.0)
    }

    static func calculateTrackConfidence(_ track: KalmanBallTracker.TrackedBall) -> Double {
        // Calculate confidence based on track age, consistency, and displacement
        guard track.positions.count >= 2 else {
            return 0.3 // Low confidence for single-point tracks
        }

        // Age-based confidence (longer tracks are more reliable)
        let ageConfidence = min(1.0, Double(track.age) / 10.0)

        // Movement-based confidence (tracks that move are more likely to be balls)
        let movementConfidence = min(1.0, Double(track.netDisplacement) * 5.0)

        // Combine factors
        let baseConfidence = (ageConfidence + movementConfidence) / 2.0

        // Ensure reasonable bounds
        return max(0.1, min(0.95, baseConfidence))
    }

    static func calculateSimpleRSquared(positions: [CGPoint]) -> Double {
        guard positions.count >= 3 else { return 0.0 }

        // Calculate linear regression R²
        let n = Double(positions.count)
        let sumX = positions.reduce(0) { $0 + Double($1.x) }
        let sumY = positions.reduce(0) { $0 + Double($1.y) }
        let sumXY = positions.reduce(0) { $0 + Double($1.x * $1.y) }
        let sumXX = positions.reduce(0) { $0 + Double($1.x * $1.x) }
        let sumYY = positions.reduce(0) { $0 + Double($1.y * $1.y) }

        let numerator = n * sumXY - sumX * sumY
        let denominator = sqrt((n * sumXX - sumX * sumX) * (n * sumYY - sumY * sumY))

        guard denominator > 0 else { return 0.0 }
        let correlation = numerator / denominator
        return max(0.0, min(1.0, correlation * correlation))
    }

    static func calculateOverallQuality(stats: ProcessingStats, rSquaredAvg: Double) -> Double {
        let detectionQuality = stats.detectionRate
        let physicsQuality = stats.physicsValidFrames > 0 ? Double(stats.physicsValidFrames) / Double(stats.processedFrames) : 0
        let trajectoryQuality = rSquaredAvg
        let completenessQuality = stats.processingCompleteness

        return (detectionQuality + physicsQuality + trajectoryQuality + completenessQuality) / 4.0
    }

    static func calculateTrajectoryConsistency(_ trajectories: [ProcessingTrajectoryData]) -> Double {
        guard !trajectories.isEmpty else { return 0.0 }

        let avgRSquared = trajectories.reduce(0) { $0 + $1.rSquared } / Double(trajectories.count)
        return avgRSquared
    }

    static func calculateClassificationAccuracy(_ classifications: [ProcessingClassificationResult]) -> Double? {
        guard !classifications.isEmpty else { return nil }

        let avgConfidence = classifications.reduce(0) { $0 + $1.confidence } / Double(classifications.count)
        return avgConfidence
    }

    static func calculateConfidenceDistribution(_ classifications: [ProcessingClassificationResult]) -> ConfidenceDistribution {
        var high = 0
        var medium = 0
        var low = 0

        for classification in classifications {
            if classification.confidence >= 0.8 {
                high += 1
            } else if classification.confidence >= 0.5 {
                medium += 1
            } else {
                low += 1
            }
        }

        return ConfidenceDistribution(high: high, medium: medium, low: low)
    }

    static func calculateQualityBreakdown(_ trajectories: [ProcessingTrajectoryData]) -> QualityBreakdown {
        guard !trajectories.isEmpty else {
            return QualityBreakdown(
                velocityConsistency: 0,
                accelerationPattern: 0,
                smoothnessScore: 0,
                verticalMotionScore: 0,
                overallCoherence: 0
            )
        }

        // Calculate average metrics across all trajectories
        var totalVelocityConsistency = 0.0
        var totalAccelerationPattern = 0.0
        var totalSmoothness = 0.0
        var totalVerticalMotion = 0.0

        for trajectory in trajectories {
            totalVelocityConsistency += velocityConsistencyScore(for: trajectory.points)
            totalAccelerationPattern += trajectory.rSquared
            totalSmoothness += trajectory.quality
            totalVerticalMotion += verticalMotionScore(for: trajectory.points)
        }

        let count = Double(trajectories.count)
        let velocityConsistency = totalVelocityConsistency / count
        let accelerationPattern = totalAccelerationPattern / count
        let smoothnessScore = totalSmoothness / count
        let verticalMotionScore = totalVerticalMotion / count
        let overallCoherence = (velocityConsistency + accelerationPattern + smoothnessScore + verticalMotionScore) / 4.0

        return QualityBreakdown(
            velocityConsistency: velocityConsistency,
            accelerationPattern: accelerationPattern,
            smoothnessScore: smoothnessScore,
            verticalMotionScore: verticalMotionScore,
            overallCoherence: overallCoherence
        )
    }

    /// 0–1 (higher = more consistent). Coefficient of variation of point velocities,
    /// inverted and clamped so callers can average it directly into a coherence score.
    private static func velocityConsistencyScore(for points: [ProcessingTrajectoryPoint]) -> Double {
        let velocities = points.map(\.velocity).filter { $0.isFinite && $0 > 0 }
        guard velocities.count >= 2 else { return 0 }
        let mean = velocities.reduce(0, +) / Double(velocities.count)
        guard mean > 0 else { return 0 }
        let variance = velocities.map { pow($0 - mean, 2) }.reduce(0, +) / Double(velocities.count)
        let cv = sqrt(variance) / mean
        return max(0, min(1, 1 - cv))
    }

    /// 0–1 (higher = more vertical motion). Ratio of summed |dy| to total path length —
    /// rallies are vertical (set, spike, dig) so a high score means a plausible ball path.
    private static func verticalMotionScore(for points: [ProcessingTrajectoryPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var verticalDistance = 0.0
        var totalDistance = 0.0
        for i in 1..<points.count {
            let dx = Double(points[i].position.x - points[i - 1].position.x)
            let dy = Double(points[i].position.y - points[i - 1].position.y)
            verticalDistance += abs(dy)
            totalDistance += sqrt(dx * dx + dy * dy)
        }
        guard totalDistance > 0 else { return 0 }
        return min(1, verticalDistance / totalDistance)
    }

    static func calculateProcessingOverhead(processingDuration: TimeInterval, videoDuration: TimeInterval) -> Double {
        guard videoDuration > 0 else { return 0 }
        return (processingDuration / videoDuration - 1.0) * 100.0
    }
}
