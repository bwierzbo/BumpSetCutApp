//
//  SamplerModel.swift
//  RallyLab
//
//  Turns a video into detector training frames. The pipeline's rallies (or
//  your hand labels) say where the action is; this pulls bursts of stills
//  from those windows, adds frames the pipeline saw no ball in (the misses
//  are the most valuable frames), and sprinkles random frames across the
//  whole video for negatives and variety. Every still is pre-labeled by the
//  shipping detector at a low threshold, reviewed here, and exported as a
//  YOLO dataset (images/ + labels/ + data.yaml) for the training script.
//

import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - Types

struct SampleBox: Identifiable, Equatable {
    let id: UUID
    /// Vision-normalized, origin bottom-left, [0,1] — what the detector emits
    /// and what OverlayGeometry draws.
    var rect: CGRect
    /// nil for a box drawn by hand.
    var confidence: Float?

    init(id: UUID = UUID(), rect: CGRect, confidence: Float?) {
        self.id = id
        self.rect = rect
        self.confidence = confidence
    }
}

struct FrameSample: Identifiable {
    enum Source: Equatable {
        /// A burst frame inside rally `index`.
        case rally(Int)
        /// Inside a rally, but the pipeline's detector saw no ball there.
        case missed
        /// Anywhere in the video.
        case random
        /// A still loaded from disk (a flywheel zip, an older export) rather
        /// than pulled from the open video.
        case file(URL)

        var label: String {
            switch self {
            case .rally(let i): return "rally \(i + 1)"
            case .missed: return "missed"
            case .random: return "random"
            case .file: return "file"
            }
        }
    }

    let id = UUID()
    let time: Double
    let source: Source
    /// Small still for the grid; the full frame is re-read on demand.
    let thumbnail: CGImage
    var boxes: [SampleBox]
    /// Exported when true. Frames start kept; the review pass discards.
    var keep = true
    var reviewed = false
}

struct SampleExportSummary {
    let directory: URL
    let images: Int
    let boxes: Int
    let validation: Int
}

// MARK: - Model

@MainActor
@Observable
final class SamplerModel {

    // Sampling
    var burstFPS: Double = 8
    /// Seconds added before and after each rally window.
    var rallyPadding: Double = 0.5
    var includeMissed = true
    var maxMissed: Double = 60
    var randomCount: Double = 40
    /// Hand labels win when present; otherwise the pipeline's predictions.
    var preferHandLabels = true

    // Pre-labeling
    /// Deliberately low: the point is to surface the detector's uncertain
    /// calls for a human to confirm or delete.
    var prelabelConfidence: Double = 0.25

    // Export
    var validationFraction: Double = 0.15
    var jpegQuality: Double = 0.92

    private(set) var samples: [FrameSample] = []
    private(set) var isSampling = false
    private(set) var isExporting = false
    private(set) var status = "Run the pipeline (or label rallies), then Sample — or load a folder of frames."
    private(set) var lastExport: SampleExportSummary?
    /// Folder name the export is written under: the video's name, or the
    /// loaded folder's.
    private(set) var datasetName = "dataset"

    var selectedId: UUID?
    /// The selected frame at review resolution.
    private(set) var preview: CGImage?
    var selectedBoxId: UUID?

    private var previewTask: Task<Void, Never>?
    private var videoURL: URL?

    nonisolated static let thumbnailWidth = 320
    nonisolated static let reviewMaxSize = CGSize(width: 1600, height: 1600)

    // MARK: - Derived

    var selected: FrameSample? {
        samples.first { $0.id == selectedId }
    }

    var keptCount: Int { samples.filter(\.keep).count }
    var reviewedCount: Int { samples.filter(\.reviewed).count }
    var boxCount: Int { samples.filter(\.keep).reduce(0) { $0 + $1.boxes.count } }

    func reset() {
        previewTask?.cancel()
        samples = []
        selectedId = nil
        selectedBoxId = nil
        preview = nil
        lastExport = nil
        videoURL = nil
        datasetName = "dataset"
        status = "Run the pipeline (or label rallies), then Sample — or load a folder of frames."
    }

    private func beginSession(name: String, video: URL?) {
        previewTask?.cancel()
        samples = []
        selectedId = nil
        selectedBoxId = nil
        preview = nil
        lastExport = nil
        videoURL = video
        datasetName = name
    }

    private func makeDetector() -> YOLODetector {
        let detector = YOLODetector()
        detector.minConfidence = Float(prelabelConfidence)
        detector.suppressesStaticObjects = false
        return detector
    }

    // MARK: - Sampling

    func sample(from lab: RallyLabModel) async {
        guard let url = lab.videoURL, !isSampling else { return }
        let duration = lab.duration
        guard duration > 0 else { status = "Couldn't read the video duration."; return }

        let rallies = ralliesToSample(from: lab)
        guard !rallies.isEmpty || randomCount > 0 else {
            status = "No rallies to sample from — run the pipeline or mark some, or add random frames."
            return
        }

        isSampling = true
        defer { isSampling = false }
        beginSession(name: url.deletingPathExtension().lastPathComponent, video: url)

        let plan = Self.plan(
            rallies: rallies,
            evidence: lab.evidence,
            duration: duration,
            burstFPS: burstFPS,
            padding: rallyPadding,
            includeMissed: includeMissed,
            maxMissed: Int(maxMissed),
            randomCount: Int(randomCount)
        )
        status = "Extracting \(plan.count) frames…"

        let detector = makeDetector()
        let generator = Self.generator(for: url, maximumSize: Self.reviewMaxSize)
        var out: [FrameSample] = []
        out.reserveCapacity(plan.count)

        for (i, item) in plan.enumerated() {
            if Task.isCancelled { break }
            let t = CMTime(seconds: item.time, preferredTimescale: 600)
            guard let frame = try? await generator.image(at: t).image else { continue }
            let dets = detector.detect(in: frame, at: t)
            guard let thumb = Self.downscale(frame, toWidth: Self.thumbnailWidth) else { continue }
            out.append(FrameSample(
                time: item.time,
                source: item.source,
                thumbnail: thumb,
                boxes: dets.map { SampleBox(rect: $0.bbox, confidence: $0.confidence) }
            ))
            if i % 10 == 0 {
                status = "Pre-labeling… \(i + 1)/\(plan.count)"
                samples = out
            }
        }

        samples = out
        selectedId = out.first?.id
        let withBall = out.filter { !$0.boxes.isEmpty }.count
        status = "\(out.count) frames · detector found a ball in \(withBall) · review, then Export."
        loadPreviewForSelection()
    }

    /// Stills already on disk — a flywheel zip from /admin/flywheel, or an
    /// earlier export — pre-labeled and reviewed the same way. Subfolders are
    /// included; files are taken in name order.
    func loadFolder(_ folder: URL) async {
        guard !isSampling else { return }
        let files = Self.imageFiles(in: folder)
        guard !files.isEmpty else {
            status = "No JPEG or PNG files in \(folder.lastPathComponent)."
            return
        }

        isSampling = true
        defer { isSampling = false }
        beginSession(name: folder.lastPathComponent, video: nil)
        status = "Pre-labeling \(files.count) files…"

        let detector = makeDetector()
        var out: [FrameSample] = []
        out.reserveCapacity(files.count)

        for (i, file) in files.enumerated() {
            if Task.isCancelled { break }
            // Off the main thread: decoding a native-resolution JPEG per file
            // would otherwise stall the window for the whole folder.
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.loadImage(file, maxPixelSize: Int(Self.reviewMaxSize.width))
            }.value
            guard let image = decoded,
                  let thumb = Self.downscale(image, toWidth: Self.thumbnailWidth) else { continue }
            let dets = detector.detect(in: image, at: CMTime(value: CMTimeValue(i), timescale: 1))
            out.append(FrameSample(
                time: Double(i),
                source: .file(file),
                thumbnail: thumb,
                boxes: dets.map { SampleBox(rect: $0.bbox, confidence: $0.confidence) }
            ))
            if i % 10 == 0 {
                status = "Pre-labeling… \(i + 1)/\(files.count)"
                samples = out
            }
        }

        samples = out
        selectedId = out.first?.id
        let withBall = out.filter { !$0.boxes.isEmpty }.count
        status = "\(out.count) files · detector found a ball in \(withBall) · review, then Export."
        loadPreviewForSelection()
    }

    private nonisolated static func imageFiles(in folder: URL) -> [URL] {
        let types: Set<String> = ["jpg", "jpeg", "png"]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where types.contains(url.pathExtension.lowercased()) {
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Rally windows to burst-sample: hand labels when present and preferred,
    /// else the pipeline's decided rallies.
    private func ralliesToSample(from lab: RallyLabModel) -> [Interval] {
        if preferHandLabels, !lab.labels.isEmpty {
            return lab.labels.map { Interval(start: $0.start, end: $0.end) }
        }
        return lab.rawPredictions
    }

    struct PlannedFrame {
        let time: Double
        let source: FrameSample.Source
    }

    /// Which moments to pull, in time order. Pure so it can be reasoned about:
    /// bursts inside padded rallies, up to `maxMissed` in-rally frames the
    /// pipeline saw no ball in (spread evenly), and `randomCount` frames
    /// anywhere in the middle 96% of the video. Near-duplicates (closer than
    /// half a burst interval) are dropped.
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
                let t = Double.random(in: (0.02 * duration)...(0.98 * duration))
                planned.append(PlannedFrame(time: t, source: .random))
            }
        }

        planned.sort { $0.time < $1.time }
        var deduped: [PlannedFrame] = []
        for frame in planned {
            if let last = deduped.last, frame.time - last.time < step / 2 {
                // Same moment twice: keep one, but a "missed" tag is the more
                // informative label for it.
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

    func select(_ id: UUID?) {
        guard id != selectedId else { return }
        selectedId = id
        selectedBoxId = nil
        loadPreviewForSelection()
    }

    func selectNext(_ delta: Int) {
        guard !samples.isEmpty else { return }
        let current = samples.firstIndex { $0.id == selectedId } ?? -1
        let next = min(max(current + delta, 0), samples.count - 1)
        select(samples[next].id)
    }

    func toggleKeep(_ id: UUID? = nil) {
        guard let index = samples.firstIndex(where: { $0.id == (id ?? selectedId) }) else { return }
        samples[index].keep.toggle()
        samples[index].reviewed = true
    }

    func markReviewed(_ id: UUID? = nil) {
        guard let index = samples.firstIndex(where: { $0.id == (id ?? selectedId) }) else { return }
        samples[index].reviewed = true
    }

    func removeSelectedBox() {
        guard let boxId = selectedBoxId,
              let index = samples.firstIndex(where: { $0.id == selectedId }) else { return }
        samples[index].boxes.removeAll { $0.id == boxId }
        samples[index].reviewed = true
        selectedBoxId = nil
    }

    func addBox(_ rect: CGRect) {
        guard let index = samples.firstIndex(where: { $0.id == selectedId }) else { return }
        let box = SampleBox(rect: Self.clamp(rect), confidence: nil)
        samples[index].boxes.append(box)
        samples[index].reviewed = true
        selectedBoxId = box.id
    }

    func updateBox(_ boxId: UUID, rect: CGRect) {
        guard let index = samples.firstIndex(where: { $0.id == selectedId }),
              let b = samples[index].boxes.firstIndex(where: { $0.id == boxId }) else { return }
        samples[index].boxes[b].rect = Self.clamp(rect)
        samples[index].reviewed = true
    }

    /// Accept the frame as-is and move on — the fast path through a review.
    func acceptAndAdvance() {
        markReviewed()
        selectNext(1)
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
        let time = sample.time
        let video = videoURL
        previewTask = Task {
            let image: CGImage?
            if case .file(let file) = sample.source {
                image = await Task.detached {
                    Self.loadImage(file, maxPixelSize: Int(Self.reviewMaxSize.width))
                }.value
            } else if let video {
                let generator = Self.generator(for: video, maximumSize: Self.reviewMaxSize)
                image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            } else {
                image = nil
            }
            guard !Task.isCancelled, selectedId == id else { return }
            preview = image
        }
    }

    // MARK: - Export

    /// Writes the kept frames as a YOLO dataset under a folder named after the
    /// video (or the loaded folder). Video frames are re-read at native
    /// resolution — the review copies were downscaled; files are copied as
    /// they are. Returns nil when nothing was kept.
    func export(to root: URL) async -> SampleExportSummary? {
        guard !isExporting else { return nil }
        let kept = samples.filter(\.keep)
        guard !kept.isEmpty else { status = "Nothing kept to export."; return nil }

        isExporting = true
        defer { isExporting = false }

        let videoName = datasetName
        let dir = root.appendingPathComponent(Self.safeName(videoName), isDirectory: true)
        let fm = FileManager.default
        do {
            for sub in ["images/train", "images/val", "labels/train", "labels/val"] {
                try fm.createDirectory(at: dir.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
            }
        } catch {
            status = "Couldn't create the dataset folders: \(error.localizedDescription)"
            return nil
        }

        // A whole rally's burst goes to one side — consecutive frames are near
        // duplicates, and one in train with its neighbour in val would make
        // validation flatter you. Missed/random frames split individually.
        // Deterministic from the key, so re-exporting keeps the same split.
        func isValidation(_ s: FrameSample) -> Bool {
            let key: UInt64
            switch s.source {
            case .rally(let index): key = UInt64(index) &+ 1
            case .missed, .random: key = UInt64(max(0, s.time) * 1000) &+ 7_919
            case .file(let url): key = UInt64(truncatingIfNeeded: url.lastPathComponent.hashValue.magnitude)
            }
            let hashed = (key &* 0x9E37_79B9_7F4A_7C15) >> 33
            return Double(hashed % 10_000) / 10_000 < validationFraction
        }

        let generator = videoURL.map { Self.generator(for: $0, maximumSize: .zero) }
        var manifest = ["file,time,source,split,boxes,reviewed"]
        var images = 0, boxes = 0, validation = 0

        for (i, s) in kept.enumerated() {
            let split = isValidation(s) ? "val" : "train"
            let base: String
            let imageURL: URL
            switch s.source {
            case .file(let file):
                base = Self.safeName(file.deletingPathExtension().lastPathComponent)
                imageURL = dir.appendingPathComponent("images/\(split)/\(base).\(file.pathExtension.lowercased())")
                do {
                    if FileManager.default.fileExists(atPath: imageURL.path) {
                        try FileManager.default.removeItem(at: imageURL)
                    }
                    try FileManager.default.copyItem(at: file, to: imageURL)
                } catch {
                    status = "Couldn't copy \(file.lastPathComponent): \(error.localizedDescription)"
                    continue
                }
            case .rally, .missed, .random:
                base = String(format: "%@_%08.3f", Self.safeName(videoName), s.time).replacingOccurrences(of: ".", with: "_")
                imageURL = dir.appendingPathComponent("images/\(split)/\(base).jpg")
                guard let generator,
                      let frame = try? await generator.image(at: CMTime(seconds: s.time, preferredTimescale: 600)).image,
                      Self.writeJPEG(frame, to: imageURL, quality: jpegQuality) else {
                    status = "Skipped a frame at \(String(format: "%.2f", s.time))s that couldn't be read."
                    continue
                }
            }
            let labelURL = dir.appendingPathComponent("labels/\(split)/\(base).txt")
            let lines = s.boxes.map(Self.yoloLine)
            do {
                try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
                    .write(to: labelURL, atomically: true, encoding: .utf8)
            } catch {
                status = "Couldn't write \(labelURL.lastPathComponent): \(error.localizedDescription)"
                return nil
            }
            manifest.append("\(imageURL.lastPathComponent),\(String(format: "%.3f", s.time)),\(s.source.label),\(split),\(s.boxes.count),\(s.reviewed)")
            images += 1
            boxes += s.boxes.count
            if split == "val" { validation += 1 }
            if i % 10 == 0 { status = "Exporting… \(i + 1)/\(kept.count)" }
        }

        do {
            try manifest.joined(separator: "\n").write(to: dir.appendingPathComponent("manifest.csv"), atomically: true, encoding: .utf8)
            try Self.dataYAML(root: dir).write(to: dir.appendingPathComponent("data.yaml"), atomically: true, encoding: .utf8)
        } catch {
            status = "Couldn't write the dataset metadata: \(error.localizedDescription)"
            return nil
        }

        let summary = SampleExportSummary(directory: dir, images: images, boxes: boxes, validation: validation)
        lastExport = summary
        status = "Exported \(images) frames (\(boxes) boxes, \(validation) val) to \(dir.lastPathComponent)/."
        return summary
    }

    /// One YOLO label line: class 0, then centre + size normalized to the
    /// image with a TOP-left origin — the Vision box is bottom-left, so only
    /// the centre's Y flips.
    nonisolated static func yoloLine(_ box: SampleBox) -> String {
        let r = box.rect
        return String(format: "0 %.6f %.6f %.6f %.6f", r.midX, 1 - r.midY, r.width, r.height)
    }

    nonisolated static func dataYAML(root: URL) -> String {
        """
        # Written by RallyLab's Sampler. Paths are absolute to this export.
        path: \(root.path)
        train: images/train
        val: images/val

        names:
          0: volleyball

        """
    }

    nonisolated static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(cleaned).isEmpty ? "video" : String(cleaned)
    }

    // MARK: - Frame helpers

    private nonisolated static func generator(for url: URL, maximumSize: CGSize) -> AVAssetImageGenerator {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = maximumSize
        // Exact frames: the label must describe the very frame that's exported.
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return gen
    }

    /// Decode a still from disk, capped to `maxPixelSize` on its longer side.
    /// Orientation metadata is applied so a phone JPEG comes up upright,
    /// matching what the detector and the export see.
    private nonisolated static func loadImage(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func downscale(_ image: CGImage, toWidth width: Int) -> CGImage? {
        guard image.width > width else { return image }
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private nonisolated static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
