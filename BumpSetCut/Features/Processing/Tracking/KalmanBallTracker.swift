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
        /// Stable identity for the life of this track — set once, preserved as the
        /// array element is mutated in place each frame. Lets the selector follow a
        /// chosen trajectory across frames (stickiness) and lets RallyLab draw each
        /// candidate's trail.
        let id = UUID()

        // (raw measurement, Kalman-filtered position, bbox size, timestamp)
        private var _positions: [(CGPoint, CGPoint, CGSize, CMTime)] = []
        private let maxPositions: Int

        /// Kalman filter state
        var kalmanState: KalmanState

        /// Mean bbox area over recent positions (normalized units²). A far-court
        /// ball is smaller; used as a tiebreaker when ranking candidate tracks.
        func meanBboxArea(lastN: Int = 12) -> CGFloat {
            let areas = _positions.suffix(lastN).map { $0.2.width * $0.2.height }
            guard !areas.isEmpty else { return 0 }
            return areas.reduce(0, +) / CGFloat(areas.count)
        }

        /// Approximate spatial ROI radius (normalized units) of this track's
        /// association gate: a detection within ~this distance of the predicted
        /// position is matched to this track; one outside it starts a new track.
        /// Derived from the Kalman position covariance × the gate sigma, so it's
        /// the actual region this trajectory "owns." Visualized in RallyLab.
        func associationRadius(config: ProcessorConfig) -> CGFloat {
            let R = config.kalmanMeasurementNoise * config.kalmanMeasurementNoise
            let varX = kalmanState.P[0][0] + R
            let varY = kalmanState.P[1][1] + R
            return config.kalmanGateThresholdSigma * sqrt(max(0, (varX + varY) / 2))
        }

        /// Raw detection-center positions (what the model reported each frame).
        var positions: [(CGPoint, CMTime)] { _positions.map { ($0.0, $0.3) } }

        /// Kalman-filtered positions — the same path smoothed against single-frame
        /// detection noise. Used by the gate when `useSmoothedTrack` is on.
        var smoothedPositions: [(CGPoint, CMTime)] { _positions.map { ($0.1, $0.3) } }

        /// Positions with bbox size for serve inference
        var positionsWithSize: [(center: CGPoint, bboxSize: CGSize, time: CMTime)] {
            _positions.map { (center: $0.0, bboxSize: $0.2, time: $0.3) }
        }

        var age: Int { _positions.count }
        var last: (CGPoint, CMTime)? { _positions.last.map { ($0.0, $0.3) } }
        var first: (CGPoint, CMTime)? { _positions.first.map { ($0.0, $0.3) } }

        var netDisplacement: CGFloat {
            guard let s = first?.0, let e = last?.0 else { return 0 }
            return hypot(e.x - s.x, e.y - s.y)
        }

        init(position: CGPoint, bboxSize: CGSize = .zero, timestamp: CMTime, config: ProcessorConfig, maxPositions: Int = 100) {
            self.maxPositions = maxPositions
            self.kalmanState = KalmanState(position: position, timestamp: timestamp, config: config)
            _positions.append((position, position, bboxSize, timestamp))
        }

        mutating func predict(to timestamp: CMTime, config: ProcessorConfig) {
            let dt = CGFloat(CMTimeGetSeconds(CMTimeSubtract(timestamp, kalmanState.timestamp)))
            guard dt > 0 else { return }
            kalmanState.predict(dt: dt, config: config)
            kalmanState.timestamp = timestamp
        }

        mutating func update(measurement: CGPoint, bboxSize: CGSize = .zero, timestamp: CMTime, config: ProcessorConfig) {
            kalmanState.update(measurement: measurement, timestamp: timestamp, config: config)
            // Store both the raw measurement and the post-update filtered estimate.
            _positions.append((measurement, kalmanState.position, bboxSize, timestamp))
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

    /// Timestamp of the most recent detection update
    private(set) var lastDetectionTime: CMTime?

    init(config: ProcessorConfig = ProcessorConfig()) {
        self.config = config
    }

    // MARK: - Dynamic Stride Support

    /// Whether there's at least one active track being updated
    var hasActiveTrack: Bool {
        tracks.contains { $0.age >= 3 }  // At least 3 detections
    }

    /// Time in seconds since the last detection was processed
    func timeSinceLastDetection(currentTime: CMTime) -> Double {
        guard let lastTime = lastDetectionTime else { return .greatestFiniteMagnitude }
        return CMTimeGetSeconds(CMTimeSubtract(currentTime, lastTime))
    }

    /// Recommended frame stride based on current tracking state
    func recommendedStride(currentTime: CMTime) -> Int {
        // Actively tracking a ball: process every frame by default. The physics
        // gate fits a parabola over a fixed-time window and needs enough samples
        // in it; skipping frames here under-samples the arc and makes the gate
        // flicker. Configurable via `activeTrackingStride`. Frame-skipping for
        // idle stretches is handled below.
        if hasActiveTrack {
            return max(1, config.activeTrackingStride)
        }

        // If recently lost track, use moderate stride
        let timeSinceLost = timeSinceLastDetection(currentTime: currentTime)
        if timeSinceLost < 1.0 {
            return 3
        }

        // No recent detections, can skip more frames
        return 4
    }

    /// Update tracker with detections for the current frame timestamp.
    /// - Parameters:
    ///   - detections: this frame's detections (`bbox` expected normalized).
    ///   - currentTime: the frame's PTS. Pass this so tracks can be aged out
    ///     even on frames with **no** detections — otherwise a track frozen at
    ///     the ball's last in-frame position survives indefinitely while the
    ///     ball is out of view, and its stale arc keeps re-validating as a
    ///     projectile. Falls back to the detections' timestamp when omitted.
    func update(with detections: [DetectionResult], at currentTime: CMTime? = nil) {
        guard let frameTime = currentTime ?? detections.first?.timestamp else {
            // No detections and no clock supplied — nothing we can age or associate.
            return
        }

        if !detections.isEmpty {
            // Update last detection time for dynamic stride
            lastDetectionTime = frameTime

            // Predict all tracks to current frame time
            for i in tracks.indices {
                tracks[i].predict(to: frameTime, config: config)
            }
        }

        // Precompute centers and bbox sizes
        let centers: [(pt: CGPoint, bboxSize: CGSize, ts: CMTime)] = detections.map { det in
            (pt: rectCenter(det.bbox),
             bboxSize: CGSize(width: det.bbox.width, height: det.bbox.height),
             ts: det.timestamp)
        }

        // Associate using sorted Mahalanobis distance (globally optimal greedy).
        // Build all valid (track, detection) candidate pairs, sort by ascending
        // distance, then assign greedily. This eliminates ordering bias that
        // causes ID switches when multiple balls are visible.
        var candidates: [(trackIdx: Int, detIdx: Int, mahal: CGFloat)] = []
        for (detIdx, det) in centers.enumerated() {
            for (trackIdx, track) in tracks.enumerated() {
                let mahal = track.kalmanState.mahalanobisDistance(to: det.pt, config: config)
                if mahal <= config.kalmanGateThresholdSigma {
                    candidates.append((trackIdx: trackIdx, detIdx: detIdx, mahal: mahal))
                }
            }
        }
        candidates.sort { $0.mahal < $1.mahal }

        var claimedTracks = Set<Int>()
        var claimedDets = Set<Int>()
        for c in candidates {
            guard !claimedTracks.contains(c.trackIdx), !claimedDets.contains(c.detIdx) else { continue }
            tracks[c.trackIdx].update(measurement: centers[c.detIdx].pt,
                                      bboxSize: centers[c.detIdx].bboxSize,
                                      timestamp: centers[c.detIdx].ts,
                                      config: config)
            claimedTracks.insert(c.trackIdx)
            claimedDets.insert(c.detIdx)
        }

        // Unclaimed detections start new tracks (if no stronger neighbor exists)
        for (detIdx, det) in centers.enumerated() where !claimedDets.contains(detIdx) {
            if !existsStrongerNeighbor(near: det.pt) {
                let maxPositions = config.enableMemoryLimits ? config.maxTrackPositions : 1000
                let newTrack = TrackedBall(
                    position: det.pt,
                    bboxSize: det.bboxSize,
                    timestamp: det.ts,
                    config: config,
                    maxPositions: maxPositions
                )
                tracks.append(newTrack)
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
