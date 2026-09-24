//
//  SamplerTabView.swift
//  RallyLab
//
//  Ingest → review → train. Left: the dataset's videos and the ingest queue.
//  Centre: the selected frame at review size with its boxes (drag on empty
//  space to draw one, drag a box to move it, drag a corner to resize, Delete
//  to remove) above a filmstrip. Right: sampling settings for new videos,
//  the label policy, and the training hand-off. The whole tab is a drop
//  target for videos and folders.
//

import AppKit
import SwiftUI

struct SamplerTabView: View {
    @Bindable var lab: RallyLabModel
    @Bindable var sampler: SamplerModel
    @State private var isDropTargeted = false

    var body: some View {
        HSplitView {
            librarySidebar
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
            mainColumn
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            controls
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 400)
        }
        .background(
            SamplerDropView(
                onDrop: { sampler.enqueue($0) },
                onStatus: { sampler.note($0) }
            )
        )
        .background(shortcuts)
    }

    // MARK: - Library (left)

    private var librarySidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Dataset").font(.headline)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([sampler.datasetRoot])
                } label: { Image(systemName: "folder") }
                .buttonStyle(.plain)
                .help(sampler.datasetRoot.path)
            }
            Text(sampler.datasetRoot.path)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)

            HStack(spacing: 8) {
                Button {
                    chooseInputs()
                } label: { Label("Add…", systemImage: "plus") }
                Button("Change Folder…") { chooseDatasetRoot() }
                    .controlSize(.small)
            }

            dropHint

            if !sampler.queue.isEmpty {
                queueList
            }

            Divider()
            HStack {
                Text("Videos (\(sampler.sessions.count))").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(sampler.stats.reviewed)/\(sampler.stats.frames) reviewed")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            sessionList
        }
        .padding(12)
    }

    private var dropHint: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.down.doc").font(.title3)
            Text("Drop videos from Photos or Finder,\nor folders of frames")
                .font(.caption2).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.quaternary))
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Queue").font(.subheadline.weight(.semibold))
                if sampler.isIngesting { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Clear done") { sampler.clearFinishedJobs() }
                    .controlSize(.mini)
                    .disabled(!sampler.queue.contains(where: \.isFinished))
            }
            ForEach(sampler.queue) { job in
                HStack(spacing: 6) {
                    Image(systemName: jobIcon(job))
                        .foregroundStyle(jobColor(job))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.url.lastPathComponent).font(.caption).lineLimit(1)
                        Text(jobText(job)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func jobIcon(_ job: IngestJob) -> String {
        switch job.state {
        case .pending: return "clock"
        case .running: return "gearshape.2"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func jobColor(_ job: IngestJob) -> Color {
        switch job.state {
        case .pending: return .secondary
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .red
        }
    }

    private func jobText(_ job: IngestJob) -> String {
        switch job.state {
        case .pending: return job.kind == .video ? "waiting" : "waiting (frames folder)"
        case .running(let t), .done(let t), .failed(let t): return t
        }
    }

    private var sessionList: some View {
        List(selection: Binding(
            get: { sampler.currentSession?.name },
            set: { name in
                if let name, let s = sampler.sessions.first(where: { $0.name == name }) { sampler.openSession(s) }
            }
        )) {
            ForEach(sampler.sessions) { session in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.name).font(.caption).lineLimit(1)
                        Text("\(session.reviewedCount)/\(session.frames.count) reviewed · \(session.boxCount) boxes")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(session.split)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(session.split == "val" ? Color.orange.opacity(0.25) : Color.gray.opacity(0.2), in: Capsule())
                }
                .tag(session.name)
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([sampler.datasetRoot.appendingPathComponent("sessions/\(session.name).json")])
                    }
                    Button("Remove from Dataset", role: .destructive) { sampler.deleteSession(session) }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minHeight: 120)
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(spacing: 10) {
            if sampler.currentSession != nil {
                reviewToolbar
            }
            Group {
                if let sample = sampler.selected {
                    ReviewCanvas(sampler: sampler, sample: sample)
                } else if sampler.isLoadingSession {
                    ContentUnavailableView("Loading frames…", systemImage: "photo.on.rectangle.angled")
                } else if let session = sampler.currentSession {
                    ContentUnavailableView(
                        "Nothing to show",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("\(session.name) has no frames matching “\(sampler.filter.rawValue)”.")
                    )
                } else if sampler.sessions.isEmpty {
                    ContentUnavailableView(
                        "Empty Dataset",
                        systemImage: "photo.stack",
                        description: Text("Drop a video from Photos or Finder — or a folder of frames — anywhere on this tab. The pipeline finds the rallies, frames are pulled and pre-labeled, and they show up here to review.")
                    )
                } else {
                    ContentUnavailableView(
                        "Pick a Video",
                        systemImage: "photo.stack",
                        description: Text("Choose a video on the left to review its frames.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !sampler.samples.isEmpty {
                filmstrip
            }
            Text(sampler.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    private var reviewToolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $sampler.filter) {
                ForEach(ReviewFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            Toggle("Lowest confidence first", isOn: $sampler.lowestConfidenceFirst)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            if let session = sampler.currentSession {
                Text("\(session.reviewedCount)/\(session.frames.count) reviewed")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 6) {
                    ForEach(sampler.visibleSamples) { s in
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

    // MARK: - Controls (right)

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Sampling (new videos)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bursts inside each rally (its hand labels when the video has them, else the pipeline's), the in-rally frames the pipeline saw no ball in, and random frames across the video. Near-identical bursts are dropped.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        labeledSlider("burst fps", value: $sampler.burstFPS, in: 1...30, step: 1, text: "\(Int(sampler.burstFPS))")
                        labeledSlider("padding s", value: $sampler.rallyPadding, in: 0...3, step: 0.25, text: String(format: "%.2f", sampler.rallyPadding))
                        Toggle(isOn: $sampler.includeMissed) { Text("frames the pipeline missed the ball in").font(.caption) }
                            .toggleStyle(.checkbox)
                        labeledSlider("max missed", value: $sampler.maxMissed, in: 0...300, step: 10, text: "\(Int(sampler.maxMissed))")
                            .disabled(!sampler.includeMissed)
                        labeledSlider("random", value: $sampler.randomCount, in: 0...300, step: 10, text: "\(Int(sampler.randomCount))")
                        labeledSlider("dedupe", value: $sampler.duplicateThreshold, in: 0...16, step: 1, text: "\(Int(sampler.duplicateThreshold))")
                            .help("Perceptual-hash distance under which a burst frame counts as a repeat of the previous one. 0 keeps everything.")
                        labeledSlider("pre-label", value: $sampler.prelabelConfidence, in: 0.05...0.9, step: 0.05, text: String(format: "%.2f", sampler.prelabelConfidence))
                            .help("Detector threshold for the boxes every frame starts with. Low on purpose: its doubtful calls are what you're here to confirm or delete.")
                        Toggle(isOn: $sampler.preferHandLabels) { Text("prefer a video's hand labels").font(.caption) }
                            .toggleStyle(.checkbox)
                    }
                    .padding(4)
                }

                GroupBox("Dataset") {
                    VStack(alignment: .leading, spacing: 8) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            GridRow {
                                stat("videos", "\(sampler.stats.videos) (\(sampler.stats.valVideos) val)")
                                stat("frames", "\(sampler.stats.frames)")
                            }
                            GridRow {
                                stat("reviewed", "\(sampler.stats.reviewed)")
                                stat("boxes", "\(sampler.stats.boxes)")
                            }
                        }
                        labeledSlider("val videos", value: $sampler.validationFraction, in: 0...0.5, step: 0.05, text: String(format: "%.0f%%", sampler.validationFraction * 100))
                            .help("Share of videos assigned to validation as they're added. Whole videos, never frames.")
                        Toggle(isOn: $sampler.reviewedOnly) { Text("only reviewed frames get labels").font(.caption) }
                            .toggleStyle(.checkbox)
                            .help("Unreviewed frames are parked out of images/ so the trainer never learns from the detector's own guesses.")
                        Button {
                            sampler.writeDataset()
                        } label: { Label("Write Labels + data.yaml", systemImage: "square.and.arrow.down") }
                        .disabled(sampler.sessions.isEmpty || sampler.isIngesting)
                    }
                    .padding(4)
                }

                GroupBox("Train") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Copies the Ultralytics command for this dataset. Run it in Terminal; the run lands in <dataset>/runs/ball.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            Text("base").font(.caption).frame(width: 76, alignment: .leading)
                            TextField("yolo26s.pt", text: $sampler.trainBaseModel).font(.caption)
                        }
                        labeledSlider("imgsz", value: $sampler.trainImageSize, in: 640...1600, step: 64, text: "\(Int(sampler.trainImageSize))")
                        labeledSlider("epochs", value: $sampler.trainEpochs, in: 20...300, step: 10, text: "\(Int(sampler.trainEpochs))")
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sampler.trainCommand, forType: .string)
                            sampler.note("Train command copied.")
                        } label: { Label("Copy Train Command", systemImage: "doc.on.clipboard") }
                        Text(sampler.trainCommand)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                    .padding(4)
                }

                GroupBox("Review keys") {
                    VStack(alignment: .leading, spacing: 4) {
                        keyRow("← →", "previous / next frame")
                        keyRow("K", "keep / discard frame")
                        keyRow("Return", "accept frame, next")
                        keyRow("⌫", "delete selected box")
                        keyRow("drag", "draw · move · resize at a corner")
                    }
                    .padding(4)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    // MARK: - Panels

    private func chooseInputs() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .folder]
        panel.prompt = "Add"
        panel.message = "Videos, or folders of JPEG/PNG frames."
        guard panel.runModal() == .OK else { return }
        sampler.enqueue(panel.urls)
    }

    private func chooseDatasetRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use"
        panel.message = "The folder that holds the dataset (images/, labels/, data.yaml)."
        panel.directoryURL = sampler.datasetRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sampler.setDatasetRoot(url)
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
            Text(text).font(.system(.caption, design: .monospaced)).frame(width: 44, alignment: .trailing)
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
                Text(caption)
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

    private var caption: String {
        if case .file = sample.source {
            return (sample.file as NSString).lastPathComponent
        }
        return String(format: "%.1fs · %@", sample.time, sample.source.label)
    }

    private var sourceColor: Color {
        switch sample.source {
        case .rally: return .yellow
        case .missed: return .orange
        case .random: return .cyan
        case .file: return .purple
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
