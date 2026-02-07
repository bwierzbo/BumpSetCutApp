//
//  MovementClassifier.swift
//  BumpSetCut
//
//  Created for Enhanced Trajectory Physics Engine - Issue #21
//

import CoreGraphics
import CoreMedia

/// Classifies volleyball movement patterns based on trajectory analysis
final class MovementClassifier {
    
    private let config: ClassificationConfig
    
    init(config: ClassificationConfig = ClassificationConfig()) {
        self.config = config
    }
    
    /// Classify movement type for a tracked ball trajectory
    func classifyMovement(_ trackedBall: KalmanBallTracker.TrackedBall) -> MovementClassification {
        guard trackedBall.positions.count >= config.minPointsRequired else {
            return MovementClassification(
                movementType: .unknown,
                confidence: 0.0,
                details: ClassificationDetails(
                    velocityConsistency: 1.0,
                    accelerationPattern: 0.0,
                    smoothnessScore: 0.0,
                    verticalMotionScore: 0.0,
                    timeSpan: 0.0
                )
            )
        }
        
        let details = analyzeTrajectoryDetails(trackedBall)
        let movementType = determineMovementType(details)
        let confidence = calculateConfidence(movementType, details)
        
        return MovementClassification(
            movementType: movementType,
            confidence: confidence,
            details: details
        )
    }
    
    // MARK: - Private Analysis Methods
    
    private func analyzeTrajectoryDetails(_ trackedBall: KalmanBallTracker.TrackedBall) -> ClassificationDetails {
        let positions = trackedBall.positions
        
        let velocityConsistency = calculateVelocityConsistency(positions)
        let accelerationPattern = calculateAccelerationPattern(positions)
        let smoothnessScore = calculateSmoothnessScore(positions)
        let verticalMotionScore = calculateVerticalMotionScore(positions)
        let timeSpan = calculateTimeSpan(positions)
        
        return ClassificationDetails(
            velocityConsistency: velocityConsistency,
            accelerationPattern: accelerationPattern,
            smoothnessScore: smoothnessScore,
            verticalMotionScore: verticalMotionScore,
            timeSpan: timeSpan
        )
    }
    
    private func calculateVelocityConsistency(_ positions: [(CGPoint, CMTime)]) -> Double {
        guard positions.count >= 3 else { return 1.0 }
        
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
        
        guard !velocities.isEmpty else { return 1.0 }
        
        let mean = velocities.reduce(0, +) / Double(velocities.count)
        guard mean > 0 else { return 1.0 }
        
        let variance = velocities.reduce(0) { sum, v in
            let diff = v - mean
            return sum + diff * diff
        } / Double(velocities.count)
        
        let coefficientOfVariation = sqrt(variance) / mean
        return min(1.0, coefficientOfVariation)
    }
    
    private func calculateAccelerationPattern(_ positions: [(CGPoint, CMTime)]) -> Double {
        guard positions.count >= 4 else { return 0.0 }
        
        var accelerations: [Double] = []
        
        for i in 2..<positions.count {
            let (p1, t1) = positions[i-2]
            let (p2, t2) = positions[i-1]
            let (p3, t3) = positions[i]
            
            let dt1 = CMTimeGetSeconds(CMTimeSubtract(t2, t1))
            let dt2 = CMTimeGetSeconds(CMTimeSubtract(t3, t2))
            guard dt1 > 0 && dt2 > 0 else { continue }
            
            // Calculate velocities
            let v1 = CGVector(
                dx: (p2.x - p1.x) / CGFloat(dt1),
                dy: (p2.y - p1.y) / CGFloat(dt1)
            )
            let v2 = CGVector(
                dx: (p3.x - p2.x) / CGFloat(dt2),
                dy: (p3.y - p2.y) / CGFloat(dt2)
            )
            
            // Calculate acceleration
            let dtAvg = (dt1 + dt2) / 2.0
            let accel = CGVector(
                dx: (v2.dx - v1.dx) / CGFloat(dtAvg),
                dy: (v2.dy - v1.dy) / CGFloat(dtAvg)
            )
            
            let magnitude = sqrt(Double(accel.dx * accel.dx + accel.dy * accel.dy))
            accelerations.append(magnitude)
        }
        
        guard !accelerations.isEmpty else { return 0.0 }
        
        // Parabolic motion should have relatively consistent downward acceleration
        let mean = accelerations.reduce(0, +) / Double(accelerations.count)
        let variance = accelerations.reduce(0) { sum, a in
            let diff = a - mean
            return sum + diff * diff
        } / Double(accelerations.count)
        
        let consistency = 1.0 - min(1.0, sqrt(variance) / max(0.001, mean))
        return max(0.0, consistency)
    }
    
    private func calculateSmoothnessScore(_ positions: [(CGPoint, CMTime)]) -> Double {
        guard positions.count >= 3 else { return 0.0 }
        
        var directionChanges: [Double] = []
        
        for i in 2..<positions.count {
            let p1 = positions[i-2].0
            let p2 = positions[i-1].0
            let p3 = positions[i].0
            
            let v1 = CGVector(dx: p2.x - p1.x, dy: p2.y - p1.y)
            let v2 = CGVector(dx: p3.x - p2.x, dy: p3.y - p2.y)
            
            let mag1 = sqrt(Double(v1.dx * v1.dx + v1.dy * v1.dy))
            let mag2 = sqrt(Double(v2.dx * v2.dx + v2.dy * v2.dy))
            
            guard mag1 > 0.001 && mag2 > 0.001 else { continue }
            
            let dot = Double(v1.dx * v2.dx + v1.dy * v2.dy)
            let cosAngle = dot / (mag1 * mag2)
            let angle = acos(max(-1.0, min(1.0, cosAngle)))
            
            directionChanges.append(angle)
        }
        
        guard !directionChanges.isEmpty else { return 1.0 }
        
        let meanChange = directionChanges.reduce(0, +) / Double(directionChanges.count)
        let smoothness = 1.0 - min(1.0, meanChange / .pi)
        
        return max(0.0, smoothness)
    }
    
    private func calculateVerticalMotionScore(_ positions: [(CGPoint, CMTime)]) -> Double {
        guard let first = positions.first?.0, let last = positions.last?.0 else { return 0.0 }
        
        let totalDisplacement = hypot(Double(last.x - first.x), Double(last.y - first.y))
        let verticalDisplacement = abs(Double(last.y - first.y))
        
        guard totalDisplacement > 0.001 else { return 0.0 }
        
        let verticalRatio = verticalDisplacement / totalDisplacement
        return min(1.0, verticalRatio * 2.0) // Scale up vertical motion importance
    }
    
    private func calculateTimeSpan(_ positions: [(CGPoint, CMTime)]) -> TimeInterval {
        guard let first = positions.first?.1, let last = positions.last?.1 else { return 0.0 }
        return CMTimeGetSeconds(CMTimeSubtract(last, first))
    }
    
    private func determineMovementType(_ details: ClassificationDetails) -> MovementType {
        let physicsScore = details.physicsScore
        
        // Airborne: High physics score with good parabolic characteristics
        if physicsScore >= config.airborneThreshold &&
           details.accelerationPattern >= config.minAccelerationPattern &&
           details.smoothnessScore >= config.minSmoothness {
            return .airborne
        }
        
        // Rolling: Low vertical motion, high smoothness but poor acceleration pattern
        if details.verticalMotionScore < config.maxVerticalForRolling &&
           details.smoothnessScore >= config.minSmoothnessForRolling &&
           details.accelerationPattern < config.maxAccelerationForRolling {
            return .rolling
        }
        
        // Carried: Poor physics characteristics, high velocity inconsistency
        if details.velocityConsistency >= config.minInconsistencyForCarried ||
           details.smoothnessScore < config.maxSmoothnessForCarried {
            return .carried
        }
        
        // Default to unknown if no clear classification
        return .unknown
    }
    
    private func calculateConfidence(_ movementType: MovementType, _ details: ClassificationDetails) -> Double {
        let baseConfidence: Double
        
        switch movementType {
        case .airborne:
            // High confidence for airborne when all physics metrics align
            baseConfidence = (details.physicsScore + details.accelerationPattern + details.smoothnessScore) / 3.0
            
        case .rolling:
            // Moderate confidence based on smoothness and low vertical motion
            let rollingScore = details.smoothnessScore * (1.0 - details.verticalMotionScore)
            baseConfidence = min(0.8, rollingScore)
            
        case .carried:
            // Confidence based on inconsistency indicators
            let carriedScore = details.velocityConsistency * (1.0 - details.smoothnessScore)
            baseConfidence = min(0.7, carriedScore)
            
        case .unknown:
            baseConfidence = 0.1
        }
        
        // Adjust confidence based on trajectory length
        let timeConfidenceMultiplier = min(1.0, details.timeSpan / config.optimalTimeSpan)
        
        return max(0.0, min(1.0, baseConfidence * timeConfidenceMultiplier))
    }
}

// MARK: - Configuration

struct ClassificationConfig {
    var minPointsRequired: Int = 5
    var optimalTimeSpan: TimeInterval = 1.0

    // Airborne thresholds
    var airborneThreshold: Double = 0.7
    var minAccelerationPattern: Double = 0.6
    var minSmoothness: Double = 0.6

    // Rolling thresholds
    var maxVerticalForRolling: Double = 0.3
    var minSmoothnessForRolling: Double = 0.7
    var maxAccelerationForRolling: Double = 0.4

    // Carried thresholds
    var minInconsistencyForCarried: Double = 0.6
    var maxSmoothnessForCarried: Double = 0.4

    init() {}

    init(from config: ProcessorConfig) {
        self.airborneThreshold = config.airbornePhysicsThreshold
        self.minAccelerationPattern = config.minAccelerationPattern
        self.minSmoothness = config.minSmoothnessForAirborne
        self.maxVerticalForRolling = config.maxVerticalMotionForRolling
        self.minSmoothnessForRolling = config.minSmoothnessForRolling
        self.maxAccelerationForRolling = config.maxAccelerationForRolling
        self.minInconsistencyForCarried = config.minInconsistencyForCarried
        self.maxSmoothnessForCarried = config.maxSmoothnessForCarried
    }
}