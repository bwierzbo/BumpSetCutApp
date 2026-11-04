//
//  CutRanges.swift
//  RallyLab (macOS and iPhone)
//
//  A cut range is a stretch of a recording that is not footage: the clip
//  started in the middle of a rally, or an editor put an instant replay
//  in. Marked in the live pass (X: cut from here … to here; ⇧X: the clip
//  starts mid-rally, the next serve ends the cut), kept raw as marked on
//  the video session and in label_rally_times.cuts, and read normalised
//  by everything that consumes a recording's time: no training window is
//  built inside one, truth rallies and predicted clips are masked to the
//  outside (the scoring contract's rule for excluded time), it is neither
//  rally nor dead time, pre-tracking never tracks in it, sampled frames
//  inside it leave training and evaluation, marking progress subtracts its
//  seconds (D-030).
//

import Foundation

/// Seconds `start ..< end` of a recording that are not footage.
struct CutRange: Codable, Hashable {
    var start: Double
    var end: Double

    var seconds: Double { max(0, end - start) }
}

extension Array where Element == CutRange {
    /// The ranges as consumers read them: empty and negative ones dropped,
    /// sorted, overlapping or touching ones merged.
    func normalised() -> [CutRange] {
        let valid = filter { $0.end > $0.start && $0.start >= 0 }.sorted { $0.start < $1.start }
        var out: [CutRange] = []
        for r in valid {
            if let last = out.last, r.start <= last.end {
                out[out.count - 1].end = Swift.max(last.end, r.end)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Whether `t` lies in a cut (`start <= t < end`).
    func contains(_ t: Double) -> Bool {
        contains { $0.start <= t && t < $0.end }
    }

    /// Whether any cut overlaps `a ..< b` by more than a point.
    func overlaps(_ a: Double, _ b: Double) -> Bool {
        contains { Swift.min($0.end, b) - Swift.max($0.start, a) > 0 }
    }

    /// The pieces of `a ..< b` outside every cut, in order; empty when the
    /// stretch is cut whole.
    func outside(_ a: Double, _ b: Double) -> [(start: Double, end: Double)] {
        guard b > a else { return [] }
        var pieces: [(start: Double, end: Double)] = []
        var from = a
        for c in normalised() where c.end > a && c.start < b {
            if c.start > from { pieces.append((from, c.start)) }
            from = Swift.max(from, c.end)
        }
        if from < b { pieces.append((from, b)) }
        return pieces
    }

    /// The seconds cut from a recording `duration` long.
    func seconds(within duration: Double) -> Double {
        normalised().reduce(0) { $0 + Swift.max(0, Swift.min($1.end, duration) - Swift.min($1.start, duration)) }
    }
}
