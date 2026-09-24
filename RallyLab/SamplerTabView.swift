//
//  SamplerTabView.swift
//  RallyLab
//
//  Sample → review → export. Left: the selected frame at review size with
//  its boxes (drag on empty space to draw one, drag a box to move it, drag a
//  corner to resize, Delete to remove) above a grid of every sampled frame.
//  Right: what to sample, the pre-label threshold, and the export.
//

import AppKit
import SwiftUI

struct SamplerTabView: View {
    @Bindable var lab: RallyLabModel
    @Bindable var sampler: SamplerModel

    var body: some View {
        HSplitView {
            mainColumn
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            controls
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
        }
        .onChange(of: lab.videoURL) { _, _ in sampler.reset() }
        .background(shortcuts)
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(spacing: 10) {
            Group {
                if lab.videoURL == nil {
                    ContentUnavailableView(
                        "No Video",
                        systemImage: "film",
                        description: Text("Open a video in the Pipeline tab (or drag one in), run the pipeline, then Sample.")
                    )
                } else if sampler.samples.isEmpty {
                    ContentUnavailableView(
                        "No Frames Yet",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(sampler.isSampling ? sampler.status : "Press Sample to pull frames from the rallies and across the video.")
                    )
                } else if let sample = sampler.selected {
                    ReviewCanvas(sampler: sampler, sample: sample)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !sampler.samples.isEmpty {
                grid
            }
            Text(sampler.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 6) {
                    ForEach(sampler.samples) { s in
                        SampleThumb(sample: s, isSelected: s.id == sampler.selectedId)
                            .id(s.id)
                            .onTapGesture { sampler.select(s.id) }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 120)
            .onChange(of: sampler.selectedId) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Sources") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sourceSummary)
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Toggle(isOn: $sampler.preferHandLabels) {
                            Text("prefer hand labels over predictions").font(.caption)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(lab.labels.isEmpty)
                        labeledSlider("burst fps", value: $sampler.burstFPS, in: 1...30, step: 1,
                                      text: "\(Int(sampler.burstFPS))")
                        labeledSlider("padding s", value: $sampler.rallyPadding, in: 0...3, step: 0.25,
                                      text: String(format: "%.2f", sampler.rallyPadding))
                        Toggle(isOn: $sampler.includeMissed) {
                            Text("frames inside rallies with no ball seen").font(.caption)
                        }
                        .toggleStyle(.checkbox)
                        .help("The pipeline ran the detector at its production threshold and saw nothing here — either the ball is hard to see or it's genuinely gone. Both are worth a label.")
                        labeledSlider("max missed", value: $sampler.maxMissed, in: 0...300, step: 10,
                                      text: "\(Int(sampler.maxMissed))")
                            .disabled(!sampler.includeMissed)
                        labeledSlider("random", value: $sampler.randomCount, in: 0...300, step: 10,
                                      text: "\(Int(sampler.randomCount))")
                            .help("Frames anywhere in the video: negatives (no ball), warm-ups, timeouts — the variety that keeps the detector honest.")
                    }
                    .padding(4)
                }

                GroupBox("Pre-label") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Every frame gets the shipping detector's boxes at this threshold. Low on purpose — its doubtful calls are what you're here to confirm or delete.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        labeledSlider("confidence", value: $sampler.prelabelConfidence, in: 0.05...0.9, step: 0.05,
                                      text: String(format: "%.2f", sampler.prelabelConfidence))
                        HStack {
                            Button {
                                Task { await sampler.sample(from: lab) }
                            } label: {
                                Label("Sample", systemImage: "wand.and.stars")
                            }
                            .disabled(lab.videoURL == nil || sampler.isSampling || lab.isProcessing)
                            if sampler.isSampling { ProgressView().controlSize(.small) }
                        }
                    }
                    .padding(4)
                }

                if !sampler.samples.isEmpty {
                    GroupBox("Review") {
                        VStack(alignment: .leading, spacing: 6) {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                                GridRow {
                                    stat("frames", "\(sampler.samples.count)")
                                    stat("kept", "\(sampler.keptCount)")
                                }
                                GridRow {
                                    stat("reviewed", "\(sampler.reviewedCount)")
                                    stat("boxes", "\(sampler.boxCount)")
                                }
                            }
                            Divider()
                            keyRow("← →", "previous / next frame")
                            keyRow("K", "keep / discard frame")
                            keyRow("Return", "accept frame, next")
                            keyRow("⌫", "delete selected box")
                            keyRow("drag", "draw a box · move a box · resize at a corner")
                        }
                        .padding(4)
                    }

                    GroupBox("Export") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Kept frames at native resolution, YOLO labels (class 0 = volleyball), data.yaml and a manifest. A folder named after the video is created inside the one you pick.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            labeledSlider("val split", value: $sampler.validationFraction, in: 0...0.5, step: 0.05,
                                          text: String(format: "%.0f%%", sampler.validationFraction * 100))
                            HStack {
                                Button {
                                    chooseExportFolder()
                                } label: {
                                    Label("Export Dataset…", systemImage: "square.and.arrow.up")
                                }
                                .disabled(sampler.keptCount == 0 || sampler.isExporting || sampler.isSampling)
                                if sampler.isExporting { ProgressView().controlSize(.small) }
                            }
                            if let done = sampler.lastExport {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([done.directory])
                                } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }
                                .buttonStyle(.link)
                            }
                        }
                        .padding(4)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    private var sourceSummary: String {
        let usingLabels = sampler.preferHandLabels && !lab.labels.isEmpty
        let count = usingLabels ? lab.labels.count : lab.rawPredictions.count
        if count == 0 {
            return "No rally windows yet — run the pipeline or mark rallies in the Pipeline tab. Random frames still work."
        }
        return "Bursting \(count) \(usingLabels ? "hand-labeled" : "predicted") rall\(count == 1 ? "y" : "ies")."
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Pick the folder to hold the dataset."
        guard panel.runModal() == .OK, let root = panel.url else { return }
        let name = lab.videoURL?.deletingPathExtension().lastPathComponent ?? "video"
        Task { _ = await sampler.export(to: root, videoName: name) }
    }

    /// Keyboard shortcuts hang on invisible buttons so they work wherever
    /// focus is (SwiftUI on macOS has no view-level key handling worth using).
    private var shortcuts: some View {
        Group {
            Button("") { sampler.selectNext(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { sampler.selectNext(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { sampler.toggleKeep() }.keyboardShortcut("k", modifiers: [])
            Button("") { sampler.acceptAndAdvance() }.keyboardShortcut(.return, modifiers: [])
            Button("") { sampler.removeSelectedBox() }.keyboardShortcut(.delete, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(sampler.samples.isEmpty)
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

    private func keyRow(_ key: String, _ what: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                .frame(width: 52, alignment: .leading)
            Text(what).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Thumbnail

private struct SampleThumb: View {
    let sample: FrameSample
    let isSelected: Bool

    var body: some View {
        Canvas { ctx, size in
            let imgSize = CGSize(width: sample.thumbnail.width, height: sample.thumbnail.height)
            let fit = OverlayGeometry.fittedRect(content: imgSize, in: size)
            ctx.draw(Image(decorative: sample.thumbnail, scale: 1, orientation: .up), in: fit)
            for box in sample.boxes {
                ctx.stroke(Path(OverlayGeometry.rect(box.rect, turns: 0, in: fit)),
                           with: .color(box.confidence == nil ? .green : .yellow), lineWidth: 1.5)
            }
            if !sample.keep {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.6)))
            }
        }
        .frame(width: 168, height: 100)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 3) {
                Circle().fill(sourceColor).frame(width: 6, height: 6)
                Text(String(format: "%.1fs · %@", sample.time, sample.source.label))
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(.black.opacity(0.55))
            .foregroundStyle(.white)
            .padding(3)
        }
        .overlay(alignment: .topTrailing) {
            if sample.reviewed {
                Image(systemName: sample.keep ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(sample.keep ? .green : .red)
                    .padding(3)
            }
        }
        .opacity(sample.keep ? 1 : 0.6)
    }

    private var sourceColor: Color {
        switch sample.source {
        case .rally: return .yellow
        case .missed: return .orange
        case .random: return .cyan
        }
    }
}

// MARK: - Review canvas

/// The selected frame with editable boxes. All hit-testing happens in the
/// fitted image rect; boxes stay Vision-normalized in the model.
private struct ReviewCanvas: View {
    @Bindable var sampler: SamplerModel
    let sample: FrameSample

    private enum Drag {
        case draw(origin: CGPoint)
        case move(boxId: UUID, original: CGRect, start: CGPoint)
        case resize(boxId: UUID, original: CGRect, anchor: CGPoint)
    }
    @State private var drag: Drag?
    @State private var liveRect: CGRect?
    private let handleRadius: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let image = sampler.preview ?? sample.thumbnail
            let imgSize = CGSize(width: image.width, height: image.height)
            let fit = OverlayGeometry.fittedRect(content: imgSize, in: geo.size)

            Canvas { ctx, _ in
                ctx.draw(Image(decorative: image, scale: 1, orientation: .up), in: fit)
                for box in sample.boxes {
                    let isSelected = box.id == sampler.selectedBoxId
                    let screen = (isSelected && drag != nil) ? (liveRect ?? OverlayGeometry.rect(box.rect, turns: 0, in: fit))
                                                             : OverlayGeometry.rect(box.rect, turns: 0, in: fit)
                    let color: Color = box.confidence == nil ? .green : .yellow
                    ctx.stroke(Path(screen), with: .color(color), lineWidth: isSelected ? 3 : 2)
                    if isSelected {
                        for corner in corners(of: screen) {
                            ctx.fill(Path(ellipseIn: CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8)), with: .color(color))
                        }
                    }
                    if let c = box.confidence {
                        ctx.draw(Text(String(format: "%.2f", c)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.black),
                                 at: CGPoint(x: screen.minX + 14, y: screen.minY - 7))
                    }
                }
                if case .draw = drag, let live = liveRect {
                    ctx.stroke(Path(live), with: .color(.green), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
                if !sample.keep {
                    ctx.fill(Path(fit), with: .color(.black.opacity(0.5)))
                    ctx.draw(Text("DISCARDED — K to keep").font(.headline).foregroundStyle(.white), at: CGPoint(x: fit.midX, y: fit.midY))
                }
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .gesture(dragGesture(fit: fit))
        }
    }

    private func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func dragGesture(fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil { drag = beginDrag(at: value.startLocation, fit: fit) }
                guard let drag else { return }
                switch drag {
                case .draw(let origin):
                    liveRect = CGRect(x: min(origin.x, value.location.x), y: min(origin.y, value.location.y),
                                      width: abs(value.location.x - origin.x), height: abs(value.location.y - origin.y))
                case .move(_, let original, let start):
                    liveRect = original.offsetBy(dx: value.location.x - start.x, dy: value.location.y - start.y)
                case .resize(_, _, let anchor):
                    liveRect = CGRect(x: min(anchor.x, value.location.x), y: min(anchor.y, value.location.y),
                                      width: abs(value.location.x - anchor.x), height: abs(value.location.y - anchor.y))
                }
            }
            .onEnded { _ in
                defer { drag = nil; liveRect = nil }
                guard let drag, let live = liveRect else { return }
                let normalized = normalize(live, in: fit)
                switch drag {
                case .draw:
                    if live.width > 4, live.height > 4 { sampler.addBox(normalized) }
                case .move(let boxId, _, _), .resize(let boxId, _, _):
                    sampler.updateBox(boxId, rect: normalized)
                }
            }
    }

    /// Corner handle of the selected box → resize; inside any box → move
    /// (and select it); empty space → draw.
    private func beginDrag(at p: CGPoint, fit: CGRect) -> Drag {
        if let selectedId = sampler.selectedBoxId,
           let box = sample.boxes.first(where: { $0.id == selectedId }) {
            let screen = OverlayGeometry.rect(box.rect, turns: 0, in: fit)
            for corner in corners(of: screen) where hypot(corner.x - p.x, corner.y - p.y) <= handleRadius {
                let anchor = CGPoint(x: corner.x == screen.minX ? screen.maxX : screen.minX,
                                     y: corner.y == screen.minY ? screen.maxY : screen.minY)
                return .resize(boxId: box.id, original: screen, anchor: anchor)
            }
        }
        // Smallest box under the cursor wins, so a ball inside a bigger
        // mistaken box is still reachable.
        let hit = sample.boxes
            .map { ($0, OverlayGeometry.rect($0.rect, turns: 0, in: fit)) }
            .filter { $0.1.insetBy(dx: -4, dy: -4).contains(p) }
            .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
        if let (box, screen) = hit {
            sampler.selectedBoxId = box.id
            return .move(boxId: box.id, original: screen, start: p)
        }
        sampler.selectedBoxId = nil
        return .draw(origin: p)
    }

    /// Screen rect inside `fit` → Vision-normalized (origin bottom-left).
    private func normalize(_ r: CGRect, in fit: CGRect) -> CGRect {
        let x = (r.minX - fit.minX) / fit.width
        let w = r.width / fit.width
        let yTop = (r.minY - fit.minY) / fit.height
        let h = r.height / fit.height
        return CGRect(x: x, y: 1 - yTop - h, width: w, height: h)
    }
}
