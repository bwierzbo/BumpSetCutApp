//
//  NetLabels.swift
//  RallyLab
//
//  A person's net box for a recording: one upright frame, taken from the
//  middle of its first marked rally (the court in play, nobody parked in
//  front of the net), the box drawn or confirmed by hand. Where the old net
//  model finds the net, its box is offered as a proposal and stays marked
//  as one; only what a person confirmed is a label. Kept in
//  <project>/net-labels.json, apart from the sessions (the open app re-saves
//  those from memory every half minute). Withheld recordings (the lineage
//  and legacy holdouts) and handheld ones are never labeled: the first must
//  stay out of every training set, the second has no net that holds still.
//
//  `RallyLab --project P --export-net-dataset <dir>` writes one JPEG and one
//  YOLO-format line per labeled recording, with a manifest, and records the
//  use in the exposure ledger before the folder is put in place.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct NetLabel: Codable, Equatable {
    /// Seconds into the video of the frame the box was drawn on.
    var time: Double
    /// Vision-normalised (bottom-up) box in the upright frame.
    var box: TrackCandidate
    /// The box started as the old net model's proposal.
    var proposed: Bool
    /// A person moved or resized it (false: confirmed as proposed, or drawn by hand).
    var adjusted: Bool
    var reviewedAt: Date
    /// The upright frame's pixel size at labeling, so an export can check its decode.
    var frameWidth: Int
    var frameHeight: Int
    /// The recording's file identity (ReservedVideos.effectiveFingerprint) when labeled:
    /// a video that later takes the same id does not inherit the label.
    var fingerprint: String
}

/// `<project>/net-labels.json`: video id → label. Read whole, written atomically;
/// a file that exists but can't be read is an error, never an empty set.
struct NetLabelStore {
    let url: URL

    init(projectDir: URL) { url = projectDir.appendingPathComponent("net-labels.json") }

    func load() throws -> [String: NetLabel] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: NetLabel].self, from: Data(contentsOf: url))
    }

    func save(_ labels: [String: NetLabel]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(labels).write(to: url, options: .atomic)
    }
}

enum NetLabels {
    enum Skip: String, Codable { case withheld, handheld, unidentified }

    /// Why a recording gets no net label, or nil when it should have one. A
    /// recording without a file identity can't carry a label that is checked
    /// against the file later, so it is skipped too.
    static func skip(video: String, camera: String, withheld: Set<String>, fingerprint: String?) -> Skip? {
        if withheld.contains(video) { return .withheld }
        if camera.lowercased().hasPrefix("handheld") { return .handheld }
        if fingerprint == nil { return .unidentified }
        return nil
    }

    /// Where to take the frame: the middle of the first marked rally at least
    /// `minRally` seconds long, else the middle of the video.
    static func frameTime(duration: Double, rallies: [(start: Double, end: Double)], minRally: Double = 2) -> Double {
        if let r = rallies.sorted(by: { $0.start < $1.start }).first(where: { $0.end - $0.start >= minRally && $0.end <= duration }) {
            return (r.start + r.end) / 2
        }
        return duration / 2
    }

    /// The YOLO text line for class 0: centre x, centre y (top-down), width and
    /// height, each a fraction of the frame. `box` is Vision-normalised (bottom-up)
    /// and is clipped to the frame first.
    static func yoloLine(_ box: CGRect) -> String {
        let r = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width > 0, r.height > 0 else { return "" }
        return String(format: "0 %.6f %.6f %.6f %.6f", r.midX, 1 - r.midY, r.width, r.height)
    }

    /// Decode the upright frame at `time` (within 0.3 s; the net doesn't move
    /// frame to frame), at most `longSide` pixels on its long side.
    static func frame(of url: URL, at time: Double, longSide: CGFloat = 1920) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: longSide, height: longSide)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        return try await gen.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    static func duration(of url: URL) async -> Double {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.92) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

/// The export: images/<video>.jpg + labels/<video>.txt + data.yaml + net-dataset.json.
enum NetDatasetExport {
    struct Entry: Codable, Equatable {
        var video: String
        var clip: String
        var camera: String
        var time: Double
        var box: TrackCandidate
        var proposed: Bool
        var adjusted: Bool
        var reviewedAt: Date
        var image: String
        var imageSHA256: String
        var width: Int
        var height: Int
        var fingerprint: String
    }

    struct Skipped: Codable, Equatable {
        var video: String
        var reason: String
    }

    struct Manifest: Codable {
        var createdAt: Date
        var project: String
        var labeled: Int
        var entries: [Entry]
        var skipped: [Skipped]
        var note: String
    }

    struct Source {
        var video: String
        var clip: String
        var camera: String
        var url: URL
        /// The file's identity now (ReservedVideos.effectiveFingerprint).
        var fingerprint: String?
    }

    /// Which recordings go out and which stay, in a stable order. A withheld
    /// recording is refused even if someone labeled it; a label whose
    /// fingerprint is not this file's is another recording's and is refused;
    /// a recording without a label is listed as skipped so the count is explained.
    static func plan(labels: [String: NetLabel], sources: [Source], withheld: Set<String>)
        -> (export: [Source], skipped: [Skipped]) {
        var export: [Source] = []
        var skipped: [Skipped] = []
        for s in sources.sorted(by: { $0.video < $1.video }) {
            if let why = NetLabels.skip(video: s.video, camera: s.camera, withheld: withheld, fingerprint: s.fingerprint) {
                skipped.append(Skipped(video: s.video, reason: why.rawValue))
            } else if let label = labels[s.video] {
                if label.fingerprint == s.fingerprint { export.append(s) }
                else { skipped.append(Skipped(video: s.video, reason: "label is another recording's (fingerprint differs)")) }
            } else {
                skipped.append(Skipped(video: s.video, reason: "unlabeled"))
            }
        }
        return (export, skipped)
    }

    /// Write the dataset into `dir` (created; must not exist). Every frame is
    /// decoded again from the video at the label's time and must come back at
    /// the size the label was drawn on, or the export stops.
    static func write(labels: [String: NetLabel], sources: [Source], withheld: Set<String>,
                      project: String, to dir: URL, progress: (String) -> Void = { _ in }) async throws -> Manifest {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dir.path])
        }
        let (export, skipped) = plan(labels: labels, sources: sources, withheld: withheld)
        try fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("labels"), withIntermediateDirectories: true)
        var entries: [Entry] = []
        for (i, s) in export.enumerated() {
            guard let label = labels[s.video] else { continue }
            progress("\(i + 1)/\(export.count) \(s.video)")
            let image = try await NetLabels.frame(of: s.url, at: label.time)
            guard image.width == label.frameWidth, image.height == label.frameHeight else {
                throw NetDatasetError.frameSizeChanged(s.video, labeled: (label.frameWidth, label.frameHeight),
                                                       decoded: (image.width, image.height))
            }
            let line = NetLabels.yoloLine(label.box.rect)
            guard !line.isEmpty else { throw NetDatasetError.emptyBox(s.video) }
            let imageFile = "images/\(s.video).jpg"
            let imageURL = dir.appendingPathComponent(imageFile)
            try NetLabels.writeJPEG(image, to: imageURL)
            try (line + "\n").write(to: dir.appendingPathComponent("labels/\(s.video).txt"), atomically: true, encoding: .utf8)
            guard let digest = DatasetSplitManifest.sha256(of: imageURL) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: imageURL.path])
            }
            entries.append(Entry(video: s.video, clip: s.clip, camera: s.camera, time: label.time, box: label.box,
                                 proposed: label.proposed, adjusted: label.adjusted, reviewedAt: label.reviewedAt,
                                 image: imageFile, imageSHA256: digest, width: image.width, height: image.height,
                                 fingerprint: label.fingerprint))
        }
        let yaml = """
        # One labeled frame per recording; split by recording group before training, never here.
        path: .
        train: images
        val: images
        names:
          0: net

        """
        try yaml.write(to: dir.appendingPathComponent("data.yaml"), atomically: true, encoding: .utf8)
        let manifest = Manifest(createdAt: Date(), project: project, labeled: entries.count, entries: entries, skipped: skipped,
                                note: "Upright frames; boxes Vision-normalised (bottom-up) in the manifest, YOLO top-down in labels/. Withheld, handheld and unidentified recordings are not exported; a label whose fingerprint is not the file's is refused.")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("net-dataset.json"), options: .atomic)
        return manifest
    }
}

/// Who each recording is and which are withheld, for the tab: from the project's
/// split manifest (`manifests/manifest.json`, written by `RallyLab --project P
/// --manifest`), which records every video's file fingerprint and split. Reading
/// the files themselves (4 MB of head and tail each) over the footage share takes
/// half an hour for a project and blocks for the SMB timeout when the share drops,
/// so the tab never does; the export does, and refuses a label whose fingerprint
/// is not the file's. The manifest counts only while it is of the project as it
/// is now: its recorded hashes of project.json and validation.json must be the
/// files' — otherwise the tab is blocked until the manifest is written again.
struct NetInventory: Equatable {
    /// Withheld in the manifest: lineage or legacy holdout, final test or candidate, or reserved as an alias of one.
    var withheld: Set<String>
    /// Each video's file fingerprint as the manifest recorded it; a video without one is unidentified.
    var fingerprint: [String: String]

    static let withheldSplits: Set<DatasetSplit> = [.lineageHoldout, .legacyHoldout, .finalTest, .finalTestCandidate]

    static func manifestURL(in projectDir: URL) -> URL { projectDir.appendingPathComponent("manifests/manifest.json") }

    /// Read and check the project's manifest. Throws when it is missing, unreadable, or not of
    /// the project.json and validation.json as they are now.
    static func load(projectDir: URL) throws -> NetInventory {
        let url = manifestURL(in: projectDir)
        guard let manifest = try DatasetSplitManifest.readStrict(from: url) else { throw NetInventoryError.noManifest(url) }
        let validation = projectDir.appendingPathComponent("pipeline_tuning/validation.json")
        return try inventory(manifest, projectJSONHash: DatasetSplitManifest.sha256(of: projectDir.appendingPathComponent("project.json")),
                             validationJSONHash: FileManager.default.fileExists(atPath: validation.path) ? DatasetSplitManifest.sha256(of: validation) : nil)
    }

    /// The manifest's answer, if its hashes are the files' (`validationJSONHash` nil = no file, which
    /// matches a manifest written when there was none).
    static func inventory(_ manifest: DatasetSplitManifest, projectJSONHash: String?, validationJSONHash: String?) throws -> NetInventory {
        guard let projectJSONHash, manifest.hashes.projectJson == projectJSONHash else { throw NetInventoryError.stale("project.json") }
        guard manifest.hashes.validationJson == validationJSONHash else { throw NetInventoryError.stale("pipeline_tuning/validation.json") }
        var withheld = Set<String>()
        var fingerprint: [String: String] = [:]
        for row in manifest.videos {
            if withheldSplits.contains(row.split) || row.reservedAs != nil { withheld.insert(row.video) }
            if let print = row.fingerprint, !print.isEmpty { fingerprint[row.video] = print }
        }
        return NetInventory(withheld: withheld, fingerprint: fingerprint)
    }
}

enum NetInventoryError: LocalizedError, Equatable {
    case noManifest(URL)
    case stale(String)

    var errorDescription: String? {
        switch self {
        case .noManifest(let url):
            return "no split manifest at \(url.path) — write it with `RallyLab --project <name> --manifest`."
        case .stale(let file):
            return "the split manifest is not of this project's \(file) — write it again with `RallyLab --project <name> --manifest`."
        }
    }
}

enum NetDatasetError: LocalizedError {
    case frameSizeChanged(String, labeled: (Int, Int), decoded: (Int, Int))
    case emptyBox(String)

    var errorDescription: String? {
        switch self {
        case let .frameSizeChanged(video, labeled, decoded):
            return "\(video): the frame decoded at \(decoded.0)×\(decoded.1), the label was drawn on \(labeled.0)×\(labeled.1) — the video changed since; label it again."
        case .emptyBox(let video):
            return "\(video): the net box lies outside the frame."
        }
    }
}
