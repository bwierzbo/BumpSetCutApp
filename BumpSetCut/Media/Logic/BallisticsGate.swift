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
  
        // Points for quadratic fit: x = time (s), y = normalized y (top-left origin)
        let points = zip(ts, ys).map { CGPoint(x: CGFloat($0.0), y: $0.1) }
  
        // Quadratic fit & loosened acceptance
        guard let fit = fitQuadratic(points: points) else { return false }
        let minR2 = max(0.0, config.parabolaMinR2 - 0.08) // loosen a bit
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
  
        // Loosened acceptance logic:
        //  - Good R² and enough vertical span, OR
        //  - Apex detected with reasonable span, OR
        //  - Slightly worse R² but clear motion speed
        let accept =
            (r2OK && spanY >= minSpan) ||
            (hasApex && spanY >= (minSpan * 0.75)) ||
            (fit.r2 >= (minR2 - 0.07) && maxSpeed >= minSpeed)
  
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
