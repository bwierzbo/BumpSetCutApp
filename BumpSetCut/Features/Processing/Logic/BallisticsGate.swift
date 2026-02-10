//
//  BallisticsGate.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreGraphics
import CoreMedia

final class BallisticsGate {

    /// Result of projectile validation with real physics metrics.
    struct ValidationResult {
        let isValid: Bool
        let rSquared: Double
        let curvatureDirectionValid: Bool
        let hasMotionEvidence: Bool
        let positionJumpsValid: Bool
        let confidenceLevel: Double
    }

    private let config: ProcessorConfig
    private let parabolicValidator: ParabolicValidator
    private let movementClassifier: MovementClassifier
    private let qualityScorer: TrajectoryQualityScore
    
    init(config: ProcessorConfig) {
        self.config = config
        
        // Initialize physics validation components
        let validatorConfig = ParabolicValidator.Config(
            minR2Threshold: config.enhancedMinR2,
            minPoints: config.parabolaMinPoints,
            gravityDirection: config.yIncreasingDown ? .down : .up,
            maxVelocityChange: config.velocityConsistencyThreshold,
            minParabolicCurvature: 0.001 // Use fixed value as not in config
        )
        self.parabolicValidator = ParabolicValidator(config: validatorConfig)
        
        let classifierConfig = ClassificationConfig(from: config)
        self.movementClassifier = MovementClassifier(config: classifierConfig)
        
        let qualityConfig = TrajectoryQualityScore.QualityConfig(
            smoothnessThreshold: config.trajectorySmoothnessThreshold,
            velocityConsistencyThreshold: config.velocityConsistencyThreshold,
            physicsScoreThreshold: config.enhancedMinR2
        )
        self.qualityScorer = TrajectoryQualityScore(config: qualityConfig)
    }
    
    func isValidProjectile(_ track: KalmanBallTracker.TrackedBall) -> Bool {
        return validateProjectile(track).isValid
    }

    /// Validate projectile and return detailed metrics for downstream consumers.
    func validateProjectile(_ track: KalmanBallTracker.TrackedBall) -> ValidationResult {
        if config.enableEnhancedPhysics {
            return validateProjectileEnhanced(track)
        }
        return validateProjectileLegacy(track)
    }
    
    /// Enhanced projectile validation using ParabolicValidator, MovementClassifier, and TrajectoryQualityScore
    private func validateProjectileEnhanced(_ track: KalmanBallTracker.TrackedBall) -> ValidationResult {
        let insufficient = ValidationResult(isValid: false, rSquared: 0, curvatureDirectionValid: false,
                                            hasMotionEvidence: false, positionJumpsValid: true, confidenceLevel: 0)

        let allSamples = track.positions
        guard allSamples.count >= config.parabolaMinPoints,
              let lastSample = allSamples.last else { return insufficient }

        let windowSec = max(0.1, config.projectileWindowSec)
        let endT = lastSample.1
        let cutoff = CMTimeSubtract(endT, CMTimeMakeWithSeconds(windowSec, preferredTimescale: 600))
        let samples = allSamples.filter { CMTimeCompare($0.1, cutoff) >= 0 }
        guard samples.count >= config.parabolaMinPoints else { return insufficient }

        let classification = movementClassifier.classifyMovement(track)
        let qualityMetrics = qualityScorer.calculateQuality(for: track)
        let parabolicResult = parabolicValidator.validateTrajectory(samples)

        var jumpsValid = true
        if samples.count >= 2,
           let lastPt = samples.last?.0 {
            let prevPt = samples[samples.count - 2].0
            let jump = hypot(lastPt.x - prevPt.x, lastPt.y - prevPt.y)
            if jump > config.maxJumpPerFrame { jumpsValid = false }
        }

        let combinedConfidence = (classification.confidence + qualityMetrics.overall + parabolicResult.r2Correlation) / 3.0
        let isValid = classification.isValidProjectile
            && qualityMetrics.overall >= config.minQualityScore
            && parabolicResult.isValid
            && jumpsValid
            && combinedConfidence >= config.minClassificationConfidence

        return ValidationResult(
            isValid: isValid,
            rSquared: parabolicResult.r2Correlation,
            curvatureDirectionValid: parabolicResult.isValid,
            hasMotionEvidence: classification.isValidProjectile,
            positionJumpsValid: jumpsValid,
            confidenceLevel: combinedConfidence
        )
    }
    
    /// Legacy projectile validation method (original implementation)
    private func validateProjectileLegacy(_ track: KalmanBallTracker.TrackedBall) -> ValidationResult {
        let insufficient = ValidationResult(isValid: false, rSquared: 0, curvatureDirectionValid: false,
                                            hasMotionEvidence: false, positionJumpsValid: true, confidenceLevel: 0)

        let allSamples = track.positions
        guard allSamples.count >= config.parabolaMinPoints,
              let lastSample = allSamples.last else { return insufficient }

        let windowSec = max(0.1, config.projectileWindowSec)
        let endT = lastSample.1
        let cutoff = CMTimeSubtract(endT, CMTimeMakeWithSeconds(windowSec, preferredTimescale: 600))
        let samples = allSamples.filter { CMTimeCompare($0.1, cutoff) >= 0 }
        guard samples.count >= config.parabolaMinPoints,
              let firstSample = samples.first else { return insufficient }

        let t0 = firstSample.1
        var ts: [Double] = []
        var ys: [CGFloat] = []
        ts.reserveCapacity(samples.count)
        ys.reserveCapacity(samples.count)
        for (pt, tm) in samples {
            let dt = CMTimeGetSeconds(CMTimeSubtract(tm, t0))
            ts.append(dt)
            ys.append(pt.y)
        }
        if (ts.last ?? 0) <= 0 {
            ts = (0..<samples.count).map { Double($0) * (1.0 / 30.0) }
        }

        // 1) Reject large per-frame spatial jumps
        var jumpsValid = true
        if samples.count >= 2,
           let lastPt = samples.last?.0 {
            let prevPt = samples[samples.count - 2].0
            let jump = hypot(lastPt.x - prevPt.x, lastPt.y - prevPt.y)
            if jump > config.maxJumpPerFrame { jumpsValid = false }
        }
        if !jumpsValid {
            return ValidationResult(isValid: false, rSquared: 0, curvatureDirectionValid: false,
                                    hasMotionEvidence: false, positionJumpsValid: false, confidenceLevel: 0)
        }

        // 2) Predict last Y from prior trajectory and gate by ROI
        if samples.count >= 5 {
            let t0p = firstSample.1
            var tsPrev: [Double] = []
            var ysPrev: [CGFloat] = []
            tsPrev.reserveCapacity(samples.count - 1)
            ysPrev.reserveCapacity(samples.count - 1)
            for i in 0..<(samples.count - 1) {
                let dt = CMTimeGetSeconds(CMTimeSubtract(samples[i].1, t0p))
                tsPrev.append(dt)
                ysPrev.append(samples[i].0.y)
            }
            if (tsPrev.last ?? 0) <= 0 {
                tsPrev = (0..<(samples.count - 1)).map { Double($0) * (1.0 / 30.0) }
            }
            let pointsPrev = zip(tsPrev, ysPrev).map { CGPoint(x: CGFloat($0.0), y: $0.1) }
            if let fitPrev = fitQuadratic(points: pointsPrev) {
                let tLast = ts.last ?? 0
                let yPred = fitPrev.a * CGFloat(tLast * tLast) + fitPrev.b * CGFloat(tLast) + fitPrev.c
                let yErr = abs(yPred - (ys.last ?? yPred))
                if yErr > config.roiYRadius {
                    return ValidationResult(isValid: false, rSquared: 0, curvatureDirectionValid: false,
                                            hasMotionEvidence: false, positionJumpsValid: true, confidenceLevel: 0)
                }
            }
        }

        let points = zip(ts, ys).map { CGPoint(x: CGFloat($0.0), y: $0.1) }
        guard let fit = fitQuadratic(points: points) else { return insufficient }

        let minR2 = max(0.0, config.parabolaMinR2)
        let r2OK = fit.r2 >= minR2

        let yMin = ys.min() ?? 0
        let yMax = ys.max() ?? 0
        let spanY = yMax - yMin
        let minSpan: CGFloat = 0.02

        var vels: [Double] = []
        vels.reserveCapacity(max(0, ts.count - 1))
        for i in 1..<ts.count {
            let dt = max(1e-3, ts[i] - ts[i-1])
            vels.append(Double(ys[i] - ys[i-1]) / dt)
        }
        var signChanges = 0
        for i in 1..<vels.count {
            if vels[i] * vels[i-1] < 0 { signChanges += 1 }
        }
        let hasApex = signChanges >= 1
        let maxSpeed = vels.map { abs($0) }.max() ?? 0
        let minSpeed = Double(config.minVelocityToConsiderActive)

        let curvatureOK = config.yIncreasingDown ? (fit.a > 0) : (fit.a < 0)
        let aMag = abs(fit.a)
        let gravityOK = (!config.useGravityBand) || (aMag >= config.gravityMinA && aMag <= config.gravityMaxA)
        let motionEvidence = hasApex || maxSpeed >= minSpeed

        let accept = r2OK && curvatureOK && gravityOK && (spanY >= minSpan) && motionEvidence

        return ValidationResult(
            isValid: accept,
            rSquared: fit.r2,
            curvatureDirectionValid: curvatureOK,
            hasMotionEvidence: motionEvidence,
            positionJumpsValid: true,
            confidenceLevel: accept ? min(1.0, fit.r2) : 0
        )
    }
    
    private func computeAccelerations(points: [CGPoint], a: CGFloat, b: CGFloat) -> [CGFloat] {
        // For y = ax² + bx + c, acceleration = 2a constant
        return Array(repeating: 2 * a, count: points.count)
    }
    
    private func stdDeviation(_ values: [CGFloat]) -> CGFloat {
        let mean = values.reduce(0, +) / CGFloat(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / CGFloat(values.count)
        return sqrt(variance)
    }
}
