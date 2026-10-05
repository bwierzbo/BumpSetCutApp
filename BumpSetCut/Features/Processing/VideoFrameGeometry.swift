//
//  VideoFrameGeometry.swift
//  BumpSetCut
//
//  Stored-frame ↔ upright-frame geometry for rotated (phone) video.
//  Compiled into RallyLab too (membershipExceptions).
//

import CoreGraphics
import ImageIO

enum VideoFrameGeometry {
    /// The orientation that turns a track's stored frames upright, from its
    /// preferredTransform (the rotation flag phones write for portrait video).
    static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    /// A Vision-normalised (bottom-left origin) box in the stored frame, in
    /// the upright frame `orientation` turns it into — the space Vision
    /// reports YOLO's boxes in when given that orientation.
    static func upright(_ rect: CGRect, from orientation: CGImagePropertyOrientation) -> CGRect {
        let (x, y) = (rect.midX, rect.midY)
        let center: CGPoint, size: CGSize
        switch orientation {
        case .right: (center, size) = (CGPoint(x: y, y: 1 - x), CGSize(width: rect.height, height: rect.width))
        case .left: (center, size) = (CGPoint(x: 1 - y, y: x), CGSize(width: rect.height, height: rect.width))
        case .down: (center, size) = (CGPoint(x: 1 - x, y: 1 - y), rect.size)
        default: return rect
        }
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}
