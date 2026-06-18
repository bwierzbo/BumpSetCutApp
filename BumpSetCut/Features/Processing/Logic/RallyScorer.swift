//
//  RallyScorer.swift
//  BumpSetCut
//
//  Shared serve-signature + weighted rally-score computation used by BOTH the
//  production pipeline and the RallyLab eval harness, so they produce
//  byte-identical numbers. Operates on captured VideoProcessor.FrameEvidence.
//

import CoreGraphics
import Foundation

/// Serve-signature readout for one rally's opening window. A serve travels down
/// the court (camera behind the baseline), so the ball's apparent size should
/// change consistently; a carried/held ball stays roughly flat. `normalizedSlope`
/// is the per-second fractional size change (signed: + = approaching/growing,
/// − = receding); `monotonicity` is the fraction of steps moving in the dominant
/// direction (~0.5 = noise, 1.0 = perfectly consistent).
struct ServeSignature {
    let normalizedSlope: Double
    let monotonicity: Double
    let sampleCount: Int
}

/// Weighted rally-likelihood breakdown. Each feature is 0…1, higher = more
/// rally-like; `total` is their weighted average (serve dropped when the opening
/// window is a skyball top-exit, since its size trend is unreliable).
struct RallyScore {
    let serve: Double         // depth/size trend over the opening window
    let travel: Double        // how much court the ball covered (spatial extent)
    let continuity: Double    // fraction of segment frames with a ball
    let sizeDynamics: Double  // size variability — a held ball barely changes
    let skyball: Bool         // opening window reached the top of frame
    let total: Double
}

/// Computes the serve signature and weighted rally score from captured frame
/// evidence. Value type — configure the tunables, then call. Production
/// (VideoProcessor) and RallyLab both build one of these so their numbers match.
struct RallyScorer {
    /// Opening window (seconds from a rally's start) the serve signature spans.
    var serveWindowSec: Double = 0.6
    /// Feature weights (sum need not be 1; the score normalizes by total weight).
    var serveWeight: Double = 0.40
    var travelWeight: Double = 0.25
    var continuityWeight: Double = 0.20
    var sizeWeight: Double = 0.15
    /// Normalized height (Vision coords, 1.0 = top) above which the opening window
    /// counts as a skyball top-exit, which bypasses the (unreliable) serve term.
    var skyBallTopThreshold: Double = 0.85
    /// Normalization references: the feature value at which each score saturates to 1.
    var serveSlopeRef: Double = 0.5    // |fractional size change / s|
    var travelRef: Double = 0.35       // normalized track spatial extent
    var sizeCVRef: Double = 0.25       // size coefficient of variation

    /// Size trend over the opening window [start, start+serveWindowSec], computed
    /// from frame evidence. Size source per frame: the raw detection nearest the
    /// selected track (truest trend), falling back to the selected candidate's
    /// smoothed mean size, then the largest detection. Side length (√area) is used
    /// so it scales linearly with apparent size. nil if too few samples.
    func serveSignature(start: Double, in evidence: [VideoProcessor.FrameEvidence]) -> ServeSignature? {
        guard !evidence.isEmpty else { return nil }
        let windowEnd = start + serveWindowSec
        var pts: [(t: Double, size: Double)] = []
        for f in evidence where f.time >= start && f.time <= windowEnd {
            let size: Double?
            if let sel = f.candidates.first(where: { $0.isSelected }) {
                if let near = f.detections.min(by: {
                    hypot($0.bbox.midX - sel.point.x, $0.bbox.midY - sel.point.y)
                        < hypot($1.bbox.midX - sel.point.x, $1.bbox.midY - sel.point.y)
                }) {
                    size = sqrt(Double(near.bbox.width * near.bbox.height))
                } else if sel.ballSize > 0 {
                    size = Double(sel.ballSize)
                } else { size = nil }
            } else if let maxDet = f.detections.map({ sqrt(Double($0.bbox.width * $0.bbox.height)) }).max(),
                      maxDet > 0 {
                size = maxDet
            } else { size = nil }
            if let s = size, s > 0 { pts.append((t: f.time - start, size: s)) }
        }
        guard pts.count >= 3 else { return nil }
        let n = Double(pts.count)
        let sumX = pts.reduce(0.0) { $0 + $1.t }
        let sumY = pts.reduce(0.0) { $0 + $1.size }
        let sumXY = pts.reduce(0.0) { $0 + $1.t * $1.size }
        let sumX2 = pts.reduce(0.0) { $0 + $1.t * $1.t }
        let denom = n * sumX2 - sumX * sumX
        guard abs(denom) > 1e-12 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom
        let mean = sumY / n
        guard mean > 1e-9 else { return nil }
        // Monotonicity: fraction of consecutive steps moving in the slope's direction.
        var agree = 0, total = 0
        for i in 1..<pts.count {
            let d = pts[i].size - pts[i - 1].size
            if d == 0 { continue }
            total += 1
            if (d > 0) == (slope > 0) { agree += 1 }
        }
        let mono = total > 0 ? Double(agree) / Double(total) : 0
        return ServeSignature(normalizedSlope: slope / mean, monotonicity: mono, sampleCount: pts.count)
    }

    /// Weighted rally-likelihood score over [start, end] from frame evidence.
    func rallyScore(start: Double, end: Double, in evidence: [VideoProcessor.FrameEvidence]) -> RallyScore? {
        guard !evidence.isEmpty else { return nil }
        let frames = evidence.filter { $0.time >= start && $0.time <= end }
        guard !frames.isEmpty else { return nil }

        // Continuity: fraction of segment frames that actually saw a ball.
        let continuity = Double(frames.filter { $0.hasBall }.count) / Double(frames.count)

        // Selected-track points + raw sizes over the segment.
        var pts: [CGPoint] = []
        var sizes: [Double] = []
        for f in frames {
            guard let sel = f.candidates.first(where: { $0.isSelected }) else { continue }
            pts.append(sel.point)
            if let near = f.detections.min(by: {
                hypot($0.bbox.midX - sel.point.x, $0.bbox.midY - sel.point.y)
                    < hypot($1.bbox.midX - sel.point.x, $1.bbox.midY - sel.point.y)
            }) {
                sizes.append(sqrt(Double(near.bbox.width * near.bbox.height)))
            } else if sel.ballSize > 0 {
                sizes.append(Double(sel.ballSize))
            }
        }

        // Travel: spatial extent the ball covered (both axes — depth shows as
        // vertical motion for a baseline camera, so we don't restrict to horizontal).
        let travel: Double = {
            guard pts.count >= 2 else { return 0 }
            let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
            let dx = (xs.max() ?? 0) - (xs.min() ?? 0)
            let dy = (ys.max() ?? 0) - (ys.min() ?? 0)
            return min(1, hypot(dx, dy) / travelRef)
        }()

        // Size dynamics: coefficient of variation. A flying ball changes apparent
        // size; a carried/held ball barely does.
        let sizeDynamics: Double = {
            guard sizes.count >= 3 else { return 0 }
            let mean = sizes.reduce(0, +) / Double(sizes.count)
            guard mean > 1e-9 else { return 0 }
            let varc = sizes.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(sizes.count)
            return min(1, (sqrt(varc) / mean) / sizeCVRef)
        }()

        // Serve: graded opening-window depth trend (magnitude × consistency).
        let serve: Double = {
            guard let s = serveSignature(start: start, in: evidence) else { return 0 }
            return min(1, abs(s.normalizedSlope) / serveSlopeRef) * s.monotonicity
        }()

        // Skyball: the ball reached the top of frame within the opening window —
        // its size trend is unreliable, so drop serve from the average (bypass).
        let windowEnd = start + serveWindowSec
        let skyball = frames.contains {
            $0.time <= windowEnd && Double($0.trackPoint?.y ?? 0) >= skyBallTopThreshold
        }

        var feats: [(v: Double, w: Double)] = [
            (travel, travelWeight),
            (continuity, continuityWeight),
            (sizeDynamics, sizeWeight),
        ]
        if !skyball { feats.append((serve, serveWeight)) }
        let wsum = feats.reduce(0) { $0 + $1.w }
        let total = wsum > 1e-9 ? feats.reduce(0) { $0 + $1.v * $1.w } / wsum : 0

        return RallyScore(serve: serve, travel: travel, continuity: continuity,
                          sizeDynamics: sizeDynamics, skyball: skyball, total: total)
    }

    /// Per-feature weighted contributions for a score, normalized so they sum to
    /// `total` — drives RallyLab's stacked contribution bar. Serve weight is zeroed
    /// on a skyball (its term is bypassed), matching `rallyScore`.
    func contributions(_ s: RallyScore) -> [(name: String, value: Double)] {
        let raw: [(String, Double, Double)] = [
            ("serve", s.serve, s.skyball ? 0 : serveWeight),
            ("travel", s.travel, travelWeight),
            ("continuity", s.continuity, continuityWeight),
            ("sizeDyn", s.sizeDynamics, sizeWeight),
        ]
        let wsum = raw.reduce(0) { $0 + $1.2 }
        guard wsum > 1e-9 else { return raw.map { ($0.0, 0) } }
        return raw.map { ($0.0, $0.1 * $0.2 / wsum) }
    }
}
