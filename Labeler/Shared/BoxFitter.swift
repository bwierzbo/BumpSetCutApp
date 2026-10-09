//
//  BoxFitter.swift
//  RallyLab (macOS and iPhone)
//
//  Tightens a ball's box to the ball before annotation review. The court
//  without the ball is the per-pixel median of frames a few steps either
//  side (the ball has moved on; the court hasn't); what differs from it
//  around the box is the ball. The blob nearest the box gives the centre
//  (its middle — for a blurred ball, the middle of the streak) and the size
//  (its width across: a streak's length is blur, not ball). A box is only
//  changed when the blob is believable: about a ball's size and near where
//  it was, round enough (a net tape or an arm is long and thin), and the
//  picture as a whole steady (a moving camera makes everything differ). A
//  ball that barely moves (at the top of its arc) is left as it was.
//

import CoreGraphics
import Foundation

enum BoxFitter {

    /// A frame in grey, top-down rows.
    struct Gray: Sendable {
        let width: Int, height: Int
        let pixels: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            var px = [UInt8](repeating: 0, count: width * height)
            let ok = px.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard ok else { return nil }
            pixels = px
        }

        subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
    }

    /// The neighbouring frames (by offset) whose median is the court.
    static let backgroundOffsets = [-6, -5, -4, -3, 3, 4, 5, 6]
    /// The search reaches this many box widths from the box's centre.
    static let reach = 3.0

    /// The box (Vision-normalised) fitted to the ball in `frame`, or nil when
    /// no believable blob is there. `court` are the neighbouring frames.
    static func fit(_ box: CGRect, frame: Gray, court: [Gray]) -> CGRect? {
        guard court.count >= 4 else { return nil }
        let W = Double(frame.width), H = Double(frame.height)
        let side = max(box.width * W, box.height * H)
        let cx = box.midX * W, cy = (1 - box.midY) * H
        let half = Int(max(reach * side, 24))
        let x0 = max(0, Int(cx) - half), x1 = min(frame.width - 1, Int(cx) + half)
        let y0 = max(0, Int(cy) - half), y1 = min(frame.height - 1, Int(cy) + half)
        let rw = x1 - x0 + 1, rh = y1 - y0 + 1
        guard rw > 8, rh > 8 else { return nil }

        // How far each pixel is from the court (the median of the others).
        var diff = [Int16](repeating: 0, count: rw * rh)
        var values = [UInt8](repeating: 0, count: court.count)
        for y in 0..<rh {
            for x in 0..<rw {
                for k in court.indices { values[k] = court[k][x0 + x, y0 + y] }
                values.sort()
                let median = (Int16(values[values.count / 2 - 1]) + Int16(values[values.count / 2])) / 2
                diff[y * rw + x] = abs(Int16(frame[x0 + x, y0 + y]) - median)
            }
        }
        // Different enough: well above how much the court itself flickers.
        let sorted = diff.sorted()
        let typical = sorted[sorted.count / 2]
        let spread = max(Int16(2), sorted[sorted.count * 3 / 4] - typical)
        let threshold = max(18, typical + 5 * spread)
        // The camera moved: too much differs to tell the ball from the rest.
        guard diff.filter({ $0 >= threshold }).count < rw * rh / 6 else { return nil }

        // Blobs of changed pixels; the believable one nearest the box wins.
        var label = [Int32](repeating: 0, count: rw * rh)
        var best: (score: Double, x: Double, y: Double, size: Double)?
        var next: Int32 = 0
        let ballArea = Double.pi * side * side / 4
        for start in 0..<(rw * rh) where diff[start] >= threshold && label[start] == 0 {
            next += 1
            label[start] = next
            var stack = [start]
            var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            while let i = stack.popLast() {
                let x = Double(i % rw), y = Double(i / rw)
                n += 1; sx += x; sy += y; sxx += x * x; syy += y * y; sxy += x * y
                for j in [i - 1, i + 1, i - rw, i + rw] where j >= 0 && j < rw * rh {
                    if abs(j % rw - i % rw) > 1 { continue }   // no wrapping across rows
                    if diff[j] >= threshold && label[j] == 0 { label[j] = next; stack.append(j) }
                }
            }
            guard n >= 6, n > 0.15 * ballArea, n < 6 * ballArea else { continue }
            let mx = sx / n, my = sy / n
            // The blob's narrower width: 4·√(smaller variance) for a filled disc.
            let vxx = sxx / n - mx * mx, vyy = syy / n - my * my, vxy = sxy / n - mx * my
            let root = (((vxx - vyy) / 2) * ((vxx - vyy) / 2) + vxy * vxy).squareRoot()
            let minor = max((vxx + vyy) / 2 - root, 0), major = (vxx + vyy) / 2 + root
            let width = 4 * minor.squareRoot()
            let gx = Double(x0) + mx + 0.5, gy = Double(y0) + my + 0.5
            let dist = hypot(gx - cx, gy - cy)
            // Near where it was, about its size, and round — or a short streak.
            guard dist < side, width > 0.6 * side, width < 1.6 * side,
                  major <= 9 * max(minor, 0.25) else { continue }
            let score = n / (1 + dist / side)
            if score > (best?.score ?? 0) { best = (score, gx, gy, width) }
        }
        guard let best else { return nil }
        let w = best.size / W, h = best.size / H
        return CGRect(x: best.x / W - w / 2, y: 1 - best.y / H - h / 2, width: w, height: h)
    }
}
