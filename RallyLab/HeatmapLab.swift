//
//  HeatmapLab.swift
//  RallyLab
//
//  Multi-frame (heatmap) models in the Models tab: add the bring_back
//  folder a desktop training run produced (converted to Core ML here, kept
//  with the dataset), and score a model on a multi-frame package's val
//  windows — on its own, against the YOLO pre-label model on the same
//  frames, and the two together — the way the trainer scores: balls in
//  play only, within 8 px at 512×288.
//

import CoreGraphics
import CoreMedia
import Foundation
import Observation

struct HeatModelEntry: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    /// From the model's metadata (written by heatmap_to_coreml.py).
    let size: String
    let package: String
    let trackedRecall: Double?
    let trackedPrecision: Double?

    init(url: URL) {
        self.url = url
        let meta = (try? Data(contentsOf: url.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        // The protobuf keeps metadata as plain strings; enough to show.
        func value(_ key: String) -> String? {
            guard let r = meta.range(of: key) else { return nil }
            let after = meta[r.upperBound...].drop { !$0.isLetter && !$0.isNumber && $0 != "." }
            let v = after.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
            return v.isEmpty ? nil : String(v)
        }
        size = [value("width"), value("height")].compactMap { $0 }.joined(separator: "×")
        package = value("package") ?? ""
        trackedRecall = value("tracked_recall").flatMap(Double.init)
        trackedPrecision = value("tracked_precision").flatMap(Double.init)
    }
}

@MainActor
@Observable
final class HeatmapLab {

    let sampler: SamplerModel
    private(set) var models: [HeatModelEntry] = []
    var selected: HeatModelEntry?
    /// Multi-frame packages in the dataset's exports, newest first.
    private(set) var packages: [URL] = []
    var package: URL?
    private(set) var isBusy = false
    private(set) var status = ""
    private(set) var progress: String?
    private(set) var result: HeatEvaluation.Result?

    init(sampler: SamplerModel) {
        self.sampler = sampler
    }

    var modelsDir: URL { sampler.datasetRoot.appendingPathComponent("models/heatmap", isDirectory: true) }
    private var exportsDir: URL { sampler.datasetRoot.appendingPathComponent("exports", isDirectory: true) }

    /// The converter lives in the repo next to the trainer.
    private static let converter = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/desktop_training/heatmap_to_coreml.py")

    func reload() {
        let fm = FileManager.default
        models = ((try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mlpackage" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(HeatModelEntry.init)
        if selected.map({ !models.contains($0) }) ?? true { selected = models.first }
        packages = ((try? fm.contentsOfDirectory(at: exportsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.contains("-multiframe-") && $0.pathExtension.isEmpty
                && fm.fileExists(atPath: $0.appendingPathComponent("windows.jsonl").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if package.map({ !packages.contains($0) }) ?? true { package = packages.first }
    }

    /// A bring_back folder (or its best.pt) from train_heatmap_model.py,
    /// converted to Core ML and kept as <project>-<run>-<stamp>.mlpackage.
    func addModel(_ source: URL) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let folder = source.pathExtension == "pt" ? source.deletingLastPathComponent() : source
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("best.pt").path) else {
            status = "No best.pt in \(folder.lastPathComponent) — pick the bring_back folder of a multi-frame run."
            return
        }
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let name = [sampler.datasetRoot.lastPathComponent, folder.lastPathComponent, stamp.string(from: Date())]
            .map(DatasetStore.safeName).joined(separator: "-")
        let out = modelsDir.appendingPathComponent("\(name).mlpackage")
        status = "Converting \(folder.lastPathComponent) to Core ML…"
        let run = await ToolEnvironment.run("python3", [Self.converter.path, folder.path, out.path])
        guard run.status == 0, FileManager.default.fileExists(atPath: out.path) else {
            status = "Couldn't convert: " + (run.lines.last { $0.contains("❌") || $0.contains("Error") } ?? run.lines.last ?? "python3 failed")
            return
        }
        reload()
        selected = models.first { $0.url == out }
        status = run.lines.last { $0.hasPrefix("Saved") } ?? "Added \(name)."
    }

    /// Every tracked rally whose video is on this Mac, for the video menu.
    var trackedRallies: [(session: String, rally: TrackedRally)] {
        sampler.sessions.filter { FileManager.default.fileExists(atPath: $0.sourcePath) }
            .flatMap { s in (s.tracks ?? []).map { (s.name, $0) } }
    }

    /// Render the side-by-side video for a tracked rally and show it in Finder.
    func renderVideo(session name: String, rally: TrackedRally) {
        guard !isBusy, let model = selected,
              let session = sampler.sessions.first(where: { $0.name == name }) else { return }
        isBusy = true
        let out = sampler.datasetRoot.appendingPathComponent("exports/videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = out.appendingPathComponent("\(model.name)-\(DatasetStore.safeName(name))-\(Int(rally.start)).mp4")
        let title = "\(name) @ \(TrackLabelModel.clock(rally.start)) (\(session.split))"
        status = "Rendering \(title)…"
        let yolo = sampler.prelabelModel
        Task {
            defer { isBusy = false; progress = nil }
            let result = await HeatmapVideo.render(video: URL(fileURLWithPath: session.sourcePath), times: rally.points.map(\.time),
                                                   title: title, heatModel: model.url, yolo: yolo, to: file) { done, total in
                Task { @MainActor [weak self] in self?.progress = "\(done)/\(total) frames" }
            }
            switch result {
            case .success(let url):
                status = "Saved \(url.lastPathComponent)."
                lastVideo = url
            case .failure(let e):
                status = e.message
            }
        }
    }

    private(set) var lastVideo: URL?

    func evaluate() {
        guard !isBusy, let model = selected, let package else { return }
        isBusy = true
        result = nil
        status = "Scoring \(model.name) on \(package.lastPathComponent)…"
        let yolo = sampler.prelabelModel
        Task {
            defer { isBusy = false; progress = nil }
            let outcome = await Task.detached(priority: .userInitiated) {
                HeatEvaluation.run(model: model.url, package: package, yolo: yolo) { done, total in
                    Task { @MainActor [weak self] in self?.progress = "\(done)/\(total) windows" }
                }
            }.value
            switch outcome {
            case .success(let r):
                result = r
                status = "Scored \(r.windows) val windows (\(r.trackedWindows) from tracked rallies)."
            case .failure(let e):
                status = e.message
            }
        }
    }
}

enum HeatEvaluation {

    struct Failure: Error { let message: String }

    struct Score: Hashable {
        var tp = 0, fp = 0, fn = 0
        var recall: Double { Double(tp) / Double(max(1, tp + fn)) }
        var precision: Double { Double(tp) / Double(max(1, tp + fp)) }
        var f1: Double { let r = recall, p = precision; return r + p > 0 ? 2 * r * p / (r + p) : 0 }
    }

    enum Detector: String, CaseIterable { case heatmap = "Multi-frame", yolo = "YOLO", both = "Both" }

    struct Result {
        /// [detector][kind] with kind "tracked", "sampled" or "all".
        var scores: [Detector: [String: Score]] = [:]
        /// The multi-frame model by environment, tracked rallies.
        var byEnvironment: [String: Score] = [:]
        /// Balls in play on tracked rallies, by who found them.
        var both = 0, onlyYOLO = 0, onlyHeatmap = 0, neither = 0
        var windows = 0, trackedWindows = 0
        var yoloName = ""
    }

    /// Hit = within this many pixels at 512×288, like the trainer's 8 px score.
    static let tolerance = 8.0
    /// Grey-level change around a ball over ±4 frames that means "in play".
    static let motion = 10.0

    static func run(model: URL, package: URL, yolo: URL?,
                    progress: @escaping @Sendable (Int, Int) -> Void) -> Swift.Result<Result, Failure> {
        guard let heat = HeatmapBallDetector(modelURL: model) else {
            return .failure(Failure(message: "Couldn't load \(model.lastPathComponent)."))
        }
        let detector = SamplerModel.detector(model: yolo, confidence: Float(ProcessorConfig().detectionConfidence))
        guard let text = try? String(contentsOf: package.appendingPathComponent("windows.jsonl"), encoding: .utf8) else {
            return .failure(Failure(message: "No windows.jsonl in \(package.lastPathComponent)."))
        }
        let windows = text.split(separator: "\n").compactMap { line -> Window? in
            try? JSONDecoder().decode(Window.self, from: Data(line.utf8))
        }.filter { $0.split == "val" }
        guard !windows.isEmpty else { return .failure(Failure(message: "No val windows in the package.")) }

        var result = Result()
        result.windows = windows.count
        result.yoloName = yolo?.deletingPathExtension().lastPathComponent ?? "app's model"
        var cache: [String: HeatmapBallDetector.Frame] = [:]
        var cacheOrder: [String] = []
        func frame(_ path: String) -> HeatmapBallDetector.Frame? {
            if let f = cache[path] { return f }
            guard let image = SamplerImageTools.loadImage(package.appendingPathComponent(path), maxPixelSize: 4096),
                  let f = heat.grayscale(image) else { return nil }
            cache[path] = f
            cacheOrder.append(path)
            if cacheOrder.count > 40 { cache[cacheOrder.removeFirst()] = nil }
            return f
        }

        for (n, w) in windows.enumerated() {
            defer { if n % 10 == 0 { progress(n, windows.count) } }
            let start = min(max(0, w.target - heat.seq / 2), w.frames.count - heat.seq)
            let frames = w.frames[start..<start + heat.seq].compactMap(frame)
            guard frames.count == heat.seq,
                  let image = SamplerImageTools.loadImage(package.appendingPathComponent(w.frames[w.target]), maxPixelSize: 4096)
            else { continue }
            let portrait = w.size[1] > w.size[0]
            // Everything in 512×288 model pixels, portrait turned as in training.
            func model(_ x: Double, _ y: Double) -> CGPoint {
                let (mx, my) = portrait ? (1 - y, x) : (x, y)
                return CGPoint(x: mx * 512, y: my * 288)
            }
            let tracked = w.labels != nil
            let moving = tracked ? Array(repeating: true, count: w.balls.count) : inPlay(w, package: package)
            let truth = zip(w.balls, moving).map { (model($0.0[0], $0.0[1]), $0.1) }
            let heatPoints = heat.peaks(in: frames, target: w.target - start).map { model($0.rect.midX, 1 - $0.rect.midY) }
            let yoloPoints = detector.detect(in: image, at: .zero).map { model($0.bbox.midX, 1 - $0.bbox.midY) }
            var bothPoints = yoloPoints
            for p in heatPoints where !bothPoints.contains(where: { hypot($0.x - p.x, $0.y - p.y) <= tolerance }) {
                bothPoints.append(p)
            }
            let kind = tracked ? "tracked" : "sampled"
            if tracked { result.trackedWindows += 1 }
            for (d, points) in [(Detector.heatmap, heatPoints), (.yolo, yoloPoints), (.both, bothPoints)] {
                let s = score(points, truth)
                for k in [kind, "all"] { result.scores[d, default: [:]][k, default: Score()].add(s) }
                if d == .heatmap, tracked { result.byEnvironment[environment(w.clip), default: Score()].add(s) }
            }
            if tracked {
                for (q, inPlay) in truth where inPlay {
                    let h = heatPoints.contains { hypot($0.x - q.x, $0.y - q.y) <= tolerance }
                    let y = yoloPoints.contains { hypot($0.x - q.x, $0.y - q.y) <= tolerance }
                    switch (h, y) {
                    case (true, true): result.both += 1
                    case (false, true): result.onlyYOLO += 1
                    case (true, false): result.onlyHeatmap += 1
                    case (false, false): result.neither += 1
                    }
                }
            }
        }
        progress(windows.count, windows.count)
        return .success(result)
    }

    /// Nearest unmatched ball within tolerance: in play → hit; resting →
    /// neither hit nor false alarm. Missed balls in play count against.
    private static func score(_ points: [CGPoint], _ truth: [(CGPoint, Bool)]) -> Score {
        var s = Score()
        var open = truth
        for p in points {
            let nearest = open.indices.min { hypot(open[$0].0.x - p.x, open[$0].0.y - p.y) < hypot(open[$1].0.x - p.x, open[$1].0.y - p.y) }
            if let i = nearest, hypot(open[i].0.x - p.x, open[i].0.y - p.y) <= tolerance {
                if open[i].1 { s.tp += 1 }
                open.remove(at: i)
            } else {
                s.fp += 1
            }
        }
        s.fn = open.filter(\.1).count
        return s
    }

    /// Per ball on a sampled window's target frame: does the patch around it
    /// change over ±4 frames? (The trainer's test.)
    private static func inPlay(_ w: Window, package: URL) -> [Bool] {
        guard !w.balls.isEmpty, w.target >= 4, w.target + 4 < w.frames.count else { return w.balls.map { _ in true } }
        let grays = [-4, 0, 4].compactMap { k -> (pixels: [UInt8], width: Int, height: Int)? in
            guard let image = SamplerImageTools.loadImage(package.appendingPathComponent(w.frames[w.target + k]), maxPixelSize: 4096)
            else { return nil }
            return gray(image)
        }
        guard grays.count == 3 else { return w.balls.map { _ in true } }
        let (before, now, after) = (grays[0], grays[1], grays[2])
        let wd = now.width, h = now.height
        return w.balls.map { b in
            let s = max(b[2] * Double(wd), b[3] * Double(h)) * 0.75 + 2
            let x0 = Int(max(0, b[0] * Double(wd) - s)), x1 = Int(min(Double(wd), b[0] * Double(wd) + s))
            let y0 = Int(max(0, b[1] * Double(h) - s)), y1 = Int(min(Double(h), b[1] * Double(h) + s))
            guard x1 > x0, y1 > y0 else { return true }
            var dBefore = 0, dAfter = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * wd + x
                    dBefore += abs(Int(now.pixels[i]) - Int(before.pixels[i]))
                    dAfter += abs(Int(now.pixels[i]) - Int(after.pixels[i]))
                }
            }
            let n = Double((x1 - x0) * (y1 - y0))
            return Double(max(dBefore, dAfter)) / n > motion
        }
    }

    private static func gray(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pixels, w, h)
    }

    static func environment(_ clip: String) -> String {
        switch clip.prefix(3) {
        case "ind": return "indoor"
        case "bch": return "beach"
        case "grs": return "grass"
        default: return "other"
        }
    }

    private struct Window: Decodable {
        let clip: String
        let split: String
        let size: [Int]
        let frames: [String]
        let target: Int
        let balls: [[Double]]
        let labels: [[[Double]]?]?
    }
}

private extension HeatEvaluation.Score {
    mutating func add(_ s: Self) { tp += s.tp; fp += s.fp; fn += s.fn }
}
