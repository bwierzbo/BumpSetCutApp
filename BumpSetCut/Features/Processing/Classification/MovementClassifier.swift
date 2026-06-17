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
        classifyMovement(positions: trackedBall.positions)
    }

    /// Classify a raw position window (used by BallisticsGate to classify the same
    /// time-windowed samples its other checks operate on).
    func classifyMovement(positions: [(CGPoint, CMTime)]) -> MovementClassification {
        guard positions.count >= config.minPointsRequired else {
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
        
        let details = analyzeTrajectoryDetails(positions)
        let movementType = determineMovementType(details)
        let confidence = calculateConfidence(movementType, details)

        return MovementClassification(
            movementType: movementType,
            confidence: confidence,
            details: details
        )
    }

    // MARK: - Private Analysis Methods

    private func analyzeTrajectoryDetails(_ positions: [(CGPoint, CMTime)]) -> ClassificationDetails {
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
    
    /// Gravity-likeness of the motion, from the curvature of a least-squares
    /// parabola fit of vertical position over time. Gravity is a constant
    /// acceleration, which shows up as the quadratic's `a` (curvature) term.
    ///
    /// This replaces a frame-to-frame second-difference estimate, which amplified
    /// position noise so badly that even a textbook arc (R²≈1) scored ~0.15. A
    /// least-squares fit is robust to that jitter: a real arc has meaningful,
    /// well-fit curvature → high; a straight/carried path has a≈0 → low.
    private func calculateAccelerationPattern(_ positions: [(CGPoint, CMTime)]) -> Double {
        guard positions.count >= 4, let t0 = positions.first?.1 else { return 0.0 }

        // Fit y(t); use raw seconds for t so curvature scale matches the gate.
        let pts: [CGPoint] = positions.map { (p, tm) in
            CGPoint(x: CGFloat(CMTimeGetSeconds(CMTimeSubtract(tm, t0))), y: p.y)
        }
        guard let fit = fitQuadratic(points: pts) else { return 0.0 }

        // Curvature magnitude normalized by the reference (saturates to 1), then
        // weighted by fit quality so a noisy fit can't masquerade as strong gravity.
        let curvature = abs(Double(fit.a))
        let magnitude = min(1.0, curvature / max(1e-6, config.gravityReferenceCurvature))
        let quality = max(0.0, min(1.0, fit.r2))
        return magnitude * quality
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
        
        // Rolling: low vertical motion, smooth, poor acceleration pattern — AND actually
        // moving with a consistent velocity (a stationary blob also has ~zero acceleration
        // and high smoothness, but its velocity is degenerate/inconsistent → that's carried,
        // not rolling).
        if details.verticalMotionScore < config.maxVerticalForRolling &&
           details.smoothnessScore >= config.minSmoothnessForRolling &&
           details.accelerationPattern < config.maxAccelerationForRolling &&
           details.velocityConsistency < config.minInconsistencyForCarried {
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
    // Minimum mean acceleration magnitude (normalized coords) for a trajectory to count
    // as having a gravity signature. Below this it's treated as constant-velocity (a
    // straight line / rolling), never airborne.
    var minMeaningfulAcceleration: Double = 0.05
    // Reference curvature for the fit-based gravity signature (|a| → ~1.0).
    var gravityReferenceCurvature: Double = 0.02

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
        self.gravityReferenceCurvature = config.gravityReferenceCurvature
    }
}