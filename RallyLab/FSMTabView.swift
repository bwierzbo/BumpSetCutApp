//
//  FSMTabView.swift
//  RallyLab
//
//  Phase 1 deterministic rally engine debug surface: live overlay on the player,
//  a color-coded state timeline, the rally summary table, and the engine controls.
//

import AVKit
import SwiftUI

struct FSMTabView: View {
    @Bindable var model: RallyLabModel

    var body: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            controls
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)
        }
    }

    // MARK: - Player + overlay + timeline

    private var leftColumn: some View {
        VStack(spacing: 10) {
            ZStack {
                if let player = model.player {
                    VideoPlayer(player: player)
                    FSMOverlayView(model: model)
                } else {
                    ContentUnavailableView(
                        "No Video", systemImage: "film",
                        description: Text("Open a video in the Pipeline tab (or drag one in), then Detect & Analyze.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            stateTimeline
            HStack(spacing: 12) {
                legendItem(.gray, "idle"); legendItem(.blue, "tracking")
                legendItem(.green, "active"); legendItem(.yellow, "lost"); legendItem(.red, "ended")
                Spacer()
                Text(model.fsmStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
    }

    private var stateTimeline: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard let r = model.engineResult, model.duration > 0 else { return }
                let dur = model.duration
                let states = r.frameStates
                // Coalesce same-state runs into one rect each (cheap redraws).
                var i = 0
                while i < states.count {
                    let st = states[i].state
                    let startT = states[i].time
                    var k = i + 1
                    while k < states.count, states[k].state == st { k += 1 }
                    let endT = k < states.count ? states[k].time : dur
                    let x = CGFloat(startT / dur) * size.width
                    let x2 = CGFloat(endT / dur) * size.width
                    ctx.fill(Path(CGRect(x: x, y: 0, width: max(1, x2 - x), height: size.height)),
                             with: .color(FSMColors.color(for: st)))
                    i = k
                }
                let px = CGFloat(model.currentTime / dur) * size.width
                ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                           with: .color(.white), lineWidth: 1)
            }
            .background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                guard model.duration > 0 else { return }
                let frac = max(0, min(1, v.location.x / geo.size.width))
                model.seek(to: frac * model.duration)
            })
        }
        .frame(height: 26)
    }

    // MARK: - Controls + summary

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Deterministic Engine (Phase 1)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ball + net + court geometry → finite state machine. Deterministic; tune the thresholds and re-run.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button {
                                Task { await model.runDeterministic() }
                            } label: { Label("Detect & Analyze", systemImage: "play.circle") }
                            .disabled(model.videoURL == nil || model.isRunningFSM)
                            if model.isRunningFSM { ProgressView().controlSize(.small) }
                        }
                        slider("stride", $model.fsmStride, 1...5, step: 1, fmt: "%.0f")
                        slider("ball conf", $model.fsmBallConfidence, 0.1...0.9, fmt: "%.2f")
                        slider("lost timeout", $model.fsmLostTimeout, 0.3...3.0, fmt: "%.1fs")
                        slider("min rally", $model.fsmMinRally, 0.2...4.0, fmt: "%.1fs")
                        slider("motion thr", $model.fsmMotionThreshold, 0.001...0.02, fmt: "%.3f")
                    }
                    .padding(4)
                }

                GroupBox("Rallies (\(model.engineResult?.rallies.count ?? 0))") {
                    if let rallies = model.engineResult?.rallies, !rallies.isEmpty {
                        summaryTable(rallies)
                    } else {
                        Text("Run Detect & Analyze to populate.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    private func summaryTable(_ rallies: [RallyRecord]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            GridRow {
                Group { Text("#"); Text("start"); Text("dur"); Text("net"); Text("side"); Text("lost"); Text("conf"); Text("end") }
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(rallies) { r in
                GridRow {
                    Button { model.seek(to: r.startTime) } label: {
                        Text("\(r.id)").font(.system(.caption, design: .monospaced))
                    }.buttonStyle(.plain)
                    Text(String(format: "%.1f", r.startTime)).font(.system(.caption, design: .monospaced))
                    Text(String(format: "%.1f", r.duration)).font(.system(.caption, design: .monospaced))
                    Text("\(r.netCrossings)").font(.system(.caption, design: .monospaced))
                    Text("\(r.sideChanges)").font(.system(.caption, design: .monospaced))
                    Text("\(r.lostTrackEvents)").font(.system(.caption, design: .monospaced))
                    Text("\(r.confidence)").font(.system(.caption, design: .monospaced))
                        .foregroundStyle(r.confidence >= 60 ? .green : (r.confidence >= 35 ? .orange : .red))
                    Text(r.endReason).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
    }

    // MARK: - Helpers

    private func slider(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        step: Double? = nil, fmt: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).frame(width: 78, alignment: .leading)
            if let step { Slider(value: value, in: range, step: step) } else { Slider(value: value, in: range) }
            Text(String(format: fmt, value.wrappedValue)).font(.system(.caption, design: .monospaced))
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func legendItem(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(t).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
