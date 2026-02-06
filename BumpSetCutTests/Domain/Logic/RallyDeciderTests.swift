//
//  RallyDeciderTests.swift
//  BumpSetCutTests
//
//  Tests for RallyDecider state machine: idle/active transitions,
//  hysteresis, minimum duration enforcement, and edge cases.
//

import XCTest
import CoreMedia
@testable import BumpSetCut

final class RallyDeciderTests: XCTestCase {

    // Default config used by most tests
    private var config: ProcessorConfig!

    override func setUp() {
        super.setUp()
        config = ProcessorConfig()
        // Defaults: startBuffer=0.3, endTimeout=1.0, minRallySec=3.0
    }

    override func tearDown() {
        config = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Create a CMTime from seconds with 600 timescale (matches production code).
    private func time(_ seconds: Double) -> CMTime {
        CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)
    }

    /// Feed the decider a sequence of (hasBall, isProjectile, time) and return final state.
    @discardableResult
    private func feed(
        _ decider: RallyDecider,
        events: [(hasBall: Bool, isProjectile: Bool, t: Double)]
    ) -> Bool {
        var state = false
        for e in events {
            state = decider.update(hasBall: e.hasBall, isProjectile: e.isProjectile, timestamp: time(e.t))
        }
        return state
    }

    // MARK: - 1. Idle -> Active transition (sustained projectile >= startBuffer)

    func testIdleToActiveTransition_SustainedProjectile() {
        let decider = RallyDecider(config: config)

        // Send continuous projectile evidence for 0.4s (> startBuffer 0.3s)
        var events: [(hasBall: Bool, isProjectile: Bool, t: Double)] = []
        for i in 0...12 {
            let t = Double(i) * (1.0 / 30.0) // ~30fps, 0.4s total
            events.append((hasBall: true, isProjectile: true, t: t))
        }

        let state = feed(decider, events: events)
        XCTAssertTrue(state, "Decider should transition to active after sustained projectile evidence >= startBuffer (0.3s)")
    }

    // MARK: - 2. Active -> Idle transition (ball absence > endTimeout)

    func testActiveToIdleTransition_BallAbsence() {
        let decider = RallyDecider(config: config)

        // First, enter rally with sustained evidence for ~4s (past minRallySec=3.0)
        var events: [(hasBall: Bool, isProjectile: Bool, t: Double)] = []
        for i in 0...120 {
            let t = Double(i) * (1.0 / 30.0) // 4.0s
            events.append((hasBall: true, isProjectile: true, t: t))
        }
        var state = feed(decider, events: events)
        XCTAssertTrue(state, "Should be in rally after sustained evidence")

        // Now send no ball / no projectile for > endTimeout (1.0s)
        let rallyEnd = 4.0
        for i in 1...40 {
            let t = rallyEnd + Double(i) * (1.0 / 30.0) // 1.3s of silence
            state = decider.update(hasBall: false, isProjectile: false, timestamp: time(t))
        }
        XCTAssertFalse(state, "Decider should exit rally after ball absence exceeding endTimeout")
    }

    // MARK: - 3. Minimum rally duration enforcement

    func testMinimumRallyDurationEnforcement() {
        let decider = RallyDecider(config: config, minRallySec: 3.0)

        // Enter rally
        var events: [(hasBall: Bool, isProjectile: Bool, t: Double)] = []
        for i in 0...15 {
            let t = Double(i) * (1.0 / 30.0) // ~0.5s of evidence to enter
            events.append((hasBall: true, isProjectile: true, t: t))
        }
        let enteredRally = feed(decider, events: events)
        XCTAssertTrue(enteredRally, "Should enter rally after startBuffer")

        // Immediately stop all evidence at ~0.5s -- rally just started, should NOT exit
        // because minRallySec=3.0s hasn't elapsed yet
        let stopTime = 0.6
        for i in 1...30 {
            let t = stopTime + Double(i) * (1.0 / 30.0) // 1.0s of no evidence
            let state = decider.update(hasBall: false, isProjectile: false, timestamp: time(t))
            // Within minRallySec window, decider should stay active
            if t - 0.5 < 3.0 {
                // Note: the decider may or may not stay active depending on endTimeout vs minRallySec
                // The shouldEnd function checks elapsed < minRallySec first and returns false
                XCTAssertTrue(state, "Should NOT exit rally before minRallySec (\(String(format: "%.2f", t))s into rally)")
            }
        }
    }

    // MARK: - 4. Soft end condition (no projectile + low ball rate)

    func testSoftEndCondition_NoProjectileLowBallRate() {
        let decider = RallyDecider(config: config, minRallySec: 1.0) // Lower min for this test

        // Enter rally with sustained evidence for 2.0s
        var events: [(hasBall: Bool, isProjectile: Bool, t: Double)] = []
        for i in 0...60 {
            let t = Double(i) * (1.0 / 30.0)
            events.append((hasBall: true, isProjectile: true, t: t))
        }
        let state = feed(decider, events: events)
        XCTAssertTrue(state, "Should be in rally")

        // Now: no projectile for > 1.5s, occasional ball but low rate (< 0.5/s)
        let base = 2.0
        var finalState = state
        // Send sparse ball detections (one every 3 seconds -- well below 0.5/s)
        for i in 1...60 {
            let t = base + Double(i) * (1.0 / 30.0) // 2.0s more
            let hasBall = (i == 15) // single ball at ~0.5s in -- not enough rate
            finalState = decider.update(hasBall: hasBall, isProjectile: false, timestamp: time(t))
        }
        XCTAssertFalse(finalState, "Should exit via soft end: no projectile for 1.5s + low ball rate")
    }

    // MARK: - 5. Hard end condition (no ball for 0.8s)

    func testHardEndCondition_NoBallForThreshold() {
        let decider = RallyDecider(config: config, minRallySec: 1.0) // Lower min for test

        // Enter rally with 2s of evidence
        var events: [(hasBall: Bool, isProjectile: Bool, t: Double)] = []
        for i in 0...60 {
            let t = Double(i) * (1.0 / 30.0)
            events.append((hasBall: true, isProjectile: true, t: t))
        }
        feed(decider, events: events)

        // Now: complete silence -- no ball, no projectile
        let base = 2.0
        var exited = false
        for i in 1...40 {
            let t = base + Double(i) * (1.0 / 30.0) // up to ~1.3s
            let state = decider.update(hasBall: false, isProjectile: false, timestamp: time(t))
            if !state {
                exited = true
                // Hard end should fire around 0.8s of no-ball
                XCTAssertGreaterThanOrEqual(t - base, 0.8, "Hard end should not fire before 0.8s of no ball")
                break
            }
        }
        XCTAssertTrue(exited, "Should have exited rally via hard end condition")
    }

    // MARK: - 6. Stay-alive when projectile seen within 1.0s

    func testStayAlive_ProjectileWithinWindow() {
        let decider = RallyDecider(config: config, minRallySec: 1.0)

        // Enter rally with 2s of evidence
        var events: [(hasBall: Bool, isProjectile: Bool, t: Double)] = []
        for i in 0...60 {
            let t = Double(i) * (1.0 / 30.0)
            events.append((hasBall: true, isProjectile: true, t: t))
        }
        feed(decider, events: events)

        // Brief gap with no ball/projectile for 0.5s, then projectile again
        let base = 2.0
        for i in 1...15 {
            let t = base + Double(i) * (1.0 / 30.0) // 0.5s gap
            decider.update(hasBall: false, isProjectile: false, timestamp: time(t))
        }

        // Projectile returns at 2.5s
        let state = decider.update(hasBall: true, isProjectile: true, timestamp: time(2.5))
        XCTAssertTrue(state, "Rally should stay alive when projectile returns within 1.0s window")
    }

    // MARK: - 7. Multiple rally detection in one session

    func testMultipleRalliesInOneSession() {
        let decider = RallyDecider(config: config, minRallySec: 1.0)

        // Rally 1: 0-2s
        for i in 0...60 {
            let t = Double(i) * (1.0 / 30.0)
            decider.update(hasBall: true, isProjectile: true, timestamp: time(t))
        }
        // Check segment from rally 1 exit
        // Gap: 2s-5s (no evidence)
        for i in 1...90 {
            let t = 2.0 + Double(i) * (1.0 / 30.0)
            decider.update(hasBall: false, isProjectile: false, timestamp: time(t))
        }
        let seg1 = decider.popEndedSegment()
        XCTAssertNotNil(seg1, "First rally should produce a segment")

        // Rally 2: 5s-7s
        for i in 0...60 {
            let t = 5.0 + Double(i) * (1.0 / 30.0)
            decider.update(hasBall: true, isProjectile: true, timestamp: time(t))
        }
        // End rally 2
        for i in 1...90 {
            let t = 7.0 + Double(i) * (1.0 / 30.0)
            decider.update(hasBall: false, isProjectile: false, timestamp: time(t))
        }
        let seg2 = decider.popEndedSegment()
        XCTAssertNotNil(seg2, "Second rally should produce a segment")

        // Segments should be distinct
        if let s1 = seg1, let s2 = seg2 {
            XCTAssertTrue(CMTimeCompare(s1.end, s2.start) <= 0,
                          "Rally segments should not overlap")
        }
    }

    // MARK: - 8. Very short ball evidence (below startBuffer)

    func testShortEvidence_BelowStartBuffer() {
        let decider = RallyDecider(config: config)

        // Send projectile for only 0.1s (< startBuffer 0.3s)
        var events: [(hasBall: Bool, isProjectile: Bool, t: Double)] = []
        for i in 0...3 {
            let t = Double(i) * (1.0 / 30.0)
            events.append((hasBall: true, isProjectile: true, t: t))
        }
        let state = feed(decider, events: events)
        XCTAssertFalse(state, "Should NOT enter rally with evidence shorter than startBuffer")
    }

    // MARK: - 9. Rapid start/stop cycling

    func testRapidStartStopCycling() {
        let decider = RallyDecider(config: config, minRallySec: 1.0)
        var segments: [(start: CMTime, end: CMTime)] = []

        var t = 0.0
        // 5 cycles of: 0.2s projectile (below startBuffer), 0.5s gap
        for _ in 0..<5 {
            // Short burst -- should NOT trigger rally entry
            for _ in 0..<6 {
                decider.update(hasBall: true, isProjectile: true, timestamp: time(t))
                t += 1.0 / 30.0
            }
            // Gap
            for _ in 0..<15 {
                decider.update(hasBall: false, isProjectile: false, timestamp: time(t))
                t += 1.0 / 30.0
            }
            if let seg = decider.popEndedSegment() {
                segments.append(seg)
            }
        }

        XCTAssertEqual(segments.count, 0,
                       "Rapid short bursts below startBuffer should not produce rally segments")
    }

    // MARK: - 10. Reset clears state completely

    func testResetClearsState() {
        let decider = RallyDecider(config: config)

        // Enter rally
        for i in 0...30 {
            let t = Double(i) * (1.0 / 30.0)
            decider.update(hasBall: true, isProjectile: true, timestamp: time(t))
        }

        // Reset
        decider.reset()

        // After reset, same short evidence should NOT produce a rally
        let state = decider.update(hasBall: true, isProjectile: true, timestamp: time(0.0))
        XCTAssertFalse(state, "After reset, decider should be in idle state")
        XCTAssertNil(decider.popEndedSegment(), "After reset, no pending segments should exist")
    }

    // MARK: - 11. Segment padding (pre/post roll applied by RallyDecider)

    func testSegmentPadding() {
        let prePad = 1.5
        let postPad = 1.5
        let decider = RallyDecider(config: config, minRallySec: 1.0, prePadSec: prePad, postPadSec: postPad)

        // Rally from ~0.5s to ~3.5s
        let rallyStart = 0.5
        for i in 0...90 {
            let t = rallyStart + Double(i) * (1.0 / 30.0)
            decider.update(hasBall: true, isProjectile: true, timestamp: time(t))
        }

        // End rally
        let rallyEnd = 3.5
        for i in 1...40 {
            let t = rallyEnd + Double(i) * (1.0 / 30.0)
            decider.update(hasBall: false, isProjectile: false, timestamp: time(t))
        }

        if let seg = decider.popEndedSegment() {
            let segStart = CMTimeGetSeconds(seg.start)
            let segEnd = CMTimeGetSeconds(seg.end)

            // Segment start should be approximately rallyStartTime - prePad (clamped to 0)
            // Rally enters after startBuffer (~0.3s) from first projectile
            XCTAssertLessThanOrEqual(segStart, rallyStart + 0.5,
                                     "Segment start should include pre-padding")
            // Segment end should be approximately endTime + postPad
            XCTAssertGreaterThan(segEnd, rallyEnd,
                                  "Segment end should include post-padding")
        } else {
            XCTFail("Expected a segment to be produced")
        }
    }

    // MARK: - 12. Ball-only evidence (no projectile) does not start rally

    func testBallOnlyDoesNotStartRally() {
        let decider = RallyDecider(config: config)

        // Send only hasBall=true, isProjectile=false for a long time
        for i in 0...90 {
            let t = Double(i) * (1.0 / 30.0)
            let state = decider.update(hasBall: true, isProjectile: false, timestamp: time(t))
            XCTAssertFalse(state, "Ball-only evidence (no projectile) should never start a rally")
        }
    }
}
