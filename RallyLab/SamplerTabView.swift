//
//  SamplerTabView.swift
//  RallyLab
//
//  Import: drop videos (or folders of frames) anywhere on the tab, or
//  choose them; the pipeline finds their rallies and they show up in the
//  Label tab to track. The whole tab is a drop target.
//
//  Behind "Review Stills" is the single-frame YOLO review. Left: the
//  dataset's videos and the ingest queue. Centre: the selected frame at
//  review size with its boxes (drag on empty space to draw one, drag a box
//  to move it, drag a corner to resize, Delete to remove) above a
//  filmstrip. Right: sampling settings for new videos, the label policy,
//  and the training hand-off.
//

import AppKit
import SwiftUI

struct SamplerTabView: View {
    @Bindable var lab: RallyLabModel
    @Bindable var sampler: SamplerModel
    /// Whether this tab is showing; review keys only apply then.
    let isActive: Bool
    @State private var isDropTargeted = false
    @State private var keyMonitor: Any?
    /// The sampling / dataset / training column; out of the way while reviewing.
    @AppStorage("RallyLab.samplerSettings") private var showSettings = false
    @State private var showShortcuts = false
    /// Full screen with only the review: no video list, no settings.
    @State private var isFocused = false
    /// The stills review rather than the import page.
    @AppStorage(SamplerTabView.stillsKey) private var showStills = false
    @State private var showImportSettings = false

    static let stillsKey = "RallyLab.samplerStills"

    /// Open a video's frames in the stills review (from elsewhere, e.g. the
    /// Project board or the Models tab).
    @MainActor
    static func showStills(_ session: VideoSession, frame: UUID? = nil, in sampler: SamplerModel) {
        UserDefaults.standard.set(true, forKey: stillsKey)
        sampler.openSession(session, frame: frame)
    }

    var body: some View {
        Group {
            if showStills { stills } else { importPage }
        }
        .background(
            SamplerDropView(
                onDrop: { sampler.enqueue($0) },
                onStatus: { sampler.note($0) }
            )
        )
    }

    // MARK: - Import

    private var importPage: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("Drop videos to import").font(.title.bold())
                    Text("From Photos or Finder. RallyLab finds the rallies in each, and they show up in the Label tab to track.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button { chooseInputs() } label: { Label("Choose Videos…", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
                .background(RoundedRectangle(cornerRadius: 18).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .foregroundStyle(Color.accentColor.opacity(0.45)))
                .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))

                if !sampler.queue.isEmpty {
                    queueList
                        .padding(16)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14))
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(sampler.sessions.count) videos").font(.headline)
                        Text(sampler.datasetRoot.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Sampling…") { showImportSettings = true }
                        .popover(isPresented: $showImportSettings) { controls.frame(width: 340, height: 520) }
                    Button("Change Folder…") { chooseDatasetRoot() }
                    Button { showStills = true } label: { Label("Review Stills", systemImage: "photo.stack") }
                        .help("The single-frame YOLO review")
                }
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))

                Text(sampler.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(.background.secondary)
    }

    // MARK: - Stills

    private var stills: some View {
        HSplitView {
            if !isFocused {
                librarySidebar
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 330)
            }
            mainColumn
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            if showSettings && !isFocused {
                controls
                    .frame(minWidth: 300, idealWidth: 320, maxWidth: 400)
            }
        }
        // Leaving full screen any other way (the green button, ⌃⌘F) ends focus too.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFocused = false
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKey(event) ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    // MARK: - Library (left)

    private var librarySidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showStills = false } label: { Label("Import", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
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
                        if case .running(let stage) = job.state {
                            WorkProgressBar(stage: stage, overall: job.fraction).font(.caption2)
                        } else {
                            Text(jobText(job)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
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
                HStack(spacing: 9) {
                    ProgressRing(value: session.frames.isEmpty ? 0
                                 : Double(session.reviewedCount) / Double(session.frames.count))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Text("\(session.reviewedCount)/\(session.frames.count) reviewed · \(session.boxCount) boxes")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    SplitBadge(split: session.split)
                }
                .padding(.vertical, 2)
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
        VStack(spacing: 0) {
            if let session = sampler.currentSession {
                ReviewHeader(sampler: sampler, session: session,
                             showSettings: $showSettings, showShortcuts: $showShortcuts,
                             isFocused: isFocused, toggleFocus: { setFocus(!isFocused) })
                Divider()
            }
            stage
                .padding(.horizontal, 12).padding(.top, 12)
            if !sampler.samples.isEmpty {
                ReviewFilmstrip(sampler: sampler)
            }
            Text(sampler.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 8)
                .padding(.top, sampler.samples.isEmpty ? 8 : 0)
        }
    }

    /// The frame on a dark stage, with its tag, actions and the accept pulse.
    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(ReviewStyle.stage)
            Group {
                if let sample = sampler.selected {
                    ReviewCanvas(sampler: sampler, sample: sample)
                        .padding(.horizontal, 14).padding(.top, 52).padding(.bottom, 66)
                } else if sampler.isLoadingSession {
                    ProgressView("Loading frames…").controlSize(.large)
                } else if let session = sampler.currentSession {
                    placeholder("Nothing to show", "line.3.horizontal.decrease.circle",
                                "\(session.name) has no frames under this filter.")
                } else if sampler.sessions.isEmpty {
                    placeholder("Empty Dataset", "photo.stack",
                                "Drop a video from Photos or Finder — or a folder of frames — anywhere on this tab. The pipeline finds the rallies, frames are pulled and pre-labeled, and they show up here to review.")
                } else {
                    placeholder("Pick a Video", "photo.stack", "Choose a video on the left to review its frames.")
                }
            }
            AcceptPulse(count: sampler.acceptCount)
        }
        .overlay(alignment: .topLeading) {
            if let sample = sampler.selected {
                let list = sampler.visibleSamples
                FrameTag(sample: sample,
                         position: (list.firstIndex { $0.id == sample.id } ?? 0) + 1,
                         total: list.count)
                    .padding(12)
            }
        }
        .overlay(alignment: .top) {
            if !sampler.samples.isEmpty, sampler.count(.unreviewed) == 0 {
                VideoDoneBanner(sampler: sampler, total: sampler.samples.count)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let sample = sampler.selected {
                ReviewActionBar(sampler: sampler, sample: sample)
                    .padding(.bottom, 12)
            }
        }
        .animation(.easeOut(duration: 0.25), value: sampler.count(.unreviewed) == 0)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ title: String, _ icon: String, _ text: String) -> some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(text))
            .foregroundStyle(.secondary)
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

    /// Full-screen review: take the window full screen and hide everything
    /// but the frame, its header and the filmstrip (and back).
    private func setFocus(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { isFocused = on }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if on != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    /// Review keys. Handled ahead of whichever control has focus — the video
    /// list and the filmstrip would otherwise take the arrow keys — except
    /// while typing in a text field or in a sheet or panel.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard isActive, showStills, !sampler.samples.isEmpty,
              let window = event.window, window.isKeyWindow, window.sheetParent == nil,
              !(window is NSPanel), window.attachedSheet == nil,
              !(window.firstResponder is NSText) else { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // Arrows: ←/→ step through frames. Shift+arrows move the selected box,
        // Shift+Option+arrows resize it, a thousandth of the image a step —
        // about a pixel at review size.
        let arrows: [UInt16: (dx: CGFloat, dy: CGFloat)] = [
            123: (-0.001, 0), 124: (0.001, 0), 126: (0, -0.001), 125: (0, 0.001),
        ]
        if let step = arrows[event.keyCode] {
            switch mods {
            case []:
                guard step.dy == 0 else { return false }   // ↑/↓ stay with the video list
                sampler.selectNext(step.dx < 0 ? -1 : 1)
            case .shift: sampler.nudgeSelectedBox(dx: step.dx, dy: step.dy, resize: false)
            case [.shift, .option]: sampler.nudgeSelectedBox(dx: step.dx, dy: step.dy, resize: true)
            default: return false
            }
            return true
        }
        switch (event.keyCode, mods) {
        case (36, []), (76, []): sampler.acceptAndAdvance(); return true      // Return, Enter
        case (51, []), (117, []): sampler.removeSelectedBox(); return true    // Delete, ⌦
        case (53, []) where isFocused: setFocus(false); return true             // Esc
        default: break
        }
        if event.characters == "?" { showShortcuts.toggle(); return true }
        switch (event.charactersIgnoringModifiers?.lowercased(), mods) {
        case ("z", .command): sampler.undo()
        case ("k", []): sampler.toggleKeep()
        case ("n", []): sampler.markNoBallAndAdvance()
        case ("f", []): setFocus(!isFocused)
        case ("c", []): sampler.carryBoxesForward()
        case ("p", []): sampler.toggleContext()
        case ("=", []), ("+", []), ("+", .shift): sampler.zoom(by: 1.5)
        case ("-", []): sampler.zoom(by: 1 / 1.5)
        case ("0", []): sampler.resetZoom()
        case ("z", []): sampler.zoomToBox()
        default: return false
        }
        return true
    }

    private func labeledSlider(_ name: String, value: Binding<Double>, in range: ClosedRange<Double>,
                               step: Double, text: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).frame(width: 76, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(text).font(.system(.caption, design: .monospaced)).frame(width: 44, alignment: .trailing)
        }
    }

    private func stat(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}

private struct ProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3)
            Circle().trim(from: 0, to: value)
                .stroke(value >= 1 ? ReviewStyle.yours : Color.accentColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if value >= 1 {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(ReviewStyle.yours)
            }
        }
        .frame(width: 18, height: 18)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}
