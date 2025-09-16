//
//  KalmanBallTracker.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreGraphics
import CoreMedia

/// Lightweight constant-velocity tracker with tight association gating.
/// Uses normalized coordinates ([0,1] in both axes). Designed to resist
/// hijacking by stationary false positives and far-away identical objects.
final class KalmanBallTracker {

    struct TrackedBall {
        private var _positions: [(CGPoint, CMTime)] = []
        private let maxPositions: Int

        var positions: [(CGPoint, CMTime)] { _positions }

        var age: Int { _positions.count }
        var last: (CGPoint, CMTime)? { _positions.last }
        var first: (CGPoint, CMTime)? { _positions.first }

        var netDisplacement: CGFloat {
            guard let s = first?.0, let e = last?.0 else { return 0 }
            return hypot(e.x - s.x, e.y - s.y)
        }

        init(maxPositions: Int = 100) {
            self.maxPositions = maxPositions
        }

        mutating func appendPosition(_ position: (CGPoint, CMTime)) {
            _positions.append(position)
            // Enforce sliding window to prevent unbounded memory growth
            if _positions.count > maxPositions {
                _positions.removeFirst(_positions.count - maxPositions)
            }
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
        // Precompute centers
        let centers: [(pt: CGPoint, ts: CMTime)] = detections.map { det in
            (pt: rectCenter(det.bbox), ts: det.timestamp)
        }

        // Associate each detection to the nearest predicted track position within a tight gate
        var claimedTracks = Set<Int>()
        for det in centers {
            // Find the best track within gate
            var bestIdx: Int? = nil
            var bestDist: CGFloat = .greatestFiniteMagnitude
            for (idx, track) in tracks.enumerated() where !claimedTracks.contains(idx) {
                guard let predicted = predictedPosition(for: track) else { continue }
                let d = distance(predicted, det.pt)
                if d <= config.trackGateRadius, d < bestDist {
                    bestDist = d
                    bestIdx = idx
                }
            }

            if let idx = bestIdx {
                // Append to existing track
                tracks[idx].appendPosition((det.pt, det.ts))
                claimedTracks.insert(idx)
            } else {
                // Start a new track only if there isn't an older, stronger track nearby
                // This reduces duplicate tracks for the same object.
                if !existsStrongerNeighbor(near: det.pt) {
                    let maxPositions = config.enableMemoryLimits ? config.maxTrackPositions : 1000
                    var newTrack = TrackedBall(maxPositions: maxPositions)
                    newTrack.appendPosition((det.pt, det.ts))
                    tracks.append(newTrack)
                }
            }
        }

        // Prune stale tracks that haven't been updated for a while
        let now = detections.last?.timestamp
        if let now = now {
            tracks.removeAll { track in
                guard let lastTime = track.positions.last?.1 else { return true }
                return CMTimeGetSeconds(CMTimeSubtract(now, lastTime)) > 2.0
            }
        }
    }

    // MARK: - Helpers

    private func predictedPosition(for track: TrackedBall) -> CGPoint? {
        guard track.positions.count >= 1 else { return nil }
        guard track.positions.count >= 2 else { return track.positions.last!.0 }
        // Simple constant-velocity extrapolation based on last two samples
        let p1 = track.positions[track.positions.count - 1].0
        let p0 = track.positions[track.positions.count - 2].0
        let v = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
        return CGPoint(x: p1.x + v.x, y: p1.y + v.y)
    }

    /// Checks whether there is an existing longer-lived track within the gate radius.
    private func existsStrongerNeighbor(near point: CGPoint) -> Bool {
        for track in tracks {
            guard let last = track.last?.0 else { continue }
            if distance(last, point) <= config.trackGateRadius, track.age >= config.minTrackAgeForPhysics {
                return true
            }
        }
        return false
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func rectCenter(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}
