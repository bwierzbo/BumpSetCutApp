//
//  EvidenceReplayer.swift
//  RallyLab
//
//  Replays per-frame evidence captured by VideoProcessor through the REAL
//  RallyDecider + SegmentBuilder. Detection/tracking/physics run once (in
//  VideoProcessor); every decider/segment-level config change is then a cheap
//  deterministic replay instead of a full re-process.
//

import CoreMedia
import Foundation

enum EvidenceReplayer {

    /// Runs the production decider + segment builder over recorded evidence.
    ///
    /// - Parameter padded: when false, preroll/postroll are zeroed so the
    ///   returned intervals are the RAW decided rally boundaries — what the
    ///   scorer must compare against hand-marked labels. Merging and
    ///   min-length filtering still run, exactly as `SegmentBuilder.finalize`
    ///   does in production.
    static func decidedRanges(
        evidence: [VideoProcessor.FrameEvidence],
        duration: Double,
        config: ProcessorConfig,
        minRallySec: Double,
        padded: Bool
    ) -> [Interval] {
        var cfg = config
        if !padded {
            cfg.preroll = 0
            cfg.postroll = 0
        }
        let decider = RallyDecider(config: cfg, minRallySec: minRallySec)
        let builder = SegmentBuilder(config: cfg)

        for frame in evidence {
            let t = CMTimeMakeWithSeconds(frame.time, preferredTimescale: 600)
            // trackPoint is the ball's position (Vision y, 1.0 = top); drives sky-ball grace.
            let isActive = decider.update(hasBall: frame.hasBall, isProjectile: frame.isProjectile,
                                          timestamp: t, ballY: frame.trackPoint?.y)
            builder.observe(isActive: isActive, at: t)
        }

        let ranges = builder.finalize(until: CMTimeMakeWithSeconds(duration, preferredTimescale: 600))
        var intervals = ranges.map {
            Interval(start: CMTimeGetSeconds($0.start), end: CMTimeGetSeconds(CMTimeRangeGetEnd($0)))
        }

        // Per-segment rally-score verdict: drop rallies whose confidence is below
        // the threshold. Re-scorable here with no re-detection. Uses the shared
        // RallyScorer over the captured evidence so it matches the inspector's numbers.
        if cfg.enableRallyScoreGate {
            let scorer = RallyScorer(
                serveWeight: cfg.rallyScoreServeWeight,
                travelWeight: cfg.rallyScoreTravelWeight,
                continuityWeight: cfg.rallyScoreContinuityWeight,
                sizeWeight: cfg.rallyScoreSizeWeight,
                skyBallTopThreshold: Double(cfg.skyBallTopThreshold))
            intervals = intervals.filter { iv in
                let total = scorer.rallyScore(start: iv.start, end: iv.end, in: evidence)?.total
                // Keep rallies the scorer can't evaluate (too few samples) — the gate
                // only drops rallies it can confidently score below the threshold.
                return (total ?? 1.0) >= cfg.rallyScoreMinConfidence
            }
        }

        // Above-net rule: a multi-contact rally must clear the net top once; single
        // arcs (e.g. a missed far-side serve) are exempt. Uses the net captured in
        // the evidence (the Net-tab box when injected) so it matches the overlay.
        if cfg.enableAboveNetRequirement,
           let net = evidence.lazy.compactMap({ $0.detectedNet }).first {
            let netTopY = net.box.maxY - cfg.aboveNetMarginY
            intervals = intervals.filter { iv in
                let inRange = evidence.filter { $0.time >= iv.start && $0.time <= iv.end }
                let ys: [CGFloat] = inRange.compactMap { (f) -> CGFloat? in
                    if let y = f.trackPoint?.y { return y }
                    return f.detections.filter { !$0.isOffCourt }.map { $0.bbox.midY }.max()
                }
                return VideoProcessor.rallyClearsNetTop(ySamples: ys, netTopY: netTopY,
                                                        arcProminence: cfg.aboveNetArcProminence)
            }
        }
        return intervals
    }
}
