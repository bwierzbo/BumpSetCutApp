//
//  CalibrationCanvasGeometry.swift
//  BumpSetCut
//
//  The Court & Net editor's geometry, apart from its views: how the upright frame sits on
//  the canvas at a zoom and a pan (and back from a touch to the frame), the shapes as they
//  are while a person is still placing them, and what a touch lands on.
//

import CoreGraphics
import Foundation

enum CalibrationTarget: String, CaseIterable, Sendable { case court, net }

/// One point a person places: a court ground point, or a net corner (its place in NetQuad.pointNames).
enum CalibrationHandle: Hashable, Sendable {
    case court(CourtLayout.Role)
    case net(Int)

    var target: CalibrationTarget {
        switch self {
        case .court: return .court
        case .net: return .net
        }
    }
}

/// The upright frame on the canvas: fitted at scale 1, zoomed about a point, panned. Zooming out past 1 leaves
/// room round the frame, where a court corner that is out of the picture is placed.
struct CalibrationViewport: Equatable {
    var canvas: CGSize
    /// The upright frame's width over its height.
    var frameAspect: CGFloat
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let scaleRange: ClosedRange<CGFloat> = 0.5...8

    var frameRect: CGRect {
        guard canvas.width > 0, canvas.height > 0, frameAspect > 0 else { return .zero }
        let height = min(canvas.width / frameAspect, canvas.height) * scale
        let width = height * frameAspect
        return CGRect(x: (canvas.width - width) / 2 + offset.width, y: (canvas.height - height) / 2 + offset.height, width: width, height: height)
    }

    /// Where a frame point (fractions, origin bottom-left) is on the canvas.
    func point(x: Double, y: Double) -> CGPoint {
        let r = frameRect
        return CGPoint(x: r.minX + CGFloat(x) * r.width, y: r.maxY - CGFloat(y) * r.height)
    }

    /// The frame point under a canvas point; outside 0…1 when the touch is off the frame.
    func normalized(_ p: CGPoint) -> (x: Double, y: Double) {
        let r = frameRect
        guard r.width > 0, r.height > 0 else { return (0, 0) }
        return (Double((p.x - r.minX) / r.width), Double((r.maxY - p.y) / r.height))
    }

    /// Zoomed to newScale with the frame point under anchor staying under it.
    func zoomed(to newScale: CGFloat, keeping anchor: CGPoint) -> CalibrationViewport {
        let under = normalized(anchor)
        var v = self
        v.scale = min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, newScale))
        let moved = v.point(x: under.x, y: under.y)
        v.offset.width += anchor.x - moved.x
        v.offset.height += anchor.y - moved.y
        return v.keptInView()
    }

    func panned(by translation: CGSize) -> CalibrationViewport {
        var v = self
        v.offset.width += translation.width
        v.offset.height += translation.height
        return v.keptInView()
    }

    /// A strip of the picture always stays on the canvas, so it can't be lost off screen — and no more than a
    /// strip, so any corner of it can be brought to the middle at any zoom.
    private func keptInView() -> CalibrationViewport {
        var v = self
        let r = v.frameRect
        let (stripX, stripY) = (min(60, canvas.width / 4), min(60, canvas.height / 4))
        v.offset.width += max(0, stripX - r.maxX) - max(0, r.minX - (canvas.width - stripX))
        v.offset.height += max(0, stripY - r.maxY) - max(0, r.minY - (canvas.height - stripY))
        return v
    }

    /// A magnifier's view: a square of side size showing this view magnified, the frame point at its centre.
    func loupe(onX x: Double, y: Double, side: CGFloat, magnification: CGFloat) -> CalibrationViewport {
        var v = CalibrationViewport(canvas: CGSize(width: side, height: side), frameAspect: frameAspect)
        let fitted = v.frameRect.height
        guard fitted > 0 else { return v }
        v.scale = frameRect.height * magnification / fitted
        let p = v.point(x: x, y: y)
        v.offset = CGSize(width: side / 2 - p.x, height: side / 2 - p.y)
        return v
    }
}

/// What a drag that starts at a touch does.
enum CalibrationDragAction: Equatable {
    case handle(CalibrationHandle)
    /// A boundary line: both its ends move together.
    case edge(CalibrationHandle, CalibrationHandle)
    /// Every placed point of the shape.
    case shape
    case pan
}

/// The court and the net while a person is placing them: a court point not placed is `unknown`, a net corner not
/// placed is nil. The net becomes a NetQuad when all four corners are there.
struct CalibrationWorkingShapes: Equatable, Sendable {
    var court: CourtLayout
    var net: [NetQuad.Point?]
    /// Court points the person said they can't place: not asked for again.
    var skipped: Set<CourtLayout.Role> = []

    /// The order a person is asked for the court's points.
    static let courtOrder: [CourtLayout.Role] = [.nearLeft, .nearRight, .netLeft, .netRight, .farLeft, .farRight]
    /// The court's boundary, corner to corner round the outside.
    static let courtBoundary: [CourtLayout.Role] = [.nearLeft, .nearRight, .netRight, .farRight, .farLeft, .netLeft]

    init(court: CourtLayout? = nil, net: NetQuad? = nil) {
        let unplaced = CourtPoint(x: 0, y: 0, status: .unknown)
        self.court = court ?? CourtLayout(nearLeft: unplaced, nearRight: unplaced, netRight: unplaced, netLeft: unplaced, farLeft: unplaced, farRight: unplaced)
        self.net = net.map { [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft] } ?? [nil, nil, nil, nil]
        skipped = Set(CourtLayout.Role.allCases.filter { court != nil && self.court[$0].status == .unknown })
    }

    var netQuad: NetQuad? {
        guard let tl = net[0], let tr = net[1], let br = net[2], let bl = net[3] else { return nil }
        return NetQuad(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
    }

    var hasCourtPoints: Bool { CourtLayout.Role.allCases.contains { court[$0].status != .unknown } }
    var hasNetCorners: Bool { net.contains { $0 != nil } }

    static func handles(of target: CalibrationTarget) -> [CalibrationHandle] {
        switch target {
        case .court: return courtOrder.map(CalibrationHandle.court)
        case .net: return (0..<4).map(CalibrationHandle.net)
        }
    }

    static func edges(of target: CalibrationTarget) -> [(CalibrationHandle, CalibrationHandle)] {
        switch target {
        case .court:
            let ring = courtBoundary.map(CalibrationHandle.court)
            return ring.indices.map { (ring[$0], ring[($0 + 1) % ring.count]) } + [(.court(.netLeft), .court(.netRight))]
        case .net:
            return (0..<4).map { (.net($0), .net(($0 + 1) % 4)) }
        }
    }

    func position(_ handle: CalibrationHandle) -> (x: Double, y: Double)? {
        switch handle {
        case .court(let role): return court[role].status == .unknown ? nil : (court[role].x, court[role].y)
        case .net(let i): return net[i].map { ($0.x, $0.y) }
        }
    }

    /// The next point to ask for: the first not placed and not skipped.
    func nextToPlace(_ target: CalibrationTarget) -> CalibrationHandle? {
        Self.handles(of: target).first { handle in
            if case .court(let role) = handle, skipped.contains(role) { return false }
            return position(handle) == nil
        }
    }

    private static func inFrame(_ x: Double, _ y: Double) -> Bool { (0...1).contains(x) && (0...1).contains(y) }

    /// Puts a point at a frame position. A court point outside the frame is `estimated` — never `seen`; one
    /// brought into the frame from outside, or placed new, is `seen`; one moved within the frame keeps what the
    /// person said of it. A net corner stays in the frame.
    mutating func set(_ handle: CalibrationHandle, x: Double, y: Double) {
        switch handle {
        case .court(let role):
            let old = court[role]
            let status: CourtPoint.Status = !Self.inFrame(x, y) ? .estimated
                : (old.status == .estimated && Self.inFrame(old.x, old.y) ? .estimated : .seen)
            court = court.moving(role, to: x, y, status: status)
            skipped.remove(role)
        case .net(let i):
            net[i] = NetQuad.Point(x: min(1, max(0, x)), y: min(1, max(0, y)))
        }
    }

    /// Takes a point away. A court point is then one the person can't place.
    mutating func remove(_ handle: CalibrationHandle) {
        switch handle {
        case .court(let role):
            court[role] = CourtPoint(x: 0, y: 0, status: .unknown)
            skipped.insert(role)
        case .net(let i):
            net[i] = nil
        }
    }

    /// A court point in the frame is `seen` or, when the person says it is hidden and judged, `estimated`.
    mutating func setEstimated(_ estimated: Bool, _ role: CourtLayout.Role) {
        let p = court[role]
        guard p.status != .unknown, Self.inFrame(p.x, p.y) else { return }
        court[role].status = estimated ? .estimated : .seen
    }

    /// Moves handles by a frame-fraction delta from where they were in start. Net corners move together and stop
    /// together at the frame's edge, so a line or a whole net keeps its shape.
    mutating func translate(_ handles: [CalibrationHandle], from start: CalibrationWorkingShapes, dx: Double, dy: Double) {
        let placed = handles.compactMap { h in start.position(h).map { (h, $0) } }
        var (dx, dy) = (dx, dy)
        let netPoints = placed.filter { $0.0.target == .net }.map(\.1)
        if let minX = netPoints.map(\.x).min(), let maxX = netPoints.map(\.x).max(), let minY = netPoints.map(\.y).min(), let maxY = netPoints.map(\.y).max() {
            dx = min(max(dx, -minX), 1 - maxX)
            dy = min(max(dy, -minY), 1 - maxY)
        }
        for (handle, p) in placed { set(handle, x: p.x + dx, y: p.y + dy) }
    }

    // MARK: What a touch lands on

    /// The placed point of target nearest p, within radius.
    func handle(near p: CGPoint, in viewport: CalibrationViewport, target: CalibrationTarget, radius: CGFloat) -> CalibrationHandle? {
        Self.handles(of: target)
            .compactMap { h -> (CalibrationHandle, CGFloat)? in
                guard let n = position(h) else { return nil }
                let q = viewport.point(x: n.x, y: n.y)
                return (h, hypot(q.x - p.x, q.y - p.y))
            }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    /// The boundary line of target nearest p, within tolerance of it.
    func edge(near p: CGPoint, in viewport: CalibrationViewport, target: CalibrationTarget, tolerance: CGFloat) -> (CalibrationHandle, CalibrationHandle)? {
        Self.edges(of: target)
            .compactMap { edge -> ((CalibrationHandle, CalibrationHandle), CGFloat)? in
                guard let a = position(edge.0), let b = position(edge.1) else { return nil }
                return (edge, Self.distance(from: p, toSegment: viewport.point(x: a.x, y: a.y), viewport.point(x: b.x, y: b.y)))
            }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let (vx, vy) = (b.x - a.x, b.y - a.y)
        let length2 = vx * vx + vy * vy
        let t = length2 > 0 ? min(1, max(0, ((p.x - a.x) * vx + (p.y - a.y) * vy) / length2)) : 0
        return hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy))
    }

    /// What a drag starting at p does: a point under the finger moves; with wholeShape on, anything else moves the
    /// shape; otherwise a line under the finger moves, and anywhere else pans the picture.
    func dragAction(at p: CGPoint, in viewport: CalibrationViewport, target: CalibrationTarget, wholeShape: Bool,
                    handleRadius: CGFloat, edgeTolerance: CGFloat) -> CalibrationDragAction {
        if let h = handle(near: p, in: viewport, target: target, radius: handleRadius) { return .handle(h) }
        if wholeShape { return (target == .court ? hasCourtPoints : hasNetCorners) ? .shape : .pan }
        if let e = edge(near: p, in: viewport, target: target, tolerance: edgeTolerance) { return .edge(e.0, e.1) }
        return .pan
    }

    /// The points a drag action moves.
    static func handles(moved action: CalibrationDragAction, target: CalibrationTarget) -> [CalibrationHandle] {
        switch action {
        case .handle(let h): return [h]
        case .edge(let a, let b): return [a, b]
        case .shape: return handles(of: target)
        case .pan: return []
        }
    }
}
