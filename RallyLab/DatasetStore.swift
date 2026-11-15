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
//  No frame of a withheld recording — the final test, a lineage or legacy
//  holdout, an alias of one (D-002, D-017) — is written into images/ or
//  labels/: `writeLabels`, the folder's one writer, parks it under excluded/.
//  A dataset with no pipeline_tuning/validation.json withholds nothing.
//

import CoreGraphics
import Foundation

struct BoxRecord: Codable, Equatable {
    /// Vision-normalized, origin bottom-left, [0,1].
    var x: Double, y: Double, w: Double, h: Double
    var confidence: Float?
    /// Carried over from earlier frames as a ball that stayed put; absent
    /// otherwise (and in datasets from before it existed).
    var held: Bool?

    init(_ box: SampleBox) {
        x = box.rect.minX; y = box.rect.minY; w = box.rect.width; h = box.rect.height
        confidence = box.confidence
        held = box.held ? true : nil
    }

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// A spot where the detector keeps guessing a ball and you keep deleting
/// it. From the second deletion on, its guesses on other unreviewed frames
/// are taken off where the spot still looks as it did (see SamplerModel).
struct RejectedSpot: Codable, Equatable {
    /// Vision-normalised, as last deleted.
    var x: Double, y: Double, w: Double, h: Double
    /// The frame it was last deleted on: what it looks like.
    var frame: UUID
    var count: Int
    /// Guesses taken off other frames, so forgetting the spot can put them back.
    var hidden: [HiddenBox] = []

    struct HiddenBox: Codable, Equatable {
        let frame: UUID
        let box: BoxRecord
    }

    var rect: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { (x, y, w, h) = (newValue.minX, newValue.minY, newValue.width, newValue.height) }
    }
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
    /// Places in this video where you've deleted the detector's guess.
    var rejected: [RejectedSpot]? = nil
    /// Rallies labeled frame by frame in the Track tab.
    var tracks: [TrackedRally]? = nil
    /// Every rally's start and end is marked (Track tab → Rally Times), so
    /// the video can score missed and false rallies.
    var ralliesMarked: Bool? = nil
    /// Tracked rallies the phone had at the last sync: one gone from here
    /// since was deleted here, so the sync deletes it there too.
    var syncedTrackIds: [UUID]? = nil
    /// Starts of found rallies you said aren't rallies (Label → Not a rally).
    var notRallies: [Double]? = nil
    /// Finished rallies whose boxes have been fitted to the ball (BoxFitter).
    var fittedTracks: [UUID]? = nil
    /// The net as NetDetector found it (the median box over sampled frames,
    /// Vision-normalised, upright), for which side of it a touch was on.
    var netBox: TrackCandidate? = nil
    /// Stretches of the video that are not footage — the clip started in the
    /// middle of a rally, an editor put an instant replay in — as marked in
    /// the live pass (raw, as marked; read through `cutRanges`). D-030.
    var cuts: [CutRange]? = nil
    /// Set aside from labeling (the backlog, migration 053): why and when; the server's value, copied by the
    /// sync. nil: not set aside.
    var backlogReason: String? = nil
    var backlogAt: Date? = nil
    /// Why the session was made with no sampled frames: it was registered for a withheld card, so no
    /// pipeline or detector ran over the recording and nothing was pre-labeled (`SamplerModel.admission`).
    /// nil: made by the ordinary ingest.
    var notSampled: String? = nil

    /// The cut ranges as every consumer reads them: normalised.
    var cutRanges: [CutRange] { (cuts ?? []).normalised() }

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

    enum LoadError: LocalizedError {
        case unlistable(URL)
        case malformed(URL)
        var errorDescription: String? {
            switch self {
            case .unlistable(let dir): return "\(dir.path) exists but can't be listed; the sessions it holds are unknown."
            case .malformed(let file): return "\(file.path) can't be decoded; its tracks and frames are unknown. Repair or restore it before building a manifest or reserving anything."
            }
        }
    }

    /// Every session, or an error naming the first file that can't be read.
    /// For audits: an unreadable session is unknown history, not no history.
    /// (`loadSessions()` stays lenient for the UI.)
    func loadSessionsStrict() throws -> [VideoSession] {
        guard fm.fileExists(atPath: sessionsDir.path) else { return [] }
        let files: [URL]
        do { files = try fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) } catch { throw LoadError.unlistable(sessionsDir) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try files.filter { $0.pathExtension == "json" }.map { url in
            guard let data = try? Data(contentsOf: url), let session = try? decoder.decode(VideoSession.self, from: data) else { throw LoadError.malformed(url) }
            return session
        }
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
            // Unreviewed and discarded frames sit parked under excluded/.
            try? fm.removeItem(at: parkedImageURL(for: frame))
            try? fm.removeItem(at: root.appendingPathComponent(frame.labelFile))
        }
        try? fm.removeItem(at: sessionURL(session.name))
    }

    /// Whether a session file of this name is there — one that can't be read is there too.
    func hasSession(named name: String) -> Bool {
        fm.fileExists(atPath: sessionURL(name).path)
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

    /// Write (or clear) the YOLO label files of these frames of the recording `session`. A frame
    /// that's not kept, or not reviewed when only reviewed labels are wanted, has its label file
    /// removed so the trainer never sees it — Ultralytics skips images without a label file only
    /// when `keep` is false, so the image itself is moved aside too.
    /// `cuts`: the recording's cut ranges (not footage; D-030) — a frame inside one is parked like a
    /// discarded one, and back when the cut goes.
    /// A frame of a withheld recording — the final test, a lineage or legacy holdout, an alias of one
    /// (D-002, D-017; owner, 2026-11-12 §5C) — is never in the dataset a trainer is pointed at, whatever
    /// the options: parked the same way, where review still finds it (`currentImageURL`). The
    /// reservations are asked as they are at this call (`ScoringExposure.Closures.current`). Every
    /// writer comes through here, so none can put one back. Throws, with nothing written or moved, when
    /// the reservations or the project can't be read (fails closed). Returns how many of the frames are
    /// in the dataset now.
    @discardableResult
    func writeLabels(for frames: [FrameRecord], of session: String, reviewedOnly: Bool, cuts: [CutRange]) throws -> Int {
        let withheld = try ScoringExposure.Closures.current(in: root).withheld.contains(session)
        return try frames.reduce(0) { count, frame in
            let excluded = withheld || !frame.keep || (reviewedOnly && !frame.reviewed) || cuts.contains(frame.time)
            return try count + (writeLabel(for: frame, excluded: excluded) ? 1 : 0)
        }
    }

    /// One frame's label file and image, in the dataset or parked out of it; whether it is in.
    private func writeLabel(for frame: FrameRecord, excluded: Bool) throws -> Bool {
        let labelURL = root.appendingPathComponent(frame.labelFile)
        let imageURL = root.appendingPathComponent(frame.file)
        let parkedURL = parkedImageURL(for: frame)

        if excluded {
            try? fm.removeItem(at: labelURL)
            if fm.fileExists(atPath: imageURL.path) {
                try fm.createDirectory(at: parkedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: parkedURL)
                try fm.moveItem(at: imageURL, to: parkedURL)
            }
            return false
        }

        if fm.fileExists(atPath: parkedURL.path), !fm.fileExists(atPath: imageURL.path) {
            try fm.moveItem(at: parkedURL, to: imageURL)
        }
        let lines = frame.boxes.map { DatasetStore.yoloLine($0.rect) }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: labelURL, atomically: true, encoding: .utf8)
        return true
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
        # NOT a model-lineage dataset (D-017/D-018). RallyLab keeps the frames of withheld
        # recordings (final test, candidates, lineage holdout, legacy holdout, their aliases) out
        # of images/ and labels/ whenever it writes them — they are parked under excluded/ — but
        # nothing audits this folder: unsupported for L2 training. A lineage trains only from a
        # package written by `RallyLab --project <name> --package-l2` with a passing preflight.
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
