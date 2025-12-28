//
//  KalmanBallTracker.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreGraphics
import CoreMedia

// MARK: - Kalman State

/// Kalman filter state: position and velocity with covariance
struct KalmanState {
    /// State vector: [x, y, vx, vy]
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var timestamp: CMTime

    /// 4x4 covariance matrix P (symmetric, stores uncertainty)
    var P: [[CGFloat]]

    /// Initialize with position and default uncertainties
    init(position: CGPoint, timestamp: CMTime, config: ProcessorConfig) {
        self.x = position.x
        self.y = position.y
        self.vx = 0
        self.vy = 0
        self.timestamp = timestamp

        // Initial covariance: high uncertainty in velocity, moderate in position
        let posVar = config.kalmanInitialPositionUncertainty * config.kalmanInitialPositionUncertainty
        let velVar = config.kalmanInitialVelocityUncertainty * config.kalmanInitialVelocityUncertainty
        self.P = [
            [posVar, 0, 0, 0],
            [0, posVar, 0, 0],
            [0, 0, velVar, 0],
            [0, 0, 0, velVar]
        ]
    }

    /// Current position as CGPoint
    var position: CGPoint {
        CGPoint(x: x, y: y)
    }

    /// Current velocity as CGPoint
    var velocity: CGPoint {
        CGPoint(x: vx, y: vy)
    }

    // MARK: - Predict Step

    /// Predict state forward by dt seconds using constant velocity model
    mutating func predict(dt: CGFloat, config: ProcessorConfig) {
        // State transition: x' = x + vx*dt, y' = y + vy*dt, v' = v
        x += vx * dt
        y += vy * dt

        // State transition matrix F:
        // [1 0 dt 0 ]
        // [0 1 0  dt]
        // [0 0 1  0 ]
        // [0 0 0  1 ]

        // P' = F * P * F^T + Q
        // For efficiency, compute directly instead of matrix multiply
        let q_pos = config.kalmanProcessNoisePosition
        let q_vel = config.kalmanProcessNoiseVelocity

        // F*P*F^T computation (constant velocity model)
        var newP = P
        // Position variance grows with velocity uncertainty
        newP[0][0] = P[0][0] + 2*dt*P[0][2] + dt*dt*P[2][2] + q_pos
        newP[0][1] = P[0][1] + dt*P[0][3] + dt*P[2][1] + dt*dt*P[2][3]
        newP[0][2] = P[0][2] + dt*P[2][2]
        newP[0][3] = P[0][3] + dt*P[2][3]

        newP[1][0] = newP[0][1]
        newP[1][1] = P[1][1] + 2*dt*P[1][3] + dt*dt*P[3][3] + q_pos
        newP[1][2] = P[1][2] + dt*P[3][2]
        newP[1][3] = P[1][3] + dt*P[3][3]

        newP[2][0] = newP[0][2]
        newP[2][1] = newP[1][2]
        newP[2][2] = P[2][2] + q_vel
        newP[2][3] = P[2][3]

        newP[3][0] = newP[0][3]
        newP[3][1] = newP[1][3]
        newP[3][2] = newP[2][3]
        newP[3][3] = P[3][3] + q_vel

        P = newP
    }

    // MARK: - Update Step

    /// Update state with measurement (position only)
    mutating func update(measurement: CGPoint, timestamp: CMTime, config: ProcessorConfig) {
        self.timestamp = timestamp

        // Measurement matrix H = [1 0 0 0; 0 1 0 0] (observe position only)
        // Innovation: y = z - H*x
        let innovX = measurement.x - x
        let innovY = measurement.y - y

        // S = H*P*H^T + R (2x2 innovation covariance)
        let R = config.kalmanMeasurementNoise * config.kalmanMeasurementNoise
        let S00 = P[0][0] + R
        let S01 = P[0][1]
        let S10 = P[1][0]
        let S11 = P[1][1] + R

        // S^-1 (2x2 inverse)
        let detS = S00 * S11 - S01 * S10
        guard abs(detS) > 1e-10 else { return }
        let invS00 = S11 / detS
        let invS01 = -S01 / detS
        let invS10 = -S10 / detS
        let invS11 = S00 / detS

        // K = P * H^T * S^-1 (4x2 Kalman gain)
        // K[i][j] = sum_k P[i][k] * H^T[k][j] * S^-1
        // H^T = [[1,0], [0,1], [0,0], [0,0]]
        let K00 = P[0][0] * invS00 + P[0][1] * invS10
        let K01 = P[0][0] * invS01 + P[0][1] * invS11
        let K10 = P[1][0] * invS00 + P[1][1] * invS10
        let K11 = P[1][0] * invS01 + P[1][1] * invS11
        let K20 = P[2][0] * invS00 + P[2][1] * invS10
        let K21 = P[2][0] * invS01 + P[2][1] * invS11
        let K30 = P[3][0] * invS00 + P[3][1] * invS10
        let K31 = P[3][0] * invS01 + P[3][1] * invS11

        // x = x + K * innovation
        x += K00 * innovX + K01 * innovY
        y += K10 * innovX + K11 * innovY
        vx += K20 * innovX + K21 * innovY
        vy += K30 * innovX + K31 * innovY

        // P = (I - K*H) * P
        // K*H is 4x4: [[K00,K01,0,0], [K10,K11,0,0], [K20,K21,0,0], [K30,K31,0,0]]
        var newP = P
        for i in 0..<4 {
            let Ki0: CGFloat
            let Ki1: CGFloat
            switch i {
            case 0: Ki0 = K00; Ki1 = K01
            case 1: Ki0 = K10; Ki1 = K11
            case 2: Ki0 = K20; Ki1 = K21
            default: Ki0 = K30; Ki1 = K31
            }
            for j in 0..<4 {
                newP[i][j] = P[i][j] - Ki0 * P[0][j] - Ki1 * P[1][j]
            }
        }
        P = newP
    }

    /// Mahalanobis distance for gating
    func mahalanobisDistance(to point: CGPoint, config: ProcessorConfig) -> CGFloat {
        let innovX = point.x - x
        let innovY = point.y - y

        // S = H*P*H^T + R (use position covariance)
        let R = config.kalmanMeasurementNoise * config.kalmanMeasurementNoise
        let S00 = P[0][0] + R
        let S01 = P[0][1]
        let S10 = P[1][0]
        let S11 = P[1][1] + R

        // S^-1
        let detS = S00 * S11 - S01 * S10
        guard abs(detS) > 1e-10 else { return .greatestFiniteMagnitude }
        let invS00 = S11 / detS
        let invS01 = -S01 / detS
        let invS11 = S00 / detS

        // d² = innovation^T * S^-1 * innovation
        let d2 = innovX * (invS00 * innovX + invS01 * innovY) +
                 innovY * (invS01 * innovX + invS11 * innovY)

        return sqrt(max(0, d2))
    }
}

// MARK: - Kalman Ball Tracker

/// Kalman filter-based tracker with Mahalanobis gating.
/// Uses normalized coordinates ([0,1] in both axes). Designed to resist
/// hijacking by stationary false positives and far-away identical objects.
final class KalmanBallTracker {

    struct TrackedBall {
        private var _positions: [(CGPoint, CMTime)] = []
        private let maxPositions: Int

        /// Kalman filter state
        var kalmanState: KalmanState

        var positions: [(CGPoint, CMTime)] { _positions }

        var age: Int { _positions.count }
        var last: (CGPoint, CMTime)? { _positions.last }
        var first: (CGPoint, CMTime)? { _positions.first }

        var netDisplacement: CGFloat {
            guard let s = first?.0, let e = last?.0 else { return 0 }
            return hypot(e.x - s.x, e.y - s.y)
        }

        init(position: CGPoint, timestamp: CMTime, config: ProcessorConfig, maxPositions: Int = 100) {
            self.maxPositions = maxPositions
            self.kalmanState = KalmanState(position: position, timestamp: timestamp, config: config)
            _positions.append((position, timestamp))
        }

        mutating func predict(to timestamp: CMTime, config: ProcessorConfig) {
            let dt = CGFloat(CMTimeGetSeconds(CMTimeSubtract(timestamp, kalmanState.timestamp)))
            guard dt > 0 else { return }
            kalmanState.predict(dt: dt, config: config)
            kalmanState.timestamp = timestamp
        }

        mutating func update(measurement: CGPoint, timestamp: CMTime, config: ProcessorConfig) {
            kalmanState.update(measurement: measurement, timestamp: timestamp, config: config)
            _positions.append((measurement, timestamp))
            // Enforce sliding window
            if _positions.count > maxPositions {
                _positions.removeFirst(_positions.count - maxPositions)
            }
        }

        /// Predicted position from Kalman state
        var predictedPosition: CGPoint {
            kalmanState.position
        }

        /// Estimated velocity from Kalman state
        var estimatedVelocity: CGPoint {
            kalmanState.velocity
        }
    }

    private(set) var tracks: [TrackedBall] = []
    private let config: ProcessorConfig

    init(config: ProcessorConfig = ProcessorConfig()) {
        self.config = config
    }

    /// Update tracker with detections for the current frame timestamp.
    /// - Important: `DetectionResult.bbox` is expected to be normalized.
    func update(with detections: [DetectionResult]) {
        guard let frameTime = detections.first?.timestamp else {
            // No detections: predict all tracks forward
            return
        }

        // Predict all tracks to current frame time
        for i in tracks.indices {
            tracks[i].predict(to: frameTime, config: config)
        }

        // Precompute centers
        let centers: [(pt: CGPoint, ts: CMTime)] = detections.map { det in
            (pt: rectCenter(det.bbox), ts: det.timestamp)
        }

        // Associate using Mahalanobis gating
        var claimedTracks = Set<Int>()
        for det in centers {
            var bestIdx: Int? = nil
            var bestMahal: CGFloat = .greatestFiniteMagnitude

            for (idx, track) in tracks.enumerated() where !claimedTracks.contains(idx) {
                let mahal = track.kalmanState.mahalanobisDistance(to: det.pt, config: config)
                if mahal <= config.kalmanGateThresholdSigma, mahal < bestMahal {
                    bestMahal = mahal
                    bestIdx = idx
                }
            }

            if let idx = bestIdx {
                // Update existing track with measurement
                tracks[idx].update(measurement: det.pt, timestamp: det.ts, config: config)
                claimedTracks.insert(idx)
            } else {
                // Start a new track only if there isn't an older, stronger track nearby
                if !existsStrongerNeighbor(near: det.pt) {
                    let maxPositions = config.enableMemoryLimits ? config.maxTrackPositions : 1000
                    let newTrack = TrackedBall(
                        position: det.pt,
                        timestamp: det.ts,
                        config: config,
                        maxPositions: maxPositions
                    )
                    tracks.append(newTrack)
                }
            }
        }

        // Prune stale tracks
        tracks.removeAll { track in
            guard let lastTime = track.positions.last?.1 else { return true }
            return CMTimeGetSeconds(CMTimeSubtract(frameTime, lastTime)) > 2.0
        }
    }

    // MARK: - Helpers

    /// Checks whether there is an existing longer-lived track within the gate radius.
    private func existsStrongerNeighbor(near point: CGPoint) -> Bool {
        for track in tracks {
            let mahal = track.kalmanState.mahalanobisDistance(to: point, config: config)
            if mahal <= config.kalmanGateThresholdSigma, track.age >= config.minTrackAgeForPhysics {
                return true
            }
        }
        return false
    }

    private func rectCenter(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}
