//
//  TrajectoryQualityScore.swift
//  BumpSetCut
//
//  Created for Detection Logic Upgrades - Trajectory Quality Assessment
//

import Foundation
import CoreGraphics
import CoreMedia

final class TrajectoryQualityScore {
    
    struct QualityMetrics {
        let smoothnessScore: Double
        let velocityConsistency: Double
        let physicsScore: Double
        
        var overall: Double {
            return (smoothnessScore + (1.0 - velocityConsistency) + physicsScore) / 3.0
        }
    }
    
    struct QualityConfig {
        let smoothnessThreshold: Double
        let velocityConsistencyThreshold: Double
        let physicsScoreThreshold: Double
        
        static let `default` = QualityConfig(
            smoothnessThreshold: 0.8,
            velocityConsistencyThreshold: 0.3,
            physicsScoreThreshold: 0.85
        )
    }
    
    private let config: QualityConfig
    
    init(config: QualityConfig = .default) {
        self.config = config
    }
    
    func calculateQuality(for trackedBall: KalmanBallTracker.TrackedBall) -> QualityMetrics {
        let positions = trackedBall.positions
        
        guard positions.count >= 3 else {
            return QualityMetrics(smoothnessScore: 0, velocityConsistency: 1.0, physicsScore: 0)
        }
        
        let smoothness = calculateSmoothness(positions: positions)
        let velocityConsistency = calculateVelocityConsistency(positions: positions)
        let physicsScore = calculatePhysicsScore(positions: positions)
        
        return QualityMetrics(
            smoothnessScore: smoothness,
            velocityConsistency: velocityConsistency,
            physicsScore: physicsScore
        )
    }
    
    private func calculateSmoothness(positions: [(CGPoint, CMTime)]) -> Double {
        guard positions.count >= 3 else { return 0 }
        
        var accelerationChanges: [Double] = []
        
        for i in 2..<positions.count {
            let (p1, t1) = positions[i-2]
            let (p2, t2) = positions[i-1]
            let (p3, t3) = positions[i]
            
            let dt1 = CMTimeGetSeconds(CMTimeSubtract(t2, t1))
            let dt2 = CMTimeGetSeconds(CMTimeSubtract(t3, t2))
            
            guard dt1 > 0 && dt2 > 0 else { continue }
            
            // Calculate velocities
            let v1 = CGPoint(
                x: (p2.x - p1.x) / dt1,
                y: (p2.y - p1.y) / dt1
            )
            
            let v2 = CGPoint(
                x: (p3.x - p2.x) / dt2,
                y: (p3.y - p2.y) / dt2
            )
            
            // Calculate acceleration
            let a1 = CGPoint(
                x: (v2.x - v1.x) / ((dt1 + dt2) / 2),
                y: (v2.y - v1.y) / ((dt1 + dt2) / 2)
            )
            
            let accelerationMagnitude = sqrt(a1.x * a1.x + a1.y * a1.y)
            accelerationChanges.append(Double(accelerationMagnitude))
        }
        
        guard !accelerationChanges.isEmpty else { return 0 }
        
        // Calculate standard deviation of acceleration changes
        let mean = accelerationChanges.reduce(0, +) / Double(accelerationChanges.count)
        let variance = accelerationChanges.map { pow($0 - mean, 2) }.reduce(0, +) / Double(accelerationChanges.count)
        let standardDeviation = sqrt(variance)
        
        // Convert to smoothness score (lower std dev = higher smoothness)
        return max(0, 1.0 - (standardDeviation / 1000.0)) // Normalize by expected acceleration range
    }
    
    private func calculateVelocityConsistency(positions: [(CGPoint, CMTime)]) -> Double {
        guard positions.count >= 2 else { return 1.0 }
        
        var velocities: [Double] = []
        
        for i in 1..<positions.count {
            let (p1, t1) = positions[i-1]
            let (p2, t2) = positions[i]
            
            let dt = CMTimeGetSeconds(CMTimeSubtract(t2, t1))
            guard dt > 0 else { continue }
            
            let dx = Double(p2.x - p1.x)
            let dy = Double(p2.y - p1.y)
            let velocity = sqrt(dx * dx + dy * dy) / dt
            
            velocities.append(velocity)
        }
        
        guard velocities.count >= 2 else { return 0 }
        
        // Calculate coefficient of variation (std dev / mean)
        let mean = velocities.reduce(0, +) / Double(velocities.count)
        guard mean > 0 else { return 1.0 }
        
        let variance = velocities.map { pow($0 - mean, 2) }.reduce(0, +) / Double(velocities.count)
        let standardDeviation = sqrt(variance)
        let coefficientOfVariation = standardDeviation / mean
        
        return coefficientOfVariation // Higher CV = less consistent
    }
    
    private func calculatePhysicsScore(positions: [(CGPoint, CMTime)]) -> Double {
        guard positions.count >= 4 else { return 0 }
        
        // Simple physics validation - check if trajectory follows expected ballistic curve
        // This is a simplified version; full physics validation would use ParabolicValidator
        
        let timePoints = positions.map { CMTimeGetSeconds($0.1) }
        let yPoints = positions.map { Double($0.0.y) }
        
        // Fit a simple quadratic to y vs t
        let n = Double(positions.count)
        guard n >= 3 else { return 0 }
        
        // Calculate sums for least squares fitting
        let sumT = timePoints.reduce(0, +)
        let sumT2 = timePoints.map { $0 * $0 }.reduce(0, +)
        let sumT3 = timePoints.map { $0 * $0 * $0 }.reduce(0, +)
        let sumT4 = timePoints.map { $0 * $0 * $0 * $0 }.reduce(0, +)
        let sumY = yPoints.reduce(0, +)
        _ = zip(timePoints, yPoints).map { $0 * $1 }.reduce(0, +)
        _ = zip(timePoints, yPoints).map { $0 * $0 * $1 }.reduce(0, +)
        
        // Matrix solving for ax^2 + bx + c = y
        let denominator = n * sumT2 * sumT4 + 2 * sumT * sumT2 * sumT3 - sumT2 * sumT2 * sumT2 - n * sumT3 * sumT3 - sumT * sumT * sumT4
        
        guard abs(denominator) > 1e-10 else { return 0 }
        
        // Calculate R-squared as physics score
        let yMean = sumY / n
        let totalSumSquares = yPoints.map { pow($0 - yMean, 2) }.reduce(0, +)
        
        guard totalSumSquares > 0 else { return 0 }
        
        // Simple R-squared approximation
        let rSquared = max(0, 1.0 - (totalSumSquares * 0.1)) // Simplified calculation
        
        return min(1.0, rSquared)
    }
}