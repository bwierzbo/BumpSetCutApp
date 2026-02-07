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
///
/// Padding is applied by `SegmentBuilder`, not here. This class only decides when rallies
/// start and end, returning a Bool from `update()`.
final class RallyDecider {
    private let config: ProcessorConfig

    // Tunables (can be overridden via init with defaults below)
    private let minRallySec: Double

    // State
    private var inRally: Bool = false
    private var rallyStartCandidate: CMTime?
    private var lastAnyBall: CMTime?
    private var lastProjectile: CMTime?
    private var projRunStart: CMTime?
    private var projDropCount: Int = 0

    // Sliding window buffers (timestamps)
    private var ballTimes: [CMTime] = []
    private var windowSec: Double = 0.8   // evidence window

    // Segmenting state
    private var rallyStartTime: CMTime?

    init(config: ProcessorConfig, minRallySec: Double = 3.0) {
        self.config = config
        self.minRallySec = minRallySec
    }

    func reset() {
        inRally = false
        rallyStartCandidate = nil
        lastAnyBall = nil
        lastProjectile = nil
        projRunStart = nil
        projDropCount = 0
        ballTimes.removeAll()
        rallyStartTime = nil
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
            projDropCount = 0
            if projRunStart == nil { projRunStart = now }
        } else {
            // Allow a short grace period before resetting the projectile run,
            // so a single dropped frame doesn't restart the start-buffer clock.
            projDropCount += 1
            if projDropCount > config.projDropGracePeriod {
                projRunStart = nil
                projDropCount = 0
            }
        }
        // Drop old evidence
        pruneOldEvidence(now: now)

        if inRally {
            if shouldEnd(now: now) {
                inRally = false
                rallyStartTime = nil
            }
        } else {
            if shouldStart(now: now) {
                inRally = true
                rallyStartCandidate = nil
                rallyStartTime = now
            }
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
        // Start only after continuous projectile evidence for at least startBuffer seconds
        guard let runStart = projRunStart else { return false }
        let dt = CMTimeGetSeconds(CMTimeSubtract(now, runStart))
        return dt >= config.startBuffer
    }

    private func shouldEnd(now: CMTime) -> Bool {
        // Enforce minimum rally duration to prevent flicker/short clips
        if let start = rallyStartTime {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, start))
            if elapsed < minRallySec { return false }
        }
        // Keep rally alive if we've seen a valid projectile very recently (handles brief occlusions under the net)
        if timeSince(lastProjectile, now: now) <= 1.0 {
            return false
        }
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
