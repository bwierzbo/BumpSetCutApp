//
//  ReviewCanvas.swift
//  RallyLab (macOS and iPhone)
//
//  The pictures annotation review draws, the same on both: the crop around
//  a box (the box fixed in the middle, the picture moved under it), and
//  the whole frame zoomed and panned with a placed box. Gestures and keys
//  are each app's own.
//

import SwiftUI

/// The part of a frame around a box that review can show while you drag,
/// cut out and decoded once when the frame loads: dragging then only slides
/// this picture, which the GPU does smoothly, instead of redrawing.
struct CropPatch {
    let image: CGImage
    /// Where it sits in the frame, image pixels (top-down).
    let origin: CGPoint
    let frameSize: CGSize

    /// Reaches this many crop widths from the box: as far as a drag goes.
    static let reach: CGFloat = 1.5

    init?(frame: CGImage, box: CGRect) {
        let size = CGSize(width: frame.width, height: frame.height)
        let side = AnnotationReview.cropSide(for: box, in: size) * Self.reach * 2
        let rect = CGRect(x: box.midX * size.width - side / 2, y: (1 - box.midY) * size.height - side / 2, width: side, height: side)
            .integral.intersection(CGRect(origin: .zero, size: size))
        guard !rect.isEmpty, let part = frame.cropping(to: rect),
              let ctx = CGContext(data: nil, width: part.width, height: part.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        guard let decoded = ctx.makeImage() else { return nil }
        image = decoded
        origin = rect.origin
        frameSize = size
    }
}

/// A square crop around `box` — `AnnotationReview.cropSide` across — with
/// the ball's centre `offset` image pixels from the box's, and the square the
/// box will be saved as (`scale` times the ball's width) fixed in the middle.
struct CropCanvas: View {
    let patch: CropPatch
    /// Vision-normalised.
    let box: CGRect
    let offset: CGSize
    let scale: CGFloat
    /// Off for a frame without a ball (only the centre cross shows).
    var showsBox = true
    /// Closer than the crop's usual view (the Mac's pinch), 1 = as usual.
    var zoom: CGFloat = 1
    var tint: Color = .green

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.geometry(frameSize: patch.frameSize, box: box, view: geo.size)
            let g = (k: fitted.k * zoom, centre: fitted.centre)
            let c = CGPoint(x: g.centre.x + offset.width, y: g.centre.y + offset.height)
            let w = CGFloat(patch.image.width) * g.k, h = CGFloat(patch.image.height) * g.k
            // The view's own size; the picture (bigger, so a drag has room) and
            // the box are laid over it rather than sizing it.
            Color.black
                .overlay(alignment: .topLeading) {
                    Image(decorative: patch.image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: w, height: h)
                        .offset(x: geo.size.width / 2 + (patch.origin.x - c.x) * g.k, y: geo.size.height / 2 + (patch.origin.y - c.y) * g.k)
                }
                .overlay {
                    Canvas { ctx, size in
                        let side = AnnotationReview.ballSide(of: box, in: patch.frameSize) * scale * g.k
                        let r = CGRect(x: size.width / 2 - side / 2, y: size.height / 2 - side / 2, width: side, height: side)
                        if showsBox { ctx.stroke(Path(r.insetBy(dx: -1, dy: -1)), with: .color(tint), lineWidth: 2) }
                        // A small cross at the centre, for centring precisely.
                        var cross = Path()
                        cross.move(to: CGPoint(x: size.width / 2 - 5, y: size.height / 2)); cross.addLine(to: CGPoint(x: size.width / 2 + 5, y: size.height / 2))
                        cross.move(to: CGPoint(x: size.width / 2, y: size.height / 2 - 5)); cross.addLine(to: CGPoint(x: size.width / 2, y: size.height / 2 + 5))
                        ctx.stroke(cross, with: .color(tint.opacity(0.8)), lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                }
        }
        .clipped()
    }

    /// Screen points per image pixel for this crop in a view of `view`
    /// points, and the box's centre in image pixels (top-down).
    static func geometry(frameSize size: CGSize, box: CGRect, view: CGSize) -> (k: CGFloat, centre: CGPoint) {
        let side = AnnotationReview.cropSide(for: box, in: size)
        return (min(view.width, view.height) / side, CGPoint(x: box.midX * size.width, y: (1 - box.midY) * size.height))
    }
}

/// The whole frame, `zoom` times fitted, centred on `centre` (top-down
/// fraction), with `box` (Vision-normalised) if there is one.
struct FrameCanvas: View {
    let image: CGImage
    let zoom: CGFloat
    let centre: CGPoint
    let box: CGRect?

    var body: some View {
        GeometryReader { geo in
            let shown = Self.shown(image: image, zoom: zoom, view: geo.size)
            let origin = Self.origin(shown: shown, centre: centre, view: geo.size)
            Canvas { ctx, _ in
                ctx.draw(Image(decorative: image, scale: 1), in: CGRect(origin: origin, size: shown))
                if let box {
                    let r = CGRect(x: origin.x + box.minX * shown.width, y: origin.y + (1 - box.maxY) * shown.height,
                                   width: box.width * shown.width, height: box.height * shown.height)
                    ctx.stroke(Path(r.insetBy(dx: -1.5, dy: -1.5)), with: .color(.blue), lineWidth: 2)
                }
            }
            .background(Color.black)
        }
        .clipped()
    }

    static func shown(image: CGImage, zoom: CGFloat, view: CGSize) -> CGSize {
        let fit = min(view.width / CGFloat(image.width), view.height / CGFloat(image.height)) * zoom
        return CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
    }

    /// Where the picture's top-left goes: `centre` in the middle, the
    /// picture kept covering the view (centred when smaller).
    static func origin(shown: CGSize, centre: CGPoint, view: CGSize) -> CGPoint {
        func clamp(_ v: CGFloat, _ view: CGFloat, _ content: CGFloat) -> CGFloat {
            content <= view ? (view - content) / 2 : min(0, max(view - content, v))
        }
        return CGPoint(x: clamp(view.width / 2 - centre.x * shown.width, view.width, shown.width),
                       y: clamp(view.height / 2 - centre.y * shown.height, view.height, shown.height))
    }

    /// A point in the view as a Vision-normalised point in the frame, if
    /// it's on the picture.
    static func framePoint(_ p: CGPoint, image: CGImage, zoom: CGFloat, centre: CGPoint, view: CGSize) -> CGPoint? {
        let shown = shown(image: image, zoom: zoom, view: view)
        let o = origin(shown: shown, centre: centre, view: view)
        let x = (p.x - o.x) / shown.width, y = (p.y - o.y) / shown.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: 1 - y)
    }

    /// Where to centre the frame for frame `i` of `rally`: the ball's last
    /// position nearby (top-down fraction), else the middle.
    static func focus(_ rally: TrackedRally, frame i: Int) -> CGPoint {
        for d in 0...30 {
            for k in [i - d, i + d] where rally.points.indices.contains(k) {
                if let b = rally.points[k].box, rally.points[k].state == .visible { return CGPoint(x: b.rect.midX, y: 1 - b.rect.midY) }
            }
        }
        return CGPoint(x: 0.5, y: 0.5)
    }
}
