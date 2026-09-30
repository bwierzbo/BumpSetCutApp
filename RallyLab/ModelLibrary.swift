//
//  ModelLibrary.swift
//  RallyLab
//
//  Closing the loop on a model trained elsewhere. Bring back its best.pt
//  and add it here: it's converted to the CoreML form the app runs (the
//  raw YOLO tensor, no NMS, at the size it was trained at) and kept in
//  <dataset>/models/. Any model
//  in the library can then pre-label new footage, and be scored against
//  the frames you've reviewed — side by side with the model the app ships.
//

import CoreGraphics
import CoreMedia
import Foundation
import Observation

struct ModelEntry: Identifiable, Hashable {
    /// nil is the model bundled with the app.
    let url: URL?
    var id: String { url?.path ?? "shipping" }
    var name: String { url?.deletingPathExtension().lastPathComponent ?? "ball_v2_small (in the app)" }
}

@MainActor
@Observable
final class ModelLibrary {

    let sampler: SamplerModel
    private(set) var models: [ModelEntry] = [ModelEntry(url: nil)]
    private(set) var isBusy = false
    private(set) var status = ""

    // Training packages
    private(set) var packages: [URL] = []
    private(set) var lastPackage: (zip: URL, summary: TrainingPackage.Summary)?

    // Evaluation
    var evaluateValOnly = true
    /// Fit every frame into the model with padding (letterbox), as Ultralytics
    /// trains and validates, instead of the app's own choice (stretch landscape,
    /// letterbox portrait/ultrawide).
    var alwaysLetterbox = false
    /// Scored at the app's own detection threshold unless changed.
    var threshold: Double = ProcessorConfig().detectionConfidence
    var baseline = ModelEntry(url: nil)
    var candidate: ModelEntry?
    private(set) var results: [String: ModelEvaluation.Result] = [:]
    private(set) var evalProgress: String?

    init(sampler: SamplerModel) {
        self.sampler = sampler
        reload()
    }

    var modelsDir: URL { sampler.datasetRoot.appendingPathComponent("models", isDirectory: true) }
    var exportsDir: URL { sampler.datasetRoot.appendingPathComponent("exports", isDirectory: true) }

    /// Re-read the library and packages (call after the dataset changes).
    func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let added = files
            .filter { ["mlpackage", "mlmodel"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { ModelEntry(url: $0) }
        models = [ModelEntry(url: nil)] + added
        if let c = candidate, !models.contains(c) { candidate = nil }
        if candidate == nil { candidate = added.first }
        if !models.contains(baseline) { baseline = ModelEntry(url: nil) }
        packages = ((try? fm.contentsOfDirectory(at: exportsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "zip" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - Packages

    var reviewedCounts: (train: Int, val: Int) {
        var train = 0, val = 0
        for s in sampler.sessions {
            let n = s.frames.filter { $0.keep && $0.reviewed }.count
            if s.split == "val" { val += n } else { train += n }
        }
        return (train, val)
    }

    func exportPackage() {
        guard !isBusy else { return }
        isBusy = true
        status = "Packaging reviewed frames…"
        let sessions = sampler.sessions
        let store = sampler.store
        let name = sampler.datasetRoot.lastPathComponent
        Task {
            defer { isBusy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await TrainingPackage.export(sessions: sessions, store: store, name: name)
                }.value
                lastPackage = result
                reload()
                let s = result.summary
                status = "Packaged \(s.trainImages) train + \(s.valImages) val images from \(s.clips) clips → \(result.zip.lastPathComponent)"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    // MARK: - Adding models

    /// Add a trained model: a `.pt` is exported to CoreML the way the app
    /// expects (no NMS); a `.mlpackage`/`.mlmodel` is copied as-is. No
    /// imgsz is passed, so Ultralytics exports at the size the model was
    /// trained at — a model trained at 1280 runs at 1280, here and in the
    /// app, which reads its input size from the model.
    func addModel(_ source: URL) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let fm = FileManager.default
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        // Project, then the file's own name (which says which run it was), then when.
        let name = [sampler.datasetRoot.lastPathComponent, source.deletingPathExtension().lastPathComponent,
                    stamp.string(from: Date())].map(DatasetStore.safeName).joined(separator: "-")

        do {
            switch source.pathExtension.lowercased() {
            case "pt":
                status = "Converting \(source.lastPathComponent) to CoreML (a minute or two)…"
                // Export in a scratch copy so the original run folder is untouched.
                let work = fm.temporaryDirectory.appendingPathComponent("rallylab-export-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: work) }
                let pt = work.appendingPathComponent("\(name).pt")
                try fm.copyItem(at: source, to: pt)
                let run = await ToolEnvironment.run("yolo", ["export", "model=\(pt.path)", "format=coreml",
                                                             "nms=False"], in: work)
                let produced = work.appendingPathComponent("\(name).mlpackage")
                guard run.status == 0, fm.fileExists(atPath: produced.path) else {
                    let why = run.lines.last(where: { $0.lowercased().contains("error") }) ?? run.lines.last ?? "no output"
                    throw ModelError.conversion(why)
                }
                try fm.moveItem(at: produced, to: modelsDir.appendingPathComponent(produced.lastPathComponent))
                // Keep the weights next to it, for the record and for fine-tuning later.
                try? fm.copyItem(at: source, to: modelsDir.appendingPathComponent("\(name).pt"))
            case "mlpackage", "mlmodel":
                try fm.copyItem(at: source, to: modelsDir.appendingPathComponent("\(name).\(source.pathExtension)"))
            default:
                throw ModelError.unsupported
            }
            guard YOLODetector(modelURL: modelsDir.appendingPathComponent(
                "\(name).\(source.pathExtension == "pt" ? "mlpackage" : source.pathExtension)")).isLoaded else {
                throw ModelError.unloadable
            }
            reload()
            candidate = models.first { $0.name == name }
            status = "Added \(name). Evaluate it against the app's model, or use it for pre-labels."
        } catch {
            status = error.localizedDescription
        }
    }

    enum ModelError: LocalizedError {
        case unsupported, unloadable, conversion(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Add a .pt, .mlpackage or .mlmodel."
            case .unloadable: return "The model was added but CoreML can't load it."
            case .conversion(let why): return "Converting to CoreML failed: \(why)"
            }
        }
    }

    func remove(_ entry: ModelEntry) {
        guard let url = entry.url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("pt"))
        if sampler.prelabelModel == url { sampler.prelabelModel = nil }
        results[entry.id] = nil
        reload()
    }

    // MARK: - Evaluation

    /// The reviewed frames the models are scored on.
    private var evaluationFrames: [ModelEvaluation.Frame] {
        sampler.sessions
            .filter { !evaluateValOnly || $0.split == "val" }
            .flatMap { session in
                session.frames.filter { $0.keep && $0.reviewed }.map {
                    ModelEvaluation.Frame(session: session.name, record: $0,
                                          image: sampler.store.currentImageURL(for: $0))
                }
            }
    }

    var evaluationFrameCount: Int { evaluationFrames.count }

    func evaluate() {
        guard !isBusy else { return }
        let frames = evaluationFrames
        guard !frames.isEmpty else {
            status = evaluateValOnly
                ? "No reviewed frames in val clips. Review some, or evaluate on all reviewed frames."
                : "No reviewed frames yet."
            return
        }
        let entries = [baseline] + (candidate.map { $0 == baseline ? [] : [$0] } ?? [])
        let letterboxAll = alwaysLetterbox
        isBusy = true
        results = [:]
        Task {
            defer { isBusy = false; evalProgress = nil }
            for entry in entries {
                evalProgress = "\(entry.name): 0/\(frames.count)"
                let name = entry.name
                let result = await Task.detached(priority: .userInitiated) {
                    ModelEvaluation.run(model: entry.url, frames: frames, alwaysLetterbox: letterboxAll) { done in
                        Task { @MainActor [weak self] in self?.evalProgress = "\(name): \(done)/\(frames.count)" }
                    }
                }.value
                guard let result else {
                    status = "Couldn't load \(entry.name)."
                    return
                }
                results[entry.id] = result
            }
            status = "Scored \(entries.count) model\(entries.count == 1 ? "" : "s") on \(frames.count) reviewed frames."
        }
    }
}

// MARK: - Scoring

enum ModelEvaluation {

    struct Frame: Sendable {
        let session: String
        let record: FrameRecord
        let image: URL
    }

    struct Detection: Sendable {
        let rect: CGRect      // Vision-normalized
        let confidence: Float
    }

    /// Every detection a model made on every frame, down to a low floor, so
    /// the threshold can be moved without re-running the model.
    struct Result: Sendable {
        let frames: [Frame]
        let detections: [[Detection]]

        struct Counts { var tp = 0, fp = 0, fn = 0
            var precision: Double { tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp) }
            var recall: Double { tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn) }
            var f1: Double { precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall) }
        }

        enum ErrorKind { case missed, falseAlarm }
        struct ErrorCase: Identifiable {
            let id = UUID()
            let kind: ErrorKind
            let frame: Frame
            let rect: CGRect
            let confidence: Float?
        }

        /// Counts overall and per environment (from the Clip ID prefix), and
        /// every miss and false alarm, at `threshold`.
        func score(at threshold: Double) -> (all: Counts, byEnv: [(String, Counts)], errors: [ErrorCase]) {
            var all = Counts()
            var byEnv: [String: Counts] = [:]
            var errors: [ErrorCase] = []
            for (frame, dets) in zip(frames, detections) {
                let truth = frame.record.boxes.map(\.rect)
                let kept = dets.filter { Double($0.confidence) >= threshold }.sorted { $0.confidence > $1.confidence }
                var used = Set<Int>()
                var c = Counts()
                for det in kept {
                    if let i = truth.indices.first(where: { !used.contains($0) && Self.matches(det.rect, truth[$0]) }) {
                        used.insert(i); c.tp += 1
                    } else {
                        c.fp += 1
                        errors.append(ErrorCase(kind: .falseAlarm, frame: frame, rect: det.rect, confidence: det.confidence))
                    }
                }
                for i in truth.indices where !used.contains(i) {
                    c.fn += 1
                    errors.append(ErrorCase(kind: .missed, frame: frame, rect: truth[i], confidence: nil))
                }
                all.tp += c.tp; all.fp += c.fp; all.fn += c.fn
                let env = Self.environment(of: frame.session)
                byEnv[env, default: Counts()].tp += c.tp
                byEnv[env, default: Counts()].fp += c.fp
                byEnv[env, default: Counts()].fn += c.fn
            }
            return (all, byEnv.sorted { $0.key < $1.key }, errors)
        }

        /// A 10-pixel ball makes IoU unforgiving, so a detection also counts
        /// when its centre falls inside the (slightly grown) true box.
        static func matches(_ det: CGRect, _ truth: CGRect) -> Bool {
            let inter = det.intersection(truth)
            if !inter.isNull {
                let iou = (inter.width * inter.height) / (det.width * det.height + truth.width * truth.height - inter.width * inter.height)
                if iou >= 0.3 { return true }
            }
            return truth.insetBy(dx: -truth.width * 0.25, dy: -truth.height * 0.25)
                .contains(CGPoint(x: det.midX, y: det.midY))
        }

        static func environment(of session: String) -> String {
            switch session.prefix(4) {
            case "ind_": return "Indoor"
            case "bch_": return "Beach"
            case "grs_": return "Grass"
            default: return "Other"
            }
        }
    }

    /// Run one model over the frames. nil if the model can't be loaded.
    static func run(model: URL?, frames: [Frame], alwaysLetterbox: Bool,
                    progress: @escaping @Sendable (Int) -> Void) -> Result? {
        let detector = model.map { YOLODetector(modelURL: $0) } ?? YOLODetector()
        guard detector.isLoaded else { return nil }
        // Fit frames into the model the way the app does, unless asked to
        // letterbox everything.
        let config = ProcessorConfig()
        detector.useScaleFitLetterbox = alwaysLetterbox || config.useScaleFitLetterbox
        detector.adaptiveLetterbox = !alwaysLetterbox && config.adaptiveLetterbox
        detector.adaptiveWideRatio = config.adaptiveLetterboxWideRatio
        detector.minConfidence = 0.05
        detector.suppressesStaticObjects = false
        var all: [[Detection]] = []
        all.reserveCapacity(frames.count)
        for (i, frame) in frames.enumerated() {
            if let image = SamplerImageTools.loadImage(frame.image, maxPixelSize: 4096) {
                let dets = detector.detect(in: image, at: CMTime(value: CMTimeValue(i), timescale: 1))
                all.append(dets.map { Detection(rect: $0.bbox, confidence: $0.confidence) })
            } else {
                all.append([])
            }
            if i % 10 == 9 { progress(i + 1) }
        }
        return Result(frames: frames, detections: all)
    }
}
