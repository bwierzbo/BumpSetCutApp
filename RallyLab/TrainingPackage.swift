//
//  TrainingPackage.swift
//  RallyLab
//
//  A frozen, self-contained copy of a dataset to train on another machine.
//  Only frames that are kept and reviewed go in. The data.yaml has no
//  absolute `path:`, so Ultralytics resolves images/ and labels/ next to
//  the yaml wherever the folder is unzipped. Each package is also the
//  record of exactly what a model was trained on: its manifest lists every
//  image, the clip it came from, its split and its box count.
//
//  Frames from phone video that's stored sideways (portrait) are reviewed
//  upright, but the app's pipeline runs the detector on the stored frame.
//  So each such frame also goes in as it's stored — the "_raw" copy, image
//  and boxes turned back — and the model learns both views.
//
//    <dataset>/exports/<name>-<yyyyMMdd-HHmm>/
//      data.yaml  README.txt  manifest.csv  summary.json
//      images/{train,val}/  labels/{train,val}/
//    <dataset>/exports/<name>-<yyyyMMdd-HHmm>.zip
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum TrainingPackage {

    struct Summary: Codable {
        let name: String
        let createdAt: Date
        let clips: Int
        let trainImages: Int
        let valImages: Int
        let boxes: Int
        let emptyImages: Int
        /// Of the images above, the stored-orientation copies of portrait frames.
        var rawCopies: Int = 0
    }

    enum PackageError: LocalizedError {
        case nothingReviewed, noValidation, zipFailed
        var errorDescription: String? {
            switch self {
            case .nothingReviewed: return "No reviewed frames yet — review some before packaging."
            case .noValidation: return "No reviewed frames in any val clip. Set at least one clip to Val and review it."
            case .zipFailed: return "The package folder was written, but zipping it failed."
            }
        }
    }

    /// Write the package and its zip. Returns the zip's URL and the summary.
    static func export(sessions: [VideoSession], store: DatasetStore, name: String) async throws -> (zip: URL, summary: Summary) {
        let frames = sessions.flatMap { session in
            session.frames.filter { $0.keep && $0.reviewed }.map { (session, $0) }
        }
        guard !frames.isEmpty else { throw PackageError.nothingReviewed }
        guard frames.contains(where: { $0.0.split == "val" }) else { throw PackageError.noValidation }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let now = Date()
        let packageName = "\(DatasetStore.safeName(name))-\(stamp.string(from: now))"
        let exports = store.root.appendingPathComponent("exports", isDirectory: true)
        let dir = exports.appendingPathComponent(packageName, isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        for sub in ["images/train", "images/val", "labels/train", "labels/val"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }

        var rotations: [String: StoredRotation] = [:]
        for session in Set(frames.map(\.0.name)) {
            if let path = frames.first(where: { $0.0.name == session })?.0.sourcePath,
               let rotation = await StoredRotation.of(video: URL(fileURLWithPath: path)) {
                rotations[session] = rotation
            }
        }

        var manifest = ["image,clip,split,source,time,boxes"]
        var counts = (train: 0, val: 0, boxes: 0, empty: 0, raw: 0)
        func add(_ fileName: String, boxes: [CGRect], session: VideoSession, frame: FrameRecord, split: String,
                 write: (URL) throws -> Void) throws {
            try write(dir.appendingPathComponent("images/\(split)/\(fileName)"))
            let label = dir.appendingPathComponent("labels/\(split)/\((fileName as NSString).deletingPathExtension).txt")
            let lines = boxes.map(DatasetStore.yoloLine)
            try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: label, atomically: true, encoding: .utf8)
            manifest.append("\(fileName),\(session.name),\(split),\(frame.source),\(String(format: "%.3f", frame.time)),\(boxes.count)")
            if split == "val" { counts.val += 1 } else { counts.train += 1 }
            counts.boxes += boxes.count
            if boxes.isEmpty { counts.empty += 1 }
        }
        for (session, frame) in frames {
            let split = session.split == "val" ? "val" : "train"
            let fileName = (frame.file as NSString).lastPathComponent
            let source = store.currentImageURL(for: frame)
            let boxes = frame.boxes.map(\.rect)
            try add(fileName, boxes: boxes, session: session, frame: frame, split: split) {
                try fm.copyItem(at: source, to: $0)
            }
            if let rotation = rotations[session.name] {
                let rawName = (fileName as NSString).deletingPathExtension + "_raw.jpg"
                try add(rawName, boxes: boxes.map(rotation.storedBox), session: session, frame: frame, split: split) {
                    try rotation.writeStoredImage(from: source, to: $0)
                }
                counts.raw += 1
            }
        }

        var summary = Summary(name: packageName, createdAt: now,
                              clips: Set(frames.map { $0.0.name }).count,
                              trainImages: counts.train, valImages: counts.val,
                              boxes: counts.boxes, emptyImages: counts.empty)
        summary.rawCopies = counts.raw
        try manifest.joined(separator: "\n").write(to: dir.appendingPathComponent("manifest.csv"), atomically: true, encoding: .utf8)
        try dataYAML.write(to: dir.appendingPathComponent("data.yaml"), atomically: true, encoding: .utf8)
        try readme(summary).write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: dir.appendingPathComponent("summary.json"))

        let zip = exports.appendingPathComponent("\(packageName).zip")
        try? fm.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // No resource forks or extended attributes: they'd unpack on Windows as
        // "._name.jpg" files that look like (unreadable) images.
        ditto.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent",
                           dir.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw PackageError.zipFailed }
        return (zip, summary)
    }

    /// No `path:` on purpose: Ultralytics then treats the yaml's own folder
    /// as the dataset root, so the package trains wherever it's unzipped.
    static let dataYAML = """
    # RallyLab training package. Paths are relative to this file.
    train: images/train
    val: images/val

    names:
      0: volleyball

    """

    static func readme(_ s: Summary) -> String {
        """
        RallyLab training package — \(s.name)

        \(s.trainImages) train images, \(s.valImages) val images, \(s.boxes) ball boxes,
        \(s.emptyImages) images with no ball, from \(s.clips) clips. Every image here was
        reviewed by hand. manifest.csv lists each one and the clip it came from.
        \(s.rawCopies) of the images (*_raw.jpg) are portrait frames as the phone stores them —
        sideways, which is how the app's pipeline sees them — alongside the upright ones.

        1. Unzip, open a terminal in this folder, and install Ultralytics if needed:
             pip install -U ultralytics

        2. Train. A model runs at the size it's trained at — RallyLab's Add Model
           converts it at that size and the app reads it from the model — so this
           is the model's resolution for good. 1280 keeps far balls several pixels
           bigger than 960; it costs about 1.8× the detector time on the phone.
           Train both to compare (same data, different name=):
             yolo detect train data=data.yaml model=yolo26s.pt imgsz=1280 epochs=120 \\
               patience=30 batch=-1 close_mosaic=15 device=0 name=ball1280
             yolo detect train data=data.yaml model=yolo26s.pt imgsz=960 epochs=120 \\
               patience=30 batch=-1 close_mosaic=15 device=0 name=ball960
           device=0 is an NVIDIA GPU; on a Mac use device=mps. Start from the current
           model's .pt if you have it (it already knows volleyballs) instead of
           yolo26s.pt.

        3. When it finishes, Ultralytics prints "Results saved to …". Bring back
           best.pt from that folder's weights/ (e.g. runs/detect/ball1280/weights/).
           In RallyLab's Models tab, Add Model… on it: it's converted for the app
           at its training size, and you can evaluate it against the current model
           (and the other size) and use it for pre-labels.

        """
    }
}

/// How a video's stored frames turn into the picture it shows — phones
/// store portrait video sideways with a rotation to apply on playback.
/// Everything here is in normalised, top-down coordinates; dataset boxes
/// are bottom-up, so they're flipped on the way in and out.
struct StoredRotation {
    /// Upright (normalised) → stored (normalised).
    let toStored: CGAffineTransform
    /// Stored width ÷ height.
    let storedAspect: CGFloat

    static func of(video: URL) async -> StoredRotation? {
        guard FileManager.default.fileExists(atPath: video.path),
              let track = try? await AVURLAsset(url: video).loadTracks(withMediaType: .video).first,
              let transform = try? await track.load(.preferredTransform),
              let natural = try? await track.load(.naturalSize),
              natural.width > 0, natural.height > 0 else { return nil }
        // Only rotations: identity (or a pure translation) needs no copy.
        guard transform.a != 1 || transform.d != 1 || transform.b != 0 || transform.c != 0 else { return nil }
        let upright = CGRect(origin: .zero, size: natural).applying(transform).standardized
        // stored px → upright px, then normalise both ends.
        let pixel = transform.concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
        let normalised = CGAffineTransform(scaleX: natural.width, y: natural.height)
            .concatenating(pixel)
            .concatenating(CGAffineTransform(scaleX: 1 / upright.width, y: 1 / upright.height))
        return StoredRotation(toStored: normalised.inverted(), storedAspect: natural.width / natural.height)
    }

    /// A dataset box (normalised, bottom-up) in the stored frame.
    func storedBox(_ box: CGRect) -> CGRect {
        let topDown = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        let stored = topDown.applying(toStored).standardized
        return CGRect(x: stored.minX, y: 1 - stored.maxY, width: stored.width, height: stored.height)
    }

    /// The upright image at `source`, turned back to the stored frame, as JPEG.
    func writeStoredImage(from source: URL, to destination: URL) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Same pixel density as the upright image.
        let outW = (sqrt(w * h * storedAspect)).rounded(), outH = (sqrt(w * h / storedAspect)).rounded()
        guard let ctx = CGContext(data: nil, width: Int(outW), height: Int(outH), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Work top-down: output pixels ← stored normalised ← upright normalised ← upright pixels.
        ctx.translateBy(x: 0, y: outH); ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(CGAffineTransform(scaleX: 1 / w, y: 1 / h)
            .concatenating(toStored)
            .concatenating(CGAffineTransform(scaleX: outW, y: outH)))
        ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)   // CG draws images bottom-up
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rotated = ctx.makeImage(),
              let out = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(out, rotated, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw CocoaError(.fileWriteUnknown) }
    }
}
