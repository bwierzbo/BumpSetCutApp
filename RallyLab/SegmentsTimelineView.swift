//
//  SegmentsTimelineView.swift
//  RallyLab
//
//  Horizontal timeline comparing hand-labeled rallies against the pipeline's
//  predictions (raw decided boundaries, with padded export ranges ghosted
//  behind them). Click anywhere to seek.
//

import SwiftUI

struct SegmentsTimelineView: View {
    let model: RallyLabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(title: "Labeled") { width in
                segmentShapes(model.labels.map { ($0.start, $0.end) }, color: .green, width: width)
                if let pending = model.pendingStart, model.duration > 0 {
                    Rectangle()
                        .fill(.orange)
                        .frame(width: 2)
                        .offset(x: width * pending / model.duration)
                }
            }
            row(title: "Predicted") { width in
                segmentShapes(model.paddedPredictions.map { ($0.start, $0.end) }, color: .blue.opacity(0.25), width: width)
                segmentShapes(model.rawPredictions.map { ($0.start, $0.end) }, color: .blue, width: width)
            }
            if !model.evidence.isEmpty {
                row(title: "Evidence") { _ in
                    EvidenceStrip(model: model)
                }
                evidenceLegend
            }
        }
    }

    private var evidenceLegend: some View {
        HStack(spacing: 12) {
            legendDot(.green, "projectile gate fired")
            legendDot(.red, "ball seen, vetoed")
            legendDot(.blue, "rally active")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.leading, 70)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label)
        }
    }

    private func row<Overlay: View>(
        title: String,
        @ViewBuilder overlay: @escaping (CGFloat) -> Overlay
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .quaternarySystemFill))
                    overlay(proxy.size.width)
                    playhead(width: proxy.size.width)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        guard model.duration > 0 else { return }
                        let fraction = min(max(0, value.location.x / proxy.size.width), 1)
                        model.seek(to: fraction * model.duration)
                    }
                )
            }
        }
        .frame(height: 40)
    }

    @ViewBuilder
    private func segmentShapes(_ segments: [(Double, Double)], color: Color, width: CGFloat) -> some View {
        if model.duration > 0 {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                let x = width * segment.0 / model.duration
                let w = max(2, width * (segment.1 - segment.0) / model.duration)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: w)
                    .padding(.vertical, 6)
                    .offset(x: x)
            }
        }
    }

    @ViewBuilder
    private func playhead(width: CGFloat) -> some View {
        if model.duration > 0 {
            Rectangle()
                .fill(.red)
                .frame(width: 1.5)
                .offset(x: width * model.currentTime / model.duration)
        }
    }
}

/// Per-frame evidence over the whole clip: an upper lane colored by the
/// projectile gate's decision (green = fired, red = ball seen but vetoed,
/// grey = no ball) and a lower lane shading the decided rally spans. Lets
/// carried-ball false positives (red ticks inside a rally span) be spotted
/// without scrubbing.
private struct EvidenceStrip: View {
    let model: RallyLabModel

    var body: some View {
        // Read main-actor model state here; the Canvas draw closure is nonisolated.
        let duration = model.duration
        let frames = model.evidence
        let rallies = model.rawPredictions

        Canvas { ctx, size in
            guard duration > 0 else { return }
            let w = size.width, h = size.height
            let gateH = h * 0.62
            let rallyY = gateH + 2
            let rallyH = max(0, h - rallyY)
            func x(_ t: Double) -> CGFloat { w * CGFloat(t / duration) }

            for i in frames.indices {
                let f = frames[i]
                let color: Color? = f.isProjectile ? .green : (f.hasBall ? .red : nil)
                guard let color else { continue }
                let x0 = x(f.time)
                let x1 = i + 1 < frames.count ? x(frames[i + 1].time) : x0 + 1
                ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: gateH)),
                         with: .color(color))
            }

            for seg in rallies {
                let rect = CGRect(x: x(seg.start), y: rallyY,
                                  width: max(1, x(seg.end) - x(seg.start)), height: rallyH)
                ctx.fill(Path(rect), with: .color(.blue))
            }
        }
    }
}
