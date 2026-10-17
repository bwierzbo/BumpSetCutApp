//
//  RallyEvents.swift
//  RallyLab (macOS and iPhone)
//
//  What happens in a rally, as live tagging marks it: what kind of rally it
//  was, and every touch of the ball — when, what, and which side of the
//  net. A video's rallylabels file keeps them with the rally's times
//  (RallyMarkRecord); the pipeline's scorer reads only the times from the
//  same file (LabeledRally), so nothing that scores changes.
//
//  BallPath turns a video's pre-tracked ball paths into the moments a press
//  can snap to: where the ball changed course (a touch), and where each
//  path starts and ends (a serve, a dead ball). The ball's size against the
//  net's tells which side of the net a touch was on.
//

import CoreGraphics
import Foundation

enum RallyKind: String, Codable, CaseIterable {
    /// Served, played out, dead.
    case rally
    /// A serve that didn't make it — into the net or out — with no play after it.
    case missedServe
    /// The ball in play but not a rally: warm-up pepper, a replayed serve.
    case other

    var name: String {
        switch self {
        case .rally: return "Rally"
        case .missedServe: return "Missed serve"
        case .other: return "Not a rally"
        }
    }
}

enum NetSide: String, Codable {
    /// The camera's half.
    case near
    case far

    var flipped: NetSide { self == .near ? .far : .near }
}

enum ContactKind: String, Codable, CaseIterable {
    case serve, pass, set, attack, block, freeBall

    var name: String {
        switch self {
        case .serve: return "Serve"
        case .pass: return "Pass"
        case .set: return "Set"
        case .attack: return "Attack"
        case .block: return "Block"
        case .freeBall: return "Free ball"
        }
    }
}

/// One touch of the ball.
struct RallyContact: Codable, Hashable {
    var time: Double
    var kind: ContactKind
    /// Which side of the net it was touched on; nil when nothing could tell.
    var side: NetSide?
}

/// A rally as the rallylabels file keeps it: the times (what LabeledRally
/// reads) and, once live-tagged, its kind and touches.
struct RallyMarkRecord: Codable {
    var startTime: Double
    var endTime: Double
    var kind: RallyKind?
    var contacts: [RallyContact]?
}

/// The ball's tracked flight through a video, boiled down to what a live
/// press snaps to.
struct BallPath {
    struct Sample {
        let time: Double
        let center: CGPoint
        /// The box's height, as a share of the frame's: how big the ball looks.
        let size: Double
    }

    /// Where the ball changed course — a touch, most likely.
    let changes: [Double]
    /// Where each tracked path starts (a serve, often) and ends (a dead ball).
    let starts: [Double]
    let ends: [Double]
    /// Every seen ball, in time order.
    let samples: [Sample]

    /// A press within this of a moment on the path snaps to it.
    static let window = 0.4
    /// How much bigger than the ball would look at the net a ball has to be
    /// to count as nearer than the net: detector boxes run loose.
    static let nearRatio = 1.2
    /// A volleyball is 0.21 m across; the net's band is a metre tall.
    static let ballToNet = 0.21

    init(tracks: [TrackedRally]) {
        var changes: [Double] = [], starts: [Double] = [], ends: [Double] = [], all: [Sample] = []
        for track in tracks {
            let seen = track.points.compactMap { p -> Sample? in
                guard p.state == .visible, let box = p.box else { return nil }
                return Sample(time: p.time, center: CGPoint(x: box.rect.midX, y: box.rect.midY), size: box.h)
            }
            guard seen.count >= 5 else { continue }
            starts.append(seen[0].time)
            ends.append(seen[seen.count - 1].time)
            changes += Self.turns(seen)
            all += seen
        }
        self.changes = changes.sorted()
        self.starts = starts.sorted()
        self.ends = ends.sorted()
        samples = all.sorted { $0.time < $1.time }
    }

    /// Where the ball turned the way a touch turns it: it was falling and
    /// goes up, or speeds up sharply, or comes back the way it came — not
    /// the gentle bend of gravity or the top of an arc. Local peaks of the
    /// turn, a quarter second apart at least.
    static func turns(_ pts: [Sample]) -> [Double] {
        let k = 2
        guard pts.count > 2 * k else { return [] }
        var turn = [Double](repeating: 0, count: pts.count)
        for i in k..<(pts.count - k) {
            let a = pts[i], before = pts[i - k], after = pts[i + k]
            // Not across a stretch where the ball was hidden.
            guard a.time - before.time < 0.2, after.time - a.time < 0.2 else { continue }
            let v1 = CGVector(dx: a.center.x - before.center.x, dy: a.center.y - before.center.y)
            let v2 = CGVector(dx: after.center.x - a.center.x, dy: after.center.y - a.center.y)
            let m1 = hypot(v1.dx, v1.dy), m2 = hypot(v2.dx, v2.dy)
            guard m1 > 0.003, m2 > 0.003 else { continue }
            let angle = acos(max(-1, min(1, (v1.dx * v2.dx + v1.dy * v2.dy) / (m1 * m2))))
            guard angle > 20 * .pi / 180 else { continue }
            let sentUp = v1.dy < 0 && v2.dy > 0
            let struck = m2 > 1.4 * m1
            let cameBack = abs(v1.dx) > 0.002 && abs(v2.dx) > 0.002 && (v1.dx < 0) != (v2.dx < 0)
            if sentUp || struck || cameBack { turn[i] = angle }
        }
        var out: [Double] = []
        for i in turn.indices where turn[i] > 0 {
            let lo = max(0, i - 4), hi = min(turn.count - 1, i + 4)
            guard turn[lo...hi].max() == turn[i] else { continue }
            if let last = out.last, pts[i].time - last < 0.25 { continue }
            out.append(pts[i].time)
        }
        return out
    }

    /// The nearest of `moments` to `t` within the window, else `t` itself.
    static func snap(_ t: Double, to moments: [Double]) -> Double {
        guard let best = moments.min(by: { abs($0 - t) < abs($1 - t) }), abs(best - t) <= window else { return t }
        return best
    }

    /// Which side of the net the ball was on at `time`, by how big it looks
    /// against how big it would look at the net (the net band's height in
    /// the frame, scaled by a ball's size against a net's). Nil without a
    /// net, or a ball seen within a tenth of a second.
    func side(at time: Double, net: CGRect?) -> NetSide? {
        guard let net, net.height > 0,
              let s = samples.min(by: { abs($0.time - time) < abs($1.time - time) }), abs(s.time - time) <= 0.1 else { return nil }
        let atNet = Self.ballToNet * net.height
        return s.size > Self.nearRatio * atNet ? .near : .far
    }
}
