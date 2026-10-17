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
    /// Normalized vertical position (Vision coords, 1.0 = top) of the ball the
    /// last frame it was seen — used to grant sky-ball grace when it exits the top.
    private var lastBallY: CGFloat?

    // Sliding window buffers (timestamps)
    private var ballTimes: [CMTime] = []
    private var windowSec: Double = 0.8   // evidence window

    // Segmenting state
    private var rallyStartTime: CMTime?

    // A serve that just flew (noteServe), waiting for play to go on; the
    // projectile time seen since its flight ended.
    private var primedServe: ServeDetector.Serve?
    private var primedProjectileSec = 0.0
    private var lastUpdate: CMTime?
    /// The serve the current rally started on (or moved back to), if one did.
    private(set) var rallyServe: ServeDetector.Serve?

    init(config: ProcessorConfig, minRallySec: Double = 1.1653) {
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
        lastBallY = nil
        primedServe = nil
        primedProjectileSec = 0
        lastUpdate = nil
        rallyServe = nil
    }

    /// When the current rally started — earlier than the frame it started on
    /// when a serve dates it (SegmentBuilder opens the segment there).
    var rallyStart: CMTime? { rallyStartTime }

    /// A serve just flew (ServeWatch). Out of a rally it primes the start:
    /// the rally begins at the serve once play goes on (`shouldStart`). In a
    /// rally that began on the serve's heels — the gate caught the pass, not
    /// the serve — the start moves back to the serve.
    ///
    /// A ball tossed back to the server flies like a serve too; caught and
    /// held, nothing follows it and it expires unstarted. Tossed straight
    /// back up into the serve, it dates the rally a moment before the toss
    /// — and wears the serve's label. A rally already started on a serve
    /// keeps it; a newer flight primes in place of an older one still waiting.
    func noteServe(_ serve: ServeDetector.Serve) {
        guard config.servePrimedStart else { return }
        if inRally {
            guard rallyServe == nil, let start = rallyStartTime else { return }
            let s = CMTimeGetSeconds(start)
            if s >= serve.contact - 0.5, s <= serve.end + config.serveContinuationSec {
                rallyStartTime = CMTimeMakeWithSeconds(serve.start, preferredTimescale: 600)
                rallyServe = serve
            }
        } else {
            primedServe = serve
            primedProjectileSec = 0
        }
    }

    /// Update with latest signals.
    /// - Parameters:
    ///   - hasBall: true when model saw a volleyball this frame
    ///   - isProjectile: true when trajectory looks like a projectile
    ///   - timestamp: current PTS
    ///   - ballY: normalized vertical position of the ball this frame (Vision
    ///     coords, 1.0 = top of frame), when known — used for sky-ball grace.
    /// - Returns: current in-rally state
    func update(hasBall: Bool, isProjectile: Bool, timestamp: CMTime, ballY: CGFloat? = nil) -> Bool {
        let now = timestamp

        if hasBall {
            lastAnyBall = now
            ballTimes.append(now)
            if let ballY { lastBallY = ballY }
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

        // A primed serve: count projectile time after its flight, until the
        // continuation window closes short of a start (a ball tossed back).
        if let serve = primedServe {
            let t = CMTimeGetSeconds(now)
            if t > serve.end + config.serveContinuationSec {
                primedServe = nil
            } else if isProjectile, t > serve.end, let last = lastUpdate {
                primedProjectileSec += min(t - CMTimeGetSeconds(last), 0.2)
            }
        }
        lastUpdate = now

        if inRally {
            if shouldEnd(now: now) {
                inRally = false
                rallyStartTime = nil
                rallyServe = nil
            }
        } else {
            if shouldStart(now: now) {
                inRally = true
                rallyStartCandidate = nil
                // Started on a serve (primed, or the gate's own start on its
                // heels): the rally dates from the serve.
                rallyStartTime = primedServe.map { CMTimeMakeWithSeconds($0.start, preferredTimescale: 600) } ?? now
                rallyServe = primedServe
                primedServe = nil
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
        // A serve followed by play: the rally starts (at the serve).
        if primedServe != nil, primedProjectileSec >= config.serveContinuationProjectileSec { return true }
        // Start only after continuous projectile evidence spanning at least
        // startBuffer seconds — measured to the last projectile frame, not to
        // now: the grace period keeps a dropped frame from restarting the run,
        // but dropped frames must not count toward it (two projectile frames
        // plus gaps used to start a rally with no ball in the air).
        guard let runStart = projRunStart, let last = lastProjectile else { return false }
        let dt = CMTimeGetSeconds(CMTimeSubtract(last, runStart))
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

        let noBallFor = timeSince(lastAnyBall, now: now)

        // Sky-ball grace: the ball was last seen near the top of the frame, so it
        // likely left the top of view on a high arc (sky ball / high dig). Give it
        // the longer sky-ball timeout to come back down before ending; skip the
        // normal hard/soft ends, which would cut it off early.
        if (lastBallY ?? 0) >= config.skyBallTopThreshold {
            return noBallFor >= config.skyBallTimeout
        }

        // Hard end if we haven't seen *any* ball for a bit
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
