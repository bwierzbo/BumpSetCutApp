//
//  CompareTabView.swift
//  RallyLab
//
//  Run two pipelines (from PipelineRegistry) over the loaded video and compare
//  their scores + rally timelines against the hand labels, head to head.
//

import SwiftUI

struct CompareTabView: View {
    @Bindable var model: RallyLabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            Divider()
            if model.comparisonA != nil || model.comparisonB != nil {
                scoreTable
                timeline
                Spacer()
            } else {
                ContentUnavailableView(
                    "No Comparison Yet",
                    systemImage: "square.split.2x1",
                    description: Text("Pick two pipelines and Run Comparison. Needs a loaded video + ground-truth labels (mark them in the Pipeline tab).")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(alignment: .top, spacing: 24) {
            pipelinePicker("Pipeline A", selection: $model.pipelineAId)
            pipelinePicker("Pipeline B", selection: $model.pipelineBId)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        Task { await model.runComparison() }
                    } label: {
                        Label("Run Comparison", systemImage: "play.rectangle.on.rectangle")
                    }
                    .disabled(model.videoURL == nil || model.isComparing)
                    if model.isComparing { ProgressView().controlSize(.small) }
                }
                Text(model.compareStatus).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func pipelinePicker(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(PipelineRegistry.all, id: \.id) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            if let p = PipelineRegistry.pipeline(id: selection.wrappedValue) {
                Text(p.detail)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(width: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Score table

    private var scoreTable: some View {
        GroupBox("Scores (raw boundaries vs labels)") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("metric").font(.caption2).foregroundStyle(.secondary)
                    Text(model.comparisonA?.pipelineName ?? "A").font(.caption.bold())
                    Text(model.comparisonB?.pipelineName ?? "B").font(.caption.bold())
                }
                metricRow("F1", highlightHigher: true) { String(format: "%.3f", $0.score.f1) } number: { $0.score.f1 }
                metricRow("Precision") { String(format: "%.3f", $0.score.precision) }
                metricRow("Recall") { String(format: "%.3f", $0.score.recall) }
                metricRow("Start MAE") { String(format: "%.2fs", $0.score.startMAE) }
                metricRow("End MAE") { String(format: "%.2fs", $0.score.endMAE) }
                metricRow("TP/FP/FN") { "\($0.score.truePositives)/\($0.score.falsePositives)/\($0.score.falseNegatives)" }
                metricRow("Rallies") { "\($0.raw.count)" }
            }
            .padding(6)
        }
    }

    /// A metric row showing A and B. When `highlightHigher` and `number` are given,
    /// the higher value is tinted green.
    private func metricRow(_ name: String,
                           highlightHigher: Bool = false,
                           _ value: @escaping (ComparisonResult) -> String,
                           number: ((ComparisonResult) -> Double)? = nil) -> some View {
        let a = model.comparisonA, b = model.comparisonB
        let na = number.flatMap { f in a.map(f) }
        let nb = number.flatMap { f in b.map(f) }
        func color(_ mine: Double?, _ other: Double?) -> Color {
            guard highlightHigher, let m = mine, let o = other, m != o else { return .primary }
            return m > o ? .green : .secondary
        }
        return GridRow {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(a.map(value) ?? "—").font(.system(.body, design: .monospaced)).foregroundStyle(color(na, nb))
            Text(b.map(value) ?? "—").font(.system(.body, design: .monospaced)).foregroundStyle(color(nb, na))
        }
    }

    // MARK: - Timelines

    private var timeline: some View {
        GroupBox("Timelines") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    legend(.green, "ground truth")
                    legend(.blue, model.comparisonA?.pipelineName ?? "A")
                    legend(.orange, model.comparisonB?.pipelineName ?? "B")
                }
                Canvas { ctx, size in
                    let dur = max(model.duration, 0.01)
                    let rowH = size.height / 3
                    func bars(_ ranges: [(Double, Double)], row: Int, color: Color) {
                        let y = CGFloat(row) * rowH + 3
                        for (s, e) in ranges {
                            let x1 = CGFloat(s / dur) * size.width
                            let x2 = CGFloat(e / dur) * size.width
                            let r = CGRect(x: x1, y: y, width: max(2, x2 - x1), height: rowH - 6)
                            ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(color))
                        }
                    }
                    bars(model.labels.map { ($0.start, $0.end) }, row: 0, color: .green)
                    bars(model.comparisonA?.raw.map { ($0.start, $0.end) } ?? [], row: 1, color: .blue)
                    bars(model.comparisonB?.raw.map { ($0.start, $0.end) } ?? [], row: 2, color: .orange)
                }
                .frame(height: 96)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(6)
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 10)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
