//
//  DeterministicRallyEngine.swift
//  BumpSetCut
//
//  Phase 1 rally engine: ball continuity + a finite state machine over court
//  geometry. Deterministic and explainable — no ML scoring, no action inference.
//  Consumes the dense per-frame ball samples + the fixed net, emits rallies (with
//  net crossings / side changes / lost-track / confidence / end reason) and a
//  per-frame state log for the timeline + overlay.
//

import CoreGraphics
import Foundation

struct DeterministicRallyEngine {
    var config: EngineConfig

    func run(samples: [BallSample], net: DetectedNet) -> EngineResult {
        let court = CourtGeometry(net: net, bufferX: config.bufferX, bufferY: config.bufferY)
        var states: [FrameState] = []
        var rallies: [RallyRecord] = []
        var nextRallyId = 1

        // --- Tracked ball (continuity) ---
        var trackPos: CGPoint? = nil
        var trackVel = CGVector.zero
        var lastSeenTime = 0.0
        var lastSeenFrame = 0
        var stableFrames = 0
        var framesSinceSeen = 0

        var state: RallyState = .idle
        var prevFrameTime = samples.first?.time ?? 0

        // --- Rally accumulators (valid while ACTIVE/LOST) ---
        var rStartFrame = 0, rStartTime = 0.0
        var rNetCross = 0, rSideChange = 0, rLost = 0
        var rFrames = 0, rMatched = 0
        var rSumConf = 0.0, rCountConf = 0
        var stationaryTime = 0.0
        var prevSeenSide: CourtSide? = nil

        func resetRallyAccumulators() {
            rNetCross = 0; rSideChange = 0; rLost = 0
            rFrames = 0; rMatched = 0; rSumConf = 0; rCountConf = 0
            stationaryTime = 0; prevSeenSide = nil
        }

        func endRally(at endTime: Double, endFrame: Int, reason: String) {
            let dur = endTime - rStartTime
            if dur >= config.minRallySec {
                let continuity = rFrames > 0 ? Double(rMatched) / Double(rFrames) : 0
                let meanConf = rCountConf > 0 ? rSumConf / Double(rCountConf) : 0
                let raw = 30 * continuity
                        + 20 * meanConf
                        + 20 * min(1, dur / 5.0)
                        + 15 * min(1, Double(rSideChange) / 3.0)
                        + 15 * min(1, Double(rNetCross) / 2.0)
                rallies.append(RallyRecord(
                    id: nextRallyId, startFrame: rStartFrame, endFrame: endFrame,
                    startTime: rStartTime, endTime: endTime,
                    netCrossings: rNetCross, sideChanges: rSideChange, lostTrackEvents: rLost,
                    confidence: Int(max(0, min(100, raw)).rounded()), endReason: reason))
                nextRallyId += 1
            }
            state = .idle
            trackPos = nil
            stableFrames = 0
            framesSinceSeen = 0
        }

        for s in samples {
            let dtFrame = max(0, s.time - prevFrameTime)

            // Candidate ball detections: confident + inside the expanded play region.
            let cands = s.observations.filter {
                $0.confidence >= config.ballConfidence && court.inExpanded($0.center)
            }

            // --- Association (continuity): resist switching. ---
            let oldPos = trackPos
            var matched: BallObservation? = nil
            if let tp = trackPos {
                let dt = max(0, s.time - lastSeenTime)
                let predicted = CGPoint(x: tp.x + trackVel.dx * CGFloat(dt),
                                        y: tp.y + trackVel.dy * CGFloat(dt))
                // LOST allows a wider reacquisition radius (occlusion recovery).
                let radius = (state == .lost) ? config.maxAssocDist * 2 : config.maxAssocDist
                if let near = cands.min(by: { dist($0.center, predicted) < dist($1.center, predicted) }),
                   dist(near.center, predicted) <= radius {
                    matched = near
                }
            } else {
                // Seed a new track from the most confident ball inside the primary court.
                matched = cands.filter { court.inPlay($0.center) }.max(by: { $0.confidence < $1.confidence })
            }

            // Motion = displacement from the last seen position.
            let displacement: CGFloat = (matched != nil && oldPos != nil) ? dist(matched!.center, oldPos!) : 0

            // --- Update the track on a match. ---
            if let m = matched {
                let dt = max(1e-3, s.time - lastSeenTime)
                trackVel = oldPos.map { CGVector(dx: (m.center.x - $0.x) / CGFloat(dt),
                                                 dy: (m.center.y - $0.y) / CGFloat(dt)) } ?? .zero
                trackPos = m.center
                lastSeenTime = s.time
                lastSeenFrame = s.frameIndex
                framesSinceSeen = 0
            } else {
                framesSinceSeen += 1
            }

            // --- State machine. ---
            switch state {
            case .idle:
                state = (matched != nil) ? .tracking : .idle
                stableFrames = (matched != nil) ? 1 : 0

            case .tracking:
                if matched != nil {
                    stableFrames += 1
                    if stableFrames >= config.minTrackFrames && displacement >= config.motionThreshold {
                        state = .active
                        rStartFrame = lastSeenFrame
                        rStartTime = s.time
                        resetRallyAccumulators()
                        prevSeenSide = court.side(ofY: trackPos!.y)
                    }
                } else if framesSinceSeen > config.minTrackFrames {
                    state = .idle; trackPos = nil; stableFrames = 0
                }

            case .active:
                rFrames += 1
                if let m = matched {
                    rMatched += 1
                    rSumConf += Double(m.confidence); rCountConf += 1
                    let side = court.side(ofY: m.center.y)
                    if let ps = prevSeenSide, ps != side {
                        rSideChange += 1
                        if m.center.x >= court.net.leftX && m.center.x <= court.net.rightX {
                            rNetCross += 1   // crossed over the net, not around it
                        }
                    }
                    prevSeenSide = side
                    if displacement < config.stationaryEps { stationaryTime += dtFrame }
                    else { stationaryTime = 0 }
                    if stationaryTime > config.stationaryTimeoutSec {
                        endRally(at: s.time, endFrame: s.frameIndex, reason: "ball stationary")
                    }
                } else {
                    state = .lost
                    rLost += 1
                }

            case .lost:
                rFrames += 1
                if let m = matched {
                    rMatched += 1
                    rSumConf += Double(m.confidence); rCountConf += 1
                    state = .active
                    prevSeenSide = court.side(ofY: m.center.y)   // don't infer a crossing across the gap
                    stationaryTime = 0
                } else if s.time - lastSeenTime > config.lostTimeoutSec {
                    endRally(at: lastSeenTime, endFrame: lastSeenFrame, reason: "ball absent (timeout)")
                }

            case .ended:
                state = .idle
            }

            states.append(FrameState(
                frameIndex: s.frameIndex, time: s.time, state: state,
                ballPoint: matched?.center ?? (state == .lost ? trackPos : nil),
                ballBox: matched?.rect))
            prevFrameTime = s.time
        }

        // Close any rally still open at end of video.
        if state == .active || state == .lost {
            endRally(at: lastSeenTime, endFrame: lastSeenFrame, reason: "video ended")
        }

        return EngineResult(rallies: rallies, frameStates: states, court: court, samples: samples)
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
