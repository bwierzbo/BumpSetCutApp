//
//  RallyTrack.swift
//  RallyLab
//
//  A rally labeled frame by frame: where the ball in play is on every
//  frame (about 30 a second), or that it's hidden. Multi-frame heatmap
//  models learn from motion, so they want every frame of a rally, not
//  scattered ones — this is the TrackNet/WASB way of labeling.
//
//  The detector proposes candidates on each frame; TrackSolver picks the
//  one most consistent path through them (a ball moves a little each
//  frame, so a sideline ball or a player's head can't hijack it). Your
//  clicks and "hidden" marks are fixed points the path is re-solved
//  around, and short gaps between found frames are filled along a
//  parabola, flagged for you to look at.
//

import CoreGraphics
import Foundation

struct TrackCandidate: Codable, Hashable {
    /// Vision-normalised (bottom-up) box in the upright frame.
    var x, y, w, h: Double
    var confidence: Double

    init(rect: CGRect, confidence: Double) {
        (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
        self.confidence = confidence
    }

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct TrackPoint: Codable, Hashable {
    enum State: String, Codable {
        /// The ball is here (`box`).
        case visible
        /// Out of sight: behind a player, the net, out of frame.
        case hidden
        /// Not decided — no candidate fit the path. Left out of training.
        case unknown
    }
    enum Origin: String, Codable {
        /// Chosen by the solver from the detector's candidates.
        case auto
        /// Yours: a click or a hidden mark. Fixed when re-solving.
        case user
        /// Interpolated across a short gap.
        case filled
    }

    /// Presentation time in the video, seconds.
    let time: Double
    var state: State
    var origin: Origin
    /// Vision-normalised (bottom-up) box in the upright frame, when visible.
    var box: TrackCandidate?
    /// Checked in annotation review (its box confirmed or tightened on a
    /// crop, or "hidden" confirmed on the whole frame): only reviewed frames
    /// are used for training. Changing the frame afterwards clears it.
    var reviewed = false
    /// Someone in annotation review wasn't sure: kept aside for a later look.
    var unsure = false

    /// Worth a look before calling the rally done.
    var isUncertain: Bool {
        switch (origin, state) {
        case (.user, _): return false
        case (.filled, _), (_, .unknown): return true
        case (.auto, .visible): return (box?.confidence ?? 0) < TrackSolver.sureConfidence
        case (.auto, .hidden): return false
        }
    }
}

extension TrackPoint {
    private enum CodingKeys: String, CodingKey { case time, state, origin, box, reviewed, unsure }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        state = try c.decode(State.self, forKey: .state)
        origin = try c.decode(Origin.self, forKey: .origin)
        box = try c.decodeIfPresent(TrackCandidate.self, forKey: .box)
        reviewed = try c.decodeIfPresent(Bool.self, forKey: .reviewed) ?? false
        unsure = try c.decodeIfPresent(Bool.self, forKey: .unsure) ?? false
    }
}

struct TrackedRally: Codable, Identifiable, Equatable {
    /// A rally's frames run this far past it each side: just enough that the
    /// multi-frame model's 9-frame window (4 frames each side of the one it
    /// answers for) has real frames at the serve and the dead ball. Any more
    /// is ball-in-hand labeling the rally cutting never uses.
    static let margin = 0.3

    let id: UUID
    var start: Double
    var end: Double
    /// One per frame, in time order.
    var points: [TrackPoint]
    /// The detector's candidates per frame (same order), kept so edits
    /// re-solve instantly without running the detector again.
    var candidates: [[TrackCandidate]]
    var done: Bool
    /// When it last changed (on this Mac or the phone): the newer side wins a sync.
    var updatedAt: Date? = nil
}

extension TrackedRally {
    /// `tracks` with updatedAt set to now on every rally that's new or
    /// changed since `before` (changes from a sync keep their own time).
    static func stamped(_ tracks: [TrackedRally], since before: [TrackedRally]) -> [TrackedRally] {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Date()
        return tracks.map { t in
            guard let o = old[t.id] else { return t.updatedAt == nil ? t.with(updatedAt: now) : t }
            if t.updatedAt != o.updatedAt { return t }
            return t.with(updatedAt: o.updatedAt) == o ? t : t.with(updatedAt: now)
        }
    }

    func with(updatedAt: Date?) -> TrackedRally {
        var t = self
        t.updatedAt = updatedAt
        return t
    }
    /// Frames with a decided label (the ball, or hidden): what training gets.
    var labeledFrames: Int { points.filter { $0.state != .unknown }.count }

    /// The rally itself: the tracked frames less the margin either side.
    var bounds: LabelRally {
        let m = min(Self.margin, (end - start) / 4)
        return LabelRally(start: start + m, end: end - m)
    }
}

/// Picks the ball in play through a rally's frames.
enum TrackSolver {

    /// Detections at or above this the solver treats as sure.
    static let sureConfidence = 0.5
    /// Gaps up to this many frames between found frames are filled.
    static let maxFill = 8
    /// A spot with a detection on at least this many frames of the rally —
    /// and this share of them — is something still (a net post, a sign, a
    /// light), not the ball in play: a ball doesn't sit within a ball's
    /// width for half a second while a rally's on.
    static let stillFrames = 15
    static let stillShare = 0.2
    /// …and its detections count this much of their confidence: the path
    /// only takes one when nothing else fits, and it's flagged to check.
    static let stillWeight = 0.2

    /// Re-solves `rally`'s non-user frames from its candidates, keeping
    /// every user point fixed, then fills short gaps.
    static func solve(_ rally: TrackedRally) -> [TrackPoint] {
        let n = rally.points.count
        guard n > 0, rally.candidates.count == n else { return rally.points }

        // States per frame: candidate k, or "none" (index count).
        // Costs are lower-is-better: an unlikely detection costs more, a
        // jump costs with its size, "none" costs a flat amount so the path
        // takes a believable candidate when there is one.
        let noneCost = 0.55
        let candidates = discountingStill(rally.candidates)
        func options(_ i: Int) -> [TrackCandidate?] {
            let p = rally.points[i]
            if p.origin == .user {
                return p.state == .visible ? [p.box] : [nil]
            }
            return candidates[i].map { Optional($0) } + [nil]
        }
        func emission(_ c: TrackCandidate?, user: Bool) -> Double {
            if user { return 0 }
            guard let c else { return noneCost }
            return 1 - c.confidence
        }
        // A ball moves up to ~5% of the frame between frames at 30 fps
        // (a hard spike); jumps beyond that cost steeply.
        func transition(_ a: TrackCandidate?, _ b: TrackCandidate?) -> Double {
            guard let a, let b else { return 0.05 }
            let d = hypot(a.rect.midX - b.rect.midX, (a.rect.midY - b.rect.midY) * 9 / 16)
            return d < 0.05 ? d * 2 : 0.1 + (d - 0.05) * 30
        }

        var opts = (0..<n).map(options)
        var cost = opts[0].map { emission($0, user: rally.points[0].origin == .user) }
        var back: [[Int]] = [Array(repeating: 0, count: opts[0].count)]
        for i in 1..<n {
            let user = rally.points[i].origin == .user
            var next: [Double] = []
            var from: [Int] = []
            for b in opts[i] {
                var best = (Double.infinity, 0)
                for (k, a) in opts[i - 1].enumerated() {
                    let c = cost[k] + transition(a, b)
                    if c < best.0 { best = (c, k) }
                }
                next.append(best.0 + emission(b, user: user))
                from.append(best.1)
            }
            cost = next
            back.append(from)
        }
        var k = cost.indices.min { cost[$0] < cost[$1] } ?? 0
        var chosen = Array<TrackCandidate?>(repeating: nil, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            chosen[i] = opts[i][k]
            k = back[i][k]
        }
        opts.removeAll()

        var points = rally.points
        for i in 0..<n where points[i].origin != .user {
            points[i].origin = .auto
            points[i].box = chosen[i]
            points[i].state = chosen[i] == nil ? .unknown : .visible
        }
        fillGaps(&points)
        return points
    }

    /// The candidates with those on a still spot (see `stillFrames`) down to
    /// `stillWeight` of their confidence. Spots are grid cells a little
    /// bigger than a ball; a candidate's frames count over its cell and the
    /// ones around it, so a detection jittering on a cell edge still counts.
    static func discountingStill(_ candidates: [[TrackCandidate]]) -> [[TrackCandidate]] {
        let cellW = 0.012, cellH = 0.012 * 16 / 9
        func cell(_ c: TrackCandidate) -> (Int, Int) { (Int((c.rect.midX / cellW).rounded(.down)), Int((c.rect.midY / cellH).rounded(.down))) }
        struct Cell: Hashable { let x, y: Int }
        var frames: [Cell: Set<Int>] = [:]
        for (i, list) in candidates.enumerated() {
            for c in list { let (x, y) = cell(c); frames[Cell(x: x, y: y), default: []].insert(i) }
        }
        let needed = max(stillFrames, Int(stillShare * Double(candidates.count)))
        return candidates.map { list in
            list.map { c in
                let (x, y) = cell(c)
                var seen = Set<Int>()
                for dx in -1...1 { for dy in -1...1 { seen.formUnion(frames[Cell(x: x + dx, y: y + dy)] ?? []) } }
                guard seen.count >= needed else { return c }
                return TrackCandidate(rect: c.rect, confidence: c.confidence * stillWeight)
            }
        }
    }

    /// Unknown runs of up to `maxFill` frames with found frames on both
    /// sides get positions on a parabola through the frames around them —
    /// x and y each quadratic in time, which is how a ball flies.
    static func fillGaps(_ points: inout [TrackPoint]) {
        var i = 0
        while i < points.count {
            guard points[i].state == .unknown else { i += 1; continue }
            var j = i
            while j < points.count, points[j].state == .unknown { j += 1 }
            defer { i = j }
            guard i > 0, j < points.count, j - i <= maxFill,
                  points[i - 1].state == .visible, points[j].state == .visible else { continue }
            let before = (max(0, i - 4)..<i).filter { points[$0].state == .visible }
            let after = (j..<min(points.count, j + 4)).filter { points[$0].state == .visible }
            let known = (before + after).compactMap { k in points[k].box.map { (points[k].time, $0) } }
            guard known.count >= 2 else { continue }
            let size = known.map { ($0.1.w, $0.1.h) }
            let w = size.map(\.0).reduce(0, +) / Double(size.count)
            let h = size.map(\.1).reduce(0, +) / Double(size.count)
            let fx = fit(known.map { ($0.0, $0.1.rect.midX) })
            let fy = fit(known.map { ($0.0, $0.1.rect.midY) })
            for k in i..<j {
                let t = points[k].time
                let rect = CGRect(x: fx(t) - w / 2, y: fy(t) - h / 2, width: w, height: h)
                points[k].box = TrackCandidate(rect: rect, confidence: 0)
                points[k].state = .visible
                points[k].origin = .filled
            }
        }
    }

    /// Least-squares quadratic (linear with fewer than 3 points) through
    /// (t, v), as a function of t.
    static func fit(_ samples: [(Double, Double)]) -> (Double) -> Double {
        let t0 = samples[0].0
        let pts = samples.map { ($0.0 - t0, $0.1) }
        if pts.count < 3 {
            let (a, b) = (pts.first!, pts.last!)
            let slope = b.0 == a.0 ? 0 : (b.1 - a.1) / (b.0 - a.0)
            return { t in a.1 + slope * (t - t0 - a.0) }
        }
        // Normal equations for v = c0 + c1·t + c2·t².
        var s = [Double](repeating: 0, count: 5), r = [Double](repeating: 0, count: 3)
        for (t, v) in pts {
            var p = 1.0
            for k in 0..<5 { s[k] += p; if k < 3 { r[k] += v * p }; p *= t }
        }
        let m = [[s[0], s[1], s[2]], [s[1], s[2], s[3]], [s[2], s[3], s[4]]]
        guard let c = solve3(m, r) else { return fit([pts.first!, pts.last!].map { ($0.0 + t0, $0.1) }) }
        return { t in let u = t - t0; return c[0] + c[1] * u + c[2] * u * u }
    }

    private static func solve3(_ m: [[Double]], _ r: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-12 else { return nil }
        return (0..<3).map { col in
            var a = m
            for row in 0..<3 { a[row][col] = r[row] }
            return det(a) / d
        }
    }
}
