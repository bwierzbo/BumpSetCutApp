//
//  NetQuad.swift
//  BumpSetCut
//
//  The physical net as a person marks it: four corners, each placed on its own. The one
//  shape for the net in RallyLab's net labels and in a recording's court and net
//  calibration. Compiled into RallyLab too (membershipExceptions).
//

import CoreGraphics
import Foundation

/// The net's four corners in the upright frame, Vision-normalised (bottom-up),
/// named as the net is seen: the top two on the tape, the bottom two where the
/// mesh meets the posts. The names are roles a person assigns by dragging, not
/// a sort; `bounds` is the box a consumer reads.
struct NetQuad: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        init(x: Double, y: Double) { self.x = x; self.y = y }
        init(_ p: CGPoint) { x = Double(p.x); y = Double(p.y) }
        var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    }

    var topLeft: Point
    var topRight: Point
    var bottomRight: Point
    var bottomLeft: Point

    init(topLeft: Point, topRight: Point, bottomRight: Point, bottomLeft: Point) {
        self.topLeft = topLeft; self.topRight = topRight; self.bottomRight = bottomRight; self.bottomLeft = bottomLeft
    }

    /// A rectangle's corners (Vision: the top is maxY).
    init(rect: CGRect) {
        let r = rect.standardized
        topLeft = Point(x: r.minX, y: r.maxY); topRight = Point(x: r.maxX, y: r.maxY)
        bottomRight = Point(x: r.maxX, y: r.minY); bottomLeft = Point(x: r.minX, y: r.minY)
    }

    /// In the order top-left, top-right, bottom-right, bottom-left.
    var points: [CGPoint] { [topLeft.cgPoint, topRight.cgPoint, bottomRight.cgPoint, bottomLeft.cgPoint] }

    /// The rectangle that just contains the four corners.
    var bounds: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// The quadrilateral's area (shoelace, frame fractions squared), whatever its winding.
    var area: Double {
        let p = points
        var twice = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            twice += Double(a.x * b.y - b.x * a.y)
        }
        return abs(twice) / 2
    }

    /// Big enough to be a net and not collapsed onto a line — including a diagonal, whose
    /// bounding box has width and height but whose area is nothing.
    var isUsable: Bool { bounds.width > 0.005 && bounds.height > 0.005 && area > 0.0005 }

    /// Corner `i` (in `points` order) moved to `p`, kept inside the frame.
    func moving(corner i: Int, to p: CGPoint) -> NetQuad {
        var q = self
        let c = Point(x: min(1, max(0, Double(p.x))), y: min(1, max(0, Double(p.y))))
        switch i {
        case 0: q.topLeft = c
        case 1: q.topRight = c
        case 2: q.bottomRight = c
        default: q.bottomLeft = c
        }
        return q
    }

    /// Every corner shifted by the same amount, the shift limited so none leaves the frame.
    func offset(dx: CGFloat, dy: CGFloat) -> NetQuad {
        let b = bounds
        let x = min(max(dx, -b.minX), 1 - b.maxX), y = min(max(dy, -b.minY), 1 - b.maxY)
        func moved(_ p: Point) -> Point { Point(x: p.x + Double(x), y: p.y + Double(y)) }
        return NetQuad(topLeft: moved(topLeft), topRight: moved(topRight), bottomRight: moved(bottomRight), bottomLeft: moved(bottomLeft))
    }
}
