//
//  OverlayGeometry.swift
//  RallyLab
//
//  Shared coordinate mapping from Vision-normalized boxes/points (origin
//  bottom-left, [0,1]) into a fitted, orientation-corrected video rect. Used by
//  both the detection overlay (DetectionOverlayView) and the net tab (NetTabView).
//

import CoreGraphics

enum OverlayGeometry {

    /// Aspect-fit `content` inside `container`, centered (matches AVKit's default
    /// video gravity), returning the letterboxed content rect.
    static func fittedRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let w = content.width * scale
        let h = content.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// Raw normalized point (origin bottom-left) → oriented top-left normalized,
    /// applying the player's clockwise quarter-turns.
    static func orientNormalized(_ p: CGPoint, turns: Int) -> CGPoint {
        // Vision origin is bottom-left; flip Y to a top-left raw space first.
        let raw = CGPoint(x: p.x, y: 1 - p.y)
        switch ((turns % 4) + 4) % 4 {
        case 1: return CGPoint(x: 1 - raw.y, y: raw.x)
        case 2: return CGPoint(x: 1 - raw.x, y: 1 - raw.y)
        case 3: return CGPoint(x: raw.y, y: 1 - raw.x)
        default: return raw
        }
    }

    /// Vision-normalized point → screen pixels inside the fitted video rect.
    static func point(_ p: CGPoint, turns: Int, in fit: CGRect) -> CGPoint {
        let o = orientNormalized(p, turns: turns)
        return CGPoint(x: fit.minX + o.x * fit.width, y: fit.minY + o.y * fit.height)
    }

    /// Vision-normalized bbox → screen CGRect inside the fitted video rect.
    static func rect(_ bbox: CGRect, turns: Int, in fit: CGRect) -> CGRect {
        // Transform both corners and take the bounding box, since rotation
        // swaps which corner is top-left.
        let a = point(CGPoint(x: bbox.minX, y: bbox.minY), turns: turns, in: fit)
        let b = point(CGPoint(x: bbox.maxX, y: bbox.maxY), turns: turns, in: fit)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
