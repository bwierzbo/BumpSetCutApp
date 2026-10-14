//
//  PipelineRunView.swift
//  Labeler
//
//  Process a video the way BumpSetCut does, on the phone: pick it from
//  Photos, say where it was filmed from, and run the app's own pipeline
//  (ProcessorConfig's defaults with the camera rules, BallFinder.current).
//  The rallies it cut are listed; Export Debug Video then draws what the
//  pipeline saw over the whole video (PipelineVideo) — detections, the
//  ball's trail, the net, the gate's readout, the rally bar — to share or
//  save. Nothing is uploaded or labeled. Videos tab → Process.
//

import AVFoundation
import PhotosUI
import SwiftUI

struct PipelineRunView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var run = PipelineRun()
    @State private var pick: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $pick, matching: .videos, preferredItemEncoding: .current) {
                        Label(run.source == nil ? "Choose a video" : "Choose another video", systemImage: "photo.on.rectangle")
                    }
                    .disabled(run.busy)
                    if run.loading { ProgressView("Loading…") }
                    if let name = run.name {
                        LabeledContent("Video", value: name)
                        LabeledContent("Length", value: clockText(run.duration))
                    }
                } footer: {
                    Text("Runs BumpSetCut's own pipeline with the app's settings (\(BallFinder.current.title)).")
                }

                Section("Filmed from") {
                    Picker("Position", selection: $run.zone) {
                        ForEach(CameraZone.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Height", selection: $run.height) {
                        Text("Raised").tag(CameraHeight.raised)
                        Text("Ground").tag(CameraHeight.ground)
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(run.busy)

                Section {
                    switch run.phase {
                    case .idle:
                        Button { run.process() } label: { Label("Process", systemImage: "wand.and.rays") }
                            .disabled(run.source == nil)
                    case .processing(let processor):
                        ProgressView(value: processor.progress) { Text("Processing… \(Int(processor.progress * 100))%") }
                        Button("Cancel", role: .destructive) { run.cancel() }
                    case .processed(let result), .rendered(let result, _):
                        LabeledContent("Rallies", value: "\(result.segments.count)")
                        ForEach(Array(result.segments.enumerated()), id: \.offset) { n, s in
                            Text("\(n + 1). \(clockText(s.startTime))–\(clockText(s.endTime))")
                                .font(.callout.monospacedDigit())
                        }
                        Button { run.process() } label: { Label("Process again", systemImage: "arrow.clockwise") }
                    case .rendering(_, let fraction):
                        ProgressView(value: fraction) { Text("Drawing the debug video… \(Int(fraction * 100))%") }
                        Button("Cancel", role: .destructive) { run.cancel() }
                    }
                }

                if let result = run.phase.result {
                    Section {
                        if case .rendered(_, let video) = run.phase {
                            ShareLink(item: video) { Label("Share or save the debug video", systemImage: "square.and.arrow.up") }
                        }
                        Button { run.render(result) } label: {
                            Label("Export Debug Video", systemImage: "ladybug")
                        }
                    } footer: {
                        Text("The whole video with what the pipeline saw drawn on: balls found (cyan multi-frame, yellow YOLO, grey off-court) with confidence, the ball's trail (green while it's in flight), the net, the gate's readout, and a bar while it's in a rally.")
                    }
                }

                if let failure = run.failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Process")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: pick) { _, item in run.load(item) }
            .onDisappear { run.discard() }
        }
        .interactiveDismissDisabled(run.busy)
    }
}

/// One video through the pipeline, then optionally drawn.
@MainActor @Observable
final class PipelineRun {
    struct Result {
        let evidence: [VideoProcessor.FrameEvidence]
        let segments: [RallySegment]
        let duration: Double
    }

    enum Phase {
        case idle
        case processing(VideoProcessor)
        case processed(Result)
        case rendering(Result, Double)
        case rendered(Result, URL)

        var result: Result? {
            switch self {
            case .processed(let r), .rendered(let r, _): return r
            case .idle, .processing, .rendering: return nil
            }
        }
    }

    private(set) var source: URL?
    /// Kept for the loaded video: processing it again after a cancel resumes
    /// from the pipeline's checkpoint.
    @ObservationIgnored private var videoId = UUID()
    private(set) var name: String?
    private(set) var duration = 0.0
    private(set) var loading = false
    private(set) var phase = Phase.idle
    private(set) var failure: String?
    var zone = CameraZone.endline { didSet { if zone != oldValue { reset() } } }
    var height = CameraHeight.raised { didSet { if height != oldValue { reset() } } }
    @ObservationIgnored private var work: Task<Void, Never>?

    var busy: Bool {
        switch phase {
        case .processing, .rendering: return true
        case .idle, .processed, .rendered: return loading
        }
    }

    func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loading = true
        failure = nil
        Task {
            defer { loading = false }
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                discard()
                source = movie.url
                name = movie.name
                videoId = UUID()
                duration = try await AVURLAsset(url: movie.url).load(.duration).seconds
            } catch {
                failure = "Couldn't load that video: \(error.localizedDescription)"
            }
        }
    }

    func process() {
        guard let source, !busy else { return }
        removeRender()
        failure = nil
        var config = ProcessorConfig()
        config.applyCamera(CameraSetup(position: zone.presetPosition, height: height))
        let processor = VideoProcessor()
        processor.config = config
        processor.collectFrameEvidence = true
        phase = .processing(processor)
        UIApplication.shared.isIdleTimerDisabled = true
        work = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            var segments: [RallySegment] = []
            do {
                segments = try await processor.processVideo(source, videoId: videoId).rallySegments
            } catch ProcessingError.noRalliesDetected {
                // No rallies is still worth drawing: the evidence is all there.
            } catch {
                phase = .idle
                if !(error is CancellationError) { failure = "Processing failed: \(error.localizedDescription)" }
                return
            }
            guard !Task.isCancelled else { phase = .idle; return }
            phase = .processed(Result(evidence: processor.frameEvidence, segments: segments,
                                      duration: processor.lastVideoDurationSec > 0 ? processor.lastVideoDurationSec : duration))
        }
    }

    func render(_ result: Result) {
        guard let source, let name, !busy else { return }
        removeRender()
        failure = nil
        phase = .rendering(result, 0)
        UIApplication.shared.isIdleTimerDisabled = true
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-debug.mp4")
        work = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let outcome = await PipelineVideo.render(
                evidence: result.evidence, clips: result.segments.map { Interval(start: $0.startTime, end: $0.endTime) },
                video: source, from: 0, length: result.duration + 1,
                title: "\(name) · BumpSetCut pipeline (\(BallFinder.current.title))", to: output) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .rendering(let r, _) = self.phase else { return }
                        self.phase = .rendering(r, fraction)
                    }
                }
            switch outcome {
            case .success(let url):
                phase = .rendered(result, url)
            case .failure(let f):
                phase = .processed(result)
                if !Task.isCancelled { failure = "Debug video failed: \(f.message)" }
            }
        }
    }

    func cancel() {
        work?.cancel()
    }

    /// A new camera setting makes the run stale: process again.
    private func reset() {
        guard !busy else { return }
        removeRender()
        phase = .idle
    }

    private func removeRender() {
        if case .rendered(_, let url) = phase { try? FileManager.default.removeItem(at: url) }
    }

    /// The copied video and any render, when leaving or picking another.
    func discard() {
        cancel()
        removeRender()
        if let source {
            try? FileManager.default.removeItem(at: source)
            ProcessingCheckpoint.delete(at: MetadataStore.shared.processingCheckpointFileURL(for: videoId))
        }
        source = nil
        name = nil
        phase = .idle
    }
}
