//
//  ServeDetector.swift
//  BumpSetCut
//
//  The serve: the rally's first ball in flight, found by its size. Filmed
//  from an end line, a served ball flies straight at or away from the
//  camera, so it grows or shrinks steadily in a way little else on court
//  does (a toss goes up and down at one size, a carried ball barely
//  changes). The ball is followed through every detection, not the
//  pipeline's chosen track — that often picks the ball up only once the
//  rally is under way.
//
//  A serve has a toss (the ball rising from the server's hand to the top,
//  when it's in the picture), contact (where the flight starts), and an end
//  at its first change of trajectory — the pass, or the serve missing (net,
//  floor, out): the size stops changing the same way, the ball turns
//  sharply, or it's lost.
//
//  Shared by the apps and RallyLab: VideoProcessor finds each rally's serve
//  from the balls it detected; RallyLab from recorded evidence.
//

import CoreGraphics
import Foundation

struct ServeDetector {
    /// One processed frame's balls on this court (Vision-normalised boxes).
    struct Frame {
        let t: Double
        let balls: [CGRect]
    }

    struct Serve: Equatable {
        /// The ball followed, toss to end (Vision-normalised).
        struct Point: Equatable {
            let t: Double
            let point: CGPoint
        }

        /// Where the toss left the server's hand, when it was seen.
        let toss: Double?
        /// The ball's flight starting: contact.
        let contact: Double
        /// Its first change of trajectory: the pass, or the serve missing.
        let end: Double
        /// Toward the camera (served from the far side) or away from it.
        let approaching: Bool
        let path: [Point]

        /// The serve as it starts: the toss, else contact.
        var start: Double { toss ?? contact }
    }

    /// The flight must change the ball's size by at least this factor…
    var minSizeRatio = 1.3
    /// …at this rate or faster (log size a second)…
    var minLogRate = 0.3
    /// …steadily: a straight-line fit of log size on time explains this
    /// share of its variance (r²). Detected box sizes jitter frame to
    /// frame, so a step-by-step test fails balls that clearly double.
    var minFit = 0.6
    /// The fit spans at most this long from contact (a serve reaches the
    /// net well within it; longer spans blend in the pass).
    var maxSpan = 1.2
    /// Sizes are smoothed over this many detections (a running median).
    var smoothing = 5
    /// A gap longer than this ends the ball's track (and the serve).
    var maxGap = 0.25
    /// The next detection is the same ball within this many ball sizes
    /// (per 30th of a second), or this share of the picture, whichever is more.
    var linkSizes = 4.0
    var minLink = 0.03
    /// The size turning against the flight by this much (log) ends it.
    var reversalLog = 0.15
    /// A turn of more than this many degrees in the picture, between moves
    /// this many detections long (single steps are mostly noise), ends it…
    var turnSpan = 3
    var maxTurnDegrees = 70.0
    /// …when the ball moves at least this fast (picture widths a second).
    var minTurnSpeed = 0.1
    /// The toss is looked for this far before contact.
    var tossReach = 1.5

    /// Contact is looked for this far before and after where the rally was
    /// decided to start (the decision comes about as the serve flies; a ball
    /// thrown back to the server just before also flies like one).
    var before = 3.0, after = 3.0

    /// The rally's serve: of the flights with contact around `rallyStart`
    /// (the decided start, before padding), the nearest — among `frames`
    /// (time-ordered).
    func serve(in frames: [Frame], rallyStart: Double) -> Serve? {
        let window = (rallyStart - before)...(rallyStart + after)
        let near = frames.filter { $0.t >= window.lowerBound - tossReach && $0.t <= window.upperBound + 3 }
        return tracks(near).flatMap { flights(on: $0) }.filter { window.contains($0.contact) }
            .min { abs($0.contact - rallyStart) < abs($1.contact - rallyStart) }
    }

    // MARK: - Following the ball

    private struct Ball {
        let t: Double
        let point: CGPoint
        let size: Double
    }

    /// Every ball followed from frame to frame: at each frame each track
    /// takes the nearest ball within reach; a ball no track takes starts
    /// one. Tracks in the order they start.
    private func tracks(_ frames: [Frame]) -> [[Ball]] {
        var open: [[Ball]] = [], done: [[Ball]] = []
        for f in frames {
            var free = f.balls.map { Ball(t: f.t, point: CGPoint(x: $0.midX, y: $0.midY), size: Double(sqrt($0.width * $0.height))) }
            open = open.filter { track in
                if f.t - track.last!.t > maxGap { done.append(track); return false }
                return true
            }
            for k in open.indices {
                let last = open[k].last!
                let reach = max(minLink, linkSizes * last.size) * max(1, (f.t - last.t) * 30)
                guard let j = free.indices.min(by: { distance(free[$0].point, last.point) < distance(free[$1].point, last.point) }),
                      distance(free[j].point, last.point) <= reach else { continue }
                open[k].append(free.remove(at: j))
            }
            open += free.map { [$0] }
        }
        return (done + open).filter { $0.count >= 3 }.sorted { $0[0].t < $1[0].t }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        // Vision-normalised, a 16:9 picture: a step across counts as much as one up.
        Double(hypot(a.x - b.x, (a.y - b.y) * 9 / 16))
    }

    // MARK: - The serve on one track

    /// Every flight on a track: a stretch growing or shrinking steadily and
    /// fast enough, then the next one after it ends.
    private func flights(on track: [Ball]) -> [Serve] {
        let logs = smoothed(track.map { log($0.size) })
        var found: [Serve] = []
        var i = 0
        while i < track.count {
            guard let s = flight(track, logs, at: i) else { i += 1; continue }
            found.append(s)
            i = track.firstIndex { $0.t > s.end } ?? track.count
        }
        return found
    }

    /// A flight starting at `i`, if one does: the size changing steadily
    /// from there by `minSizeRatio` at `minLogRate` or faster — the longest
    /// span up to `maxSpan` whose straight-line fit of log size on time
    /// says so and fits (`minFit`).
    private func flight(_ track: [Ball], _ logs: [Double], at i: Int) -> Serve? {
        var approaching: Bool?
        var n = 0.0, st = 0.0, sl = 0.0, stt = 0.0, sll = 0.0, stl = 0.0
        let t0 = track[i].t
        for j in i..<track.count {
            let t = track[j].t - t0, l = logs[j]
            n += 1; st += t; sl += l; stt += t * t; sll += l * l; stl += t * l
            guard j > i else { continue }
            if t > maxSpan { break }
            guard n >= 3 else { continue }
            let vt = stt - st * st / n, vl = sll - sl * sl / n, cov = stl - st * sl / n
            guard vt > 0, vl > 0 else { continue }
            let slope = cov / vt, fit = cov * cov / (vt * vl)
            if fit >= minFit, abs(slope) >= minLogRate, abs(slope) * t >= log(minSizeRatio) { approaching = slope > 0 }
        }
        guard let approaching else { return nil }
        let tossAt = toss(track, before: i)
        let endAt = end(track, logs, from: i, approaching: approaching)
        return Serve(toss: tossAt.map { track[$0].t }, contact: track[i].t, end: track[endAt].t, approaching: approaching,
                     path: track[(tossAt ?? i)...endAt].map { .init(t: $0.t, point: $0.point) })
    }

    /// Running median of `values`, `smoothing` wide.
    private func smoothed(_ values: [Double]) -> [Double] {
        let half = smoothing / 2
        return values.indices.map { k in
            let window = values[max(0, k - half)...min(values.count - 1, k + half)].sorted()
            return window[window.count / 2]
        }
    }

    /// Where the toss left the server's hand: going back from contact over
    /// the ball's highest point, the lowest point before it — if the ball
    /// rose to contact.
    private func toss(_ track: [Ball], before contact: Int) -> Int? {
        let from = track.firstIndex { $0.t >= track[contact].t - tossReach } ?? contact
        guard from < contact else { return nil }
        let earlier = track[from...contact]
        guard let top = earlier.indices.max(by: { earlier[$0].point.y < earlier[$1].point.y }) else { return nil }
        let rise = track[from...top]
        guard let bottom = rise.indices.min(by: { rise[$0].point.y < rise[$1].point.y }), bottom < top,
              track[top].point.y - track[bottom].point.y > 0.03 else { return nil }
        return bottom
    }

    /// The first change of trajectory after contact at `i` (its index).
    private func end(_ track: [Ball], _ logs: [Double], from i: Int, approaching: Bool) -> Int {
        let sign = approaching ? 1.0 : -1.0
        var extreme = logs[i] * sign
        for k in (i + 1)..<track.count {
            let v = logs[k] * sign
            extreme = max(extreme, v)
            if extreme - v >= reversalLog { return k }
            if k >= i + 2 * turnSpan, turned(track[k - 2 * turnSpan], track[k - turnSpan], track[k]) { return k - turnSpan }
        }
        return track.count - 1
    }

    /// The picture direction from a→b to b→c turns more than maxTurnDegrees.
    private func turned(_ a: Ball, _ b: Ball, _ c: Ball) -> Bool {
        let u = CGVector(dx: b.point.x - a.point.x, dy: (b.point.y - a.point.y) * 9 / 16)
        let v = CGVector(dx: c.point.x - b.point.x, dy: (c.point.y - b.point.y) * 9 / 16)
        let du = Double(hypot(u.dx, u.dy)), dv = Double(hypot(v.dx, v.dy))
        guard b.t > a.t, c.t > b.t, du / (b.t - a.t) >= minTurnSpeed, dv / (c.t - b.t) >= minTurnSpeed else { return false }
        let cos = Double(u.dx * v.dx + u.dy * v.dy) / (du * dv)
        return acos(min(1, max(-1, cos))) * 180 / .pi > maxTurnDegrees
    }
}

extension ServeDetector.Frame {
    /// The on-court balls of each frame of recorded evidence.
    static func from(_ evidence: [VideoProcessor.FrameEvidence]) -> [ServeDetector.Frame] {
        evidence.map { e in .init(t: e.time, balls: e.detections.filter { !$0.isOffCourt }.map(\.bbox)) }
    }
}
