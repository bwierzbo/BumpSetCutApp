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

/// A square crop of `image` around `box` — `AnnotationReview.cropSide`
/// across — with the ball's centre `offset` image pixels from the box's,
/// and the box `scale` times its size, fixed in the middle.
struct CropCanvas: View {
    let image: CGImage
    /// Vision-normalised.
    let box: CGRect
    let offset: CGSize
    let scale: CGFloat
    var tint: Color = .green

    var body: some View {
        GeometryReader { geo in
            let g = Self.geometry(image: image, box: box, view: geo.size)
            Canvas { ctx, size in
                let c = CGPoint(x: g.centre.x + offset.width, y: g.centre.y + offset.height)
                let origin = CGPoint(x: size.width / 2 - c.x * g.k, y: size.height / 2 - c.y * g.k)
                // Only the part on screen: the whole frame at this zoom is
                // tens of thousands of points across.
                let seen = CGRect(x: (0 - origin.x) / g.k, y: (0 - origin.y) / g.k, width: size.width / g.k, height: size.height / g.k)
                    .insetBy(dx: -2, dy: -2).integral
                    .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                if !seen.isEmpty, let part = image.cropping(to: seen) {
                    ctx.draw(Image(decorative: part, scale: 1),
                             in: CGRect(x: origin.x + seen.minX * g.k, y: origin.y + seen.minY * g.k,
                                        width: seen.width * g.k, height: seen.height * g.k))
                }
                let w = box.width * CGFloat(image.width) * scale * g.k, h = box.height * CGFloat(image.height) * scale * g.k
                let r = CGRect(x: size.width / 2 - w / 2, y: size.height / 2 - h / 2, width: w, height: h)
                ctx.stroke(Path(r.insetBy(dx: -1, dy: -1)), with: .color(tint), lineWidth: 2)
                // A small cross at the centre, for centring precisely.
                var cross = Path()
                cross.move(to: CGPoint(x: size.width / 2 - 5, y: size.height / 2)); cross.addLine(to: CGPoint(x: size.width / 2 + 5, y: size.height / 2))
                cross.move(to: CGPoint(x: size.width / 2, y: size.height / 2 - 5)); cross.addLine(to: CGPoint(x: size.width / 2, y: size.height / 2 + 5))
                ctx.stroke(cross, with: .color(tint.opacity(0.8)), lineWidth: 1)
            }
            .background(Color.black)
        }
        .clipped()
    }

    /// Screen points per image pixel for this crop in a view of `view`
    /// points, and the box's centre in image pixels (top-down).
    static func geometry(image: CGImage, box: CGRect, view: CGSize) -> (k: CGFloat, centre: CGPoint) {
        let size = CGSize(width: image.width, height: image.height)
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
