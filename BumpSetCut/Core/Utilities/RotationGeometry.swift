//
//  RotationGeometry.swift
//  BumpSetCut
//
//  Shared geometry helper for rotating video frames without exposing
//  triangular black corners. Used by PreTrimService (bake) and the
//  rally viewer (.scaleEffect at playback).
//

import CoreGraphics
import Foundation

enum RotationGeometry {
    /// Smallest scale factor that lets a rectangle of `size` rotated by
    /// `angleDegrees` (about its center) still cover the original
    /// axis-aligned bounds. Returns 1.0 for a zero-size input or zero angle.
    static func coverScale(angleDegrees: Double, size: CGSize) -> CGFloat {
        let theta = abs(angleDegrees) * .pi / 180.0
        let w = abs(size.width)
        let h = abs(size.height)
        guard w > 0, h > 0, theta > 0 else { return 1.0 }
        let c = cos(theta)
        let s = sin(theta)
        let aspectMax = max(h / w, w / h)
        return CGFloat(c + aspectMax * s)
    }

    /// Display size after the source `preferredTransform` is applied (translation
    /// stripped — only the linear part affects dimensions). Always returns
    /// positive values so it's safe to use as a frame size or for aspect ratios.
    static func uprightSize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        var linear = preferredTransform
        linear.tx = 0
        linear.ty = 0
        let r = naturalSize.applying(linear)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// Largest rect with `content`'s aspect ratio that fits inside `bounds`
    /// (aspect-fit). Falls back to `bounds` if either dimension is non-positive.
    static func aspectFitSize(content: CGSize, in bounds: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let contentAspect = content.width / content.height
        let boundsAspect = bounds.width / bounds.height
        if contentAspect > boundsAspect {
            return CGSize(width: bounds.width, height: bounds.width / contentAspect)
        } else {
            return CGSize(width: bounds.height * contentAspect, height: bounds.height)
        }
    }
}
