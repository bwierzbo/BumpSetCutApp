//
//  RallyTimesBar.swift
//  RallyLab (macOS and iPhone)
//

import SwiftUI

/// The video's length with cut ranges (dark, not footage), found rallies
/// (grey), yours (orange), the one being asked about (blue), touches as
/// ticks, and the playhead.
struct RallyTimesBar: View {
    let time: Double
    let duration: Double
    let found: [[Double]]
    let marked: [LabelRally]
    let current: [Double]?
    let pending: Double?
    var ticks: [Double] = []
    /// Cut ranges (D-030), each [start, end].
    var cuts: [[Double]] = []
    /// Where the cut being made starts: drawn to the playhead.
    var pendingCut: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(duration, 0.1)
            Canvas { ctx, size in
                func bar(_ a: Double, _ b: Double, _ y: CGFloat, _ h: CGFloat, _ c: Color) {
                    ctx.fill(Path(roundedRect: CGRect(x: a / d * w, y: y, width: max(2, (b - a) / d * w), height: h), cornerRadius: h / 2),
                             with: .color(c))
                }
                // Cuts in red: on the phone the former dark band read as nothing (owner, device walkthrough 2026-11-04).
                for c in cuts { ctx.fill(Path(CGRect(x: c[0] / d * w, y: 0, width: max(2, (c[1] - c[0]) / d * w), height: size.height)), with: .color(.red.opacity(0.4))) }
                if let pendingCut {
                    ctx.fill(Path(CGRect(x: pendingCut / d * w, y: 0, width: max(2, (max(time, pendingCut) - pendingCut) / d * w), height: size.height)),
                             with: .color(.red.opacity(0.22)))
                }
                ctx.fill(Path(CGRect(x: 0, y: 10, width: w, height: 2)), with: .color(.secondary.opacity(0.3)))
                for f in found { bar(f[0], f[1], 2, 5, .secondary.opacity(0.5)) }
                for r in marked { bar(r.start, r.end, 13, 7, .orange) }
                if let current { bar(current[0], current[1], 0, size.height, .blue.opacity(0.25)) }
                if let pending { bar(pending, max(time, pending), 13, 7, .orange.opacity(0.5)) }
                for t in ticks { ctx.fill(Path(CGRect(x: t / d * w - 0.75, y: 11, width: 1.5, height: 11)), with: .color(.white)) }
                ctx.fill(Path(CGRect(x: time / d * w - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
            }
        }
    }
}
