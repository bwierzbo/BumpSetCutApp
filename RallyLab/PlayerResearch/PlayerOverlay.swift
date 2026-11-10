//
//  PlayerOverlay.swift
//  RallyLab
//
//  The diagnostic picture of one analysed frame: every person's box in its
//  track's colour with the track ID, state and court membership, the pose
//  skeleton from the joints Vision reported (missing joints draw nothing), the
//  unmatched poses dashed, the net quad and the court lane when there is one,
//  and a header line with the recording, interval, time and tick. What is drawn
//  is exactly what the frame line holds — nothing is smoothed for the picture.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PlayerOverlay {
    static let bones: [(String, String)] = [
        ("left_ankle", "left_knee"), ("left_knee", "left_hip"), ("right_ankle", "right_knee"), ("right_knee", "right_hip"),
        ("left_hip", "root"), ("right_hip", "root"), ("root", "neck"), ("neck", "nose"),
        ("neck", "left_shoulder"), ("neck", "right_shoulder"), ("left_shoulder", "left_elbow"), ("left_elbow", "left_wrist"),
        ("right_shoulder", "right_elbow"), ("right_elbow", "right_wrist"), ("nose", "left_eye"), ("nose", "right_eye"),
        ("left_eye", "left_ear"), ("right_eye", "right_ear"),
        // The COCO-17 torso, for detectors without neck and root (RTMPose); with Vision they close the torso too.
        ("left_shoulder", "right_shoulder"), ("left_hip", "right_hip"), ("left_shoulder", "left_hip"), ("right_shoulder", "right_hip"),
    ]

    private static let palette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.95, 0.33, 0.25), (0.20, 0.65, 0.95), (0.35, 0.85, 0.35), (0.98, 0.80, 0.20), (0.75, 0.40, 0.95),
        (0.10, 0.85, 0.80), (0.98, 0.55, 0.10), (0.95, 0.45, 0.70), (0.60, 0.80, 0.20), (0.55, 0.55, 0.98),
    ]

    /// What to draw; the run's JPEGs draw everything, the Player Lab window toggles each layer.
    struct Options: Equatable, Sendable {
        var boxes = true
        var labels = true
        var skeletons = true
        var unmatchedPoses = true
        var net = true
        var lane = true
        var tentative = true
        var outOfCourt = true
        var header = true
        /// The court geometry (court_geometry_v1) when one is passed in.
        var court = true
    }

    /// Short zone names for labels.
    static func short(_ z: CourtZone) -> String {
        switch z {
        case .nearCourt: return "near"
        case .farCourt: return "far"
        case .nearServingArea: return "near-srv"
        case .farServingArea: return "far-srv"
        case .outsideCourt: return "out"
        case .unknown: return "?"
        }
    }

    static func zoneColor(_ z: CourtZone, alpha: CGFloat = 1) -> CGColor {
        switch z {
        case .nearCourt: return CGColor(red: 0.25, green: 0.6, blue: 1, alpha: alpha)
        case .farCourt: return CGColor(red: 1, green: 0.6, blue: 0.15, alpha: alpha)
        case .nearServingArea: return CGColor(red: 0.55, green: 0.85, blue: 1, alpha: alpha)
        case .farServingArea: return CGColor(red: 1, green: 0.85, blue: 0.4, alpha: alpha)
        case .outsideCourt: return CGColor(gray: 0.6, alpha: alpha)
        case .unknown: return CGColor(red: 0.9, green: 0.2, blue: 0.9, alpha: alpha)
        }
    }

    /// The court halves and serving areas of `g`, outlined in pixel space of a `w` × `h` picture.
    static func drawCourt(_ g: CourtLayout, spec: CourtSpec, w: CGFloat, h: CGFloat, color: CGColor, dashed: Bool, ctx: CGContext,
                          settings: CourtZoneClassifier.Settings = .init()) {
        func path(_ pts: [(Double, Double)]) {
            guard let f = pts.first else { return }
            ctx.move(to: CGPoint(x: f.0 * w, y: f.1 * h))
            for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0 * w, y: p.1 * h)) }
            ctx.closePath()
        }
        let near = g.outline([(0, 0), (1, 0), (1, 0.5), (0, 0.5)]), far = g.outline([(0, 0.5), (1, 0.5), (1, 1), (0, 1)])
        ctx.setFillColor(zoneColor(.nearCourt, alpha: 0.12)); path(near); ctx.fillPath()
        ctx.setFillColor(zoneColor(.farCourt, alpha: 0.12)); path(far); ctx.fillPath()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: dashed ? [8, 5] : [])
        path(near); path(far); ctx.strokePath()
        let d = settings.serveDepthM / spec.lengthM, m = settings.serveSideMargin
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 4])
        if g.map(near: true) != nil { path(g.outline([(-m, -d), (1 + m, -d), (1 + m, 0), (-m, 0)])) }
        if g.map(near: false) != nil { path(g.outline([(-m, 1), (1 + m, 1), (1 + m, 1 + d), (-m, 1 + d)])) }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        for r in CourtLayout.Role.allCases where g[r].status != .unknown {
            let p = CGPoint(x: g[r].x * w, y: g[r].y * h), rect = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.setStrokeColor(color)
            if g[r].status == .seen { ctx.setFillColor(color); ctx.fillEllipse(in: rect) } else { ctx.strokeEllipse(in: rect) }
        }
    }

    static func color(_ track: Int, alpha: CGFloat = 1) -> CGColor {
        let c = palette[abs(track) % palette.count]
        return CGColor(red: c.0, green: c.1, blue: c.2, alpha: alpha)
    }

    static func text(_ s: String, at p: CGPoint, size: CGFloat, color: CGColor, in ctx: CGContext) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
        ctx.fill(CGRect(x: p.x - 2, y: p.y - 3, width: bounds.width + 4, height: bounds.height + 4))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    private static func skeleton(_ pose: PlayerFeatures.Pose, color: CGColor, dashed: Bool, w: CGFloat, h: CGFloat, ctx: CGContext) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: dashed ? [4, 3] : [])
        for (a, b) in bones {
            guard let ja = pose.j(a), let jb = pose.j(b) else { continue }
            ctx.move(to: CGPoint(x: ja.x * w, y: ja.y * h))
            ctx.addLine(to: CGPoint(x: jb.x * w, y: jb.y * h))
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setFillColor(color)
        for j in pose.joints.compactMap({ $0 }) {
            ctx.fillEllipse(in: CGRect(x: j.x * w - 2.5, y: j.y * h - 2.5, width: 5, height: 5))
        }
    }

    /// The overlay as JPEG data (every layer), nil when the image can't be drawn.
    static func render(_ image: CGImage, frame: PlayerFeatures.Frame, recording: String, net: PlayerFeatures.NetGeometry?, lane: PlayerCourtLane?) -> Data? {
        compose(image, frame: frame, recording: recording, net: net, lane: lane, options: Options()).flatMap(jpeg)
    }

    private static func membership(_ p: PlayerFeatures.Person, _ zones: [PersonZone?]?, _ i: Int) -> PlayerFeatures.CourtMembership {
        guard let zones else { return p.court }
        guard zones.indices.contains(i), let z = zones[i] else { return .unknown }
        return CourtMembershipPass.membership(z)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// The frame with the chosen layers drawn on it.
    /// `court`: a court to draw and the colour to draw it in (dashed: not confirmed). `zones`: per person, zones to
    /// show in place of the frame line's own (a preview against a court being edited), nil to show the line's.
    static func compose(_ image: CGImage, frame: PlayerFeatures.Frame, recording: String, net: PlayerFeatures.NetGeometry?, lane: PlayerCourtLane?,
                        options o: Options, court: (geometry: CourtLayout, spec: CourtSpec, color: CGColor, dashed: Bool)? = nil,
                        zones: [PersonZone?]? = nil) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        if o.net, let net, net.corners.count == 4 {
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.8))
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: net.corners[0][0] * w, y: net.corners[0][1] * h))
            for c in net.corners.dropFirst() + [net.corners[0]] { ctx.addLine(to: CGPoint(x: c[0] * w, y: c[1] * h)) }
            ctx.strokePath()
        }
        if o.court, let court {
            drawCourt(court.geometry, spec: court.spec, w: w, h: h, color: court.color, dashed: court.dashed, ctx: ctx)
        }
        if o.lane, let lane, court == nil {
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 0, alpha: 0.5))
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            let ys = stride(from: 0.0, through: 1.0, by: 0.05)
            for edge in [0, 1] {
                for (i, y) in ys.enumerated() {
                    let s = lane.span(atY: y)
                    let p = CGPoint(x: (edge == 0 ? s.lo : s.hi) * w, y: y * h)
                    if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
                }
            }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for (i, p) in frame.persons.enumerated() where (o.tentative || p.state == .confirmed) && (o.outOfCourt || membership(p, zones, i) != .outside) {
            let zone = zones.map { $0.indices.contains(i) ? $0[i] : nil } ?? p.zone
            let col = color(p.track)
            ctx.setStrokeColor(col)
            ctx.setLineWidth(p.state == .confirmed ? 2.5 : 1)
            ctx.setLineDash(phase: 0, lengths: membership(p, zones, i) == .outside ? [5, 4] : [])
            if o.boxes { ctx.stroke(CGRect(x: p.box.x * w, y: p.box.y * h, width: p.box.w * w, height: p.box.h * h)) }
            ctx.setLineDash(phase: 0, lengths: [])
            if o.skeletons, let pose = p.pose { skeleton(pose, color: col, dashed: false, w: w, h: h, ctx: ctx) }
            if let zone {
                // The ground point the zone was read at, in the zone's colour.
                let g = CourtGround.point(p)
                ctx.setFillColor(zoneColor(zone.zone))
                ctx.fillEllipse(in: CGRect(x: g.x * w - 4, y: g.y * h - 4, width: 8, height: 8))
            }
            guard o.labels else { continue }
            let where_ = zone.map { "\(short($0.zone))\($0.uncertain ? "~" : "")" } ?? p.court.rawValue
            let tag = "#\(p.track)\(p.state == .tentative ? "?" : "")\(p.ambiguous ? "!" : "") \(where_)"
            text(tag, at: CGPoint(x: p.box.x * w, y: min(h - 14, p.box.maxY * h + 3)), size: 10, color: col, in: ctx)
        }
        for pose in frame.unmatchedPoses where o.unmatchedPoses { skeleton(pose, color: CGColor(gray: 1, alpha: 0.9), dashed: true, w: w, h: h, ctx: ctx) }
        let header = String(format: "%@  %@  t=%.3fs tick=%d seg=%d%@  persons=%d poses=%d unmatched=%d", recording, frame.interval, frame.t, frame.tick,
                            frame.seg, frame.reset.map { " reset=\($0)" } ?? "", frame.persons.count, frame.persons.filter { $0.pose != nil }.count,
                            frame.unmatchedPoses.count)
        if o.header { text(header, at: CGPoint(x: 6, y: h - 16), size: 11, color: CGColor(gray: 1, alpha: 1), in: ctx) }
        return ctx.makeImage()
    }
}
