//
//  RallyTruth.swift
//  RallyLab (macOS and iPhone)
//
//  One reading of a recording's marks and cut ranges, for the marking pass
//  and for everything that trains, scores or tunes on it (owner, 2026-11-04,
//  the amendment to D-028; the semantics are the approved scoring contract's
//  and classifier dataset contract's, D-021):
//   - a mark is a rally only when its kind is `rally`, or absent — a mark
//     from before live tagging is a rally (D-028 §3);
//   - a missed serve or a "not a rally" mark is an excluded span: no rally
//     is there, and its time is neither rally nor not-rally — masked, so a
//     clip inside it is neither a hit nor a false clip and no frame of it
//     trains (the contract's X, with the cut ranges);
//   - a cut range is excluded too, and is not footage (D-030);
//   - the time outside the rallies, the excluded spans and the cuts is
//     not-rally time only once the pass over the recording is complete;
//     before that it is unknown, and nothing may count it as dead time or
//     a false clip.
//

import Foundation

struct RallyTruth: Equatable {
    /// Seconds `start ..< end` of the recording.
    struct Span: Equatable {
        var start: Double
        var end: Double
        var seconds: Double { max(0, end - start) }
    }

    /// A mark as the pass keeps it, wherever it lives (the Mac's sidecar, the phone's rally times, the server).
    struct Mark: Equatable {
        var start: Double
        var end: Double
        var kind: RallyKind?
    }

    /// The rallies, outside the cuts.
    let positives: [Span]
    /// The missed serves and "not a rally" marks, outside the cuts: excluded spans.
    let excluded: [Span]
    /// Every mark outside the cuts with its kind, in time order: `positives` and `excluded` are its two halves
    /// (for a consumer that must keep a kind — the classifier dataset's excluded spans, a legacy mark's provenance).
    let pieces: [Mark]
    /// The cut ranges, normalised: excluded.
    let cuts: [CutRange]
    /// Every rally in the recording is marked: the time outside the rallies and the cuts is not-rally time.
    let complete: Bool

    /// A piece a cut leaves shorter than this is dropped (the scoring mask's rule).
    static let sliver = 0.1

    /// A rally, by its kind: `rally`, or none (a mark from before live tagging; D-028 §3).
    static func isRally(_ kind: RallyKind?) -> Bool { (kind ?? .rally) == .rally }

    init(marks: [Mark], cuts: [CutRange], complete: Bool) {
        let cuts = cuts.normalised()
        let pieces = marks.sorted { $0.start < $1.start }.flatMap { m in
            cuts.outside(m.start, m.end).filter { $0.end - $0.start >= Self.sliver }.map { Mark(start: $0.start, end: $0.end, kind: m.kind) }
        }
        self.pieces = pieces
        positives = pieces.filter { Self.isRally($0.kind) }.map { Span(start: $0.start, end: $0.end) }
        excluded = pieces.filter { !Self.isRally($0.kind) }.map { Span(start: $0.start, end: $0.end) }
        self.cuts = cuts
        self.complete = complete
    }

    /// The most of `start ..< end` that lies inside one rally, in seconds.
    func rallySeconds(within start: Double, _ end: Double) -> Double {
        positives.reduce(0) { Swift.max($0, Swift.min($1.end, end) - Swift.max($1.start, start)) }
    }

    /// Whether more than half of `start ..< end` lies inside one rally: a pre-tracked rally or a found one
    /// there is the marked rally, not something of its own.
    func coveredByRally(_ start: Double, _ end: Double) -> Bool {
        rallySeconds(within: start, end) > 0.5 * (end - start)
    }

    /// Everything masked from scoring and training: the excluded spans and the cut ranges, as one normalised list.
    var mask: [CutRange] { (excluded.map { CutRange(start: $0.start, end: $0.end) } + cuts).normalised() }

    /// The time outside the rallies, the excluded spans and the cuts, in order — not-rally time once the pass is
    /// complete; nothing before that (it is unknown, not dead).
    func unmarked(within duration: Double) -> [Span] {
        guard complete, duration > 0 else { return [] }
        let taken = positives.map { CutRange(start: $0.start, end: $0.end) } + mask
        return taken.outside(0, duration).filter { $0.end - $0.start >= Self.sliver }.map { Span(start: $0.start, end: $0.end) }
    }

    /// What closing a mark of `kind` over `start ..< end` does to the pre-tracked rallies mostly inside it: a
    /// rally confirms them, trimmed to it; a missed serve or a "not a rally" turns them down as they are (no
    /// rally is there, whatever the ball did). Each as it was, as it becomes, and the verdict — the stores apply
    /// them and keep the befores for undo.
    static func pretrackedChanges(_ tracks: [TrackedRally], start: Double, end: Double, kind: RallyKind)
        -> [(before: TrackedRally, after: TrackedRally, isRally: Bool)] {
        let truth = RallyTruth(marks: [Mark(start: start, end: end, kind: .rally)], cuts: [], complete: false)
        return tracks.filter { $0.isMachine && truth.coveredByRally($0.start, $0.end) }.map { t in
            isRally(kind) ? (t, t.trimmed(start: start, end: end), true) : (t, t, false)
        }
    }
}
