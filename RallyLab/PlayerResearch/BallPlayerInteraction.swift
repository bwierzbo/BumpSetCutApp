//
//  BallPlayerInteraction.swift
//  RallyLab
//
//  bpi_v1: the interface a later fusion experiment (D in the A/B/C/D plan) joins
//  ball and player features through, with a reference implementation and tests.
//  Nothing in Phase P0 runs it on real data and nothing trains on it. Ball samples
//  come from `rcf_v1` steps (`has_ball`, `sel_x`, `sel_y`, `max_conf`); player
//  frames from `player_features_v1`; both are on the 600-tick time base in the
//  same upright Vision-normalised space, joined by recording and nearest tick.
//
//  Geometric proximity is evidence, never proof of a contact: no field here is a
//  "touch" label. A frame with no ball, or no pose, gives nulls and a reason; it
//  is never a non-rally label (D-010: ball visibility is not rally activity).
//

import Foundation

enum BallPlayerInteraction {
    /// One `rcf_v1` step, reduced to what interaction needs.
    struct BallSample: Equatable, Sendable {
        var tick: Int
        var visible: Bool
        var x: Double?
        var y: Double?
        var conf: Double?
    }

    struct Settings: Equatable, Sendable {
        /// The ball step joined to a player frame is the nearest one within this many ticks.
        var toleranceTicks = 30
        /// The window either side of the frame for the ball's direction change (this much look-ahead).
        var turnWindowSec = 0.2
        /// The ball must be this close to a person (normalised units) for the turn to be attributed near them.
        var nearRadius = 0.08
        var minJointConf = 0.2
        var described: [String: String] {
            ["version": PlayerFeatures.interactionVersion, "toleranceTicks": "\(toleranceTicks)", "turnWindowSec": "\(turnWindowSec)",
             "lookaheadSec": "\(turnWindowSec)", "nearRadius": "\(nearRadius)", "minJointConf": "\(minJointConf)",
             "meaning": "geometric proximity as evidence, never a contact label"]
        }
    }

    enum Missing: String, Codable, Sendable {
        case noBallStep = "no_ball_step"
        case ballNotVisible = "ball_not_visible"
        case noPersons = "no_persons"
        case noPose = "no_pose"
        case frameNotAnalysed = "frame_not_analysed"
    }

    struct Features: Codable, Equatable, Sendable {
        var tick: Int
        /// The ball step used, nil when none was within tolerance.
        var ballTick: Int?
        var nearestTrack: Int?
        /// Ball to the nearest in-court (else any) person's box; 0 inside the box.
        var boxDistance: Double?
        /// Ball to the nearest usable wrist of any person.
        var wristDistance: Double?
        /// Change of `boxDistance` to the same track per second since the previous frame (< 0 approaching).
        var approachRate: Double?
        /// The ball's direction change across ±turnWindowSec, degrees, when the ball is within nearRadius of a person.
        var turnNearDeg: Double?
        /// That person's foot speed (pfd_v1).
        var nearestSpeed: Double?
        /// Ball confidence × the person's (pose, else box) confidence.
        var confidence: Double?
        var missing: [Missing]
    }

    private static func boxDistance(_ b: PlayerFeatures.Box, _ x: Double, _ y: Double) -> Double {
        let dx = max(b.x - x, 0, x - (b.x + b.w)), dy = max(b.y - y, 0, y - (b.y + b.h))
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The nearest ball step to `tick` within tolerance (ties: the earlier one).
    static func ballStep(near tick: Int, in ball: [BallSample], tolerance: Int) -> BallSample? {
        ball.filter { abs($0.tick - tick) <= tolerance }.min { a, b in
            let da = abs(a.tick - tick), db = abs(b.tick - tick)
            return da != db ? da < db : a.tick < b.tick
        }
    }

    private static func position(at tick: Int, in ball: [BallSample], tolerance: Int) -> (Double, Double)? {
        guard let s = ballStep(near: tick, in: ball, tolerance: tolerance), s.visible, let x = s.x, let y = s.y else { return nil }
        return (x, y)
    }

    /// One `Features` per player frame, in order. `ball` must be one recording's steps in time order.
    static func compute(frames: [PlayerFeatures.Frame], ball: [BallSample], settings: Settings = Settings()) -> [Features] {
        var out: [Features] = []
        var lastDistance: [Int: (tick: Int, d: Double, seg: Int)] = [:]
        let window = PlayerFeatures.tick(settings.turnWindowSec)
        for f in frames {
            var r = Features(tick: f.tick, missing: [])
            guard f.masks.ran else { r.missing = [.frameNotAnalysed]; out.append(r); continue }
            guard let step = ballStep(near: f.tick, in: ball, tolerance: settings.toleranceTicks) else { r.missing = [.noBallStep]; out.append(r); continue }
            r.ballTick = step.tick
            guard step.visible, let bx = step.x, let by = step.y else { r.missing = [.ballNotVisible]; out.append(r); continue }
            guard !f.persons.isEmpty else { r.missing = [.noPersons]; out.append(r); continue }
            let pool = f.persons.contains { $0.court == .inside } ? f.persons.filter { $0.court == .inside } : f.persons
            let nearest = pool.min { a, b in
                let da = boxDistance(a.box, bx, by), db = boxDistance(b.box, bx, by)
                return da != db ? da < db : a.track < b.track
            }!
            let d = boxDistance(nearest.box, bx, by)
            r.nearestTrack = nearest.track
            r.boxDistance = d
            r.nearestSpeed = nearest.derived.speed
            if let prev = lastDistance[nearest.track], prev.seg == f.seg, f.tick > prev.tick {
                r.approachRate = (d - prev.d) / (Double(f.tick - prev.tick) / Double(PlayerFeatures.timescale))
            }
            for p in f.persons { lastDistance[p.track] = (f.tick, boxDistance(p.box, bx, by), f.seg) }
            let wrists = f.persons.compactMap(\.pose).flatMap { pose in
                ["left_wrist", "right_wrist"].compactMap { pose.j($0) }.filter { $0.c >= settings.minJointConf }
            }
            if wrists.isEmpty {
                r.missing.append(.noPose)
            } else {
                r.wristDistance = wrists.map { (($0.x - bx) * ($0.x - bx) + ($0.y - by) * ($0.y - by)).squareRoot() }.min()
            }
            if d <= settings.nearRadius,
               let before = position(at: step.tick - window, in: ball, tolerance: settings.toleranceTicks),
               let after = position(at: step.tick + window, in: ball, tolerance: settings.toleranceTicks) {
                let ux = bx - before.0, uy = by - before.1, vx = after.0 - bx, vy = after.1 - by
                let nu = (ux * ux + uy * uy).squareRoot(), nv = (vx * vx + vy * vy).squareRoot()
                if nu > 1e-9, nv > 1e-9 { r.turnNearDeg = acos(max(-1, min(1, (ux * vx + uy * vy) / (nu * nv)))) * 180 / .pi }
            }
            if let bc = step.conf { r.confidence = bc * (nearest.pose?.conf ?? nearest.conf) }
            out.append(r)
        }
        return out
    }
}
