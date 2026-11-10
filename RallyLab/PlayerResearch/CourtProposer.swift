//
//  CourtProposer.swift
//  RallyLab
//
//  Automatic court proposals for one camera view (court_geometry_v1, research P2). No
//  model is trained or run: two classical methods, kept apart so they can be compared,
//  and a combination made only where the evidence supports one.
//
//  A. net_guided_v1 — from the person's net label alone. The mesh's height on screen (1 m
//     of mesh) gives the scale at the net; the ground under the net is the tape height
//     below the tape (2.35 m: between the 2.24 m and 2.43 m nets); the sidelines meet that
//     ground line inside the posts (the mesh is 0.5 m wider than the court — the net's
//     width is never taken as the court's); the end lines come from a pinhole camera with
//     an assumed field of view (68° across the long side), an assumed height (1.5 m at
//     ground level, 3 m elevated), no roll and no yaw. Every point it gives is `estimated`.
//  B. court_lines_v1 — lines on the ground. A per-pixel median of several frames across
//     the segment removes the players; a ridge response (a pixel unlike both its
//     neighbours 2 or 4 px away while they match each other) marks thin painted lines,
//     tape and rope, not the edges between surfaces. A sideline must cross the net's
//     ground line near one of its ends and slant outward toward the camera: every such
//     line is scored by how much it stands out from strips 6 px to either side, along the
//     near half (above the net line the post stands where the sideline runs), and the best
//     on each side is kept. End lines are searched the
//     same way between the two sidelines — the outermost that stands out on each side; an
//     indoor centre line under the net, when one stands out, replaces the net's ground
//     line. The net label only anchors the search. A corner two found lines make is `seen`
//     inside the frame and `estimated` outside it; a corner with no line is `unknown`.
//  combined_v1 — B's sidelines and found lines; where B has no end line, A's end line is
//     cut by B's sidelines (`estimated`). Made only when B found both sidelines.
//
//  Every proposal keeps its method, a score, which evidence placed each point and what it
//  assumed. None is a confirmation.
//

import AVFoundation
import CoreGraphics
import Foundation

/// An upright RGB picture, rows top-down.
struct CourtRGBImage: Sendable {
    var width: Int
    var height: Int
    /// width × height × 3 bytes.
    var rgb: [UInt8]

    init(width: Int, height: Int, rgb: [UInt8]) { self.width = width; self.height = height; self.rgb = rgb }

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { rgb[3 * i] = rgba[4 * i]; rgb[3 * i + 1] = rgba[4 * i + 1]; rgb[3 * i + 2] = rgba[4 * i + 2] }
        self.init(width: w, height: h, rgb: rgb)
    }

    var cgImage: CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) { rgba[4 * i] = rgb[3 * i]; rgba[4 * i + 1] = rgb[3 * i + 1]; rgba[4 * i + 2] = rgb[3 * i + 2] }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The per-pixel, per-channel median of same-sized pictures.
    static func median(_ images: [CourtRGBImage]) -> CourtRGBImage? {
        guard let first = images.first, images.allSatisfy({ $0.width == first.width && $0.height == first.height }) else { return nil }
        let n = images.count, count = first.rgb.count
        var out = [UInt8](repeating: 0, count: count)
        var column = [UInt8](repeating: 0, count: n)
        for i in 0..<count {
            for k in 0..<n { column[k] = images[k].rgb[i] }
            column.sort()
            out[i] = column[n / 2]
        }
        return CourtRGBImage(width: first.width, height: first.height, rgb: out)
    }
}

enum CourtProposer {
    struct Assumptions: Equatable, Sendable {
        var tapeHeightM = 2.35
        var meshDepthM = 1.0
        /// How much longer the mesh is than the court is wide.
        var meshOverhangM = 0.5
        var longSideFovDeg = 68.0
        var groundCameraHeightM = 1.5
        var elevatedCameraHeightM = 3.0
    }

    /// A point with y down, in pixels of a picture `w` × `h`.
    struct P: Equatable { var x: Double; var y: Double }

    static func toPixels(_ c: [Double], _ w: Double, _ h: Double) -> P { P(x: c[0] * w, y: (1 - c[1]) * h) }
    static func toVision(_ p: P, _ w: Double, _ h: Double) -> (Double, Double) { (p.x / w, 1 - p.y / h) }

    static func inFrame(_ v: (Double, Double)) -> Bool { (0...1).contains(v.0) && (0...1).contains(v.1) }

    /// The net label's ground line in pixels (y down): where each post meets the ground, from the mesh's height on
    /// screen and the tape's height. nil without four corners.
    static func netFoot(_ net: PlayerFeatures.NetGeometry, w: Double, h: Double, a: Assumptions) -> (left: P, right: P, pxPerM: Double, tapeLeft: P, tapeRight: P)? {
        guard net.corners.count == 4, net.corners.allSatisfy({ $0.count == 2 }) else { return nil }
        let tl = toPixels(net.corners[0], w, h), tr = toPixels(net.corners[1], w, h)
        let br = toPixels(net.corners[2], w, h), bl = toPixels(net.corners[3], w, h)
        let below = (a.tapeHeightM - a.meshDepthM) / a.meshDepthM
        let gl = P(x: bl.x + (bl.x - tl.x) * below, y: bl.y + (bl.y - tl.y) * below)
        let gr = P(x: br.x + (br.x - tr.x) * below, y: br.y + (br.y - tr.y) * below)
        let mesh = (hypot(bl.x - tl.x, bl.y - tl.y) + hypot(br.x - tr.x, br.y - tr.y)) / 2
        guard mesh > 1, gr.x - gl.x > 4 else { return nil }
        return (gl, gr, mesh / a.meshDepthM, tl, tr)
    }

    // MARK: - A. Net-guided

    static func netGuided(net: PlayerFeatures.NetGeometry, width: Int, height: Int, camera: String?, spec: CourtSpec,
                          assumptions a: Assumptions = Assumptions(), now: Date = Date()) -> CourtProposal? {
        let start = Date()
        let w = Double(width), h = Double(height)
        guard let foot = netFoot(net, w: w, h: h, a: a) else { return nil }
        var notes: [String] = []
        let meshLen = spec.widthM + a.meshOverhangM
        let inset = a.meshOverhangM / 2 / meshLen
        let gl = foot.left, gr = foot.right
        let netL = P(x: gl.x + (gr.x - gl.x) * inset, y: gl.y + (gr.y - gl.y) * inset)
        let netR = P(x: gr.x - (gr.x - gl.x) * inset, y: gr.y - (gr.y - gl.y) * inset)
        let s = foot.pxPerM
        let widthScale = hypot(gr.x - gl.x, gr.y - gl.y) / meshLen
        let ratio = widthScale / s
        if ratio < 0.6 || ratio > 1.6 {
            notes.append(String(format: "the net label's width and height disagree with a %.1f m mesh by %.2f×: the label or the dimensions are off", meshLen, ratio))
        }
        let f = max(w, h) / 2 / tan(a.longSideFovDeg / 2 * .pi / 180)
        let d = f / s
        let elevated = camera?.lowercased().contains("elevated") == true
        let camH = elevated ? a.elevatedCameraHeightM : a.groundCameraHeightM
        let yg = (netL.y + netR.y) / 2
        let vp = P(x: w / 2, y: yg - s * camH)
        func toward(_ p: P, _ k: Double) -> P { P(x: vp.x + (p.x - vp.x) * k, y: vp.y + (p.y - vp.y) * k) }
        let half = spec.lengthM / 2
        let kFar = d / (d + half)
        let farL = toward(netL, kFar), farR = toward(netR, kFar)
        var g = CourtLayout(nearLeft: CourtPoint(x: 0, y: 0, status: .unknown), nearRight: CourtPoint(x: 0, y: 0, status: .unknown),
                              netRight: point(netR, w, h), netLeft: point(netL, w, h), farLeft: point(farL, w, h), farRight: point(farR, w, h))
        if d - half > 1 {
            let kNear = d / (d - half)
            g.nearLeft = point(toward(netL, kNear), w, h)
            g.nearRight = point(toward(netR, kNear), w, h)
        } else {
            notes.append(String(format: "the camera seems to stand inside the court (%.1f m from the net by the assumed field of view): the near end line is not placed", d))
        }
        for r in CourtLayout.Role.allCases where g[r].status != .unknown {
            let p = g[r]
            if !(CourtLayout.placeableRange.contains(p.x) && CourtLayout.placeableRange.contains(p.y)) { g[r].status = .unknown }
        }
        notes.append(String(format: "assumed: net tape %.2f m, mesh %.1f m deep and %.1f m long (%@), field of view %.0f° across the long side, camera %.1f m high (%@), no roll, no yaw",
                            a.tapeHeightM, a.meshDepthM, meshLen, spec.source, a.longSideFovDeg, camH, elevated ? "elevated card" : "ground-level card"))
        notes.append(String(format: "camera ≈ %.1f m from the net by those assumptions", d))
        guard g.isUsable else { return nil }
        var confidence = 0.25
        if ratio < 0.6 || ratio > 1.6 { confidence = 0.1 }
        let sources = Dictionary(uniqueKeysWithValues: CourtLayout.Role.allCases.map { r -> (String, String) in
            (r.rawValue, g[r].status == .unknown ? "none" : ([.netLeft, .netRight].contains(r) ? "net_label" : "assumed"))
        })
        return CourtProposal(method: .netGuided, geometry: g, confidence: confidence, uncertainty: notes, pointSources: sources,
                             inputs: ["net": net.origin, "netLabelFingerprint": net.labelFingerprint, "camera": camera ?? "unknown", "spec": spec.source],
                             frameTimes: [], createdAt: now, ms: Date().timeIntervalSince(start) * 1000, codeSha: nil)
    }

    private static func point(_ p: P, _ w: Double, _ h: Double, status: CourtPoint.Status = .estimated) -> CourtPoint {
        let v = toVision(p, w, h)
        return CourtPoint(x: v.0, y: v.1, status: status)
    }

    // MARK: - B. Lines on the ground

    /// A straight line x·cosθ + y·sinθ = ρ in pixels (y down).
    struct Line: Equatable {
        var theta: Double
        var rho: Double

        func intersection(_ o: Line) -> P? {
            let det = cos(theta) * sin(o.theta) - sin(theta) * cos(o.theta)
            guard abs(det) > 1e-9 else { return nil }
            return P(x: (rho * sin(o.theta) - o.rho * sin(theta)) / det, y: (cos(theta) * o.rho - cos(o.theta) * rho) / det)
        }

        static func through(_ a: P, _ b: P) -> Line {
            let dx = b.x - a.x, dy = b.y - a.y
            var theta = atan2(dx, -dy)   // the normal (cos θ, sin θ) ⟂ (dx, dy)
            if theta < 0 { theta += .pi }
            if theta >= .pi { theta -= .pi }
            return Line(theta: theta, rho: a.x * cos(theta) + a.y * sin(theta))
        }

        /// x where the line reaches height y (nil when it runs level).
        func x(atY y: Double) -> Double? { abs(cos(theta)) > 1e-9 ? (rho - y * sin(theta)) / cos(theta) : nil }
        /// y where the line reaches x (nil when it runs upright).
        func y(atX x: Double) -> Double? { abs(sin(theta)) > 1e-9 ? (rho - x * cos(theta)) / sin(theta) : nil }
    }

    /// Thin-line response on the ground below the net's tape.
    struct LineEvidence {
        var width: Int
        var height: Int
        /// Ridge response per pixel (0 outside the search region).
        var response: [Double]
        /// The response a pixel needs to count as covered by a line.
        var threshold: Double
        /// The segments the search chose (pixels, y down), for the diagnostic picture.
        var found: [(P, P)] = []
    }

    /// The ridge response below the net's tape (and outside the mesh), within three quarters of the net's width beside
    /// each post: a painted line, tape or rope differs from the ground on both sides of it while the two sides match
    /// each other; an edge between two surfaces (the field's end, a shadow) differs on one side only.
    static func lineEvidence(_ img: CourtRGBImage, net: PlayerFeatures.NetGeometry, assumptions a: Assumptions = Assumptions()) -> LineEvidence? {
        let w = img.width, h = img.height
        guard w > 32, h > 32, let foot = netFoot(net, w: Double(w), h: Double(h), a: a) else { return nil }
        let tape = Line.through(foot.tapeLeft, foot.tapeRight)
        let netBottomL = toPixels(net.corners[3], Double(w), Double(h)), netBottomR = toPixels(net.corners[2], Double(w), Double(h))
        let meshLeft = min(foot.tapeLeft.x, netBottomL.x) - 4, meshRight = max(foot.tapeRight.x, netBottomR.x) + 4
        let meshBottom = Line.through(netBottomL, netBottomR)
        let span = foot.right.x - foot.left.x
        let xLo = max(0, Int(foot.left.x - 0.75 * span)), xHi = min(w - 1, Int(foot.right.x + 0.75 * span))
        func inGround(_ x: Int, _ y: Int) -> Bool {
            guard x >= xLo, x <= xHi, let ty = tape.y(atX: Double(x)), Double(y) > ty + 3 else { return false }
            if Double(x) > meshLeft, Double(x) < meshRight, Double(y) < (meshBottom.y(atX: Double(x)) ?? ty) + 4 { return false }
            return true
        }
        @inline(__always) func dist(_ i: Int, _ j: Int) -> Double {
            let p = i * 3, q = j * 3
            let d0 = Double(img.rgb[p]) - Double(img.rgb[q]), d1 = Double(img.rgb[p + 1]) - Double(img.rgb[q + 1]), d2 = Double(img.rgb[p + 2]) - Double(img.rgb[q + 2])
            return (d0 * d0 + d1 * d1 + d2 * d2).squareRoot()
        }
        let dirs = [(1, 0), (0, 1), (1, 1), (1, -1)]
        let r = 4
        var response = [Double](repeating: 0, count: w * h)
        var values: [Double] = []
        for y in r..<(h - r) {
            for x in r..<(w - r) where inGround(x, y) {
                let i = y * w + x
                var best = 0.0
                for d in [2, 4] {
                    for (dx, dy) in dirs {
                        let a = (y - dy * d) * w + (x - dx * d), b = (y + dy * d) * w + (x + dx * d)
                        best = max(best, min(dist(i, a), dist(i, b)) - dist(a, b))
                    }
                }
                response[i] = best
                values.append(best)
            }
        }
        guard values.count > 100 else { return nil }
        values.sort()
        return LineEvidence(width: w, height: h, response: response, threshold: max(values[Int(Double(values.count - 1) * 0.85)], 8))
    }

    /// How much a segment stands out: the mean response along it less the mean of two strips 6 px to either side, and
    /// the share of its in-frame length covered by line evidence. A line on textured ground scores near zero; a painted
    /// line, tape or rope well above it.
    static func segmentScore(_ a: P, _ b: P, _ ev: LineEvidence) -> (contrast: Double, coverage: Double, length: Double) {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 1 else { return (0, 0, 0) }
        let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len, nx = -uy, ny = ux
        func at(_ x: Double, _ y: Double) -> Double? {
            let xi = Int(x.rounded()), yi = Int(y.rounded())
            guard xi >= 0, xi < ev.width, yi >= 0, yi < ev.height else { return nil }
            return ev.response[yi * ev.width + xi]
        }
        var sum = 0.0, side = 0.0, covered = 0, n = 0
        var t = 0.0
        while t <= len {
            let x = a.x + ux * t, y = a.y + uy * t
            t += 1
            guard let centre = at(x, y) else { continue }
            // Within a pixel of the line (a line one pixel off still counts).
            let v = max(centre, at(x + nx, y + ny) ?? 0, at(x - nx, y - ny) ?? 0)
            let s1 = at(x + nx * 6, y + ny * 6) ?? 0, s2 = at(x - nx * 6, y - ny * 6) ?? 0
            sum += v; side += (s1 + s2) / 2; n += 1
            if v > ev.threshold { covered += 1 }
        }
        guard n > 0 else { return (0, 0, 0) }
        return ((sum - side) / Double(n), Double(covered) / Double(n), Double(n))
    }

    /// The court-lines proposal (B) and the combination with A, from the line response of a median picture.
    static func fromLines(_ evidence: LineEvidence, net: PlayerFeatures.NetGeometry, netGuided: CourtProposal?, spec: CourtSpec,
                          assumptions a: Assumptions = Assumptions(), frameTimes: [Double], ms: Double, now: Date = Date())
        -> (lines: CourtProposal?, combined: CourtProposal?, notes: [String], evidence: LineEvidence) {
        var ev = evidence
        let w = Double(ev.width), h = Double(ev.height)
        guard let foot = netFoot(net, w: w, h: h, a: a) else { return (nil, nil, ["no net corners"], ev) }
        var notes: [String] = []
        let netDir = (foot.right.x - foot.left.x, foot.right.y - foot.left.y)
        let netWidth = hypot(netDir.0, netDir.1)
        let ndx = netDir.0 / netWidth, ndy = netDir.1 / netWidth
        let meshLen = spec.widthM + a.meshOverhangM
        let inset = a.meshOverhangM / 2 / meshLen
        let tapeY = (foot.tapeLeft.y + foot.tapeRight.y) / 2
        let minContrast = 4.0, minCoverage = 0.3

        // Division: a centre line close under the net's ground line (indoor), else that ground line.
        var division = Line.through(foot.left, foot.right)
        var divisionSeen = false
        do {
            var best: (Line, Double)?
            for dy in stride(from: -0.05 * h, through: 0.05 * h, by: 1) {
                let a0 = P(x: foot.left.x, y: foot.left.y + dy), b0 = P(x: foot.right.x, y: foot.right.y + dy)
                let s = segmentScore(a0, b0, ev)
                if s.contrast > 2 * minContrast, s.coverage > 0.5, s.contrast > (best?.1 ?? 0) { best = (Line.through(a0, b0), s.contrast) }
            }
            if let best { division = best.0; divisionSeen = true; notes.append("a line under the net (a centre line) gives the net's ground line") }
        }

        // Where a segment along `dir` from `p` leaves the frame (or reaches `limitY` going up).
        func extent(_ p: P, _ dx: Double, _ dy: Double, limitY: Double? = nil) -> P {
            var t = 0.0
            while true {
                let q = P(x: p.x + dx * (t + 1), y: p.y + dy * (t + 1))
                if q.x < 0 || q.x >= w || q.y < 0 || q.y >= h { break }
                if let limitY, dy < 0, q.y < limitY { break }
                t += 1
            }
            return P(x: p.x + dx * t, y: p.y + dy * t)
        }

        // Sidelines: through a point of the division near where the court's edge should cross it, slanting outward toward
        // the camera; scored on both halves (to the frame's edge below, to the tape's height above).
        func sideline(left: Bool) -> (line: Line, cross: P, contrast: Double)? {
            let along = left ? inset : 1 - inset
            let ex = foot.left.x + netDir.0 * along, ey = foot.left.y + netDir.1 * along
            let base = P(x: ex, y: division.y(atX: ex) ?? ey)
            var best: (Line, P, Double, o: Double, deg: Double)?
            let tol = 0.3 * netWidth
            func consider(_ o: Double, _ deg: Double) {
                let p = P(x: base.x + ndx * o, y: base.y + ndy * o)
                let r = deg * .pi / 180
                let dx = (left ? -1 : 1) * sin(r), dy = cos(r)   // toward the camera
                // Scored on the near half only: above the net's ground line the post stands where the sideline would run.
                let near = segmentScore(p, extent(p, dx, dy), ev)
                guard near.length > 0.1 * h else { return }
                let contrast = near.contrast, coverage = near.coverage
                guard contrast >= minContrast, coverage >= minCoverage else { return }
                let value = contrast * coverage.squareRoot() * (1 - 0.3 * abs(o) / tol)
                if value > (best?.2 ?? 0) { best = (Line.through(p, P(x: p.x + dx, y: p.y + dy)), p, value, o, deg) }
            }
            // Coarse (2 px, 1°), then fine around the best (0.5 px, 0.25°).
            // At least 8° off upright: the posts stand upright exactly where a sideline crosses the net line.
            for o in stride(from: -tol, through: tol, by: 2) { for deg in stride(from: 8.0, through: 80, by: 1) { consider(o, deg) } }
            if let b = best {
                for o in stride(from: b.o - 2, through: b.o + 2, by: 0.5) {
                    for deg in stride(from: max(8, b.deg - 1), through: min(80, b.deg + 1), by: 0.25) { consider(o, deg) }
                }
            }
            return best.map { ($0.0, $0.1, $0.2) }
        }
        let sl = sideline(left: true), sr = sideline(left: false)
        guard let sl, let sr else {
            notes.append("court lines: \(sl == nil ? "no left" : "a left") and \(sr == nil ? "no right" : "a right") sideline stands out near the net's ends")
            ev.found = [sl, sr].compactMap { $0 }.map { s in (s.cross, extent(s.cross, -sin(s.line.theta), cos(s.line.theta))) }
            return (nil, nil, notes, ev)
        }
        if let vp = sl.line.intersection(sr.line), vp.y > min(sl.cross.y, sr.cross.y) {
            notes.append("the two sidelines meet below the net line: not a court seen from behind an end line")
            return (nil, nil, notes, ev)
        }

        // End lines: segments between the sidelines, the outermost one that stands out on each side.
        func endLine(near: Bool) -> Line? {
            let ny = (sl.cross.y + sr.cross.y) / 2
            let ys = near ? Array(stride(from: ny + 0.03 * h, through: h - 1, by: 2)) : Array(stride(from: tapeY + 2, through: ny - 0.01 * h, by: 1))
            var candidates: [(Line, Double, Double)] = []
            for y1 in ys {
                for dy in stride(from: -0.08 * h, through: 0.08 * h, by: 2) {
                    let y2 = y1 + dy
                    guard let x1 = sl.line.x(atY: y1), let x2 = sr.line.x(atY: y2) else { continue }
                    let a0 = P(x: x1, y: y1), b0 = P(x: x2, y: y2)
                    let s = segmentScore(a0, b0, ev)
                    guard s.length > 0.15 * w, s.contrast >= minContrast, s.coverage >= minCoverage else { continue }
                    candidates.append((Line.through(a0, b0), s.contrast * s.coverage.squareRoot(), (y1 + y2) / 2))
                }
            }
            guard let best = candidates.map(\.1).max() else { return nil }
            let strong = candidates.filter { $0.1 >= 0.6 * best }
            return (near ? strong.max { $0.2 < $1.2 } : strong.min { $0.2 < $1.2 })?.0
        }
        let nearLine = endLine(near: true), farLine = endLine(near: false)
        ev.found = [sl.line, sr.line, nearLine, farLine].compactMap { $0 }.compactMap { l in
            let pts = [0.0, h - 1].compactMap { y in l.x(atY: y).map { P(x: $0, y: y) } }
            return pts.count == 2 ? (pts[0], pts[1]) : nil
        }

        func corner(_ a: Line, _ b: Line?) -> CourtPoint {
            guard let b, let p = a.intersection(b) else { return CourtPoint(x: 0, y: 0, status: .unknown) }
            let v = toVision(p, w, h)
            return CourtPoint(x: v.0, y: v.1, status: inFrame(v) ? .seen : .estimated)
        }
        guard let crossL = sl.line.intersection(division), let crossR = sr.line.intersection(division) else { return (nil, nil, notes, ev) }
        let dl = toVision(crossL, w, h), dr = toVision(crossR, w, h)
        let divisionStatus: CourtPoint.Status = divisionSeen ? .seen : .estimated
        var g = CourtLayout(nearLeft: corner(sl.line, nearLine), nearRight: corner(sr.line, nearLine),
                            netRight: CourtPoint(x: dr.0, y: dr.1, status: inFrame(dr) ? divisionStatus : .estimated),
                            netLeft: CourtPoint(x: dl.0, y: dl.1, status: inFrame(dl) ? divisionStatus : .estimated),
                            farLeft: corner(sl.line, farLine), farRight: corner(sr.line, farLine))
        for r in CourtLayout.Role.allCases where g[r].status != .unknown
            && !(CourtLayout.placeableRange.contains(g[r].x) && CourtLayout.placeableRange.contains(g[r].y)) { g[r].status = .unknown }
        notes.append(String(format: "court lines: both sidelines (scores %.1f, %.1f), %@, %@", sl.contrast, sr.contrast,
                            nearLine == nil ? "no near end line" : "a near end line", farLine == nil ? "no far end line" : "a far end line"))
        let linesSources = Dictionary(uniqueKeysWithValues: CourtLayout.Role.allCases.map { r -> (String, String) in
            if g[r].status == .unknown { return (r.rawValue, "none") }
            if [.netLeft, .netRight].contains(r) { return (r.rawValue, divisionSeen ? "line" : "line+net_label") }
            return (r.rawValue, "line")
        })
        // How many lines were found, nothing more: the pilot measured these proposals wrong often enough (P2 report)
        // that no score here may read as reliable.
        let found = 2 + (nearLine == nil ? 0 : 1) + (farLine == nil ? 0 : 1)
        let score = 0.1 * Double(found)
        notes.append("unvalidated: line positions are not checked against the court's real shape")
        let inputs = ["net": net.origin, "netLabelFingerprint": net.labelFingerprint, "frames": "\(frameTimes.count)", "picture": "\(ev.width)x\(ev.height)",
                      "threshold": String(format: "%.1f", ev.threshold)]
        let lines: CourtProposal? = g.isUsable
            ? CourtProposal(method: .courtLines, geometry: g, confidence: score, uncertainty: notes, pointSources: linesSources, inputs: inputs,
                            frameTimes: frameTimes, createdAt: now, ms: ms, codeSha: nil)
            : nil
        if !g.isUsable { notes.append("court lines: the found lines don't make a usable court (\(g.problems.joined(separator: "; ")))") }

        // Combined: B's lines; a missing end line from A's, cut by B's sidelines.
        guard let ag = netGuided?.geometry else { return (lines, nil, notes, ev) }
        var c = g
        var sources = linesSources
        func fill(near: Bool) {
            let roles: [CourtLayout.Role] = near ? [.nearLeft, .nearRight] : [.farLeft, .farRight]
            guard roles.contains(where: { c[$0].status == .unknown }), ag[roles[0]].status != .unknown, ag[roles[1]].status != .unknown else { return }
            let end = Line.through(toPixels([ag[roles[0]].x, ag[roles[0]].y], w, h), toPixels([ag[roles[1]].x, ag[roles[1]].y], w, h))
            for (role, side) in zip(roles, [sl.line, sr.line]) {
                guard let p = side.intersection(end) else { continue }
                let v = toVision(p, w, h)
                c[role] = CourtPoint(x: v.0, y: v.1, status: .estimated)
                sources[role.rawValue] = "line+assumed"
            }
        }
        fill(near: true)
        fill(near: false)
        guard c.isUsable, c != g else { return (lines, nil, notes + (c.isUsable ? [] : ["combined: unusable (\(c.problems.joined(separator: "; ")))"]), ev) }
        let assumed = sources.values.filter { $0 == "line+assumed" }.count
        let combined = CourtProposal(method: .combined, geometry: c, confidence: max(0.1, score - 0.05 * Double(assumed)),
                                     uncertainty: notes + (netGuided?.uncertainty.filter { $0.hasPrefix("assumed") } ?? []),
                                     pointSources: sources, inputs: inputs, frameTimes: frameTimes, createdAt: now, ms: ms, codeSha: nil)
        return (lines, combined, notes, ev)
    }

    // MARK: - Frames

    /// Times spread over [from, to], `count` of them, avoiding excluded spans.
    static func sampleTimes(from: Double, to: Double, count: Int, excluded: [PlayerFeatures.TickSpan]) -> [Double] {
        guard to > from, count > 0 else { return [] }
        let step = (to - from) / Double(count + 1)
        return (1...count).map { from + Double($0) * step }.filter { PlayerFeaturesRun.exclusion(at: $0, in: excluded) == nil }
    }

    /// Decodes the upright frames at `times` (at most `longSide` px) from a local file.
    static func frames(of url: URL, at times: [Double], longSide: Int = 640) async throws -> [CourtRGBImage] {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: longSide, height: longSide)
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        var out: [CourtRGBImage] = []
        for t in times {
            let image = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            if let rgb = CourtRGBImage(image) { out.append(rgb) }
        }
        return out
    }

    struct Outcome {
        var proposals: [CourtProposal]
        var frameTimes: [Double] = []
        var notes: [String]
        var median: CourtRGBImage?
        var evidence: LineEvidence?
    }

    /// Both methods and the combination for one segment of one recording.
    /// `markings`: what the person said marks the court; `none` skips the line search (there is nothing to find).
    /// `experiment`: whose ledger records the frames read (detector_evaluation, `ref`) before the first is decoded — the
    /// one place both the GUI and `--player-lab-court` read footage for a court, so neither can skip it. A ledger that
    /// can't be written stops the proposal.
    static func propose(footage: URL, net: PlayerFeatures.NetGeometry?, binding b: CourtCalibrationFile.Binding, from: Double, to: Double,
                        excluded: [PlayerFeatures.TickSpan], spec: CourtSpec, markings: CourtSetup.Markings? = nil, frameCount: Int = 9,
                        experiment: URL, ref: String, codeSha: String?, now: Date = Date()) async throws -> Outcome {
        guard let net else { return Outcome(proposals: [], frameTimes: [], notes: ["no person net label for this recording: place the court by hand"], median: nil, evidence: nil) }
        var proposals: [CourtProposal] = []
        var notes: [String] = []
        if var a = netGuided(net: net, width: b.frameWidth, height: b.frameHeight, camera: b.camera, spec: spec, now: now) {
            a.codeSha = codeSha
            proposals.append(a)
        } else { notes.append("net-guided: the net label doesn't give a usable court") }
        if markings == CourtSetup.Markings.none {
            return Outcome(proposals: proposals, frameTimes: [], notes: notes + ["no court markings (person's answer): no line search"], median: nil, evidence: nil)
        }
        let start = Date()
        let times = sampleTimes(from: from, to: to, count: frameCount, excluded: excluded)
        try ExposureLog.record(videos: [b.recordingId], kind: .detectorEvaluation, ref: ref,
                               note: "court calibration research P2 (D-034, proposed): \(times.count) frames of the experiment's copy read for a classical court-line search; no model, not training",
                               in: experiment, now: now)
        let pictures = try await frames(of: footage, at: times)
        guard pictures.count >= 3, let median = CourtRGBImage.median(pictures) else {
            return Outcome(proposals: proposals, frameTimes: times, notes: notes + ["court lines: fewer than 3 frames decoded"], median: nil, evidence: nil)
        }
        guard let ev = lineEvidence(median, net: net) else {
            return Outcome(proposals: proposals, frameTimes: times, notes: notes + ["court lines: no ground region below the net"], median: median, evidence: nil)
        }
        var r = fromLines(ev, net: net, netGuided: proposals.first { $0.method == .netGuided }, spec: spec, frameTimes: times, ms: 0, now: now)
        let ms = Date().timeIntervalSince(start) * 1000
        for var p in [r.lines, r.combined].compactMap({ $0 }) { p.codeSha = codeSha; p.ms = ms; proposals.append(p) }
        return Outcome(proposals: proposals, frameTimes: times, notes: notes + r.notes, median: median, evidence: r.evidence)
    }
}
