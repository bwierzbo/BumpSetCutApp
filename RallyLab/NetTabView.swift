//
//  NetTabView.swift
//  RallyLab
//
//  Samples a few frames from the loaded video, runs the net model, and shows
//  where it thinks the net is: a main still with the aggregated net box + net
//  line, a filmstrip of every sampled frame with its per-frame box, and stats.
//

import SwiftUI

struct NetTabView: View {
    @Bindable var model: RallyLabModel

    var body: some View {
        HSplitView {
            mainColumn
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            controls
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
        }
    }

    // MARK: - Main still + filmstrip

    private var mainColumn: some View {
        VStack(spacing: 10) {
            Group {
                if model.videoURL == nil {
                    ContentUnavailableView(
                        "No Video",
                        systemImage: "film",
                        description: Text("Open a video in the Pipeline tab (or drag one in), then Detect Net.")
                    )
                } else if let sample = bestSample {
                    netStill(sample)
                } else {
                    ContentUnavailableView(
                        "No Net Yet",
                        systemImage: "rectangle.dashed",
                        description: Text("Press Detect Net to sample frames and locate the net.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !model.netSamples.isEmpty {
                filmstrip
            }
        }
        .padding(12)
    }

    /// The sampled frame with the most confident net detection (falls back to the
    /// first sample) — the clearest backdrop for the aggregated net.
    private var bestSample: NetSample? {
        model.netSamples.filter { $0.box != nil }
            .max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) })
            ?? model.netSamples.first
    }

    private func netStill(_ sample: NetSample) -> some View {
        Canvas { ctx, size in
            let imgSize = CGSize(width: sample.image.width, height: sample.image.height)
            let fit = OverlayGeometry.fittedRect(content: imgSize, in: size)
            ctx.draw(Image(decorative: sample.image, scale: 1, orientation: .up), in: fit)

            // Faint per-frame boxes to show detection jitter across samples.
            for s in model.netSamples {
                guard let b = s.box else { continue }
                ctx.stroke(Path(OverlayGeometry.rect(b, turns: 0, in: fit)),
                           with: .color(.cyan.opacity(0.22)), lineWidth: 1)
            }

            // Aggregated net box (bright) + net tape line (top edge) + center line.
            if let agg = model.netResult?.aggregatedBox {
                let r = OverlayGeometry.rect(agg, turns: 0, in: fit)
                ctx.stroke(Path(r), with: .color(.cyan), style: StrokeStyle(lineWidth: 2))
                var tape = Path()
                tape.move(to: CGPoint(x: r.minX, y: r.minY))
                tape.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                ctx.stroke(tape, with: .color(.yellow), style: StrokeStyle(lineWidth: 3))
                var center = Path()
                center.move(to: CGPoint(x: r.minX, y: r.midY))
                center.addLine(to: CGPoint(x: r.maxX, y: r.midY))
                ctx.stroke(center, with: .color(.yellow.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.netSamples) { thumb($0) }
            }
        }
        .frame(height: 108)
    }

    private func thumb(_ s: NetSample) -> some View {
        Canvas { ctx, size in
            let imgSize = CGSize(width: s.image.width, height: s.image.height)
            let fit = OverlayGeometry.fittedRect(content: imgSize, in: size)
            ctx.draw(Image(decorative: s.image, scale: 1, orientation: .up), in: fit)
            if let b = s.box {
                ctx.stroke(Path(OverlayGeometry.rect(b, turns: 0, in: fit)),
                           with: .color(.cyan), lineWidth: 1.5)
            }
        }
        .frame(width: 168, height: 100)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottomLeading) {
            Text(s.box != nil ? String(format: "%.2f", s.confidence ?? 0) : "—")
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(.black.opacity(0.55))
                .foregroundStyle(s.box != nil ? Color.cyan : Color.gray)
                .padding(3)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Net Detection") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sample frames across the video, run the net model on each, and aggregate where it thinks the net is.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack {
                            Button {
                                Task { await model.detectNet() }
                            } label: {
                                Label("Detect Net", systemImage: "wand.and.stars")
                            }
                            .disabled(model.videoURL == nil || model.isDetectingNet)
                            if model.isDetectingNet { ProgressView().controlSize(.small) }
                        }

                        labeledSlider("samples", value: $model.netSampleCount, in: 3...20, step: 1,
                                      text: "\(Int(model.netSampleCount))")
                        labeledSlider("confidence", value: $model.netConfidence, in: 0.05...0.9, step: nil,
                                      text: String(format: "%.2f", model.netConfidence))
                        Toggle(isOn: $model.netLetterbox) {
                            Text("letterbox (scaleFit)").font(.caption)
                        }
                        .toggleStyle(.checkbox)
                        .help("How the frame is fit into the model's square input. Letterbox (scaleFit) preserves aspect; turn OFF to stretch (scaleFill). If the net box is systematically too tall/short, flip this and re-run — it depends on how the model was trained.")

                        Text(model.netStatus)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(4)
                }

                if let r = model.netResult {
                    GroupBox("Result") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            GridRow {
                                stat("frames", "\(r.framesDetected)/\(r.totalSamples)")
                                stat("mean conf", String(format: "%.2f", r.meanConfidence))
                            }
                            GridRow {
                                stat("net top Y", String(format: "%.3f", r.aggregatedBox.maxY))
                                stat("net mid Y", String(format: "%.3f", r.aggregatedBox.midY))
                            }
                        }
                        .padding(4)
                    }
                    Text("Net Y is Vision-normalized (0 = bottom, 1 = top of frame). The yellow tape line is what the future “ball must clear the net” rule will key on.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    private func labeledSlider(_ name: String, value: Binding<Double>, in range: ClosedRange<Double>,
                               step: Double?, text: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).frame(width: 76, alignment: .leading)
            if let step { Slider(value: value, in: range, step: step) } else { Slider(value: value, in: range) }
            Text(text).font(.system(.caption, design: .monospaced)).frame(width: 38, alignment: .trailing)
        }
    }

    private func stat(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}
