//
//  RallyTimesBar.swift
//  RallyLab (macOS and iPhone)
//

import SwiftUI

/// The video's length with found rallies (grey), yours (orange), the one
/// being asked about (blue) and the playhead.
struct RallyTimesBar: View {
    let time: Double
    let duration: Double
    let found: [[Double]]
    let marked: [LabelRally]
    let current: [Double]?
    let pending: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(duration, 0.1)
            Canvas { ctx, size in
                func bar(_ a: Double, _ b: Double, _ y: CGFloat, _ h: CGFloat, _ c: Color) {
                    ctx.fill(Path(roundedRect: CGRect(x: a / d * w, y: y, width: max(2, (b - a) / d * w), height: h), cornerRadius: h / 2),
                             with: .color(c))
                }
                ctx.fill(Path(CGRect(x: 0, y: 10, width: w, height: 2)), with: .color(.secondary.opacity(0.3)))
                for f in found { bar(f[0], f[1], 2, 5, .secondary.opacity(0.5)) }
                for r in marked { bar(r.start, r.end, 13, 7, .orange) }
                if let current { bar(current[0], current[1], 0, size.height, .blue.opacity(0.25)) }
                if let pending { bar(pending, max(time, pending), 13, 7, .orange.opacity(0.5)) }
                ctx.fill(Path(CGRect(x: time / d * w - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
            }
        }
    }
}
