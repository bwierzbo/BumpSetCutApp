//
//  FSMOverlayView.swift
//  RallyLab
//
//  Live per-frame overlay for the deterministic Phase 1 engine, synced to the
//  player scrubber: net line + court regions (fixed), the tracked ball box + recent
//  trail, and the current FSM state — looked up from the engine's frame-state log at
//  model.currentTime.
//

import SwiftUI

/// State → color, shared by the overlay and the timeline.
enum FSMColors {
    static func color(for s: RallyState) -> Color {
        switch s {
        case .idle: return .gray
        case .tracking: return .blue
        case .active: return .green
        case .lost: return .yellow
        case .ended: return .red
        }
    }
}

struct FSMOverlayView: View {
    @Bindable var model: RallyLabModel

    var body: some View {
        let time = model.currentTime
        let displaySize = model.videoDisplaySize
        let turns = model.videoRotationQuarterTurns

        Canvas { ctx, size in
            guard let r = model.engineResult else { return }
            let fit = OverlayGeometry.fittedRect(content: displaySize, in: size)

            // Court regions (fixed for the video).
            ctx.stroke(Path(OverlayGeometry.rect(r.court.expandedRegion, turns: turns, in: fit)),
                       with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            ctx.stroke(Path(OverlayGeometry.rect(r.court.playRegion, turns: turns, in: fit)),
                       with: .color(.white.opacity(0.4)), lineWidth: 1)

            // Net plane line across the net's x-extent.
            let nL = OverlayGeometry.point(CGPoint(x: r.court.net.leftX, y: r.court.net.lineY), turns: turns, in: fit)
            let nR = OverlayGeometry.point(CGPoint(x: r.court.net.rightX, y: r.court.net.lineY), turns: turns, in: fit)
            var netPath = Path(); netPath.move(to: nL); netPath.addLine(to: nR)
            ctx.stroke(netPath, with: .color(.cyan), lineWidth: 2)

            guard let idx = nearestIndex(r.frameStates, time: time) else { return }
            let fs = r.frameStates[idx]
            let col = FSMColors.color(for: fs.state)

            // Recent tracked-ball trail.
            var pts: [CGPoint] = []
            var j = idx
            while j >= 0, r.frameStates[j].time >= time - 0.6 {
                if let bp = r.frameStates[j].ballPoint {
                    pts.append(OverlayGeometry.point(bp, turns: turns, in: fit))
                }
                j -= 1
            }
            if pts.count >= 2 {
                var trail = Path(); trail.move(to: pts[0])
                for p in pts.dropFirst() { trail.addLine(to: p) }
                ctx.stroke(trail, with: .color(col.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            // Tracked ball box (or a dot if only a predicted point during LOST).
            if let bb = fs.ballBox {
                ctx.stroke(Path(OverlayGeometry.rect(bb, turns: turns, in: fit)), with: .color(col), lineWidth: 2)
            } else if let bp = fs.ballPoint {
                let c = OverlayGeometry.point(bp, turns: turns, in: fit)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                           with: .color(col), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            }

            // State badge.
            let label = Text(fs.state.rawValue.uppercased())
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(col)
            ctx.draw(label, at: CGPoint(x: fit.minX + 8, y: fit.minY + 8), anchor: .topLeading)
        }
        .allowsHitTesting(false)
    }

    /// Last frame-state at or before `time` (binary search; states are time-sorted).
    private func nearestIndex(_ states: [FrameState], time: Double) -> Int? {
        guard !states.isEmpty else { return nil }
        var lo = 0, hi = states.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if states[mid].time <= time { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }
}
