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
