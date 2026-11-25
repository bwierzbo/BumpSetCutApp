//
//  CourtLayout.swift
//  BumpSetCut
//
//  `court_geometry_v1`: where the playing court lies in one stable camera view, as six
//  ground points in the upright, Vision-normalised frame (origin bottom-left, y up — the
//  space the pipeline's boxes and the net's corners are in):
//
//      farLeft ───────── farRight        v = 1   (far end line)
//         │                  │
//      netLeft ───────── netRight        v = ½   (where the net's ground line meets the sidelines)
//         │                  │
//      nearLeft ──────── nearRight       v = 0   (near end line, nearest the camera)
//
//  `left` is the sideline on the image's left at the near end. Each half is its own
//  perspective map (a homography from the court half to the image), so the court is
//  never assumed rectangular on screen, and a net line that is not at the court's exact
//  middle on screen is kept as placed. A point outside the frame is allowed (an end line
//  below the picture is common): it is `estimated`, never invented as `seen`. A point
//  nobody can place is `unknown`, and the half that needs it has no map.
//
//  The geometry of the player-feasibility research (P2, PR #166), taken as it was so a
//  court placed there and a court placed on the iPhone are the same six points. These are
//  the court's ground lines; the physical net is a separate shape (NetQuad).
//

import Foundation

enum CourtGeometryV1 {
    static let schemaVersion = "court_geometry_v1"
}

/// A 3×3 projective map, row-major.
struct Homography: Equatable, Sendable {
    var m: [Double]

    /// The map taking `from[i]` to `to[i]` (four point pairs, no three collinear), nil when degenerate.
    ///
    /// Fitted about the centre of the `from` points: a projective map is known only up to a factor, and the
    /// factor is fixed by making its weight 1 at that centre — a point inside the region, where the weight of a
    /// map onto a finite convex shape is never zero. Fixing it at the origin instead loses every map whose weight
    /// is zero there (a far half tapering to half its width is one) and leaves the others with either sign; fixed
    /// at the centre, a weight ≤ 0 means beyond the horizon, for the map and for its inverse.
    static func fit(from: [(Double, Double)], to: [(Double, Double)]) -> Homography? {
        guard from.count == 4, to.count == 4 else { return nil }
        let (cx, cy) = (from.map(\.0).reduce(0, +) / 4, from.map(\.1).reduce(0, +) / 4)
        // Eight unknowns, two rows per pair, in coordinates centred on (cx, cy).
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y) = (from[i].0 - cx, from[i].1 - cy), (u, v) = to[i]
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        guard let h = solve(a) else { return nil }
        // Back to the caller's coordinates: the centred map after a shift by (−cx, −cy).
        return Homography(m: [
            h[0], h[1], h[2] - cx * h[0] - cy * h[1],
            h[3], h[4], h[5] - cx * h[3] - cy * h[4],
            h[6], h[7], 1 - cx * h[6] - cy * h[7],
        ])
    }

    /// Gaussian elimination with partial pivoting on an n×(n+1) augmented matrix.
    private static func solve(_ input: [[Double]]) -> [Double]? {
        var a = input
        let n = a.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[p][c]) > 1e-12 else { return nil }
            a.swapAt(c, p)
            for r in 0..<n where r != c {
                let f = a[r][c] / a[c][c]
                if f != 0 { for k in c...n { a[r][k] -= f * a[c][k] } }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }

    /// The image of (x, y) and the projective weight; a weight ≤ 0 is beyond the horizon (behind the camera).
    func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double, w: Double) {
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-12 else { return (.infinity, .infinity, 0) }
        return ((m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w, w)
    }

    var inverse: Homography? {
        let a = m
        let det = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6])
        guard abs(det) > 1e-15 else { return nil }
        let inv = [
            (a[4] * a[8] - a[5] * a[7]), -(a[1] * a[8] - a[2] * a[7]), (a[1] * a[5] - a[2] * a[4]),
            -(a[3] * a[8] - a[5] * a[6]), (a[0] * a[8] - a[2] * a[6]), -(a[0] * a[5] - a[2] * a[3]),
            (a[3] * a[7] - a[4] * a[6]), -(a[0] * a[7] - a[1] * a[6]), (a[0] * a[4] - a[1] * a[3]),
        ].map { $0 / det }
        return Homography(m: inv)
    }
}

/// One ground point of the court, upright Vision-normalised.
struct CourtPoint: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable, CaseIterable {
        /// Placed on something visible in the frame (a line, a corner, a post foot).
        case seen
        /// Inferred: off the frame, hidden, or from an assumption (dimensions, camera height). Usable, with that caveat.
        case estimated
        /// Nobody could place it; the half that needs it has no map.
        case unknown
    }
    var x: Double
    var y: Double
    var status: Status
}

/// The six ground points of one camera view.
struct CourtLayout: Codable, Equatable, Sendable {
    enum Role: String, Codable, CaseIterable, Sendable {
        case nearLeft, nearRight, netRight, netLeft, farLeft, farRight
        /// Court coordinates: u across (0 left sideline … 1 right), v along (0 near end line … ½ net … 1 far end line).
        var court: (u: Double, v: Double) {
            switch self {
            case .nearLeft: return (0, 0)
            case .nearRight: return (1, 0)
            case .netRight: return (1, 0.5)
            case .netLeft: return (0, 0.5)
            case .farLeft: return (0, 1)
            case .farRight: return (1, 1)
            }
        }
        var label: String {
            switch self {
            case .nearLeft: return "near left"
            case .nearRight: return "near right"
            case .netRight: return "net right"
            case .netLeft: return "net left"
            case .farLeft: return "far left"
            case .farRight: return "far right"
            }
        }
    }

    var nearLeft: CourtPoint
    var nearRight: CourtPoint
    var netRight: CourtPoint
    var netLeft: CourtPoint
    var farLeft: CourtPoint
    var farRight: CourtPoint

    subscript(role: Role) -> CourtPoint {
        get {
            switch role {
            case .nearLeft: return nearLeft
            case .nearRight: return nearRight
            case .netRight: return netRight
            case .netLeft: return netLeft
            case .farLeft: return farLeft
            case .farRight: return farRight
            }
        }
        set {
            switch role {
            case .nearLeft: nearLeft = newValue
            case .nearRight: nearRight = newValue
            case .netRight: netRight = newValue
            case .netLeft: netLeft = newValue
            case .farLeft: farLeft = newValue
            case .farRight: farRight = newValue
            }
        }
    }

    /// How far a point may sit outside the frame: an end line well below the picture is still placeable.
    static let placeableRange: ClosedRange<Double> = -1.5...2.5

    static let nearRoles: [Role] = [.nearLeft, .nearRight, .netRight, .netLeft]
    static let farRoles: [Role] = [.netLeft, .netRight, .farRight, .farLeft]

    /// The court-half → image map, nil when a point it needs is unknown or the half is degenerate or folded.
    func map(near: Bool) -> Homography? {
        let roles = near ? Self.nearRoles : Self.farRoles
        let pts = roles.map { self[$0] }
        guard pts.allSatisfy({ $0.status != .unknown }), Self.isSimpleConvex(pts.map { ($0.x, $0.y) }) else { return nil }
        return Homography.fit(from: roles.map(\.court), to: pts.map { ($0.x, $0.y) })
    }

    /// A convex quadrilateral that doesn't cross itself, of usable area.
    static func isSimpleConvex(_ p: [(Double, Double)]) -> Bool { isConvex(p) && polygonArea(p) > 1e-4 }

    /// Four corners that turn the same way all round: no crossing, no fold, no three on one line.
    static func isConvex(_ p: [(Double, Double)]) -> Bool {
        guard p.count == 4 else { return false }
        var sign = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let cross = (b.0 - a.0) * (c.1 - b.1) - (b.1 - a.1) * (c.0 - b.0)
            guard abs(cross) > 1e-9 else { return false }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return true
    }

    static func polygonArea(_ p: [(Double, Double)]) -> Double {
        var twice = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; twice += a.0 * b.1 - b.0 * a.1 }
        return abs(twice) / 2
    }

    /// Every reason this geometry can't be used; empty when it can (at least one half mapped, every point placeable).
    var problems: [String] {
        var out: [String] = []
        for r in Role.allCases where self[r].status != .unknown && !(Self.placeableRange.contains(self[r].x) && Self.placeableRange.contains(self[r].y)) {
            out.append("\(r.label) is too far outside the frame")
        }
        let nearOK = map(near: true) != nil, farOK = map(near: false) != nil
        if !nearOK && !farOK { out.append("neither court half forms a convex four-sided region") }
        if nearOK, farOK {
            // The halves share the net line; they must lie on opposite sides of it.
            let l = netLeft, r = netRight
            func side(_ p: CourtPoint) -> Double { (r.x - l.x) * (p.y - l.y) - (r.y - l.y) * (p.x - l.x) }
            let near = [nearLeft, nearRight].map(side), far = [farLeft, farRight].map(side)
            if !(near.allSatisfy { $0 < 0 } && far.allSatisfy { $0 > 0 }) && !(near.allSatisfy { $0 > 0 } && far.allSatisfy { $0 < 0 }) {
                out.append("the near and far halves overlap across the net line")
            }
        }
        return out
    }

    var isUsable: Bool { problems.isEmpty }

    /// Court coordinates of an image point, from the half whose map puts it on that half's side of the net
    /// (the near map below v = ½, the far map above); nil beyond the horizon or with no map.
    func courtCoordinates(_ x: Double, _ y: Double) -> (u: Double, v: Double)? {
        if let h = map(near: true)?.inverse {
            let c = h.apply(x, y)
            if c.w > 0, c.y <= 0.5 { return (c.x, c.y) }
            if map(near: false) == nil { return c.w > 0 ? (c.x, c.y) : nil }
        }
        if let h = map(near: false)?.inverse {
            let c = h.apply(x, y)
            if c.w > 0, c.y >= 0.5 { return (c.x, c.y) }
            if map(near: true) == nil { return c.w > 0 ? (c.x, c.y) : nil }
        }
        return nil
    }

    /// The image of court coordinates, through the half they lie on (or the only mapped half).
    func image(u: Double, v: Double) -> (x: Double, y: Double)? {
        let preferNear = v <= 0.5
        for near in preferNear ? [true, false] : [false, true] {
            if let h = map(near: near) {
                let p = h.apply(u, v)
                if p.w > 0 { return (p.x, p.y) }
                return nil
            }
        }
        return nil
    }

    /// The polygon of court coordinates `corners` drawn in the image (`steps` points per edge so long edges stay
    /// straight through the right half's map), empty when unmapped.
    func outline(_ corners: [(Double, Double)], steps: Int = 8) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            for s in 0..<steps {
                let t = Double(s) / Double(steps)
                guard let p = image(u: a.0 + (b.0 - a.0) * t, v: a.1 + (b.1 - a.1) * t) else { return [] }
                out.append((p.x, p.y))
            }
        }
        return out
    }

    func moving(_ role: Role, to x: Double, _ y: Double, status: CourtPoint.Status? = nil) -> CourtLayout {
        var g = self
        let r = Self.placeableRange
        g[role] = CourtPoint(x: min(r.upperBound, max(r.lowerBound, x)), y: min(r.upperBound, max(r.lowerBound, y)),
                             status: status ?? (self[role].status == .unknown ? .seen : self[role].status))
        return g
    }

    /// Roles whose point differs from `other`'s (position beyond `tolerance`, or status).
    func changedRoles(from other: CourtLayout, tolerance: Double = 1e-6) -> [Role] {
        Role.allCases.filter { r in
            let a = self[r], b = other[r]
            return a.status != b.status || abs(a.x - b.x) > tolerance || abs(a.y - b.y) > tolerance
        }
    }
}

/// The court's real size: metadata kept with a calibration, never proof of where the court is.
struct CourtSpec: Codable, Hashable, Sendable {
    /// Sideline to sideline, metres.
    var widthM: Double
    /// End line to end line, metres.
    var lengthM: Double
    /// Where the numbers came from ("standard beach (FIVB 16 × 8 m)", "grass 4v4 18 × 9 m (person's answers)").
    var source: String

    static let beach = CourtSpec(widthM: 8, lengthM: 16, source: "standard beach (FIVB 16 × 8 m)")
    static let indoor = CourtSpec(widthM: 9, lengthM: 18, source: "standard indoor (FIVB 18 × 9 m)")
}

/// What the person says about the court: it gives the court's size and is kept with the calibration as
/// metadata — never as proof of where the court is.
struct CourtSetup: Codable, Equatable, Sendable {
    enum Surface: String, Codable, CaseIterable, Sendable { case beach, grass, indoor }
    enum Format: String, Codable, CaseIterable, Sendable { case twos = "2v2", fours = "4v4", sixes = "6v6" }

    var surface: Surface?
    var format: Format?
    var answeredAt: Date?

    /// The court size the answers imply: 16 × 8 m for beach and grass doubles, 18 × 9 m for indoor and grass
    /// fours or sixes; nil until the surface is known.
    var spec: CourtSpec? {
        guard let surface else { return nil }
        switch (surface, format) {
        case (.indoor, _): return .indoor
        case (.beach, _): return .beach
        case (.grass, .twos?): return CourtSpec(widthM: 8, lengthM: 16, source: "grass 2v2 16 × 8 m (person's answers)")
        case (.grass, _): return CourtSpec(widthM: 9, lengthM: 18, source: "grass \(format?.rawValue ?? "") 18 × 9 m (person's answers)")
        }
    }
}
