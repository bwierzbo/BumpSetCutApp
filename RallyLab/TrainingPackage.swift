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
//    <dataset>/exports/<name>-<yyyyMMdd-HHmm>/
//      data.yaml  README.txt  manifest.csv  summary.json
//      images/{train,val}/  labels/{train,val}/
//    <dataset>/exports/<name>-<yyyyMMdd-HHmm>.zip
//

import Foundation

enum TrainingPackage {

    struct Summary: Codable {
        let name: String
        let createdAt: Date
        let clips: Int
        let trainImages: Int
        let valImages: Int
        let boxes: Int
        let emptyImages: Int
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
    static func export(sessions: [VideoSession], store: DatasetStore, name: String) throws -> (zip: URL, summary: Summary) {
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

        var manifest = ["image,clip,split,source,time,boxes"]
        var counts = (train: 0, val: 0, boxes: 0, empty: 0)
        for (session, frame) in frames {
            let split = session.split == "val" ? "val" : "train"
            let fileName = (frame.file as NSString).lastPathComponent
            let image = dir.appendingPathComponent("images/\(split)/\(fileName)")
            try fm.copyItem(at: store.currentImageURL(for: frame), to: image)
            let label = dir.appendingPathComponent("labels/\(split)/\((fileName as NSString).deletingPathExtension).txt")
            let lines = frame.boxes.map { DatasetStore.yoloLine($0.rect) }
            try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: label, atomically: true, encoding: .utf8)

            manifest.append("\(fileName),\(session.name),\(split),\(frame.source),\(String(format: "%.3f", frame.time)),\(frame.boxes.count)")
            if split == "val" { counts.val += 1 } else { counts.train += 1 }
            counts.boxes += frame.boxes.count
            if frame.boxes.isEmpty { counts.empty += 1 }
        }

        let summary = Summary(name: packageName, createdAt: now,
                              clips: Set(frames.map { $0.0.name }).count,
                              trainImages: counts.train, valImages: counts.val,
                              boxes: counts.boxes, emptyImages: counts.empty)
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
        ditto.arguments = ["-c", "-k", "--keepParent", dir.path, zip.path]
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

        1. Unzip, open a terminal in this folder, and install Ultralytics if needed:
             pip install -U ultralytics

        2. Train (drop device=0 on a Mac; start from the current model's .pt if
           you have it instead of yolo26s.pt):
             yolo detect train data=data.yaml model=yolo26s.pt imgsz=1280 epochs=120 \\
               patience=30 batch=-1 close_mosaic=15 device=0 name=ball

        3. When it finishes, Ultralytics prints "Results saved to …". Bring back
           best.pt from that folder's weights/ (usually runs/detect/ball/weights/).
           In RallyLab's Models tab, Add Model… on it: it's converted for the app,
           and you can evaluate it against the current model and use it for
           pre-labels.

        """
    }
}
