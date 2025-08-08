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
        guard track.positions.count >= config.parabolaMinPoints else { return false }
        
        // Convert to relative coordinates (frame index as x, y position as y)
        let points = track.positions.enumerated().map { (i, val) in
            CGPoint(x: CGFloat(i), y: val.0.y)
        }
        
        guard let fit = fitQuadratic(points: points) else { return false }
        guard fit.r2 >= config.parabolaMinR2 else { return false }
        
        // Optional: accel consistency
        let accelVals = computeAccelerations(points: points, a: fit.a, b: fit.b)
        let stdDev = stdDeviation(accelVals)
        return stdDev <= config.accelConsistencyMaxStd
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
