//
//  InspectorPane.swift
//  RallyLab
//
//  Right-hand panel: pipeline controls, score readout, ground-truth list
//  editor, config sliders, and the parameter sweep.
//

import SwiftUI

struct InspectorPane: View {
    @Bindable var model: RallyLabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pipelineSection
                scoreSection
                labelsSection
                configSection
                sweepSection
            }
            .padding(12)
        }
    }

    // MARK: - Pipeline

    private var pipelineSection: some View {
        GroupBox("Pipeline") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Run Pipeline") {
                        Task { await model.runPipeline() }
                    }
                    .disabled(model.videoURL == nil || model.isProcessing)

                    Button("Seed Labels from Predictions") {
                        Task { await model.seedFromPredictions() }
                    }
                    .disabled(model.videoURL == nil || model.isProcessing)
                }

                if let processor = model.activeProcessor {
                    ProgressView(value: processor.progress)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: - Score

    private var scoreSection: some View {
        GroupBox("Score (raw boundaries vs labels)") {
            if let score = model.score {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        metric("F1", score.f1, format: "%.3f")
                        metric("Precision", score.precision, format: "%.3f")
                        metric("Recall", score.recall, format: "%.3f")
                    }
                    GridRow {
                        metric("Start MAE", score.startMAE, format: "%.2fs")
                        metric("End MAE", score.endMAE, format: "%.2fs")
                        metric("TP/FP/FN", nil, text: "\(score.truePositives)/\(score.falsePositives)/\(score.falseNegatives)")
                    }
                    GridRow {
                        metric("Start ≤1s", score.startWithinTolerance * 100, format: "%.0f%%")
                        metric("End ≤1s", score.endWithinTolerance * 100, format: "%.0f%%")
                        metric("Optimizer", score.optimizerScore(), format: "%.3f")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } else {
                Text("Run the pipeline and add labels to see a score.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
        }
    }

    private func metric(_ name: String, _ value: Double?, format: String = "%.2f", text: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text ?? String(format: format, value ?? 0))
                .font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - Ground truth

    private var labelsSection: some View {
        GroupBox("Ground Truth (\(model.labels.count) rallies)") {
            VStack(alignment: .leading, spacing: 6) {
                if model.labels.isEmpty {
                    Text("Mark rallies with S/E while the video plays, or seed from predictions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach($model.labels) { $label in
                    HStack(spacing: 6) {
                        Button {
                            model.seek(to: label.start)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Jump to this rally")

                        TextField("Start", value: $label.start, format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 76)
                        Text("–")
                        TextField("End", value: $label.end, format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 76)
                        Text(String(format: "%.1fs", max(0, label.end - label.start)))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button(role: .destructive) {
                            model.deleteLabel(label)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if let url = model.labelsFileURL {
                    Text("Saved to \(url.lastPathComponent)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: - Config

    private var configSection: some View {
        GroupBox("Config") {
            VStack(spacing: 8) {
                Text("Detection & gate — re-run to apply:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                slider("detectionConf", value: $model.detectionConfidence, in: 0.1...0.95, format: "%.2f",
                       info: "Minimum YOLO confidence to keep a volleyball detection. Lower surfaces marginal/noisier detections (more recall); higher keeps only confident hits. Changes what the model detects, so it needs a re-run.")
                slider("minGravitySig", value: $model.minGravitySignature, in: 0...1.0, format: "%.2f",
                       info: "Minimum gravity signature (consistent downward acceleration) to accept a ball as free flight. Carried/rolled balls score near 0; raise to veto more of them. The veto only fires when this AND the flatness test below both trip.")
                slider("maxVertForRoll", value: $model.maxVerticalMotionForRolling, in: 0...1.0, format: "%.2f",
                       info: "How flat the motion must be for the supported-ball veto (veto = flat AND low-gravity). Raising it makes the veto rely mostly on gravity, so it catches balls carried with bobbing — but risks vetoing real plays at serve/contact where gravity briefly dips. Watch the score when you raise it.")
                slider("minCurvature", value: $model.minCurvatureMagnitude, in: 0...0.02, format: "%.3f",
                       info: "Minimum parabola curvature |a|. A held/carried ball travels in a near-straight line (a≈0); raise this to reject those before the classifier veto even runs.")
                slider("minSpanY", value: $model.minProjectileSpanY, in: 0...0.2, format: "%.3f",
                       info: "Minimum vertical travel (fraction of frame height) over the fit window for a ball to count as a projectile. Filters out balls that barely move vertically.")
                slider("parabolaMinR2", value: $model.parabolaMinR2, in: 0.5...0.98, format: "%.2f",
                       info: "Minimum parabola fit quality (R²) to accept a projectile. Jumpy/erratic motion (like a player picking up a ball) fits a clean arc poorly, so raising this rejects it — at the risk of also dropping noisy real arcs. The most direct dial for 'require smooth arc motion'.")
                slider("activeStride", value: $model.activeTrackingStride, in: 1...5, step: 1, format: "%.0f",
                       info: "Frames processed while actively tracking a ball: 1 = every frame (densest, most stable gate), 2 = every other, etc. Higher saves compute during rallies but under-samples the gate's parabola window and can make the projectile decision flicker. Keep at 1 unless processing is too slow.")
                Toggle(isOn: $model.vetoCarriedMovement) {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
                        Text("veto carried/jumpy class")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Also reject tracks the classifier labels 'carried' — jumpy, inconsistent motion like a player picking up a ball. The classifier already detects this; the gate normally ignores it. Targeted fix for pickup false positives; check that real rallies (which classify as airborne) survive after enabling.")
                Toggle(isOn: $model.useSmoothedTrack) {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
                        Text("smooth track (Kalman)")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Run the gate's checks (jump, ROI, curvature fit) on the Kalman-filtered track positions instead of the raw detection centers, so single-frame detection jitter doesn't trip them. Also smooths the on-screen trail. The filter is already running; this just uses its output. Reduces green/gray flicker on clean arcs.")
                Toggle(isOn: $model.enableLoopRejection) {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
                        Text("reject doubling-back (loops)")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Reject a track that makes a sideways excursion but returns near its horizontal start — a pickup/scoop loop. A real ball in play travels across; a loop comes back. Catches loops the short-window parabola checks can't see, regardless of movement class. Spares near-vertical tosses (little sideways motion) and clean arcs (monotonic horizontal travel).")
                if model.enableLoopRejection {
                    slider("loopReturnRatio", value: $model.loopReturnRatio, in: 0.1...0.9, format: "%.2f",
                           info: "Reject when net horizontal travel is ≤ this fraction of the side-to-side excursion — i.e. the ball came at least this far back. Lower = stricter (only near-complete loops rejected); higher = catches partial doubling-back too (riskier for real plays).")
                }
                if model.detectionConfigDirty {
                    HStack(spacing: 6) {
                        Label("Detection settings changed — re-run to apply.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Re-run") { Task { await model.runPipeline() } }
                            .controlSize(.small)
                            .disabled(model.isProcessing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                Text("Below re-score live from cached detections:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                slider("startBuffer", value: $model.startBuffer, in: 0...1.5, format: "%.2fs",
                       info: "Seconds of continuous projectile evidence required before a rally is allowed to start. Higher = fewer false starts but may clip the serve; lower = rallies start sooner.")
                slider("endTimeout", value: $model.endTimeout, in: 0.3...3.0, format: "%.2fs",
                       info: "Seconds without seeing any ball before a rally ends. Higher bridges longer occlusions/gaps (and can merge two real rallies into one); lower ends rallies sooner.")
                slider("projDropGrace", value: $model.projDropGracePeriod, in: 0...8, step: 1, format: "%.0f frames",
                       info: "How many consecutive non-projectile frames are tolerated before the start-buffer countdown resets. Stops a single dropped detection from restarting the rally-start clock.")
                slider("minRallySec", value: $model.minRallySec, in: 0.5...6.0, format: "%.2fs",
                       info: "Minimum rally duration. A rally can't end before this many seconds have elapsed — suppresses flickery, too-short detections.")
                slider("minGapToMerge", value: $model.minGapToMerge, in: 0...2.0, format: "%.2fs",
                       info: "Two finalized rallies separated by a gap smaller than this are merged into one. Higher merges more aggressively.")
                slider("minSegmentLength", value: $model.minSegmentLength, in: 0...4.0, format: "%.2fs",
                       info: "Final rallies shorter than this are dropped entirely. Higher discards more short segments.")
                slider("skyBallTimeout", value: $model.skyBallTimeout, in: 0.8...5.0, format: "%.2fs",
                       info: "When the ball was last seen near the top of the frame (a sky ball / high dig that left the top of view), keep the rally alive this long for it to come back down, instead of the normal ~0.8s no-ball cutoff. Higher = more tolerance for high arcs, at the cost of a longer tail when a rally really does end on a high ball.")
                slider("skyBallTopY", value: $model.skyBallTopThreshold, in: 0.5...0.95, format: "%.2f",
                       info: "How near the top of the frame the ball must be (normalized height, 1.0 = very top) for the sky-ball grace above to apply. Lower = triggers for balls that are only moderately high; higher = only when the ball is right at the top edge.")
                slider("preroll", value: $model.preroll, in: 0...5.0, format: "%.2fs",
                       info: "Lead-in: how many seconds before the detected start the exported rally clip begins, so it captures the serve/wind-up even when detection is a little late. Shown as the lighter padded block in the timeline; it does NOT change the score (which is measured on the raw pre-padding boundaries).")
                Divider()
                Button {
                    model.copyParameters()
                } label: {
                    Label("Copy Parameters", systemImage: "doc.on.clipboard")
                }
                .help("Copy the current values to the clipboard. Paste them to the assistant to bake in as the shared ProcessorConfig defaults for RallyLab and BumpSetCut.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func slider(
        _ name: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        format: String,
        info: String
    ) -> some View {
        ParamSlider(name: name, value: value, range: range, step: step, format: format, info: info)
    }

    // MARK: - Sweep

    private var sweepSection: some View {
        GroupBox("Parameter Sweep") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Run Sweep") {
                        Task { await model.runSweep() }
                    }
                    .disabled(model.evidence.isEmpty || model.labels.isEmpty || model.isSweeping)

                    if model.isSweeping {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !model.sweepCandidates.isEmpty {
                    Text("Top configs (ranked, prefers staying near your current settings):")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(Array(model.sweepCandidates.enumerated()), id: \.element.id) { index, cand in
                        sweepRow(index: index, cand: cand)
                    }
                    HStack {
                        Button("Apply Best") { model.applySweepCandidate() }
                        Button("Revert") { model.revertSweepApply() }
                            .disabled(!model.canRevertSweepApply)
                    }
                } else {
                    Text("Searches the six live-rescore parameters against your labels using the cached evidence, and keeps your config close to where it is unless a change clearly helps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func sweepRow(index: Int, cand: RallyLabModel.SweepCandidate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("#\(index + 1)").font(.caption.bold())
                Text(String(format: "score %.3f · F1 %.3f · drift %.0f%%",
                            cand.score, cand.f1, cand.driftFromCurrent * 100))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { model.applySweepCandidate(cand) }
                    .controlSize(.small)
            }
            Text(paramSummary(cand.params))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func paramSummary(_ p: [String: Double]) -> String {
        func v(_ k: String, _ fmt: String = "%.2f") -> String { String(format: fmt, p[k] ?? 0) }
        return "sb \(v("startBuffer"))  et \(v("endTimeout"))  grace \(v("projDropGracePeriod", "%.0f"))  minR \(v("minRallySec"))  gap \(v("minGapToMerge"))  minSeg \(v("minSegmentLength"))"
    }
}

/// One labeled slider row. The ⓘ button opens a popover with the parameter's
/// description on click (hover tooltips proved unreliable on this window).
private struct ParamSlider: View {
    let name: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let format: String
    let info: String

    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Button {
                    showInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(showInfo ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                    Text(info)
                        .font(.callout)
                        .frame(width: 280, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                }
                .help(info)
                Text(name)
                    .font(.system(.caption, design: .monospaced))
            }
            .frame(width: 130, alignment: .trailing)
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(String(format: format, value))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 70, alignment: .leading)
        }
    }
}
