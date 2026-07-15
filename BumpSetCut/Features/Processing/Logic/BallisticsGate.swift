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
        // Populated by the legacy path whenever there are enough samples to
        // classify — now set even on rejected frames, for diagnosis.
        var gravitySignature: Double? = nil
        var movementType: MovementType? = nil
        // Human-readable reason this frame was NOT accepted as a projectile
        // (nil when accepted). Diagnostic only.
        var rejectionReason: String? = nil
    }

    private let config: ProcessorConfig
    private let movementClassifier: MovementClassifier

    /// Fixed per-video net, when detected. Used by the under-net rejection: a
    /// trajectory that never rises above the net's bottom edge is a ground roll /
    /// carry, not a rally. Nil → the rule is skipped.
    var net: DetectedNet?

    init(config: ProcessorConfig) {
        self.config = config

        let classifierConfig = ClassificationConfig(from: config)
        self.movementClassifier = MovementClassifier(config: classifierConfig)
    }

    func isValidProjectile(_ track: KalmanBallTracker.TrackedBall) -> Bool {
        return validateProjectile(track).isValid
    }

    /// Validate projectile and return detailed metrics for downstream consumers.
    func validateProjectile(_ track: KalmanBallTracker.TrackedBall) -> ValidationResult {
        func reject(_ reason: String, positionJumpsValid: Bool = true, rSquared: Double = 0,
                    grav: Double? = nil, type: MovementType? = nil,
                    curvatureValid: Bool = false, motion: Bool = false) -> ValidationResult {
            ValidationResult(isValid: false, rSquared: rSquared, curvatureDirectionValid: curvatureValid,
                             hasMotionEvidence: motion, positionJumpsValid: positionJumpsValid,
                             confidenceLevel: 0, gravitySignature: grav, movementType: type,
                             rejectionReason: reason)
        }

        let allSamples = config.useSmoothedTrack ? track.smoothedPositions : track.positions
        guard allSamples.count >= config.parabolaMinPoints,
              let lastSample = allSamples.last else { return reject("too few points") }

        let windowSec = max(0.1, config.projectileWindowSec)
        let endT = lastSample.1
        let cutoff = CMTimeSubtract(endT, CMTimeMakeWithSeconds(windowSec, preferredTimescale: 600))
        let samples = allSamples.filter { CMTimeCompare($0.1, cutoff) >= 0 }
        guard samples.count >= config.parabolaMinPoints,
              let firstSample = samples.first else { return reject("too few points in window") }

        // Classify up front so gravity signature + movement class are available on
        // EVERY return below — accepted or rejected — for diagnosis.
        let classification = movementClassifier.classifyMovement(positions: samples)
        let grav = classification.details.accelerationPattern
        let mType = classification.movementType

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

        // 0) Under-net rejection: a ball rolled/carried along the ground to the
        // other side never arcs over the net. If the trajectory's HIGHEST point
        // (max Vision y) stays below the net's bottom edge, trash it.
        if config.enableUnderNetRejection, let net,
           let maxY = ys.max(), maxY < net.box.minY - config.underNetMarginY {
            return reject("under net (rolled/carried)", grav: grav, type: mType)
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
            return reject("position jump too big", positionJumpsValid: false, grav: grav, type: mType)
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
                    return reject("off predicted path (ROI)", grav: grav, type: mType)
                }
            }
        }

        let points = zip(ts, ys).map { CGPoint(x: CGFloat($0.0), y: $0.1) }
        guard let fit = fitQuadratic(points: points) else { return reject("no parabola fit", grav: grav, type: mType) }

        let minR2 = max(0.0, config.parabolaMinR2)
        let r2OK = fit.r2 >= minR2

        let yMin = ys.min() ?? 0
        let yMax = ys.max() ?? 0
        let spanY = yMax - yMin
        let minSpan = config.minProjectileSpanY

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
        // A real parabola has meaningful curvature; a held/carried ball is ~linear
        // (a ≈ 0). This magnitude floor is the primary held-ball rejection.
        let curvatureMagOK = aMag >= config.minCurvatureMagnitude
        // Keep the optional gravity-band upper bound (lower bound is now the floor above).
        let gravityBandOK = (!config.useGravityBand) || (aMag <= config.gravityMaxA)
        // Require genuine motion: either real measured speed, or an apex paired with
        // actual vertical travel (so a noise-induced velocity sign flip on a nearly
        // stationary ball — tiny span — no longer counts as motion).
        let motionEvidence = (maxSpeed >= minSpeed) || (hasApex && spanY >= minSpan)

        // Collect the specific failed checks so a rejected frame can say why.
        var fails: [String] = []
        if !r2OK { fails.append("low R² (\(String(format: "%.2f", fit.r2))<\(String(format: "%.2f", minR2)))") }
        if !curvatureOK { fails.append("curvature direction") }
        if !curvatureMagOK { fails.append("curvature too small") }
        if !gravityBandOK { fails.append("curvature > gravity band") }
        if spanY < minSpan { fails.append("low vertical span") }
        if !motionEvidence { fails.append("no motion") }

        var accept = fails.isEmpty
        var reason: String? = accept ? nil : fails.joined(separator: ", ")

        // Supported-ball veto. A ground roll fakes every numeric check above: a sloped
        // path is ~linear and a line is a perfect degenerate parabola (R² ≈ 1); perspective
        // slope supplies spanY; noise wobble supplies spurious apexes and curvature beyond
        // the tiny magnitude floor.
        //
        // The veto fires only when the motion is BOTH flat (little vertical travel) AND
        // lacks a gravity signature (no sustained, consistently-downward acceleration).
        if accept && config.movementClassifierEnabled {
            let isFlat = classification.details.verticalMotionScore < config.maxVerticalMotionForRolling
            let noGravity = grav < config.minGravitySignature
            let isCarried = config.vetoCarriedMovement && mType == .carried
            if mType == .rolling {
                accept = false; reason = "veto: rolling"
            } else if isCarried {
                accept = false; reason = "veto: carried"
            } else if isFlat && noGravity {
                accept = false; reason = "veto: flat + no gravity"
            }
        }

        // Doubling-back veto. A pickup/scoop traces a loop: it goes sideways and
        // returns near its horizontal start. A real ball in play travels across,
        // so its horizontal motion is roughly monotonic (net ≈ excursion). The
        // short-window parabola checks can't see the loop; this looks over a
        // longer lookback at horizontal travel-vs-return.
        if accept && config.enableLoopRejection {
            let loopCutoff = CMTimeSubtract(endT, CMTimeMakeWithSeconds(config.loopCheckWindowSec, preferredTimescale: 600))
            let loopXs = allSamples.filter { CMTimeCompare($0.1, loopCutoff) >= 0 }.map { $0.0.x }
            if loopXs.count >= 4, let xMin = loopXs.min(), let xMax = loopXs.max(),
               let xFirst = loopXs.first, let xLast = loopXs.last {
                let excursion = xMax - xMin
                let net = abs(xLast - xFirst)
                if excursion >= CGFloat(config.loopMinExcursion),
                   net <= excursion * CGFloat(config.loopReturnRatio) {
                    accept = false
                    reason = "doubling back (loop)"
                }
            }
        }

        return ValidationResult(
            isValid: accept,
            rSquared: fit.r2,
            curvatureDirectionValid: curvatureOK,
            hasMotionEvidence: motionEvidence,
            positionJumpsValid: true,
            confidenceLevel: accept ? min(1.0, fit.r2) : 0,
            gravitySignature: grav,
            movementType: mType,
            rejectionReason: reason
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
