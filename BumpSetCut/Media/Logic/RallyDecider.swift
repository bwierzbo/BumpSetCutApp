//
//  RallyDecider.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreMedia
import CoreGraphics

/// Hysteresis-based rally state machine.
/// Start after sustained activity (`startBuffer`), end after inactivity (`endTimeout`).
final class RallyDecider {
    private let config: ProcessorConfig

    private var inRally: Bool = false
    private var rallyStartCandidate: CMTime?
    private var lastActive: CMTime?

    init(config: ProcessorConfig) {
        self.config = config
    }

    func reset() {
        inRally = false
        rallyStartCandidate = nil
        lastActive = nil
    }

    /// Update with the latest evidence that ball is actively being played.
    /// - Parameters:
    ///   - isBallActive: true if ballistics gate passed and motion looks real.
    ///   - timestamp: frame PTS
    /// - Returns: current in-rally state
    func update(isBallActive: Bool, timestamp: CMTime) -> Bool {
        if isBallActive {
            lastActive = timestamp
        }

        if inRally {
            if shouldEnd(now: timestamp) {
                inRally = false
            }
        } else {
            if shouldStart(now: timestamp, active: isBallActive) {
                inRally = true
                rallyStartCandidate = nil
                lastActive = timestamp
            }
        }

        return inRally
    }

    private func shouldStart(now: CMTime, active: Bool) -> Bool {
        guard active else { return false }
        if rallyStartCandidate == nil { rallyStartCandidate = now }
        let dt = CMTimeGetSeconds(CMTimeSubtract(now, rallyStartCandidate!))
        return dt >= config.startBuffer
    }

    private func shouldEnd(now: CMTime) -> Bool {
        guard let last = lastActive else { return true }
        let dt = CMTimeGetSeconds(CMTimeSubtract(now, last))
        return dt >= config.endTimeout
    }
}
