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

    // Tunables (can be overridden via init with defaults below)
    private let minRallySec: Double
    private let prePadSec: Double
    private let postPadSec: Double

    // State
    private var inRally: Bool = false
    private var rallyStartCandidate: CMTime?
    private var lastAnyBall: CMTime?
    private var lastProjectile: CMTime?
    private var projRunStart: CMTime?

    // Sliding window buffers (timestamps)
    private var ballTimes: [CMTime] = []
    private var windowSec: Double = 0.8   // evidence window

    // Segmenting state
    private var rallyStartTime: CMTime?
    private var pendingSegment: (start: CMTime, end: CMTime)?

    init(config: ProcessorConfig, minRallySec: Double = 3.0, prePadSec: Double = 1.5, postPadSec: Double = 1.5) {
        self.config = config
        self.minRallySec = minRallySec
        self.prePadSec = prePadSec
        self.postPadSec = postPadSec
    }

    func reset() {
        inRally = false
        rallyStartCandidate = nil
        lastAnyBall = nil
        lastProjectile = nil
        projRunStart = nil
        ballTimes.removeAll()
        rallyStartTime = nil
        pendingSegment = nil
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
            if projRunStart == nil { projRunStart = now }
        } else {
            // Require continuous projectile evidence; reset run when it drops
            projRunStart = nil
        }
        // Drop old evidence
        pruneOldEvidence(now: now)

        if inRally {
            if shouldEnd(now: now) {
                inRally = false
                // Only emit a segment if we actually had a recorded start time
                if let start = rallyStartTime {
                    let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, start))
                    if elapsed >= minRallySec {
                        // Build padded segment
                        let prePad = CMTimeMakeWithSeconds(prePadSec, preferredTimescale: 600)
                        let postPad = CMTimeMakeWithSeconds(postPadSec, preferredTimescale: 600)
                        let paddedStart = CMTimeMaximum(.zero, CMTimeSubtract(start, prePad))
                        let paddedEnd = CMTimeAdd(now, postPad)
                        pendingSegment = (paddedStart, paddedEnd)
                    }
                }
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

    /// Returns the most recently ended rally segment with pre/post padding, if any, and clears it.
    func popEndedSegment() -> (start: CMTime, end: CMTime)? {
        defer { pendingSegment = nil }
        return pendingSegment
    }
}
