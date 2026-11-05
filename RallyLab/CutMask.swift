//
//  CutMask.swift
//  RallyLab
//
//  Scoring and tuning see a recording less its cut ranges (D-030): a truth
//  rally or a predicted clip keeps only its pieces outside the cuts, and
//  one with nothing left outside is gone — the scoring contract's rule for
//  excluded time. Applied after a pass is replayed from its evidence, never
//  to the evidence, so the pass cache is untouched by a cut.
//
//  The excluded spans (a missed serve, a "not a rally" mark; RallyTruth)
//  mask differently from a cut (the contract §2): a clip keeps its pieces
//  outside them as ONE prediction — matched on the pieces, its boundaries
//  read at the scorable span's ends — and a clip with nothing outside is
//  unscored, neither a hit nor a false clip. A cut splits a clip into
//  predictions of its own; an excluded span never does.
//

import Foundation

extension Array where Element == Interval {
    /// Slivers shorter than this that a cut leaves behind are dropped.
    static var cutSliver: Double { 0.1 }

    /// The intervals' pieces outside `cuts`, in order.
    func outside(_ cuts: [CutRange]) -> [Interval] {
        guard !cuts.isEmpty else { return self }
        return flatMap { iv in
            cuts.outside(iv.start, iv.end)
                .filter { $0.end - $0.start >= Self.cutSliver }
                .map { Interval(start: $0.start, end: $0.end) }
        }
    }
}

/// A delivered clip or raw prediction read against the excluded spans: its scorable pieces, as one prediction.
struct ScorableClip: Equatable {
    /// As delivered (after the cuts split it).
    let clip: Interval
    /// Its pieces outside the excluded spans, in order; never empty.
    let pieces: [Interval]

    /// First to last scorable tick: where its boundaries are read.
    var span: Interval { Interval(start: pieces[0].start, end: pieces[pieces.count - 1].end) }
    var seconds: Double { pieces.reduce(0) { $0 + $1.duration } }
    func overlap(_ t: Interval) -> Double { pieces.reduce(0) { $0 + RallyCutScore.overlap($1, t) } }
    func iou(_ t: Interval) -> Double {
        let inter = overlap(t), union = seconds + t.duration - inter
        return union > 0 ? inter / union : 0
    }
}

extension Array where Element == Interval {
    /// Each clip on its pieces outside the excluded spans, and how many had nothing left outside (unscored).
    func scorable(excluding excluded: [Interval]) -> (scored: [ScorableClip], unscored: Int) {
        let mask = excluded.map { CutRange(start: $0.start, end: $0.end) }
        var scored: [ScorableClip] = [], unscored = 0
        for clip in self {
            let pieces = mask.isEmpty ? [clip] : [clip].outside(mask)
            if pieces.isEmpty { unscored += 1 } else { scored.append(ScorableClip(clip: clip, pieces: pieces)) }
        }
        return (scored, unscored)
    }
}

/// The contract's raw scorer over masked clips: greedy one-to-one matching by descending IoU on the pieces
/// (ties: the earlier truth, then the earlier clip); boundary errors at the scorable span's ends.
struct MaskedMatch {
    let matches: [(clip: ScorableClip, truth: Interval, iou: Double)]
    let unmatchedClips: [ScorableClip]
    let unmatchedTruth: [Interval]

    init(_ clips: [ScorableClip], truth: [Interval], iou threshold: Double) {
        var pairs: [(ci: Int, ti: Int, iou: Double)] = []
        for (ci, c) in clips.enumerated() {
            for (ti, t) in truth.enumerated() {
                let v = c.iou(t)
                if v >= threshold { pairs.append((ci, ti, v)) }
            }
        }
        pairs.sort { a, b in
            if a.iou != b.iou { return a.iou > b.iou }
            if truth[a.ti].start != truth[b.ti].start { return truth[a.ti].start < truth[b.ti].start }
            return clips[a.ci].span.start < clips[b.ci].span.start
        }
        var usedClip = Set<Int>(), usedTruth = Set<Int>()
        var matches: [(clip: ScorableClip, truth: Interval, iou: Double)] = []
        for pair in pairs where !usedClip.contains(pair.ci) && !usedTruth.contains(pair.ti) {
            usedClip.insert(pair.ci); usedTruth.insert(pair.ti)
            matches.append((clips[pair.ci], truth[pair.ti], pair.iou))
        }
        self.matches = matches
        unmatchedClips = clips.enumerated().filter { !usedClip.contains($0.offset) }.map(\.element)
        unmatchedTruth = truth.enumerated().filter { !usedTruth.contains($0.offset) }.map(\.element)
    }

    /// As the pipeline's scorer reports it (the matched clip given by its scorable span).
    func result(tolerance: Double = 1.0) -> ScoringResult {
        let startErrs = matches.map { abs($0.clip.span.start - $0.truth.start) }
        let endErrs = matches.map { abs($0.clip.span.end - $0.truth.end) }
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        func within(_ v: [Double]) -> Double { v.isEmpty ? 0 : Double(v.filter { $0 <= tolerance }.count) / Double(v.count) }
        return ScoringResult(truePositives: matches.count, falsePositives: unmatchedClips.count, falseNegatives: unmatchedTruth.count,
                             startMAE: mean(startErrs), endMAE: mean(endErrs),
                             startWithinTolerance: within(startErrs), endWithinTolerance: within(endErrs),
                             matches: matches.map { ($0.clip.span, $0.truth, $0.iou) },
                             unmatchedPredictions: unmatchedClips.map(\.span), unmatchedGroundTruth: unmatchedTruth)
    }
}
