//
//  RallyDecider.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreMedia
import CoreGraphics

/// Hysteresis-based rally state machine with sliding-window evidence.
/// Starts when we see sustained ball evidence or any projectile; ends quickly when evidence disappears.
final class RallyDecider {
    private let config: ProcessorConfig

    // State
    private var inRally: Bool = false
    private var rallyStartCandidate: CMTime?
    private var lastAnyBall: CMTime?
    private var lastProjectile: CMTime?

    // Sliding window buffers (timestamps)
    private var ballTimes: [CMTime] = []
    private var windowSec: Double = 0.8   // evidence window

    init(config: ProcessorConfig) {
        self.config = config
    }

    func reset() {
        inRally = false
        rallyStartCandidate = nil
        lastAnyBall = nil
        lastProjectile = nil
        ballTimes.removeAll()
    }

    /// Update with latest signals.
    /// - Parameters:
    ///   - hasBall: true when model saw a volleyball this frame
    ///   - isProjectile: true when trajectory looks like a projectile
    ///   - timestamp: current PTS
    /// - Returns: current in-rally state
    func update(hasBall: Bool, isProjectile: Bool, timestamp: CMTime) -> Bool {
        let now = timestamp

        if hasBall {
            lastAnyBall = now
            ballTimes.append(now)
        }
        if isProjectile {
            lastProjectile = now
        }
        // Drop old evidence
        pruneOldEvidence(now: now)

        if inRally {
            if shouldEnd(now: now) { inRally = false }
        } else {
            if shouldStart(now: now) { inRally = true; rallyStartCandidate = nil }
        }
        return inRally
    }

    private func pruneOldEvidence(now: CMTime) {
        let cutoff = CMTimeSubtract(now, CMTimeMakeWithSeconds(windowSec, preferredTimescale: 600))
        ballTimes.removeAll { $0 < cutoff }
    }

    private func ballRatePerSec(now: CMTime) -> Double {
        // Simple rate: count / window
        return Double(ballTimes.count) / max(windowSec, 0.001)
    }

    private func timeSince(_ t: CMTime?, now: CMTime) -> Double {
        guard let t = t else { return .infinity }
        return CMTimeGetSeconds(CMTimeSubtract(now, t))
    }

    private func shouldStart(now: CMTime) -> Bool {
        // Start if: any projectile recently OR ball rate sustained and buffered
        let projRecent = timeSince(lastProjectile, now: now) <= 0.8
        let rate = ballRatePerSec(now: now)
        let hasSustainedBall = rate >= 1.5 // ~>= 1–2 detections per second in window

        if projRecent || hasSustainedBall {
            if rallyStartCandidate == nil { rallyStartCandidate = now }
            let dt = CMTimeGetSeconds(CMTimeSubtract(now, rallyStartCandidate!))
            return dt >= config.startBuffer
        } else {
            rallyStartCandidate = nil
            return false
        }
    }

    private func shouldEnd(now: CMTime) -> Bool {
        // Hard end if we haven't seen *any* ball for a bit
        let noBallFor = timeSince(lastAnyBall, now: now)
        if noBallFor >= min(0.8, config.endTimeout) { return true }

        // Softer end: if we haven't seen projectile in a while and ball rate is low
        let noProjFor = timeSince(lastProjectile, now: now)
        if noProjFor > 1.5 && ballRatePerSec(now: now) < 0.5 {
            return true
        }

        // Fallback to global timeout (safety)
        return noBallFor >= config.endTimeout
    }
}
