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
    
    init(config: ProcessorConfig) {
        self.config = config
    }
    
    func isValidProjectile(_ track: KalmanBallTracker.TrackedBall) -> Bool {
        // Must have enough samples to say anything meaningful
        guard track.positions.count >= config.parabolaMinPoints else { return false }
  
        // Build time-based samples (use real timestamps; fallback to ~30fps indices if degenerate)
        let samples = track.positions
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
        // --- Anti-stationary early rejections ---
        if samples.count >= 2 {
            // Total path length over the window
            var path: CGFloat = 0
            for i in 1..<samples.count {
                let p0 = samples[i-1].0, p1 = samples[i].0
                path += hypot(p1.x - p0.x, p1.y - p0.y)
            }
            // Net displacement first -> last
            let disp = hypot(samples.last!.0.x - samples.first!.0.x, samples.last!.0.y - samples.first!.0.y)
            // Vertical span
            let spanY = (ys.max() ?? 0) - (ys.min() ?? 0)
            if spanY < config.minVerticalSpan { return false }
            if path < config.minPathLength { return false }
            if disp < config.minNetDisplacement { return false }
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
  
        // Points for quadratic fit: x = time (s), y = normalized y (top-left origin)
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

        // Require a few samples above a minimum speed to reject standstill
        var fastSamples = 0
        for v in vels { if abs(v) >= Double(config.speedThreshold) { fastSamples += 1 } }
        if fastSamples < config.minSpeedSamplesAbove { return false }
  
        // Tight acceptance: good fit, enough span, reasonable speed, and correct curvature sign
        // With y increasing downward (top-left origin), gravity implies a downward-opening parabola => a > 0
        let curvatureOK = fit.a > 0
        let accept = r2OK && curvatureOK && spanY >= max(config.minVerticalSpan, 0.02)
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
