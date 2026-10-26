//
//  PilotBlind.swift
//  Labeler/Shared — compiled by RallyLab (macOS) and the Labeler iPhone app
//
//  The 24-rally pilot (D-004) as both apps see it, and the one blind-review rule they both
//  enforce (protocol §6): while a selected rally's first review is not committed, no
//  legacy mark inside its frozen window is shown — whatever a toggle says, wherever the
//  playhead is. A rally counts as committed when a reviewed rally of the record overlaps
//  the selected legacy interval (the same pairing the boundary audit uses), so the rule
//  does not depend on how either device numbers its legacy marks. Neither app shows a
//  model prediction during review.
//

import Foundation

/// One selected rally of a frozen pilot draw, as the apps need it.
struct PilotWindow: Codable, Equatable {
    var video: String
    var legacyIndex: Int
    var legacyStart: Double
    var legacyEnd: Double
    /// [start, end] of the evaluation window, frozen from legacy information alone.
    var window: [Double]
    var stratum: String
    var repeatReview: Bool
}

/// A frozen pilot draw as published for the phone (migration 049): read-only, identified by the record's id, the
/// SHA-256 of the frozen record file, and the server's digest of the selection it stores.
struct PilotPublication: Codable, Equatable {
    var id: String
    var project: String
    var recordSha256: String
    var selectionDigest: String
    var selection: [PilotWindow]
    var publishedAt: Date?

    func windows(for session: String) -> [PilotWindow] {
        selection.filter { $0.video == session }.sorted { $0.window[0] < $1.window[0] }
    }
}

enum PilotBlind {
    /// The reviewed rally that answers this selected rally: first one linked to this exact legacy mark (index and
    /// recorded times) inside the window; otherwise one whose extent touches the legacy interval (closed intervals,
    /// so a single event on one frame — truncated at the recording's edge — still counts), the longest overlap
    /// first, then the one whose legacy link names this mark.
    static func answer(to w: PilotWindow, in file: EventReview.File?) -> EventReview.Rally? {
        guard let file else { return nil }
        func extent(_ r: EventReview.Rally) -> (Double, Double)? {
            guard let a = r.contact?.earliest ?? r.dead?.earliest, let b = r.dead?.latest ?? r.contact?.latest else { return nil }
            return (a, b)
        }
        func overlap(_ r: EventReview.Rally) -> Double? {
            guard let (a, b) = extent(r), a <= w.legacyEnd + 1e-9, b >= w.legacyStart - 1e-9 else { return nil }
            return min(b, w.legacyEnd) - max(a, w.legacyStart)
        }
        // Reliable provenance first: a rally whose legacy link names this mark by its index AND its recorded legacy
        // times (so another device's numbering cannot pair it wrongly), lying within the frozen window — a correction
        // may move well off a short legacy mark.
        let linked = file.rallies.filter { r in
            guard r.reviewState == .reviewed, r.legacyIndex == w.legacyIndex, let ls = r.legacyStart, let le = r.legacyEnd,
                  abs(ls - w.legacyStart) < 1e-3, abs(le - w.legacyEnd) < 1e-3, let (a, b) = extent(r) else { return false }
            return a <= w.window[1] + 1e-9 && b >= w.window[0] - 1e-9
        }
        if let r = linked.first { return r }
        // The fallback never takes a rally reliably linked to a different legacy mark (its recorded legacy times name
        // another interval): one annotation answers one selection.
        func linkedElsewhere(_ r: EventReview.Rally) -> Bool {
            guard let ls = r.legacyStart, let le = r.legacyEnd else { return false }
            return abs(ls - w.legacyStart) >= 1e-3 || abs(le - w.legacyEnd) >= 1e-3
        }
        let candidates = file.rallies.filter { $0.reviewState == .reviewed && overlap($0) != nil && !linkedElsewhere($0) }
        return candidates.max { l, r in
            let lo = overlap(l)!, ro = overlap(r)!
            if abs(lo - ro) > 1e-9 { return lo < ro }
            return (l.legacyIndex == w.legacyIndex ? 1 : 0) < (r.legacyIndex == w.legacyIndex ? 1 : 0)
        }
    }

    static func firstReviewCommitted(_ w: PilotWindow, in file: EventReview.File?) -> Bool { answer(to: w, in: file) != nil }

    /// Which of these legacy marks may be drawn: none that falls inside the window of a selected rally whose first
    /// review is not committed yet.
    static func visible(_ marks: [(start: Double, end: Double)], windows: [PilotWindow], record: EventReview.File?) -> [Bool] {
        let blind = windows.filter { !firstReviewCommitted($0, in: record) }
        return marks.map { m in !blind.contains { w in m.end > w.window[0] && m.start < w.window[1] } }
    }

    /// The marks that may be drawn.
    static func filter(_ marks: [(start: Double, end: Double)], windows: [PilotWindow], record: EventReview.File?) -> [(start: Double, end: Double)] {
        zip(marks, visible(marks, windows: windows, record: record)).filter(\.1).map(\.0)
    }
}
