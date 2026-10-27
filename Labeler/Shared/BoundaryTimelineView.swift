//
//  BoundaryTimelineView.swift
//  Labeler/Shared — compiled by RallyLab (macOS) and the Labeler iPhone app
//
//  The whole recording on one bar, drawn the same way on both platforms: reviewed
//  coverage (green floor), unknown (dark), spans (amber / grey / purple), rallies
//  (blue; withdrawn dimmed; an uncertain event's interval lighter), legacy marks (thin
//  orange, optional), the draft (white outline), an open span's start, the playhead.
//  Click, tap or drag to seek; a click or tap with no real drag also selects.
//

import SwiftUI

struct BoundaryTimelineView: View {
    let file: EventReview.File?
    let duration: Double
    let playhead: Double
    let legacyMarks: [(start: Double, end: Double)]
    let showLegacy: Bool
    let draft: (start: Double, end: Double)?
    let openSpanStart: Double?
    let selected: UUID?
    /// Seek, loosely while dragging (`exact == false`) and exactly when the drag ends.
    let seek: (Double, Bool) -> Void
    /// A click or tap with no real drag: select the rally under it (nil when none).
    let select: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let d = max(duration, 0.001)
            let x: (Double) -> CGFloat = { CGFloat($0 / d) * w }
            Canvas { ctx, _ in
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 4), with: .color(.black.opacity(0.35)))
                if let f = file {
                    for c in EventReview.union(f.coverage) {
                        ctx.fill(Path(CGRect(x: x(c.start), y: h - 8, width: max(1, x(c.end) - x(c.start)), height: 8)), with: .color(.green.opacity(0.8)))
                    }
                    for s in f.spans {
                        let color: Color = s.kind == .nonRallyActivity ? .orange : s.kind == .transition ? .gray : .purple
                        ctx.fill(Path(CGRect(x: x(s.start), y: h * 0.55, width: max(2, x(s.end) - x(s.start)), height: h * 0.25)), with: .color(color.opacity(0.7)))
                    }
                    for r in f.rallies {
                        guard let a = r.contact?.earliest ?? r.dead?.earliest, let b = r.dead?.latest ?? r.contact?.latest else { continue }
                        let isSelected = r.rallyId == selected
                        let rect = CGRect(x: x(a), y: h * 0.12, width: max(2, x(b) - x(a)), height: h * 0.38)
                        ctx.fill(Path(rect), with: .color((r.reviewState == .withdrawn ? Color.gray : Color.blue).opacity(isSelected ? 1 : 0.7)))
                        for e in [r.contact, r.dead].compactMap({ $0 }) where e.earliest < e.latest {
                            ctx.fill(Path(CGRect(x: x(e.earliest), y: h * 0.12, width: max(1, x(e.latest) - x(e.earliest)), height: h * 0.38)), with: .color(.white.opacity(0.35)))
                        }
                    }
                }
                if showLegacy {
                    for m in legacyMarks {
                        ctx.fill(Path(CGRect(x: x(m.start), y: h * 0.02, width: max(1, x(m.end) - x(m.start)), height: 3)), with: .color(.orange.opacity(0.9)))
                    }
                }
                if let draft {
                    ctx.stroke(Path(CGRect(x: x(draft.start), y: h * 0.10, width: max(2, x(draft.end) - x(draft.start)), height: h * 0.42)), with: .color(.white), lineWidth: 1.5)
                }
                if let s = openSpanStart { ctx.fill(Path(CGRect(x: x(s) - 1, y: h * 0.5, width: 2, height: h * 0.35)), with: .color(.orange)) }
                ctx.fill(Path(CGRect(x: x(playhead) - 1, y: 0, width: 2, height: h)), with: .color(.white))
                var m = 60.0
                while m < d {
                    ctx.fill(Path(CGRect(x: x(m), y: h - 12, width: 1, height: 4)), with: .color(.white.opacity(0.5)))
                    m += 60
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in seek(Double(min(max(0, drag.location.x), w) / w) * d, false) }
                .onEnded { drag in
                    let t = Double(min(max(0, drag.location.x), w) / w) * d
                    seek(t, true)
                    if abs(drag.translation.width) < 3 { select(t) }
                })
        }
    }
}
