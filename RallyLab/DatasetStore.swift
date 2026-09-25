//
//  DatasetStore.swift
//  RallyLab
//
//  The detector training dataset on disk — one folder that every sampled
//  video and loaded frames folder accumulates into, in the layout Ultralytics
//  reads directly:
//
//    <root>/images/{train,val}/<video>_<t>.jpg   written once, native res
//    <root>/labels/{train,val}/<video>_<t>.txt   rewritten as review edits land
//    <root>/sessions/<video>.json                every frame's boxes + review state
//    <root>/data.yaml
//
//  A video is assigned to train or val as a whole when it's added, so frames
//  from one game never sit on both sides of the split.
//

import CoreGraphics
import Foundation

struct BoxRecord: Codable, Equatable {
    /// Vision-normalized, origin bottom-left, [0,1].
    var x: Double, y: Double, w: Double, h: Double
    var confidence: Float?

    init(_ box: SampleBox) {
        x = box.rect.minX; y = box.rect.minY; w = box.rect.width; h = box.rect.height
        confidence = box.confidence
    }

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct FrameRecord: Codable, Identifiable, Equatable {
    let id: UUID
    /// Relative to the dataset root, e.g. `images/train/game_0012_500.jpg`.
    let file: String
    let time: Double
    /// `rally:<index>`, `missed`, `random`, or `file`.
    let source: String
    var boxes: [BoxRecord]
    var keep: Bool
    var reviewed: Bool

    var labelFile: String {
        file.replacingOccurrences(of: "images/", with: "labels/")
            .replacingOccurrences(of: ".jpg", with: ".txt")
            .replacingOccurrences(of: ".jpeg", with: ".txt")
            .replacingOccurrences(of: ".png", with: ".txt")
    }
}

struct VideoSession: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let sourcePath: String
    let split: String          // "train" | "val"
    let addedAt: Date
    var frames: [FrameRecord]

    var reviewedCount: Int { frames.filter(\.reviewed).count }
    var boxCount: Int { frames.filter(\.keep).reduce(0) { $0 + $1.boxes.count } }
}

struct DatasetStats {
    var videos = 0, valVideos = 0, frames = 0, reviewed = 0, boxes = 0
}

final class DatasetStore: @unchecked Sendable {

    static let defaultRoot = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RallyLab/Dataset", isDirectory: true)

    let root: URL
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
    }

    private var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    private var dataYAML: URL { root.appendingPathComponent("data.yaml") }

    func prepare() throws {
        for sub in ["images/train", "images/val", "labels/train", "labels/val", "sessions"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    // MARK: - Sessions

    func loadSessions() -> [VideoSession] {
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> VideoSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(VideoSession.self, from: data)
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    func save(_ session: VideoSession) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(session).write(to: sessionURL(session.name), options: .atomic)
    }

    func remove(_ session: VideoSession) throws {
        for frame in session.frames {
            try? fm.removeItem(at: root.appendingPathComponent(frame.file))
            try? fm.removeItem(at: root.appendingPathComponent(frame.labelFile))
        }
        try? fm.removeItem(at: sessionURL(session.name))
    }

    private func sessionURL(_ name: String) -> URL {
        sessionsDir.appendingPathComponent("\(name).json")
    }

    /// Whole videos go to val: the first video is train, the second is val
    /// (a trainer needs one), and after that a video goes to val whenever
    /// val's share has fallen under `valFraction`, so the split converges as
    /// the dataset grows.
    func splitForNewVideo(existing: [VideoSession], valFraction: Double) -> String {
        guard valFraction > 0 else { return "train" }
        let val = existing.filter { $0.split == "val" }.count
        let total = existing.count
        guard total > 0 else { return "train" }
        return Double(val) / Double(total) < valFraction ? "val" : "train"
    }

    /// A name no other session uses, so two exports of the same video don't
    /// overwrite each other's frames.
    func uniqueName(for base: String, existing: [VideoSession]) -> String {
        let safe = DatasetStore.safeName(base)
        guard existing.contains(where: { $0.name == safe }) else { return safe }
        var n = 2
        while existing.contains(where: { $0.name == "\(safe)_\(n)" }) { n += 1 }
        return "\(safe)_\(n)"
    }

    // MARK: - Files

    func imageRelativePath(session name: String, split: String, time: Double) -> String {
        let stamp = String(format: "%08.3f", time).replacingOccurrences(of: ".", with: "_")
        return "images/\(split)/\(name)_\(stamp).jpg"
    }

    func imageRelativePath(session name: String, split: String, copiedFile: URL) -> String {
        let base = DatasetStore.safeName(copiedFile.deletingPathExtension().lastPathComponent)
        return "images/\(split)/\(name)__\(base).\(copiedFile.pathExtension.lowercased())"
    }

    /// Write (or clear) one frame's YOLO label file. A frame that's not kept,
    /// or not reviewed when only reviewed labels are wanted, has its label
    /// file removed so the trainer never sees it — Ultralytics skips images
    /// without a label file only when `keep` is false, so the image itself is
    /// moved aside too.
    func writeLabel(for frame: FrameRecord, reviewedOnly: Bool) throws {
        let labelURL = root.appendingPathComponent(frame.labelFile)
        let imageURL = root.appendingPathComponent(frame.file)
        let excluded = !frame.keep || (reviewedOnly && !frame.reviewed)
        let parkedURL = parkedImageURL(for: frame)

        if excluded {
            try? fm.removeItem(at: labelURL)
            if fm.fileExists(atPath: imageURL.path) {
                try fm.createDirectory(at: parkedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: parkedURL)
                try fm.moveItem(at: imageURL, to: parkedURL)
            }
            return
        }

        if fm.fileExists(atPath: parkedURL.path), !fm.fileExists(atPath: imageURL.path) {
            try fm.moveItem(at: parkedURL, to: imageURL)
        }
        let lines = frame.boxes.map { DatasetStore.yoloLine($0.rect) }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: labelURL, atomically: true, encoding: .utf8)
    }

    /// Excluded frames keep their image under `excluded/` so un-discarding
    /// later doesn't need the video again.
    private func parkedImageURL(for frame: FrameRecord) -> URL {
        root.appendingPathComponent("excluded").appendingPathComponent(frame.file)
    }

    /// Where the frame's image currently lives (kept or parked).
    func currentImageURL(for frame: FrameRecord) -> URL {
        let live = root.appendingPathComponent(frame.file)
        return fm.fileExists(atPath: live.path) ? live : parkedImageURL(for: frame)
    }

    func writeDataYAML() throws {
        let text = """
        # Written by RallyLab's Sampler. Whole videos are assigned to train or val.
        path: \(root.path)
        train: images/train
        val: images/val

        names:
          0: volleyball

        """
        try text.write(to: dataYAML, atomically: true, encoding: .utf8)
    }

    func stats(_ sessions: [VideoSession]) -> DatasetStats {
        var s = DatasetStats()
        s.videos = sessions.count
        s.valVideos = sessions.filter { $0.split == "val" }.count
        for session in sessions {
            s.frames += session.frames.count
            s.reviewed += session.reviewedCount
            s.boxes += session.boxCount
        }
        return s
    }

    // MARK: - Formats

    /// One YOLO label line: class 0, then centre + size normalized to the
    /// image with a TOP-left origin — the Vision box is bottom-left, so only
    /// the centre's Y flips.
    static func yoloLine(_ r: CGRect) -> String {
        String(format: "0 %.6f %.6f %.6f %.6f", r.midX, 1 - r.midY, r.width, r.height)
    }

    static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(cleaned).isEmpty ? "video" : String(cleaned)
    }

    /// The `yolo` invocation for this dataset — copied to the clipboard, not
    /// run here, so the training environment stays the user's.
    func trainCommand(imgsz: Int, epochs: Int, baseModel: String) -> String {
        "yolo detect train data=\"\(dataYAML.path)\" model=\(baseModel) imgsz=\(imgsz) epochs=\(epochs) patience=30 batch=-1 close_mosaic=15 project=\"\(root.appendingPathComponent("runs").path)\" name=ball"
    }
}
