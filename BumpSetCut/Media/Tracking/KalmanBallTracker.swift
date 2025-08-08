//
//  KalmanBallTracker.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreGraphics
import CoreMedia

final class KalmanBallTracker {
    struct TrackedBall {
        var positions: [(CGPoint, CMTime)]
    }
    
    private(set) var tracks: [TrackedBall] = []
    
    func update(with detections: [DetectionResult]) {
        // Simple nearest-neighbor association for now
        for det in detections {
            if let idx = tracks.firstIndex(where: { track in
                guard let last = track.positions.last else { return false }
                return distance(last.0, rectCenter(det.bbox)) < 50
            }) {
                tracks[idx].positions.append((rectCenter(det.bbox), det.timestamp))
            } else {
                tracks.append(TrackedBall(positions: [(rectCenter(det.bbox), det.timestamp)]))
            }
        }
        
        // Optional: prune old tracks
        let now = detections.last?.timestamp
        if let now = now {
            tracks.removeAll { track in
                guard let lastTime = track.positions.last?.1 else { return true }
                return CMTimeGetSeconds(CMTimeSubtract(now, lastTime)) > 2.0
            }
        }
    }
    
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
    
    private func rectCenter(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}
