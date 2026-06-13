//
//  RallySegmentationScorer.swift
//  BumpSetCut
//
//  Evaluates predicted rally segments against hand-labeled ground truth.
//  Pure value types in Double seconds (no CoreMedia) so it is trivially
//  unit-testable and usable as the ParameterOptimizer.evaluationFunction.
//

import Foundation

// MARK: - Inputs

/// A hand-labeled rally boundary. Mirror your labeling convention here
/// (e.g. start = serve contact, end = ball dead). Keep it CONSISTENT with
/// what RallyDecider is trying to predict, and score against RAW decided
/// boundaries (pre preroll/postroll) — not the padded export ranges — or
/// you will measure SegmentBuilder.preroll as if it were model error.
struct LabeledRally: Codable, Equatable {
    let startTime: Double   // seconds
    let endTime: Double     // seconds
    var duration: Double { max(0, endTime - startTime) }
}

/// Minimal interval the scorer works on. Build these from either
/// [RallySegment] (predicted) or [LabeledRally] (ground truth).
struct Interval: Equatable {
    let start: Double
    let end: Double
    var duration: Double { max(0, end - start) }

    /// Temporal Intersection-over-Union with another interval.
    func iou(_ other: Interval) -> Double {
        let interStart = Swift.max(start, other.start)
        let interEnd = Swift.min(end, other.end)
        let inter = Swift.max(0, interEnd - interStart)
        let union = duration + other.duration - inter
        return union > 0 ? inter / union : 0
    }
}

// MARK: - Config

struct ScoringConfig {
    /// Min temporal IoU for a predicted segment to count as matching a
    /// ground-truth rally. 0.5 is a sensible default; raise it if you care
    /// about tight boundaries, lower it if you only care about "found it".
    var iouMatchThreshold: Double = 0.5
    /// A boundary (start or end) counts as "on time" if within this many
    /// seconds of the labeled boundary. Tune to what's actually usable.
    var boundaryToleranceSec: Double = 1.0
}

// MARK: - Result

struct ScoringResult {
    // Detection-level (did we find the right rallies?)
    let truePositives: Int
    let falsePositives: Int      // predicted, matched nothing -> hallucinated rally
    let falseNegatives: Int      // labeled, matched nothing  -> missed rally
    var precision: Double { let d = truePositives + falsePositives; return d > 0 ? Double(truePositives) / Double(d) : 0 }
    var recall: Double { let d = truePositives + falseNegatives; return d > 0 ? Double(truePositives) / Double(d) : 0 }
    var f1: Double { let d = precision + recall; return d > 0 ? 2 * precision * recall / d : 0 }

    // Boundary-level (computed only over matched pairs)
    let startMAE: Double         // mean |predStart - trueStart|, seconds
    let endMAE: Double           // mean |predEnd - trueEnd|, seconds
    let startWithinTolerance: Double  // fraction of matched starts within tolerance
    let endWithinTolerance: Double    // fraction of matched ends within tolerance

    // Diagnostics for manual review of the actual failures.
    let matches: [(pred: Interval, truth: Interval, iou: Double)]
    let unmatchedPredictions: [Interval]   // inspect these for false starts
    let unmatchedGroundTruth: [Interval]   // inspect these for missed rallies

    /// One number for ParameterOptimizer. F1 alone ignores sloppy boundaries,
    /// so blend in a boundary term. Weight to taste.
    func optimizerScore(boundaryWeight: Double = 0.25) -> Double {
        let avgWithin = (startWithinTolerance + endWithinTolerance) / 2
        return (1 - boundaryWeight) * f1 + boundaryWeight * avgWithin
    }
}

// MARK: - Scorer

enum RallySegmentationScorer {

    /// Convenience overload taking your domain types directly.
    /// Pass `paddingToSubtract` = (preroll, postroll) if you can only get
    /// padded RallySegments out; better to feed raw decided boundaries.
    static func score(
        predicted: [RallySegment],
        groundTruth: [LabeledRally],
        config: ScoringConfig = ScoringConfig(),
        paddingToSubtract: (preroll: Double, postroll: Double)? = nil
    ) -> ScoringResult {
        let pred = predicted.map { seg -> Interval in
            if let p = paddingToSubtract {
                return Interval(start: seg.startTime + p.preroll, end: seg.endTime - p.postroll)
            }
            return Interval(start: seg.startTime, end: seg.endTime)
        }
        let truth = groundTruth.map { Interval(start: $0.startTime, end: $0.endTime) }
        return score(predicted: pred, groundTruth: truth, config: config)
    }

    /// Core scorer on plain intervals.
    static func score(
        predicted: [Interval],
        groundTruth: [Interval],
        config: ScoringConfig = ScoringConfig()
    ) -> ScoringResult {

        // Greedy IoU matching: take the highest-IoU pair above threshold,
        // remove both, repeat. Good enough for the typical handful of
        // rallies per clip; swap for Hungarian if you ever need optimal.
        var candidatePairs: [(pi: Int, ti: Int, iou: Double)] = []
        for (pi, p) in predicted.enumerated() {
            for (ti, t) in groundTruth.enumerated() {
                let v = p.iou(t)
                if v >= config.iouMatchThreshold { candidatePairs.append((pi, ti, v)) }
            }
        }
        candidatePairs.sort { $0.iou > $1.iou }

        var usedPred = Set<Int>()
        var usedTruth = Set<Int>()
        var matches: [(pred: Interval, truth: Interval, iou: Double)] = []
        for pair in candidatePairs {
            if usedPred.contains(pair.pi) || usedTruth.contains(pair.ti) { continue }
            usedPred.insert(pair.pi)
            usedTruth.insert(pair.ti)
            matches.append((predicted[pair.pi], groundTruth[pair.ti], pair.iou))
        }

        let unmatchedPredictions = predicted.enumerated()
            .filter { !usedPred.contains($0.offset) }.map { $0.element }
        let unmatchedGroundTruth = groundTruth.enumerated()
            .filter { !usedTruth.contains($0.offset) }.map { $0.element }

        // Boundary error over matched pairs only.
        var startErrs: [Double] = []
        var endErrs: [Double] = []
        for m in matches {
            startErrs.append(abs(m.pred.start - m.truth.start))
            endErrs.append(abs(m.pred.end - m.truth.end))
        }
        let startMAE = startErrs.isEmpty ? 0 : startErrs.reduce(0, +) / Double(startErrs.count)
        let endMAE = endErrs.isEmpty ? 0 : endErrs.reduce(0, +) / Double(endErrs.count)
        let startWithin = startErrs.isEmpty ? 0 :
            Double(startErrs.filter { $0 <= config.boundaryToleranceSec }.count) / Double(startErrs.count)
        let endWithin = endErrs.isEmpty ? 0 :
            Double(endErrs.filter { $0 <= config.boundaryToleranceSec }.count) / Double(endErrs.count)

        return ScoringResult(
            truePositives: matches.count,
            falsePositives: unmatchedPredictions.count,
            falseNegatives: unmatchedGroundTruth.count,
            startMAE: startMAE,
            endMAE: endMAE,
            startWithinTolerance: startWithin,
            endWithinTolerance: endWithin,
            matches: matches,
            unmatchedPredictions: unmatchedPredictions,
            unmatchedGroundTruth: unmatchedGroundTruth
        )
    }

    /// Aggregate across a whole test set of videos by pooling counts and
    /// errors (so a 9-rally video weighs more than a 2-rally one).
    static func scoreCorpus(
        _ perVideo: [(predicted: [Interval], groundTruth: [Interval])],
        config: ScoringConfig = ScoringConfig()
    ) -> ScoringResult {
        let results = perVideo.map { score(predicted: $0.predicted, groundTruth: $0.groundTruth, config: config) }
        let tp = results.reduce(0) { $0 + $1.truePositives }
        let fp = results.reduce(0) { $0 + $1.falsePositives }
        let fn = results.reduce(0) { $0 + $1.falseNegatives }
        let allMatches = results.flatMap { $0.matches }
        let startErrs = allMatches.map { abs($0.pred.start - $0.truth.start) }
        let endErrs = allMatches.map { abs($0.pred.end - $0.truth.end) }
        let mae: ([Double]) -> Double = { $0.isEmpty ? 0 : $0.reduce(0, +) / Double($0.count) }
        let within: ([Double]) -> Double = { errs in
            errs.isEmpty ? 0 : Double(errs.filter { $0 <= config.boundaryToleranceSec }.count) / Double(errs.count)
        }
        return ScoringResult(
            truePositives: tp, falsePositives: fp, falseNegatives: fn,
            startMAE: mae(startErrs), endMAE: mae(endErrs),
            startWithinTolerance: within(startErrs), endWithinTolerance: within(endErrs),
            matches: allMatches,
            unmatchedPredictions: results.flatMap { $0.unmatchedPredictions },
            unmatchedGroundTruth: results.flatMap { $0.unmatchedGroundTruth }
        )
    }
}
