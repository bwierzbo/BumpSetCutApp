//
//  HeldBalls.swift
//  RallyLab
//
//  Balls that stay put — on the sideline, under the net post, in a bag —
//  are in frame after frame. Once one has been boxed in about the same
//  place on the two reviewed frames just before this one, it's carried
//  onto this frame, but only if it's really still there: the patch around
//  its last box is looked for near the same spot here (normalised cross-
//  correlation, so light changes don't matter; searching a little around
//  it, so a handheld camera's drift doesn't either). Found → a "held" box
//  where it matched best. Moved, picked up or covered → nothing.
//

import CoreGraphics
import Foundation

enum HeldBalls {

    struct Candidate {
        /// Vision-normalised, in the frame it was last seen on.
        let rect: CGRect
        let from: FrameSample
    }

    /// Frames further apart than this aren't taken as showing the same scene.
    static let maxGap: Double = 20

    /// Balls boxed in about the same place on each of the two reviewed,
    /// kept frames just before `current`.
    static func candidates(for current: FrameSample, in samples: [FrameSample]) -> [Candidate] {
        let earlier = samples
            .filter { $0.reviewed && $0.keep && $0.time < current.time && current.time - $0.time <= maxGap }
            .sorted { $0.time > $1.time }
        guard earlier.count >= 2, earlier[0].time - earlier[1].time <= maxGap else { return [] }
        let (last, before) = (earlier[0], earlier[1])
        return last.boxes.compactMap { box in
            before.boxes.contains { sameSpot($0.rect, box.rect) } ? Candidate(rect: box.rect, from: last) : nil
        }
    }

    /// Centres within most of a ball's width, sizes within 2× of each other.
    static func sameSpot(_ a: CGRect, _ b: CGRect) -> Bool {
        let size = max(a.width, a.height, b.width, b.height)
        let ratio = max(a.width, b.width) / max(min(a.width, b.width), 0.0001)
        return hypot(a.midX - b.midX, a.midY - b.midY) < max(size * 0.75, 0.004) && ratio < 2
    }

    // MARK: - Finding it again

    /// Match score (−1…1) a found patch needs.
    static let minScore: Float = 0.7

    /// Where the candidate's ball is in `image`, or nil if it isn't there.
    /// `fromImage` is the frame it was last boxed on, `seconds` before this
    /// one; both are the same video, so the same size. The longer the gap,
    /// the further a handheld camera has drifted, so the wider the search.
    static func locate(_ candidate: Candidate, fromImage: CGImage, in image: CGImage, seconds: Double) -> CGRect? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard fromImage.width == image.width, fromImage.height == image.height else { return nil }
        // Top-left pixels.
        let box = CGRect(x: candidate.rect.minX * w, y: (1 - candidate.rect.maxY) * h,
                         width: candidate.rect.width * w, height: candidate.rect.height * h)
        // The ball with a ring of what's around it, which is what makes the match specific.
        let side = Int(min(max(max(box.width, box.height) * 1.6, 16), 48))
        let radius = Int(min(max(max(box.width, box.height) * 0.8, 6) + 6 * CGFloat(seconds), 40))
        let templateOrigin = CGPoint(x: (box.midX - CGFloat(side) / 2).rounded(), y: (box.midY - CGFloat(side) / 2).rounded())
        let regionSide = side + 2 * radius
        let regionOrigin = CGPoint(x: templateOrigin.x - CGFloat(radius), y: templateOrigin.y - CGFloat(radius))
        guard let template = BallSnapper.grayscale(fromImage, from: templateOrigin, side: side),
              let region = BallSnapper.grayscale(image, from: regionOrigin, side: regionSide) else { return nil }

        // A flat patch (sky, a wall) matches anywhere: don't trust it.
        let t = template.map(Float.init)
        let n = Float(t.count)
        let tMean = t.reduce(0, +) / n
        let tDev = t.map { $0 - tMean }
        let tNorm = tDev.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard tNorm / n.squareRoot() > 8 else { return nil }

        let r = region.map(Float.init)
        func score(_ ox: Int, _ oy: Int) -> Float {
            var sum: Float = 0
            for y in 0..<side {
                let row = (oy + y) * regionSide + ox
                for x in 0..<side { sum += r[row + x] }
            }
            let mean = sum / n
            var dot: Float = 0, norm: Float = 0
            for y in 0..<side {
                let row = (oy + y) * regionSide + ox
                for x in 0..<side {
                    let v = r[row + x] - mean
                    dot += v * tDev[y * side + x]
                    norm += v * v
                }
            }
            return norm > 0 ? dot / (norm.squareRoot() * tNorm) : -1
        }
        // Balls sit in groups and look alike: of equally good matches the one
        // that moved least is the same ball, so distance costs a little.
        func ranked(_ ox: Int, _ oy: Int) -> (raw: Float, adjusted: Float) {
            let raw = score(ox, oy)
            let moved = Float(hypot(Double(ox - radius), Double(oy - radius)) / Double(max(radius, 1)))
            return (raw, raw - 0.12 * moved)
        }
        // Every other pixel first, then the pixels around the best of those.
        var best: (raw: Float, adjusted: Float, ox: Int, oy: Int) = (-1, -2, radius, radius)
        for oy in stride(from: 0, through: 2 * radius, by: 2) {
            for ox in stride(from: 0, through: 2 * radius, by: 2) {
                let s = ranked(ox, oy)
                if s.adjusted > best.adjusted { best = (s.raw, s.adjusted, ox, oy) }
            }
        }
        let coarse = best
        for oy in max(0, coarse.oy - 1)...min(2 * radius, coarse.oy + 1) {
            for ox in max(0, coarse.ox - 1)...min(2 * radius, coarse.ox + 1) where (ox, oy) != (coarse.ox, coarse.oy) {
                let s = ranked(ox, oy)
                if s.adjusted > best.adjusted { best = (s.raw, s.adjusted, ox, oy) }
            }
        }
        best = (best.raw, best.adjusted, best.ox - radius, best.oy - radius)
        guard best.raw >= minScore else { return nil }
        let moved = box.offsetBy(dx: CGFloat(best.ox), dy: CGFloat(best.oy))
        return CGRect(x: moved.minX / w, y: 1 - moved.maxY / h, width: moved.width / w, height: moved.height / h)
    }
}
