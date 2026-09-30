//
//  ModelsTabView.swift
//  RallyLab
//
//  Package → train elsewhere → bring the model back → score it. Left: the
//  training package and the model library (with the pre-label choice).
//  Right: evaluation — the app's model against a candidate on your
//  reviewed frames, and every miss and false alarm, one click from the
//  frame in the Sampler.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModelsTabView: View {
    @Bindable var library: ModelLibrary
    /// Open a frame in the Sampler tab.
    let showFrame: (String, UUID) -> Void

    @State private var errorFilter: ModelEvaluation.Result.ErrorKind = .missed

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    packageBox
                    modelsBox
                    if !library.status.isEmpty {
                        Text(library.status).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)

            evaluationColumn
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { library.reload() }
    }

    // MARK: - Package

    private var packageBox: some View {
        GroupBox("1 · Training package") {
            VStack(alignment: .leading, spacing: 8) {
                let counts = library.reviewedCounts
                Text("\(counts.train) train and \(counts.val) val frames reviewed in \(library.sampler.datasetRoot.lastPathComponent).")
                    .font(.callout)
                Text("A zip of every kept, reviewed frame with its labels and a data.yaml that works wherever it's unzipped. Copy it to your desktop and follow the README inside.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button {
                        library.exportPackage()
                    } label: { Label("Export Training Package", systemImage: "shippingbox") }
                    .disabled(library.isBusy || counts.train + counts.val == 0)
                    if library.isBusy && library.evalProgress == nil { ProgressView().controlSize(.small) }
                }
                if !library.packages.isEmpty {
                    Divider()
                    Text("Packages").font(.caption.weight(.semibold))
                    ForEach(library.packages.prefix(5), id: \.self) { zip in
                        HStack {
                            Text(zip.deletingPathExtension().lastPathComponent).font(.caption.monospaced())
                            Spacer()
                            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Models

    private var modelsBox: some View {
        GroupBox("2 · Models") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add the best.pt you trained. It's converted for the app (CoreML, 960, no NMS) and kept with this dataset.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    chooseModel()
                } label: { Label("Add Model…", systemImage: "plus") }
                .disabled(library.isBusy)

                ForEach(library.models) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.url == nil ? "iphone" : "cpu")
                            .foregroundStyle(.secondary).frame(width: 16)
                        Text(entry.name).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        if library.sampler.prelabelModel == entry.url {
                            Text("pre-labels").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                        }
                    }
                    .contextMenu {
                        Button("Use for Pre-labels") { library.sampler.prelabelModel = entry.url }
                        if let url = entry.url {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button("Remove", role: .destructive) { library.remove(entry) }
                        }
                    }
                }

                Picker("Pre-label with", selection: Binding(
                    get: { library.models.first { $0.url == library.sampler.prelabelModel } ?? library.models[0] },
                    set: { library.sampler.prelabelModel = $0.url }
                )) {
                    ForEach(library.models) { Text($0.name).tag($0) }
                }
                .font(.caption)
                Text("Applies to clips sampled from now on. A better model means fewer boxes to fix.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pt") ?? .data,
                                     UTType(filenameExtension: "mlpackage") ?? .package,
                                     UTType(filenameExtension: "mlmodel") ?? .data]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add"
        panel.message = "runs/ball/weights/best.pt from your training run, or a .mlpackage."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await library.addModel(url) }
    }

    // MARK: - Evaluation

    private var evaluationColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3 · Evaluate").font(.headline)
            HStack(spacing: 12) {
                Picker("Baseline", selection: $library.baseline) {
                    ForEach(library.models) { Text($0.name).tag($0) }
                }
                .frame(maxWidth: 280)
                Picker("Candidate", selection: $library.candidate) {
                    Text("None").tag(ModelEntry?.none)
                    ForEach(library.models) { Text($0.name).tag(Optional($0)) }
                }
                .frame(maxWidth: 280)
            }
            .font(.caption)
            HStack(spacing: 12) {
                Picker("", selection: $library.evaluateValOnly) {
                    Text("Val clips").tag(true)
                    Text("All reviewed").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Toggle("Letterbox every frame", isOn: $library.alwaysLetterbox)
                    .toggleStyle(.checkbox).font(.caption)
                    .help("Off: frames go into the model the way the app does it (landscape stretched, portrait letterboxed). On: every frame letterboxed, as Ultralytics trains and validates.")
                Text("\(library.evaluationFrameCount) frames").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    library.evaluate()
                } label: { Label("Run Evaluation", systemImage: "gauge.with.dots.needle.67percent") }
                .disabled(library.isBusy)
                if let p = library.evalProgress {
                    ProgressView().controlSize(.small)
                    Text(p).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("confidence").font(.caption).frame(width: 70, alignment: .leading)
                Slider(value: $library.threshold, in: 0.05...0.95, step: 0.05)
                Text(String(format: "%.2f", library.threshold)).font(.caption.monospaced()).frame(width: 36)
            }
            Text("0.70 is what the app's pipeline uses. A box counts when it overlaps the true box (IoU ≥ 0.3) or its centre lands on the ball.")
                .font(.caption2).foregroundStyle(.secondary)

            if library.results.isEmpty {
                ContentUnavailableView(
                    "No Scores Yet",
                    systemImage: "gauge.with.dots.needle.bottom.50percent",
                    description: Text("Review some frames in val clips, pick a candidate model, and run the evaluation.")
                )
                .frame(maxHeight: .infinity)
            } else {
                scoreTable
                Divider()
                errorGallery
            }
        }
        .padding(14)
    }

    private var scoredModels: [(ModelEntry, ModelEvaluation.Result)] {
        ([library.baseline] + (library.candidate.map { [$0] } ?? []))
            .compactMap { entry in library.results[entry.id].map { (entry, $0) } }
    }

    private var scoreTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(["Model", "Where", "Precision", "Recall", "F1", "Found", "False alarms", "Missed"], id: \.self) {
                    Text($0).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            ForEach(scoredModels, id: \.0.id) { entry, result in
                let score = result.score(at: library.threshold)
                row(entry.name, "All", score.all, bold: true)
                ForEach(score.byEnv, id: \.0) { env, counts in
                    row("", env, counts, bold: false)
                }
            }
        }
        .font(.caption.monospacedDigit())
    }

    @ViewBuilder
    private func row(_ model: String, _ scope: String, _ c: ModelEvaluation.Result.Counts, bold: Bool) -> some View {
        GridRow {
            Text(model).lineLimit(1).fontWeight(bold ? .semibold : .regular)
            Text(scope)
            Text(percent(c.precision))
            Text(percent(c.recall))
            Text(percent(c.f1)).fontWeight(bold ? .semibold : .regular)
            Text("\(c.tp)")
            Text("\(c.fp)")
            Text("\(c.fn)")
        }
    }

    private func percent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

    /// The candidate's mistakes (or the baseline's, when there's no candidate).
    private var galleryModel: (ModelEntry, ModelEvaluation.Result)? {
        scoredModels.last
    }

    @ViewBuilder
    private var errorGallery: some View {
        if let (entry, result) = galleryModel {
            let errors = result.score(at: library.threshold).errors
            let missed = errors.filter { $0.kind == .missed }
            let alarms = errors.filter { $0.kind == .falseAlarm }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Mistakes by \(entry.name)").font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("", selection: $errorFilter) {
                        Text("Missed balls (\(missed.count))").tag(ModelEvaluation.Result.ErrorKind.missed)
                        Text("False alarms (\(alarms.count))").tag(ModelEvaluation.Result.ErrorKind.falseAlarm)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Text("Click one to open the frame in the Sampler — a wrong label is fixed there, and a real miss is what the next round of footage should target.")
                    .font(.caption2).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(errorFilter == .missed ? missed : alarms) { error in
                            ErrorCrop(error: error)
                                .onTapGesture { showFrame(error.frame.session, error.frame.record.id) }
                        }
                    }
                }
            }
        }
    }
}

/// A close crop around a mistake: the ball it missed (red) or what it
/// wrongly called a ball (orange), with the clip and confidence.
private struct ErrorCrop: View {
    let error: ModelEvaluation.Result.ErrorCase
    @State private var crop: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                Color.black
                if let crop {
                    Image(decorative: crop, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(error.kind == .missed ? Color.red : Color.orange, lineWidth: 2)
                        .frame(width: 150 / 5, height: 150 / 5)
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(error.frame.session).font(.system(size: 9, design: .monospaced)).lineLimit(1)
            Text(error.confidence.map { String(format: "conf %.2f", $0) } ?? "no detection")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(width: 150)
        .task { crop = Self.makeCrop(error) }
    }

    /// Five box-widths of context (at least 6% of the frame) around the box,
    /// so the box outline drawn at 1/5 of the tile lines up with it.
    static func makeCrop(_ error: ModelEvaluation.Result.ErrorCase) -> CGImage? {
        guard let image = SamplerImageTools.loadImage(error.frame.image, maxPixelSize: 2400) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let side = max(max(error.rect.width * w, error.rect.height * h) * 5, 0.06 * max(w, h))
        let cx = error.rect.midX * w, cy = (1 - error.rect.midY) * h
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
        return image.cropping(to: rect.integral)
    }
}
