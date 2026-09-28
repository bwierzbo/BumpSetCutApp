//
//  BallSnapper.swift
//  RallyLab
//
//  Click-to-box: given a click on a ball, find the ball's box.
//
//  1. The ball detector on square crops around the click, at about the
//     scale it was trained at and a little closer (it's run at 960, so a
//     480 crop is a 2× zoom). Zooming further takes a ball out of the size
//     range the model knows and it stops seeing it. The most confident
//     detection over the click wins.
//  2. If the detector sees nothing there, the ball is segmented: the patch
//     around the click is split light/dark (Otsu), the panel seams are
//     closed, the region under the click is grown out, and if it's round
//     its bounds are the box. Growing outwards on the panel colour copes with
//     textured balls in a way that edge-hunting from the click doesn't.
//  3. If neither finds a round blob, a box of the video's usual ball size,
//     centred on the click, to adjust by hand.
//

import CoreGraphics
import CoreMedia
import Foundation

enum BallSnapper {

    enum Method: Equatable {
        case detector(Float)
        /// Segmented from its surroundings.
        case outline
        case guess
    }

    struct Result {
        /// Vision-normalised (origin bottom-left) in the whole image.
        let rect: CGRect
        let method: Method
    }

    /// `point` is top-left normalised in `image`. `usualSize` is a typical
    /// box width as a fraction of the image width, for the last resort.
    static func snap(at point: CGPoint, in image: CGImage, detector: YOLODetector?, usualSize: CGFloat?) -> Result {
        let size = CGSize(width: image.width, height: image.height)
        let click = CGPoint(x: point.x * size.width, y: point.y * size.height)

        if let detector, let found = detect(at: click, in: image, detector: detector) {
            return Result(rect: visionRect(found.rect, in: size), method: .detector(found.confidence))
        }
        if let blob = segment(at: click, in: image) {
            return Result(rect: visionRect(blob, in: size), method: .outline)
        }
        let side = (usualSize ?? 0.015) * size.width
        return Result(rect: visionRect(CGRect(x: click.x - side / 2, y: click.y - side / 2, width: side, height: side), in: size),
                      method: .guess)
    }

    // MARK: - Detector on zoomed crops

    private static let cropSides: [CGFloat] = [960, 640, 480]

    private static func detect(at click: CGPoint, in image: CGImage, detector: YOLODetector) -> (rect: CGRect, confidence: Float)? {
        var best: (rect: CGRect, confidence: Float)?
        for side in cropSides {
            let s = min(side, CGFloat(min(image.width, image.height)))
            let crop = CGRect(x: min(max(click.x - s / 2, 0), CGFloat(image.width) - s),
                              y: min(max(click.y - s / 2, 0), CGFloat(image.height) - s),
                              width: s, height: s).integral
            guard let patch = image.cropping(to: crop) else { continue }
            for det in detector.detect(in: patch, at: .zero) {
                // Vision (bottom-left) in the crop → top-left pixels in the image.
                let box = CGRect(x: crop.minX + det.bbox.minX * crop.width,
                                 y: crop.minY + (1 - det.bbox.maxY) * crop.height,
                                 width: det.bbox.width * crop.width, height: det.bbox.height * crop.height)
                // It has to be the thing clicked, and not a crop-sized box
                // (the ball is bigger than this crop — a larger one gets it).
                guard box.insetBy(dx: -box.width * 0.5, dy: -box.height * 0.5).contains(click),
                      box.width < crop.width * 0.8, box.height < crop.height * 0.8 else { continue }
                if det.confidence > (best?.confidence ?? 0) { best = (box, det.confidence) }
            }
        }
        return best
    }

    // MARK: - Segmentation

    /// Patch half-sizes tried in turn, in image pixels: a blob touching the
    /// patch edge is either bigger than it or has leaked into background.
    private static let patchRadii = [24, 40, 64]

    private static func segment(at click: CGPoint, in image: CGImage) -> CGRect? {
        for radius in patchRadii {
            let side = 2 * radius + 1
            let origin = CGPoint(x: click.x.rounded() - CGFloat(radius), y: click.y.rounded() - CGFloat(radius))
            guard let gray = grayscale(image, from: origin, side: side),
                  let blob = blob(in: gray, side: side, seed: radius) else { continue }
            if blob.minX > 0, blob.minY > 0, blob.maxX < side - 1, blob.maxY < side - 1 {
                return CGRect(x: origin.x + CGFloat(blob.minX), y: origin.y + CGFloat(blob.minY),
                              width: CGFloat(blob.maxX - blob.minX + 1), height: CGFloat(blob.maxY - blob.minY + 1))
            }
        }
        return nil
    }

    private struct Blob { var minX: Int, minY: Int, maxX: Int, maxY: Int }

    /// The round region around `seed` (the patch centre), or nil.
    private static func blob(in gray: [UInt8], side: Int, seed: Int) -> Blob? {
        let threshold = otsu(gray)
        var mask = gray.map { $0 > threshold }
        // The click can land on a seam: go with what most of the pixels
        // around it are.
        var bright = 0, total = 0
        for dy in -2...2 { for dx in -2...2 { total += 1; if mask[(seed + dy) * side + seed + dx] { bright += 1 } } }
        let wantBright = bright * 2 > total
        if !wantBright { mask = mask.map { !$0 } }
        // Close the seams between panels (dilate, then erode).
        mask = erode(dilate(mask, side: side), side: side)
        guard mask[seed * side + seed] else { return nil }

        // Grow from the click.
        var seen = [Bool](repeating: false, count: side * side)
        var stack = [seed * side + seed]
        seen[seed * side + seed] = true
        var box = Blob(minX: seed, minY: seed, maxX: seed, maxY: seed)
        var area = 0
        while let i = stack.popLast() {
            area += 1
            let x = i % side, y = i / side
            box.minX = min(box.minX, x); box.maxX = max(box.maxX, x)
            box.minY = min(box.minY, y); box.maxY = max(box.maxY, y)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < side && ny < side && !seen[ny * side + nx] && mask[ny * side + nx] {
                seen[ny * side + nx] = true
                stack.append(ny * side + nx)
            }
        }
        // Round-ish and mostly filled: a ball, not a strip of sky or a limb.
        let w = Double(box.maxX - box.minX + 1), h = Double(box.maxY - box.minY + 1)
        guard w >= 3, h >= 3, w / h > 0.55, w / h < 1.8,
              Double(area) / (Double.pi / 4 * w * h) > 0.6 else { return nil }
        return box
    }

    private static func otsu(_ gray: [UInt8]) -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        for v in gray { histogram[Int(v)] += 1 }
        let total = Double(gray.count)
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var sumBelow = 0.0, countBelow = 0.0, best = 0.0, threshold = 0
        for t in 0..<256 {
            countBelow += Double(histogram[t])
            guard countBelow > 0, countBelow < total else { continue }
            sumBelow += Double(t * histogram[t])
            let meanBelow = sumBelow / countBelow, meanAbove = (sum - sumBelow) / (total - countBelow)
            let between = countBelow * (total - countBelow) * (meanBelow - meanAbove) * (meanBelow - meanAbove)
            if between > best { best = between; threshold = t }
        }
        return UInt8(threshold)
    }

    private static func dilate(_ mask: [Bool], side: Int) -> [Bool] {
        morph(mask, side: side) { $0 || $1 }
    }

    private static func erode(_ mask: [Bool], side: Int) -> [Bool] {
        morph(mask, side: side) { $0 && $1 }
    }

    /// 3×3 neighbourhood combine; edges read their own value.
    private static func morph(_ mask: [Bool], side: Int, _ combine: (Bool, Bool) -> Bool) -> [Bool] {
        var out = mask
        for y in 0..<side {
            for x in 0..<side {
                var v = mask[y * side + x]
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                        v = combine(v, mask[ny * side + nx])
                    }
                }
                out[y * side + x] = v
            }
        }
        return out
    }

    /// An 8-bit grey square of `side` pixels whose top-left is `origin` in
    /// the image (outside the image reads as black).
    private static func grayscale(_ image: CGImage, from origin: CGPoint, side: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // CG is bottom-up: place the image so `origin` (top-left) lands at row 0.
            ctx.draw(image, in: CGRect(x: -origin.x, y: origin.y + CGFloat(side) - CGFloat(image.height),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Top-left pixel rect → Vision-normalised, clamped to the image.
    private static func visionRect(_ r: CGRect, in size: CGSize) -> CGRect {
        let clipped = r.intersection(CGRect(origin: .zero, size: size))
        return CGRect(x: clipped.minX / size.width, y: 1 - clipped.maxY / size.height,
                      width: clipped.width / size.width, height: clipped.height / size.height)
    }
}
