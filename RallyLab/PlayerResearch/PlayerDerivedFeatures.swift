//
//  PlayerDerivedFeatures.swift
//  RallyLab
//
//  pfd_v1: the compact derived features of the player-feasibility research, from a
//  track's own history inside one segment up to the current frame (causal) — foot
//  speed, acceleration and turn; arm elevation, torso lean and knee angle from the
//  pose; crouch and lift relative to the track's trailing median; and, per frame,
//  how many in-court tracks move and how coherently. Measurements, not actions: no
//  "spike" or "dig" is ever inferred from them, and a missing input gives null.
//

import Foundation

struct PlayerDerivedFeatures {
    struct Settings: Equatable, Sendable {
        /// Below this foot speed (normalised units / s) a track counts as still, and has no direction.
        var minMovingSpeed = 0.05
        /// Joints under this confidence are not used.
        var minJointConf = 0.2
        /// The trailing window for the median height and ground line.
        var historySec = 1.0
        var described: [String: String] {
            ["version": PlayerFeatures.derivedVersion, "causal": "track history within the segment up to this frame",
             "minMovingSpeed": "\(minMovingSpeed)", "minJointConf": "\(minJointConf)", "historySec": "\(historySec)"]
        }
    }

    private struct Sample { var t: Double; var footX: Double; var footY: Double; var h: Double; var speed: Double?; var vx: Double?; var vy: Double? }

    let settings: Settings
    private var history: [Int: [Sample]] = [:]

    init(settings: Settings = Settings()) { self.settings = settings }

    mutating func reset() { history.removeAll() }

    private static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private func usable(_ p: PlayerFeatures.Pose?, _ name: String) -> PlayerFeatures.Joint? {
        guard let j = p?.j(name), j.c >= settings.minJointConf else { return nil }
        return j
    }

    /// Angle at `b` between b→a and b→c, degrees.
    private static func angle(_ a: PlayerFeatures.Joint, _ b: PlayerFeatures.Joint, _ c: PlayerFeatures.Joint) -> Double? {
        let ux = a.x - b.x, uy = a.y - b.y, vx = c.x - b.x, vy = c.y - b.y
        let nu = (ux * ux + uy * uy).squareRoot(), nv = (vx * vx + vy * vy).squareRoot()
        guard nu > 1e-9, nv > 1e-9 else { return nil }
        let cosv = max(-1, min(1, (ux * vx + uy * vy) / (nu * nv)))
        return acos(cosv) * 180 / .pi
    }

    /// Pose-only features, no history needed.
    func poseFeatures(_ pose: PlayerFeatures.Pose?) -> (arm: Double?, lean: Double?, knee: Double?) {
        let neck = usable(pose, "neck"), root = usable(pose, "root")
        var torso: Double?
        if let neck, let root { torso = ((neck.x - root.x) * (neck.x - root.x) + (neck.y - root.y) * (neck.y - root.y)).squareRoot() }
        var arm: Double?
        if let torso, torso > 1e-6 {
            for side in ["left", "right"] {
                if let w = usable(pose, "\(side)_wrist"), let s = usable(pose, "\(side)_shoulder") {
                    let e = (w.y - s.y) / torso
                    arm = max(arm ?? e, e)
                }
            }
        }
        var lean: Double?
        if let neck, let root, torso.map({ $0 > 1e-6 }) == true {
            lean = atan2(abs(neck.x - root.x), neck.y - root.y) * 180 / .pi
        }
        var knee: Double?
        for side in ["left", "right"] {
            if let h = usable(pose, "\(side)_hip"), let k = usable(pose, "\(side)_knee"), let a = usable(pose, "\(side)_ankle"),
               let v = Self.angle(h, k, a) {
                knee = min(knee ?? v, v)
            }
        }
        return (arm, lean, knee)
    }

    /// The derived features for `track` observed at `t` with `box` and `pose`; records the observation.
    mutating func observe(track: Int, at t: Double, box: PlayerFeatures.Box, pose: PlayerFeatures.Pose?) -> PlayerFeatures.PersonDerived {
        let (fx, fy) = box.foot
        var past = history[track] ?? []
        let prev = past.last
        var speed: Double?, vx: Double?, vy: Double?, accel: Double?, turn: Double?
        if let prev, t - prev.t > 1e-9 {
            let dt = t - prev.t
            vx = (fx - prev.footX) / dt
            vy = (fy - prev.footY) / dt
            speed = (vx! * vx! + vy! * vy!).squareRoot()
            if let ps = prev.speed { accel = (speed! - ps) / dt }
            if let pvx = prev.vx, let pvy = prev.vy, let ps = prev.speed,
               ps >= settings.minMovingSpeed, speed! >= settings.minMovingSpeed {
                let c = max(-1, min(1, (pvx * vx! + pvy * vy!) / (ps * speed!)))
                turn = acos(c)
            }
        }
        let window = past.filter { t - $0.t <= settings.historySec + 1e-9 }
        let medH = Self.median(window.map(\.h) + [box.h])
        let medY = Self.median(window.map(\.footY) + [fy])
        let p = poseFeatures(pose)
        past.append(Sample(t: t, footX: fx, footY: fy, h: box.h, speed: speed, vx: vx, vy: vy))
        history[track] = past.filter { t - $0.t <= settings.historySec + 1e-9 }
        return PlayerFeatures.PersonDerived(
            speed: speed, accel: accel, turn: turn, armElevation: p.arm, torsoLeanDeg: p.lean, kneeAngleDeg: p.knee,
            heightRatio: medH.flatMap { $0 > 1e-9 ? box.h / $0 : nil },
            lift: (medH != nil && medY != nil && medH! > 1e-9) ? (fy - medY!) / medH! : nil)
    }

    /// The frame summary over its persons.
    func scene(_ persons: [PlayerFeatures.Person]) -> PlayerFeatures.SceneDerived {
        let confirmed = persons.filter { $0.state == .confirmed }
        let inCourt = confirmed.filter { $0.court == .inside }
        let speeds = inCourt.compactMap(\.derived.speed)
        let moving = inCourt.filter { ($0.derived.speed ?? 0) >= settings.minMovingSpeed }
        var coherence: Double?
        let dirs: [(Double, Double)] = moving.compactMap { p in
            guard let s = history[p.track]?.last, let vx = s.vx, let vy = s.vy, let sp = s.speed, sp > 0 else { return nil }
            return (vx / sp, vy / sp)
        }
        if dirs.count >= 2 {
            let mx = dirs.map(\.0).reduce(0, +) / Double(dirs.count), my = dirs.map(\.1).reduce(0, +) / Double(dirs.count)
            coherence = (mx * mx + my * my).squareRoot()
        }
        return PlayerFeatures.SceneDerived(
            persons: persons.count, confirmed: confirmed.count, inCourt: inCourt.count,
            meanSpeedInCourt: speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count),
            movingShareInCourt: speeds.isEmpty ? nil : Double(moving.count) / Double(speeds.count),
            coherenceInCourt: coherence, posesInCourt: inCourt.filter { $0.pose != nil }.count)
    }
}
