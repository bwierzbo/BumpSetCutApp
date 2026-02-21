//
//  RallyDeciderGracePeriodTests.swift
//  BumpSetCutTests
//
//  Tests for RallyDecider projRunStart grace period behavior.
//  A single dropped projectile frame should not reset the start-buffer clock.
//

import XCTest
import CoreMedia
@testable import BumpSetCut

final class RallyDeciderGracePeriodTests: XCTestCase {

    private func time(_ seconds: Double) -> CMTime {
        CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)
    }

    // MARK: - 1. Single dropped frame does NOT reset projRunStart

    func testSingleDroppedFrame_DoesNotResetProjRunStart() {
        var config = ProcessorConfig()
        config.projDropGracePeriod = 2 // allow up to 2 consecutive non-projectile frames

        let decider = RallyDecider(config: config)
        let dt = 1.0 / 30.0

        // Feed projectile for 0.2s (6 frames)
        for i in 0..<6 {
            _ = decider.update(hasBall: true, isProjectile: true, timestamp: time(Double(i) * dt))
        }

        // Drop 1 frame (within grace period)
        _ = decider.update(hasBall: true, isProjectile: false, timestamp: time(6.0 * dt))

        // Resume projectile -- the run should still be counting from the original start
        // Total elapsed: 0.0 to ~0.33s = 10 frames at 30fps, well past startBuffer=0.3s
        var state = false
        for i in 7..<11 {
            state = decider.update(hasBall: true, isProjectile: true, timestamp: time(Double(i) * dt))
        }

        XCTAssertTrue(state, "Rally should start because projRunStart survived 1 dropped frame within grace period")
    }

    // MARK: - 2. Exceeding grace period DOES reset projRunStart

    func testExceedingGracePeriod_ResetsProjRunStart() {
        var config = ProcessorConfig()
        config.projDropGracePeriod = 2
        config.startBuffer = 0.3

        let decider = RallyDecider(config: config)
        let dt = 1.0 / 30.0

        // Feed projectile for 0.2s (6 frames)
        for i in 0..<6 {
            _ = decider.update(hasBall: true, isProjectile: true, timestamp: time(Double(i) * dt))
        }

        // Drop 3 frames (exceeds grace period of 2)
        for i in 6..<9 {
            _ = decider.update(hasBall: true, isProjectile: false, timestamp: time(Double(i) * dt))
        }

        // Resume projectile -- projRunStart was reset, so we need another full startBuffer
        // Feed only 0.2s more (not enough to reach startBuffer again from new start)
        var state = false
        for i in 9..<15 {
            state = decider.update(hasBall: true, isProjectile: true, timestamp: time(Double(i) * dt))
        }

        XCTAssertFalse(state, "Rally should NOT start because grace period was exceeded, resetting the start-buffer clock")
    }

    // MARK: - 3. Grace period of 0 preserves original strict behavior

    func testGracePeriodZero_StrictBehavior() {
        var config = ProcessorConfig()
        config.projDropGracePeriod = 0 // any non-projectile frame resets immediately

        let decider = RallyDecider(config: config)
        let dt = 1.0 / 30.0

        // Feed projectile for 0.25s (8 frames, just under startBuffer=0.3s)
        for i in 0..<8 {
            _ = decider.update(hasBall: true, isProjectile: true, timestamp: time(Double(i) * dt))
        }

        // Drop exactly 1 frame -- with grace=0, this should reset projRunStart
        _ = decider.update(hasBall: true, isProjectile: false, timestamp: time(8.0 * dt))

        // Resume projectile for only a short burst (not enough for startBuffer from scratch)
        var state = false
        for i in 9..<15 {
            state = decider.update(hasBall: true, isProjectile: true, timestamp: time(Double(i) * dt))
        }

        XCTAssertFalse(state, "With grace=0, a single dropped frame should reset projRunStart (strict behavior)")
    }
}
