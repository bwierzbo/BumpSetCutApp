//
//  BallisticsGate.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreGraphics
import CoreMedia

final class BallisticsGate {
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
        
        let classifierConfig = ClassificationConfig()
        self.movementClassifier = MovementClassifier(config: classifierConfig)
        
        let qualityConfig = TrajectoryQualityScore.QualityConfig(
            smoothnessThreshold: config.trajectorySmoothnessThreshold,
            velocityConsistencyThreshold: config.velocityConsistencyThreshold,
            physicsScoreThreshold: config.enhancedMinR2
        )
        self.qualityScorer = TrajectoryQualityScore(config: qualityConfig)
    }
    
    func isValidProjectile(_ track: KalmanBallTracker.TrackedBall) -> Bool {
        // Use enhanced physics validation if enabled
        if config.enableEnhancedPhysics {
            return isValidProjectileEnhanced(track)
        }
        
        // Fall back to legacy validation
        return isValidProjectileLegacy(track)
    }
    
    /// Enhanced projectile validation using ParabolicValidator, MovementClassifier, and TrajectoryQualityScore
    private func isValidProjectileEnhanced(_ track: KalmanBallTracker.TrackedBall) -> Bool {
        // Must have enough samples to say anything meaningful
        let allSamples = track.positions
        guard allSamples.count >= config.parabolaMinPoints else { return false }

        // Time-windowed samples: use only the last `projectileWindowSec` seconds
        let windowSec = max(0.1, config.projectileWindowSec)
        let endT = allSamples.last!.1
        let cutoff = CMTimeSubtract(endT, CMTimeMakeWithSeconds(windowSec, preferredTimescale: 600))
        let samples = allSamples.filter { CMTimeCompare($0.1, cutoff) >= 0 }
        guard samples.count >= config.parabolaMinPoints else { return false }
        
        // Step 1: Movement Classification - reject non-airborne movements
        let classification = movementClassifier.classifyMovement(track)
        guard classification.isValidProjectile else { return false }
        
        // Step 2: Trajectory Quality Assessment
        let qualityMetrics = qualityScorer.calculateQuality(for: track)
        guard qualityMetrics.overall >= config.minQualityScore else { return false }
        
        // Step 3: Parabolic Validation - comprehensive physics check
        let parabolicResult = parabolicValidator.validateTrajectory(samples)
        guard parabolicResult.isValid else { return false }
        
        // Step 4: Basic coherence checks (preserve existing spatial jump detection)
        if samples.count >= 2 {
            let lastPt = samples.last!.0
            let prevPt = samples[samples.count - 2].0
            let jump = hypot(lastPt.x - prevPt.x, lastPt.y - prevPt.y)
            if jump > config.maxJumpPerFrame {
                return false
            }
        }
        
        // Step 5: Confidence-based final decision
        let combinedConfidence = (classification.confidence + qualityMetrics.overall + parabolicResult.r2Correlation) / 3.0
        return combinedConfidence >= config.minClassificationConfidence
    }
    
    /// Legacy projectile validation method (original implementation)
    private func isValidProjectileLegacy(_ track: KalmanBallTracker.TrackedBall) -> Bool {
        // Must have enough samples to say anything meaningful
        let allSamples = track.positions
        guard allSamples.count >= config.parabolaMinPoints else { return false }

        // Time-windowed samples: use only the last `projectileWindowSec` seconds
        let windowSec = max(0.1, config.projectileWindowSec)
        let endT = allSamples.last!.1
        let cutoff = CMTimeSubtract(endT, CMTimeMakeWithSeconds(windowSec, preferredTimescale: 600))
        let samples = allSamples.filter { CMTimeCompare($0.1, cutoff) >= 0 }
        guard samples.count >= config.parabolaMinPoints else { return false }
  
        // Build time-based arrays (use real timestamps; fallback to ~30fps indices if degenerate)
        let t0 = samples.first!.1
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
            // Fallback if timestamps are identical: assume ~30fps spacing
            ts = (0..<samples.count).map { Double($0) * (1.0 / 30.0) }
        }

        // --- ROI / coherence checks (reject sudden jumps and off-trajectory last point) ---
        // Use tunable thresholds from ProcessorConfig (normalized units)

        // 1) Reject large per-frame spatial jumps (uses normalized XY positions)
        if samples.count >= 2 {
            let lastPt = samples.last!.0
            let prevPt = samples[samples.count - 2].0
            let jump = hypot(lastPt.x - prevPt.x, lastPt.y - prevPt.y)
            if jump > config.maxJumpPerFrame {
                return false
            }
        }

        // 2) Predict last Y from prior trajectory (fit on all but the last point) and gate by ROI
        if samples.count >= 5 {
            let t0p = samples.first!.1
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
                    return false
                }
            }
        }
  
        // Points for quadratic fit: x = time (s), y = normalized y
        // NOTE: Vision bounding boxes are bottom-left origin by default (y increases upward).
        //       Use config.yIncreasingDown to pick the correct curvature sign.
        let points = zip(ts, ys).map { CGPoint(x: CGFloat($0.0), y: $0.1) }
  
        // Quadratic fit & acceptance
        guard let fit = fitQuadratic(points: points) else { return false }
        let minR2 = max(0.0, config.parabolaMinR2)
        let r2OK = fit.r2 >= minR2

        // Vertical span must be non-trivial to avoid flat noise (normalized coords)
        let yMin = ys.min() ?? 0
        let yMax = ys.max() ?? 0
        let spanY = yMax - yMin
        let minSpan: CGFloat = 0.02 // ~2% of height

        // Velocity & apex evidence (sign change in vertical velocity indicates a peak)
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
        let minSpeed = Double(config.minVelocityToConsiderActive) // normalized / s

        // Curvature sign depends on Y axis direction:
        // - If y increases downward (top-left), real projectile opens downward => a > 0
        // - If y increases upward (Vision default bottom-left), real projectile opens downward in world => a < 0
        let curvatureOK = config.yIncreasingDown ? (fit.a > 0) : (fit.a < 0)

        // Gravity band: compare by magnitude due to different pixel/time scales; keep tunable range
        let aMag = abs(fit.a)
        let gravityOK = (!config.useGravityBand) || (aMag >= config.gravityMinA && aMag <= config.gravityMaxA)

        // Tight acceptance: good fit, correct curvature, enough span, and some motion evidence
        let accept = r2OK
            && curvatureOK
            && gravityOK
            && (spanY >= minSpan)
            && (hasApex || maxSpeed >= minSpeed)

        return accept
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
