//
//  TrackFinder.swift
//  RallyLab (macOS and iPhone)
//
//  The ball's candidates on each frame of a rally, as the Track tab and the
//  iPhone's tracking both find them: YOLO's boxes, plus the multi-frame
//  model's peaks merged in. TrackSolver then picks the path through them.
//  After you fix a frame, it looks again near your fix (lookAgain) for the
//  ball the first pass missed on the frames either side.
//

import CoreGraphics
import Foundation

enum TrackFinder {

    /// The multi-frame model's peaks on every frame — run on overlapping
    /// windows of the frames in order (HeatmapWindows, as the pipeline runs
    /// it), each frame answered from a window with frames both sides —
    /// merged with YOLO's candidates: one at the same spot raises that
    /// candidate's confidence; one YOLO didn't have is added. It sees motion,
    /// so it adds blurred and far balls and skips still ones. A frame that
    /// couldn't be read stands in with the one before it.
    /// A multi-frame peak with no YOLO candidate at the spot counts this much.
    static let heatAloneWeight = 0.6

    static func addHeatmapCandidates(_ heat: HeatmapBallDetector, grays: [HeatmapBallDetector.Frame?],
                                     to found: inout [[TrackCandidate]]) {
        for (i, peaks) in heatPeaks(heat, grays: grays).enumerated() where found.indices.contains(i) {
            for peak in peaks {
                let c = CGPoint(x: peak.rect.midX, y: peak.rect.midY)
                let near = found[i].indices.first { k in
                    let r = found[i][k].rect
                    return hypot(r.midX - c.x, (r.midY - c.y) * 9 / 16) < max(r.width, 0.012)
                }
                if let k = near {
                    found[i][k].confidence = 1 - (1 - found[i][k].confidence) * (1 - Double(peak.confidence))
                } else {
                    // On its own it's less sure: picked when it fits the path, not
                    // over "hidden" (it can carry a ball on through an occlusion).
                    found[i].append(TrackCandidate(rect: peak.rect, confidence: Double(peak.confidence) * heatAloneWeight))
                }
            }
        }
    }

    /// The multi-frame model's peaks on each of `grays`, from overlapping
    /// windows in order; a frame that couldn't be read stands in with the
    /// one before it.
    private static func heatPeaks(_ heat: HeatmapBallDetector, grays: [HeatmapBallDetector.Frame?]) -> [[HeatmapBallDetector.Peak]] {
        var windows = HeatmapWindows(detector: heat)
        var answers: [[HeatmapBallDetector.Peak]] = []
        var last: HeatmapBallDetector.Frame?
        for gray in grays {
            guard let frame = gray ?? last ?? grays.lazy.compactMap({ $0 }).first else { answers.append([]); continue }
            last = frame
            answers += windows.push(frame)
        }
        return answers + windows.finish()
    }

    // MARK: - Looking again near a fix

    /// Frames looked at each way from a fix.
    static let lookAgainSteps = 15
    /// A ball found where the path says it should be is likely the ball, if
    /// faint: it counts this sure at least — enough for the path to take it,
    /// still under "sure", so it's shown for you to check.
    static let lookAgainConfidence = 0.45

    /// The multi-frame model's peaks this faint count when looking again —
    /// far under its own threshold, but only a peak on the ball's path is
    /// taken.
    static let lookAgainHeatThreshold: Float = 0.1

    /// The ball the first pass missed near your fix on frame `fix`, walking
    /// out each way from it. On each frame, where the ball should be (from
    /// its last two positions) is checked in turn against:
    ///  1. the candidates the first pass already has, and the multi-frame
    ///     model's peaks at a much lower threshold — it sees a blurred ball
    ///     the detector can't at any threshold;
    ///  2. the detector on zoomed crops around the spot at a low threshold.
    /// It stops at your other points, after two frames in a row without the
    /// ball, or when the "ball" stops moving (a head or a pole, not a ball in
    /// play). Returns the new candidates by frame, to add before re-solving.
    /// `heat` should have its threshold at `lookAgainHeatThreshold`.
    static func lookAgain(from fix: Int, in rally: TrackedRally, detector: YOLODetector, heat: HeatmapBallDetector?,
                          image: (Int) -> CGImage?) -> [Int: [TrackCandidate]] {
        func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, (a.y - b.y) * 9 / 16) }
        let points = rally.points
        guard points.indices.contains(fix), rally.candidates.count == points.count,
              let fixBox = points[fix].box, points[fix].state == .visible else { return [:] }
        // The multi-frame model over the frames either side (and the few its
        // windows need past them).
        let span = max(0, fix - lookAgainSteps - 4)..<min(points.count, fix + lookAgainSteps + 5)
        var faint: [Int: [TrackCandidate]] = [:]
        if let heat {
            let grays = span.map { k in image(k).flatMap { heat.grayscale($0) } }
            for (n, peaks) in heatPeaks(heat, grays: grays).enumerated() {
                faint[span.lowerBound + n] = peaks.map { TrackCandidate(rect: $0.rect, confidence: Double($0.confidence)) }
            }
        }
        var added: [Int: [TrackCandidate]] = [:]
        for step in [-1, 1] {
            // The ball's positions this way, newest last (the frame behind the
            // fix gives the speed, when it's known).
            var seen = [centre(fixBox.rect)]
            if let behind = points[safe: fix - step], behind.state == .visible, let b = behind.box { seen.insert(centre(b.rect), at: 0) }
            var misses = 0
            var k = fix + step
            while points.indices.contains(k), abs(k - fix) <= lookAgainSteps, points[k].origin != .user, misses < 2,
                  !isStill(seen) {
                defer { k += step }
                let last = seen[seen.count - 1]
                let velocity = seen.count > 1 ? CGPoint(x: last.x - seen[seen.count - 2].x, y: last.y - seen[seen.count - 2].y) : .zero
                let gap = CGFloat(misses + 1)
                let predicted = CGPoint(x: last.x + velocity.x * gap, y: last.y + velocity.y * gap)
                let reach = 0.03 + 0.5 * distance(.zero, velocity) * Double(gap)
                func nearest(_ list: [TrackCandidate]) -> TrackCandidate? {
                    list.filter { distance(centre($0.rect), predicted) < reach }
                        .min { distance(centre($0.rect), predicted) < distance(centre($1.rect), predicted) }
                }
                if let have = nearest(rally.candidates[k]) {
                    // Already there; too faint for the path to take it over
                    // "no ball", it's raised (a copy, the original kept).
                    if have.confidence < lookAgainConfidence {
                        added[k, default: []].append(TrackCandidate(rect: have.rect, confidence: lookAgainConfidence))
                    }
                    seen.append(centre(have.rect))
                    misses = 0
                    continue
                }
                if let peak = nearest(faint[k] ?? []) {
                    added[k, default: []].append(TrackCandidate(rect: peak.rect, confidence: max(peak.confidence, lookAgainConfidence)))
                    seen.append(centre(peak.rect))
                    misses = 0
                    continue
                }
                guard let frame = image(k) else { misses += 1; continue }
                let size = CGSize(width: frame.width, height: frame.height)
                // Vision (bottom-up) ↔ top-left pixels.
                let spot = CGPoint(x: predicted.x * size.width, y: (1 - predicted.y) * size.height)
                let found = nearest(detections(around: spot, in: frame, detector: detector, sides: [480, 960]).map { d in
                    TrackCandidate(rect: CGRect(x: d.rect.minX / size.width, y: 1 - d.rect.maxY / size.height,
                                                width: d.rect.width / size.width, height: d.rect.height / size.height),
                                   confidence: Double(d.confidence))
                })
                guard let found else { misses += 1; continue }
                added[k, default: []].append(TrackCandidate(rect: found.rect, confidence: max(found.confidence, lookAgainConfidence)))
                seen.append(centre(found.rect))
                misses = 0
            }
        }
        return added
    }

    /// The last few positions barely move: not a ball in play.
    private static func isStill(_ seen: [CGPoint]) -> Bool {
        guard seen.count >= 6 else { return false }
        let last = seen.suffix(6)
        let xs = last.map(\.x), ys = last.map(\.y)
        return xs.max()! - xs.min()! < 0.003 && ys.max()! - ys.min()! < 0.005
    }

    /// The detector on square crops of `image` around `spot` (top-left
    /// pixels), each side in turn: a 480 crop at its 960 input is a 2× zoom,
    /// so a small or blurred ball the whole frame hid shows up. Boxes in
    /// top-left pixels of the whole image; crop-sized boxes (something
    /// bigger than the crop) are dropped.
    static func detections(around spot: CGPoint, in image: CGImage, detector: YOLODetector,
                           sides: [CGFloat]) -> [(rect: CGRect, confidence: Float)] {
        var out: [(rect: CGRect, confidence: Float)] = []
        for side in sides {
            let s = min(side, CGFloat(min(image.width, image.height)))
            let crop = CGRect(x: min(max(spot.x - s / 2, 0), CGFloat(image.width) - s),
                              y: min(max(spot.y - s / 2, 0), CGFloat(image.height) - s),
                              width: s, height: s).integral
            guard let patch = image.cropping(to: crop) else { continue }
            for det in detector.detect(in: patch, at: .zero) {
                // Vision (bottom-left) in the crop → top-left pixels in the image.
                let box = CGRect(x: crop.minX + det.bbox.minX * crop.width,
                                 y: crop.minY + (1 - det.bbox.maxY) * crop.height,
                                 width: det.bbox.width * crop.width, height: det.bbox.height * crop.height)
                guard box.width < crop.width * 0.8, box.height < crop.height * 0.8 else { continue }
                out.append((box, det.confidence))
            }
        }
        return out
    }
}

/// The multi-frame model for looking again, loaded once per model file
/// with its threshold at `TrackFinder.lookAgainHeatThreshold`.
final class LookAgainHeat: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: (url: URL, heat: HeatmapBallDetector)?

    func detector(for url: URL?) -> HeatmapBallDetector? {
        guard let url else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let loaded, loaded.url == url { return loaded.heat }
        guard let heat = HeatmapBallDetector(modelURL: url) else { return nil }
        heat.threshold = TrackFinder.lookAgainHeatThreshold
        loaded = (url, heat)
        return heat
    }
}

extension Array {
    /// The element at `i`, if there is one.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
