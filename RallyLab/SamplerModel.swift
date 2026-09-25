//
//  SamplerModel.swift
//  RallyLab
//
//  Turns videos into detector training data with as little clicking as
//  possible. Drop videos (Photos or Finder) or folders of stills onto the
//  Sampler tab and they queue up: the pipeline finds the rallies, bursts of
//  stills are pulled from those windows plus the in-rally frames the
//  pipeline saw no ball in (the misses — most valuable) and random frames
//  across the video, near-duplicates are dropped, the shipping detector
//  pre-labels every frame at a low threshold, and everything lands in one
//  persistent dataset (see DatasetStore). Review edits write straight back
//  to that dataset, so quitting loses nothing.
//

import AVFoundation
import CoreGraphics
import Foundation
import Observation

// MARK: - Types

struct SampleBox: Identifiable, Equatable {
    let id: UUID
    /// Vision-normalized, origin bottom-left, [0,1] — what the detector emits
    /// and what OverlayGeometry draws.
    var rect: CGRect
    /// nil for a box drawn by hand.
    var confidence: Float?

    init(rect: CGRect, confidence: Float?) {
        id = UUID()
        self.rect = rect
        self.confidence = confidence
    }

    init(_ record: BoxRecord) {
        self.init(rect: record.rect, confidence: record.confidence)
    }
}

struct FrameSample: Identifiable {
    enum Source: Equatable {
        case rally(Int)
        /// Inside a rally, but the pipeline's detector saw no ball there.
        case missed
        /// Anywhere in the video.
        case random
        /// A still loaded from disk.
        case file

        var label: String {
            switch self {
            case .rally(let i): return "rally \(i + 1)"
            case .missed: return "missed"
            case .random: return "random"
            case .file: return "file"
            }
        }

        var key: String {
            switch self {
            case .rally(let i): return "rally:\(i)"
            case .missed: return "missed"
            case .random: return "random"
            case .file: return "file"
            }
        }

        init(key: String) {
            if key.hasPrefix("rally:"), let i = Int(key.dropFirst(6)) { self = .rally(i) }
            else if key == "missed" { self = .missed }
            else if key == "random" { self = .random }
            else { self = .file }
        }
    }

    let id: UUID
    /// Relative path inside the dataset.
    let file: String
    let time: Double
    let source: Source
    /// Small still for the grid; the full frame is re-read on demand.
    let thumbnail: CGImage
    var boxes: [SampleBox]
    var keep: Bool
    var reviewed: Bool

    /// The most doubtful box on the frame — what "lowest confidence first"
    /// sorts by. Hand-drawn boxes count as certain; no boxes as 1.
    var minConfidence: Float {
        boxes.compactMap(\.confidence).min() ?? 1
    }

    init(record: FrameRecord, thumbnail: CGImage) {
        id = record.id
        file = record.file
        time = record.time
        source = Source(key: record.source)
        self.thumbnail = thumbnail
        boxes = record.boxes.map(SampleBox.init)
        keep = record.keep
        reviewed = record.reviewed
    }

    var record: FrameRecord {
        FrameRecord(id: id, file: file, time: time, source: source.key,
                    boxes: boxes.map(BoxRecord.init), keep: keep, reviewed: reviewed)
    }
}

struct IngestJob: Identifiable, Equatable {
    enum Kind: Equatable { case video, folder }
    enum State: Equatable {
        case pending
        case running(String)
        case done(String)
        case failed(String)
    }
    let id = UUID()
    let url: URL
    let kind: Kind
    var state: State = .pending

    var isFinished: Bool {
        if case .done = state { return true }
        if case .failed = state { return true }
        return false
    }
}

enum ReviewFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unreviewed = "Unreviewed"
    case withBoxes = "Has ball"
    case noBoxes = "No ball"
    var id: String { rawValue }
}

// MARK: - Model

@MainActor
@Observable
final class SamplerModel {

    // Sampling (applies to videos ingested from now on)
    var burstFPS: Double = 8
    /// Seconds added before and after each rally window.
    var rallyPadding: Double = 0.5
    var includeMissed = true
    var maxMissed: Double = 60
    var randomCount: Double = 40
    /// Hand labels win when present; otherwise the pipeline's predictions.
    var preferHandLabels = true
    /// Hamming distance (0–64) below which a burst frame is the same picture
    /// as the previous kept one and is dropped. 0 disables.
    var duplicateThreshold: Double = 6

    // Pre-labeling
    /// Deliberately low: the point is to surface the detector's uncertain
    /// calls for a human to confirm or delete.
    var prelabelConfidence: Double = 0.25

    // Dataset
    var validationFraction: Double = 0.15
    /// Only reviewed frames get label files; the rest are parked until
    /// they've been looked at, so pre-labels never train the model.
    var reviewedOnly = true
    var jpegQuality: Double = 0.92
    var trainImageSize: Double = 1280
    var trainEpochs: Double = 120
    var trainBaseModel = "yolo26s.pt"

    private(set) var datasetRoot: URL
    private(set) var store: DatasetStore
    private(set) var sessions: [VideoSession] = []
    private(set) var stats = DatasetStats()

    // Ingest
    private(set) var queue: [IngestJob] = []
    private(set) var isIngesting = false
    private(set) var status = "Drop videos or folders of frames here to start."

    // Review
    private(set) var currentSession: VideoSession?
    private(set) var samples: [FrameSample] = []
    private(set) var isLoadingSession = false
    var filter: ReviewFilter = .all
    var lowestConfidenceFirst = false
    var selectedId: UUID?
    /// The selected frame at review resolution.
    private(set) var preview: CGImage?
    var selectedBoxId: UUID?

    private var previewTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    nonisolated static let thumbnailWidth = 320
    nonisolated static let reviewMaxPixel = 1600
    private static let rootKey = "RallyLab.datasetRoot"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.rootKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = saved ?? DatasetStore.defaultRoot
        datasetRoot = root
        store = DatasetStore(root: root)
        reloadSessions()
    }

    // MARK: - Dataset

    func setDatasetRoot(_ url: URL) {
        datasetRoot = url
        store = DatasetStore(root: url)
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        closeSession()
        reloadSessions()
        status = "Dataset: \(url.path)"
    }

    func reloadSessions() {
        sessions = store.loadSessions()
        stats = store.stats(sessions)
    }

    func deleteSession(_ session: VideoSession) {
        if currentSession?.name == session.name { closeSession() }
        try? store.remove(session)
        reloadSessions()
        status = "Removed \(session.name) from the dataset."
    }

    /// Rewrites every label file under the current policy and refreshes
    /// data.yaml — the one step before training.
    func writeDataset() {
        do {
            try store.prepare()
            var written = 0
            for session in sessions {
                for frame in session.frames {
                    try store.writeLabel(for: frame, reviewedOnly: reviewedOnly)
                    if frame.keep, !(reviewedOnly && !frame.reviewed) { written += 1 }
                }
            }
            try store.writeDataYAML()
            reloadSessions()
            status = "Wrote \(written) labels and data.yaml (\(reviewedOnly ? "reviewed frames only" : "every kept frame"))."
        } catch {
            status = "Couldn't write the dataset: \(error.localizedDescription)"
        }
    }

    var trainCommand: String {
        store.trainCommand(imgsz: Int(trainImageSize), epochs: Int(trainEpochs), baseModel: trainBaseModel)
    }

    // MARK: - Ingest queue

    /// Videos and folders; anything else is ignored. Kicks the queue.
    func enqueue(_ urls: [URL]) {
        var added = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                queue.append(IngestJob(url: url, kind: .folder))
                added += 1
            } else if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
                queue.append(IngestJob(url: url, kind: .video))
                added += 1
            }
        }
        guard added > 0 else { status = "Nothing to add — drop .mov/.mp4 videos or folders of JPEG/PNG frames."; return }
        Task { await processQueue() }
    }

    func clearFinishedJobs() {
        queue.removeAll(where: \.isFinished)
    }

    func note(_ message: String) {
        status = message
    }

    func processQueue() async {
        guard !isIngesting else { return }
        isIngesting = true
        defer { isIngesting = false }

        while let index = queue.firstIndex(where: { $0.state == .pending }) {
            let job = queue[index]
            setJob(job.id, .running("Starting…"))
            do {
                let session = try await ingest(job)
                setJob(job.id, .done("\(session.frames.count) frames · \(session.boxCount) boxes"))
                reloadSessions()
                if currentSession == nil { openSession(session) }
            } catch {
                setJob(job.id, .failed(error.localizedDescription))
            }
        }
    }

    private func setJob(_ id: UUID, _ state: IngestJob.State) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].state = state
        if case .running(let text) = state { status = "\(queue[i].url.lastPathComponent): \(text)" }
    }

    private func ingest(_ job: IngestJob) async throws -> VideoSession {
        try store.prepare()
        let existing = store.loadSessions()
        let name = store.uniqueName(for: job.url.deletingPathExtension().lastPathComponent, existing: existing)
        let split = store.splitForNewVideo(existing: existing, valFraction: validationFraction)
        let records: [FrameRecord]
        switch job.kind {
        case .video: records = try await ingestVideo(job, name: name, split: split)
        case .folder: records = try await ingestFolder(job, name: name, split: split)
        }
        let session = VideoSession(name: name, sourcePath: job.url.path, split: split, addedAt: Date(), frames: records)
        try store.save(session)
        for frame in records { try store.writeLabel(for: frame, reviewedOnly: reviewedOnly) }
        try store.writeDataYAML()
        return session
    }

    private struct IngestSettings: Sendable {
        let burstFPS: Double, padding: Double, includeMissed: Bool, maxMissed: Int, randomCount: Int
        let confidence: Float, duplicateThreshold: Int, jpegQuality: Double
        let name: String, split: String, root: URL
    }

    private func ingestSettings(name: String, split: String) -> IngestSettings {
        IngestSettings(
            burstFPS: burstFPS, padding: rallyPadding, includeMissed: includeMissed,
            maxMissed: Int(maxMissed), randomCount: Int(randomCount),
            confidence: Float(prelabelConfidence), duplicateThreshold: Int(duplicateThreshold),
            jpegQuality: jpegQuality, name: name, split: split, root: datasetRoot
        )
    }

    /// Reports pre-labeling progress from the detached ingest back onto the job.
    private func prelabelProgress(for jobId: UUID) -> @Sendable (Int, Int) -> Void {
        { done, total in
            Task { @MainActor [weak self] in self?.setJob(jobId, .running("Pre-labeling… \(done)/\(total)")) }
        }
    }

    private func ingestVideo(_ job: IngestJob, name: String, split: String) async throws -> [FrameRecord] {
        let video = job.url
        let labelsURL = video.deletingPathExtension().appendingPathExtension("rallylabels.json")
        let labeled: [LabeledRally] = preferHandLabels
            ? ((try? Data(contentsOf: labelsURL)).flatMap { try? JSONDecoder().decode([LabeledRally].self, from: $0) } ?? [])
            : []

        setJob(job.id, .running("Running pipeline…"))
        let processor = VideoProcessor()
        processor.config = ProcessorConfig()
        processor.collectFrameEvidence = true
        do {
            _ = try await processor.processVideo(video, videoId: UUID())
        } catch ProcessingError.noRalliesDetected {
            // Fine: random frames and any hand labels still apply.
        }
        let evidence = processor.frameEvidence
        let duration = processor.lastVideoDurationSec
        guard duration > 0 else { throw IngestError.unreadable }
        let rallies = labeled.isEmpty
            ? EvidenceReplayer.decidedRanges(evidence: evidence, duration: duration, config: ProcessorConfig(),
                                             minRallySec: 1.1653, padded: false)
            : labeled.map { Interval(start: $0.startTime, end: $0.endTime) }

        let settings = ingestSettings(name: name, split: split)
        let plan = Self.plan(rallies: rallies, evidence: evidence, duration: duration,
                             burstFPS: settings.burstFPS, padding: settings.padding,
                             includeMissed: settings.includeMissed, maxMissed: settings.maxMissed,
                             randomCount: settings.randomCount)
        guard !plan.isEmpty else { throw IngestError.nothingToSample }
        setJob(job.id, .running("Extracting \(plan.count) frames (\(rallies.count) rallies)…"))

        let progress = prelabelProgress(for: job.id)
        return try await Task.detached(priority: .userInitiated) {
            try Self.extractAndLabel(video: video, plan: plan, settings: settings, progress: progress)
        }.value
    }

    private func ingestFolder(_ job: IngestJob, name: String, split: String) async throws -> [FrameRecord] {
        let files = SamplerImageTools.imageFiles(in: job.url)
        guard !files.isEmpty else { throw IngestError.noImages }
        setJob(job.id, .running("Pre-labeling \(files.count) files…"))
        let settings = ingestSettings(name: name, split: split)
        let progress = prelabelProgress(for: job.id)
        return try await Task.detached(priority: .userInitiated) {
            try Self.copyAndLabel(files: files, settings: settings, progress: progress)
        }.value
    }

    enum IngestError: LocalizedError {
        case unreadable, nothingToSample, noImages
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read the video."
            case .nothingToSample: return "No rallies found and no random frames requested."
            case .noImages: return "No JPEG or PNG files in the folder."
            }
        }
    }

    // MARK: - Ingest work (off the main thread)

    /// The shipping detector at the pre-label threshold, with static-object
    /// suppression off: every frame is judged on its own.
    private nonisolated static func makePrelabeler(confidence: Float) -> YOLODetector {
        let detector = YOLODetector()
        detector.minConfidence = confidence
        detector.suppressesStaticObjects = false
        return detector
    }

    private nonisolated static func unreviewedRecord(
        file: String, time: Double, source: FrameSample.Source, detections: [DetectionResult]
    ) -> FrameRecord {
        FrameRecord(
            id: UUID(), file: file, time: time, source: source.key,
            boxes: detections.map { BoxRecord(SampleBox(rect: $0.bbox, confidence: $0.confidence)) },
            keep: true, reviewed: false
        )
    }

    /// Pull each planned frame at native resolution, drop near-duplicates,
    /// pre-label, and write the JPEG into the dataset.
    private nonisolated static func extractAndLabel(
        video: URL, plan: [PlannedFrame], settings: IngestSettings,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) throws -> [FrameRecord] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = .zero
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let detector = makePrelabeler(confidence: settings.confidence)
        let store = DatasetStore(root: settings.root)

        var records: [FrameRecord] = []
        var lastKept: [String: (hash: UInt64, centers: [CGPoint])] = [:]
        for (i, item) in plan.enumerated() {
            let t = CMTime(seconds: item.time, preferredTimescale: 600)
            guard let frame = try? generator.copyCGImage(at: t, actualTime: nil) else { continue }
            let dets = detector.detect(in: frame, at: t)

            // Near-duplicate check against the last kept frame of the same
            // source. The court barely changes between burst frames, so the
            // picture hash alone would drop almost everything; what matters
            // for a ball detector is whether the ball moved. With detections
            // on both frames, compare where they are; with none on either,
            // fall back to the picture hash.
            if settings.duplicateThreshold > 0, let thumb = SamplerImageTools.downscale(frame, toWidth: 64) {
                let hash = SamplerImageTools.dHash(thumb)
                let centers = dets.map { CGPoint(x: $0.bbox.midX, y: $0.bbox.midY) }
                let group = item.source.key
                if let previous = lastKept[group],
                   SamplerImageTools.isSameMoment(previous, (hash, centers), hashThreshold: settings.duplicateThreshold) {
                    continue
                }
                lastKept[group] = (hash, centers)
            }

            let relative = store.imageRelativePath(session: settings.name, split: settings.split, time: item.time)
            let url = settings.root.appendingPathComponent(relative)
            guard SamplerImageTools.writeJPEG(frame, to: url, quality: settings.jpegQuality) else { continue }
            records.append(unreviewedRecord(file: relative, time: item.time, source: item.source, detections: dets))
            if i % 10 == 0 { progress(i + 1, plan.count) }
        }
        return records
    }

    private nonisolated static func copyAndLabel(
        files: [URL], settings: IngestSettings, progress: @escaping @Sendable (Int, Int) -> Void
    ) throws -> [FrameRecord] {
        let detector = makePrelabeler(confidence: settings.confidence)
        let store = DatasetStore(root: settings.root)
        let fm = FileManager.default

        var records: [FrameRecord] = []
        for (i, file) in files.enumerated() {
            guard let image = SamplerImageTools.loadImage(file, maxPixelSize: reviewMaxPixel) else { continue }
            let dets = detector.detect(in: image, at: CMTime(value: CMTimeValue(i), timescale: 1))
            let relative = store.imageRelativePath(session: settings.name, split: settings.split, copiedFile: file)
            let dest = settings.root.appendingPathComponent(relative)
            try? fm.removeItem(at: dest)
            do { try fm.copyItem(at: file, to: dest) } catch { continue }
            records.append(unreviewedRecord(file: relative, time: Double(i), source: .file, detections: dets))
            if i % 10 == 0 { progress(i + 1, files.count) }
        }
        return records
    }

    struct PlannedFrame: Sendable {
        let time: Double
        let source: FrameSample.Source
    }

    /// Which moments to pull, in time order: bursts inside padded rallies, up
    /// to `maxMissed` in-rally frames the pipeline saw no ball in (spread
    /// evenly), and `randomCount` frames anywhere in the middle 96% of the
    /// video. Moments closer than half a burst interval merge, keeping the
    /// "missed" tag when both apply.
    nonisolated static func plan(
        rallies: [Interval],
        evidence: [VideoProcessor.FrameEvidence],
        duration: Double,
        burstFPS: Double,
        padding: Double,
        includeMissed: Bool,
        maxMissed: Int,
        randomCount: Int
    ) -> [PlannedFrame] {
        var planned: [PlannedFrame] = []
        let step = 1 / max(burstFPS, 0.5)

        for (index, rally) in rallies.enumerated() {
            let start = max(0, rally.start - padding)
            let end = min(duration, rally.end + padding)
            guard end > start else { continue }
            var t = start
            while t <= end {
                planned.append(PlannedFrame(time: t, source: .rally(index)))
                t += step
            }
        }

        if includeMissed, maxMissed > 0 {
            let inRally: (Double) -> Bool = { t in
                rallies.contains { t >= $0.start && t <= $0.end }
            }
            let missed = evidence.filter { !$0.hasBall && inRally($0.time) }.map(\.time)
            if !missed.isEmpty {
                let stride = max(1, Int((Double(missed.count) / Double(maxMissed)).rounded(.up)))
                for (i, t) in missed.enumerated() where i % stride == 0 {
                    planned.append(PlannedFrame(time: t, source: .missed))
                }
            }
        }

        if randomCount > 0, duration > 0 {
            for _ in 0..<randomCount {
                planned.append(PlannedFrame(time: Double.random(in: (0.02 * duration)...(0.98 * duration)), source: .random))
            }
        }

        planned.sort { $0.time < $1.time }
        var deduped: [PlannedFrame] = []
        for frame in planned {
            if let last = deduped.last, frame.time - last.time < step / 2 {
                if frame.source == .missed, last.source != .missed {
                    deduped[deduped.count - 1] = PlannedFrame(time: last.time, source: .missed)
                }
                continue
            }
            deduped.append(frame)
        }
        return deduped
    }

    // MARK: - Review

    var visibleSamples: [FrameSample] {
        var list = samples
        switch filter {
        case .all: break
        case .unreviewed: list = list.filter { !$0.reviewed }
        case .withBoxes: list = list.filter { !$0.boxes.isEmpty }
        case .noBoxes: list = list.filter { $0.boxes.isEmpty }
        }
        if lowestConfidenceFirst {
            list.sort { $0.minConfidence < $1.minConfidence }
        }
        return list
    }

    var selected: FrameSample? { samples.first { $0.id == selectedId } }

    /// Load a session's frames for review: thumbnails come from the stored
    /// JPEGs, decoded off the main thread.
    func openSession(_ session: VideoSession) {
        loadTask?.cancel()
        previewTask?.cancel()
        currentSession = session
        samples = []
        selectedId = nil
        selectedBoxId = nil
        preview = nil
        isLoadingSession = true
        let store = self.store
        let frames = session.frames
        loadTask = Task {
            let loaded: [FrameSample] = await Task.detached(priority: .userInitiated) {
                var out: [FrameSample] = []
                out.reserveCapacity(frames.count)
                for record in frames {
                    if Task.isCancelled { break }
                    let url = store.currentImageURL(for: record)
                    guard let thumb = SamplerImageTools.loadImage(url, maxPixelSize: Self.thumbnailWidth) else { continue }
                    out.append(FrameSample(record: record, thumbnail: thumb))
                }
                return out
            }.value
            guard !Task.isCancelled, currentSession?.name == session.name else { return }
            samples = loaded
            isLoadingSession = false
            select(visibleSamples.first?.id)
            status = "\(session.name): \(session.frames.count) frames, \(session.reviewedCount) reviewed."
        }
    }

    func closeSession() {
        loadTask?.cancel()
        previewTask?.cancel()
        currentSession = nil
        samples = []
        selectedId = nil
        selectedBoxId = nil
        preview = nil
        isLoadingSession = false
    }

    func select(_ id: UUID?) {
        guard id != selectedId else { return }
        selectedId = id
        selectedBoxId = nil
        loadPreviewForSelection()
    }

    func selectNext(_ delta: Int) {
        let list = visibleSamples
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedId } ?? -1
        let next = min(max(current + delta, 0), list.count - 1)
        select(list[next].id)
    }

    func toggleKeep(_ id: UUID? = nil) {
        mutate(id ?? selectedId) { $0.keep.toggle(); $0.reviewed = true }
    }

    func markReviewed(_ id: UUID? = nil) {
        mutate(id ?? selectedId) { $0.reviewed = true }
    }

    func removeSelectedBox() {
        guard let boxId = selectedBoxId else { return }
        mutate(selectedId) { $0.boxes.removeAll { $0.id == boxId }; $0.reviewed = true }
        selectedBoxId = nil
    }

    func addBox(_ rect: CGRect) {
        let box = SampleBox(rect: Self.clamp(rect), confidence: nil)
        mutate(selectedId) { $0.boxes.append(box); $0.reviewed = true }
        selectedBoxId = box.id
    }

    func updateBox(_ boxId: UUID, rect: CGRect) {
        mutate(selectedId) { sample in
            guard let b = sample.boxes.firstIndex(where: { $0.id == boxId }) else { return }
            sample.boxes[b].rect = Self.clamp(rect)
            sample.reviewed = true
        }
    }

    /// Accept the frame as-is and move on — the fast path through a review.
    func acceptAndAdvance() {
        markReviewed()
        selectNext(1)
    }

    /// Apply an edit and persist it: the session JSON and that frame's label
    /// file are rewritten immediately, so nothing is lost on quit.
    private func mutate(_ id: UUID?, _ edit: (inout FrameSample) -> Void) {
        guard let id, let index = samples.firstIndex(where: { $0.id == id }),
              var session = currentSession else { return }
        edit(&samples[index])
        let record = samples[index].record
        if let r = session.frames.firstIndex(where: { $0.id == id }) {
            session.frames[r] = record
        }
        currentSession = session
        do {
            try store.save(session)
            try store.writeLabel(for: record, reviewedOnly: reviewedOnly)
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
        if let s = sessions.firstIndex(where: { $0.name == session.name }) {
            sessions[s] = session
            stats = store.stats(sessions)
        }
    }

    private nonisolated static func clamp(_ r: CGRect) -> CGRect {
        let x0 = min(max(r.minX, 0), 1), x1 = min(max(r.maxX, 0), 1)
        let y0 = min(max(r.minY, 0), 1), y1 = min(max(r.maxY, 0), 1)
        return CGRect(x: x0, y: y0, width: max(0.002, x1 - x0), height: max(0.002, y1 - y0))
    }

    private func loadPreviewForSelection() {
        previewTask?.cancel()
        preview = nil
        guard let sample = selected else { return }
        let id = sample.id
        let url = store.currentImageURL(for: sample.record)
        previewTask = Task {
            let image = await Task.detached { SamplerImageTools.loadImage(url, maxPixelSize: Self.reviewMaxPixel) }.value
            guard !Task.isCancelled, selectedId == id else { return }
            preview = image
        }
    }
}
