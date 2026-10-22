//
//  MultiFramePackage.swift
//  RallyLab
//
//  A training package for multi-frame heatmap detectors (TrackNet / WASB /
//  VballNet family). Those models see a short run of consecutive frames,
//  so every reviewed frame goes in with the frames around it, pulled from
//  its source video: `span` on each side, about 1/30 s apart whatever the
//  video's frame rate (a 60 fps clip contributes every other frame), so
//  motion looks the same to the model across clips. Only the reviewed
//  frame in the middle is labeled; the trainer scores only that frame.
//
//  Frames are written as the video stores them — portrait phone video
//  sideways — because that's what the app's pipeline sees, and boxes are
//  turned to match. Frames shared by overlapping windows are written once.
//
//    <dataset>/exports/<name>-multiframe-<yyyyMMdd-HHmm>/
//      windows.jsonl  README.txt  summary.json
//      frames/<clip>/<microseconds>.jpg
//    <dataset>/exports/<name>-multiframe-<yyyyMMdd-HHmm>.zip
//
//  Rallies you've tracked and marked done in the Track tab go in too,
//  densely: a window centred on every other frame, with a label for every
//  frame in it ("labels": [] = no ball, null = not labeled). A ball hidden
//  for a moment between two sightings (behind a player, the net) is still
//  there: "occluded" gives where it must be, straight between them, so the
//  trainer can tell it from a ball that's gone.
//
//  Pre-tracked rallies (PreTracker — the model's own, in train videos) go
//  in the same way, with their sure frames (MachineLabels) as labels too:
//  "pseudo" says which frames' labels are the model's, which the trainer
//  uses with --pseudo (weighed less) and leaves unlabeled without it.
//
//  Videos with every rally marked also give dead-time windows ("dead": true,
//  no labels), well away from any rally: where the app runs the model on
//  the whole video but no rally is on, scored as how often it fires there.
//
//  windows.jsonl, one line per window:
//    {"clip", "split", "time", "size": [w, h], "frames": [2·span+1 paths],
//     "target": span, "balls": [[cx, cy, w, h], …],      (fractions, top-down)
//     "labels": [[[cx, cy, w, h], …] or null, …],      (tracked rallies only)
//     "occluded": [[cx, cy, w, h] or null, …],         (tracked, when any is hidden between sightings)
//     "pseudo": [true or false, …],                    (pre-tracked, when any frame's label is the model's)
//     "dead": true}                                    (dead-time windows only)
//
//  Frames are written whole (a `.part` file moved into place) and every
//  frame a window needs is written or the export fails naming it: nothing
//  is skipped quietly. An export cut short — the volume it writes to or
//  reads from goes away, which is noticed within seconds and is final —
//  leaves only frames/ behind, and can be completed with `resume:` the same
//  folder: a frame already there is reused only once it is proven to be a
//  whole JPEG, at a time the current plan needs, at the size this export
//  would write, and (on a sample per clip, regenerated from the video) of
//  this video. windows.jsonl, README.txt and summary.json are written only
//  after every clip's folder has been listed and found complete.
//

import AVFoundation
import CoreGraphics
import Foundation

enum MultiFramePackage {

    /// Frames each side of the labeled one: 8 → 17-frame windows, enough for
    /// a 9-frame model with the labeled frame anywhere in its input.
    static let span = 8
    /// Neighbours are about this far apart in time, whatever the clip's fps.
    static let frameRate = 30.0
    /// Frames are scaled down to fit this on their long side — enough for
    /// the trainer's --size 1024. A package only for 512 training can be
    /// written at 512: a quarter of the disk (pre-tracked rallies make many
    /// frames).
    static let longSide: CGFloat = 1024
    /// In a tracked rally, a window is centred on every this-many frames.
    static let trackStride = 2
    /// A hidden ball is placed between sightings this close together (s).
    static let occludedGap = 0.6
    /// Dead-time windows: this often, at least `deadMargin` from any rally.
    static let deadStep = 3.0
    static let deadMargin = 1.5

    struct Summary: Codable {
        let name: String
        let createdAt: Date
        let clips: Int
        let trainWindows: Int
        let valWindows: Int
        /// Of those, windows from tracked rallies (every frame labeled).
        var trackedWindows: Int = 0
        /// Dead-time windows, from videos with every rally marked.
        var deadWindows: Int = 0
        /// Pre-tracked rallies, and their sure frames labeled by the model.
        var machineRallies: Int = 0
        var machineFrames: Int = 0
        let balls: Int
        let noBallWindows: Int
        let frames: Int
        /// Clips whose reviewed frames couldn't go in because the video is gone.
        let missingVideos: [String]
        let framesWithoutVideo: Int
        /// Reviewed frames too close to the start or end of their video.
        let framesAtEdges: Int
        /// Present when the export completed an earlier, interrupted one (`resume:`).
        var resume: ResumeReport? = nil
    }

    /// What a resumed export found in the folder and did with it.
    struct ResumeReport: Codable, Equatable {
        /// One clip's retained frames checked against its video: `sampled` frames regenerated and
        /// compared (ExportIO.meanDifference), the worst of them `maxDifference` (≤ ExportIO.sameFrame).
        struct SourceCheck: Codable, Equatable {
            var clip: String
            var retained: Int
            var sampled: Int
            var maxDifference: Double
        }
        var from: String
        /// Frames already in the folder, validated and kept.
        var framesRetained: Int
        /// Frames in the folder that were not whole JPEGs; replaced, and listed here (up to 50).
        var framesReplaced: Int
        var replaced: [String]
        /// Frames written by this run.
        var framesWritten: Int
        /// Leftover `.part` files (a write cut short) removed; never frames.
        var partialFilesRemoved: Int
        var sourceChecks: [SourceCheck]
    }

    enum PackageError: LocalizedError, ExportIO.Final {
        case nothingReviewed, noVideos, noValidation, zipFailed
        case nameTaken(String)
        /// A frame a window needs could not be produced (decoded or written) after every retry.
        case frameFailed(clip: String, frame: String, detail: String)
        /// After writing, a clip's folder does not hold exactly the frames the plan needs.
        case folderIncomplete(clip: String, detail: String)
        var errorDescription: String? {
            switch self {
            case .nameTaken(let name): return "A package named \(name) already exists (folder or zip). Nothing is overwritten: wait a minute or move it away."
            case .nothingReviewed: return "No reviewed frames yet — review some before packaging."
            case .noVideos: return "None of the reviewed frames' videos are on this Mac — the frames around each one come from the video."
            case .noValidation: return "No reviewed frames from a val clip whose video is here. Set a clip with its video to Val."
            case .zipFailed: return "The package folder was written, but zipping it failed."
            case .frameFailed(let clip, let frame, let detail): return "\(clip): frame \(frame) could not be exported (\(detail)). No frame is skipped; nothing is finished. Fix the cause and resume with --resume."
            case .folderIncomplete(let clip, let detail): return "\(clip): the frames folder is not what the plan needs after writing (\(detail)). Nothing is finished."
            }
        }
    }

    enum ResumeError: LocalizedError, Equatable, ExportIO.Final {
        case notAFolder(String)
        /// The folder holds something other than frames/: a finished package, or not a package at all.
        case notResumable(String, found: [String])
        case strayClipFolder(String)
        case unexpectedFile(String)
        /// A clip's retained frames are not the size this export writes (another --long-side, or another video).
        case sizeMismatch(clip: String, retained: String, expected: String)
        /// A retained frame differs from the same moment of the clip's video more than a JPEG round trip allows.
        case sourceMismatch(clip: String, frame: String, difference: Double)
        /// More torn frames in one clip than an interruption leaves; the folder is not trusted.
        case tooManyInvalid(clip: String, count: Int, limit: Int)

        var errorDescription: String? {
            switch self {
            case .notAFolder(let p): return "--resume \(p) is not a folder."
            case .notResumable(let p, let found): return "\(p) is not an unfinished package (found \(found.joined(separator: ", "))): only a folder holding frames/ alone — an export cut short — can be resumed. A finished package is never written into."
            case .strayClipFolder(let p): return "\(p) is not a clip this export packages. Nothing is removed; nothing is written."
            case .unexpectedFile(let p): return "\(p) is not a frame this export writes. Nothing is removed; nothing is written."
            case .sizeMismatch(let clip, let retained, let expected): return "\(clip): retained frames are \(retained), this export writes \(expected) (another --long-side, or another video). Nothing is reused."
            case .sourceMismatch(let clip, let frame, let d): return "\(clip): retained frame \(frame) differs from the video at that moment (mean difference \(String(format: "%.1f", d)) > \(ExportIO.sameFrame)); the folder was not exported from this video. Nothing is reused."
            case .tooManyInvalid(let clip, let n, let limit): return "\(clip): \(n) retained frames are not whole JPEGs (an interruption leaves at most \(limit)); the folder is not trusted. Nothing is reused."
            }
        }
    }

    /// Torn frames an interruption can leave in one clip folder; more means the folder is not an export's.
    static let maxInvalidPerClip = 8
    /// Retained frames regenerated per clip for the source check: first, last and three between.
    static let sourceSample = 5

    private struct Window: Encodable {
        let clip: String
        let split: String
        let time: Double
        let size: [Int]
        let frames: [String]
        let target: Int
        let balls: [[Double]]
        var labels: [[[Double]]?]? = nil
        var occluded: [[Double]?]? = nil
        var dead: Bool? = nil
        var pseudo: [Bool]? = nil
    }

    /// `unreviewed`: every labeled frame of a finished rally is a label, not
    /// only the ones checked in annotation review — for a quick look at where
    /// the footage gets, never for a training round.
    /// `valOnly`: just the val clips, and no zip — the test set for scoring
    /// models on this Mac, in minutes rather than the hour the train clips
    /// take. Returns the folder; otherwise the zip.
    /// `beforeZip`: run on the finished folder before it is zipped (a
    /// lineage package's preflight, LineagePackage). If it throws, the
    /// folder is removed and the error is rethrown: no package exists.
    /// A package name is never reused: an existing folder or zip of the same
    /// name (two exports in one minute) is an error, so a rejected export can
    /// never leave an older zip next to its own failed record.
    /// The reviewed sampled frames of a session: what the exporter labels from them.
    static func reviewedFrames(_ session: VideoSession) -> [FrameRecord] {
        session.frames.filter { $0.keep && $0.reviewed && $0.source != "file" }
    }

    /// Whether the exporter would take anything from this session: reviewed frames, a
    /// ready track, or rally marks for dead time. Such a session needs its video.
    static func contributes(_ session: VideoSession) -> Bool {
        !reviewedFrames(session).isEmpty || !readyTracks(session).isEmpty || session.ralliesMarked == true
    }

    /// `exportsDir`: where the package folder and zip go; the project's `exports/` when nil.
    /// `resume`: the folder of an export that was cut short (frames/ and nothing else), to be
    /// completed in place; its name is the package name and its parent the exports folder.
    /// `note`: progress lines for the log.
    static func export(sessions: [VideoSession], store: DatasetStore, name: String, unreviewed: Bool = false, valOnly: Bool = false,
                       longSide: CGFloat = longSide, exportsDir: URL? = nil, resume: URL? = nil, beforeZip: ((URL) throws -> Void)? = nil,
                       now: Date = Date(), note: (@Sendable (String) -> Void)? = nil,
                       progress: @escaping @Sendable (Int, Int) -> Void) async throws -> (output: URL, summary: Summary) {
        let fm = FileManager.default
        // Final-test recordings (D-002) never enter a package, train or val.
        let finalTest = try PipelineTuner.ValidationSet.finalTestNames(in: store.root)
        let sessions = sessions.filter { !finalTest.contains($0.name) }
        let all: [(VideoSession, [FrameRecord])] = sessions.map { ($0, Self.reviewedFrames($0)) }.filter { Self.contributes($0.0) }
        let reviewed = valOnly ? all.filter { $0.0.split == "val" } : all
        guard !reviewed.isEmpty else { throw PackageError.nothingReviewed }
        let usable = reviewed.filter { fm.fileExists(atPath: $0.0.sourcePath) }
        let missing = reviewed.filter { !fm.fileExists(atPath: $0.0.sourcePath) }
        guard !usable.isEmpty else { throw PackageError.noVideos }
        guard usable.contains(where: { $0.0.split == "val" }) else { throw PackageError.noValidation }

        let packageName: String
        let exports: URL
        if let resume {
            packageName = resume.lastPathComponent
            exports = resume.deletingLastPathComponent()
        } else {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmm"
            packageName = "\(DatasetStore.safeName(name))\(unreviewed ? "-unreviewed" : "")\(valOnly ? "-val" : "")-multiframe-\(stamp.string(from: now))"
            exports = exportsDir ?? store.root.appendingPathComponent("exports", isDirectory: true)
        }
        let dir = exports.appendingPathComponent(packageName, isDirectory: true)
        let zip = exports.appendingPathComponent("\(packageName).zip")
        if resume != nil {
            try Self.checkResumable(dir, zip: zip, clipFolders: Set(usable.map { DatasetStore.safeName($0.0.name) }))
        } else {
            guard !fm.fileExists(atPath: dir.path), !fm.fileExists(atPath: zip.path) else { throw PackageError.nameTaken(packageName) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // The package folder as it is now; a vanished mount leaves a different folder at this path.
        let outputAnchor = try ExportIO.Anchor(path: dir.path)

        let total = usable.reduce(0) { $0 + $1.1.count }
        var done = 0
        var lines: [String] = []
        var counts = (train: 0, val: 0, balls: 0, empty: 0, frames: 0, edges: 0, tracked: 0, dead: 0, machineRallies: 0, machineFrames: 0)
        var resumed = ResumeReport(from: packageName, framesRetained: 0, framesReplaced: 0, replaced: [], framesWritten: 0,
                                   partialFilesRemoved: 0, sourceChecks: [])
        var expectedFiles: [(folder: URL, keys: Set<Int64>)] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for (session, frames) in usable {
            let clipDir = "frames/\(DatasetStore.safeName(session.name))"
            let clipURL = dir.appendingPathComponent(clipDir, isDirectory: true)
            try outputAnchor.verify()
            try await ExportIO.retrying("creating \(clipDir)", anchors: [outputAnchor]) {
                try fm.createDirectory(at: clipURL, withIntermediateDirectories: true)
            }
            let clip = try await ClipFrames(video: URL(fileURLWithPath: session.sourcePath), longSide: longSide)
            // The video file itself (through the dataset's link), so a footage mount that drops is noticed.
            let anchors = [outputAnchor, try ExportIO.Anchor(path: session.sourcePath)]

            var needed: [Int64: CMTime] = [:]
            var windows: [(FrameRecord, [CMTime])] = []
            for frame in frames {
                guard let times = clip.window(around: frame.time) else { counts.edges += 1; continue }
                windows.append((frame, times))
                for t in times { needed[ClipFrames.key(t)] = t }
            }
            // Tracked rallies: a window on every `trackStride`-th labeled frame.
            var tracked: [(time: Double, times: [CMTime], labels: [TrackPoint?], occluded: [CGRect?], pseudo: [Bool])] = []
            for rally in Self.readyTracks(session) {
                // Only frames checked in annotation review are labels — and a
                // pre-tracked rally's sure ones, marked as the model's; the
                // rest are still frames the model sees around them.
                // In a val video only what a person checked: the score is
                // people's labels, never the model's own.
                let val = session.split == "val"
                let sure = val ? [] : MachineLabels.trusted(rally)
                let labeled = rally.points.indices.filter { rally.points[$0].isChecked || (!val && unreviewed) || sure.contains($0) }
                let key = { (p: TrackPoint) in ClipFrames.key(CMTime(seconds: p.time, preferredTimescale: 600_000)) }
                let byKey = Dictionary(labeled.map { (key(rally.points[$0]), rally.points[$0]) }, uniquingKeysWith: { a, _ in a })
                let machine = Set(sure.map { key(rally.points[$0]) })
                let occluded = Dictionary(Self.occluded(rally, unreviewed: unreviewed && !val).map { (key($0.point), $0.box) },
                                          uniquingKeysWith: { a, _ in a })
                if rally.isMachine { counts.machineRallies += 1; counts.machineFrames += sure.count }
                for i in labeled where i % Self.trackStride == 0 && rally.points[i].state != .unknown {
                    let point = rally.points[i]
                    guard let times = clip.window(around: point.time, exact: true) else { counts.edges += 1; continue }
                    tracked.append((point.time, times, times.map { byKey[ClipFrames.key($0)] }, times.map { occluded[ClipFrames.key($0)] },
                                    times.map { machine.contains(ClipFrames.key($0)) }))
                    for t in times { needed[ClipFrames.key(t)] = t }
                }
            }
            // Dead time: only where every rally is marked, so "no rally" is known.
            var dead: [(time: Double, times: [CMTime])] = []
            if session.ralliesMarked == true {
                let marks = RallyMarkModel.load(RallyMarkModel.labelsURL(for: URL(fileURLWithPath: session.sourcePath)))
                for t in stride(from: Self.deadMargin, to: clip.duration - Self.deadMargin, by: Self.deadStep)
                where !marks.contains(where: { t > $0.start - Self.deadMargin && t < $0.end + Self.deadMargin }) {
                    guard let times = clip.window(around: t) else { continue }
                    dead.append((t, times))
                    for t in times { needed[ClipFrames.key(t)] = t }
                }
            }

            // Frames already in the folder (a resumed export): kept only once proven.
            var written = Set<Int64>()
            var sizes: [Int64: Int] = [:]
            if resume != nil {
                let retained = try await Self.retainedFrames(in: clipURL, clipDir: clipDir, clip: session.name, needed: needed,
                                                             frames: clip, anchors: anchors)
                written = retained.kept
                sizes = retained.sizes
                resumed.framesRetained += retained.kept.count
                resumed.framesReplaced += retained.replaced.count
                resumed.replaced += retained.replaced.prefix(max(0, 50 - resumed.replaced.count)).map { "\(clipDir)/\($0).jpg" }
                resumed.partialFilesRemoved += retained.partialFilesRemoved
                if let check = retained.sourceCheck { resumed.sourceChecks.append(check) }
                note?("  \(session.name): \(retained.kept.count) frames retained"
                      + (retained.replaced.isEmpty ? "" : ", \(retained.replaced.count) torn frame(s) replaced")
                      + ", \(needed.count - retained.kept.count) to write")
            }

            // Every needed frame not yet in the folder is decoded and written whole, or the export fails naming it.
            let toWrite = needed.filter { !written.contains($0.key) }.values.sorted { $0 < $1 }
            var undecoded: [CMTime] = []
            let lost = VolumeWatch(anchors: anchors, generator: clip.generator)
            defer { lost.stop() }
            var produced = 0
            for await result in clip.generator.images(for: toWrite) {
                if let error = lost.error { throw error }
                let key = ClipFrames.key(result.requestedTime)
                guard let image = try? result.image else { undecoded.append(result.requestedTime); continue }
                sizes[key] = try await Self.write(image, key: key, in: clipURL, clip: session.name, anchors: anchors)
                written.insert(key)
                produced += 1
                if produced % 50 == 0 { for a in anchors { try a.verify() } }
            }
            if let error = lost.error { throw error }
            // A frame the batch could not decode is asked for again on its own, a bounded number of times.
            for time in undecoded {
                let key = ClipFrames.key(time)
                let image: CGImage
                do {
                    image = try await ExportIO.retrying("decoding \(session.name) frame \(key)", anchors: anchors) {
                        try await clip.generator.image(at: time).image
                    }
                } catch let failure as ExportIO.Failure {
                    guard case .gaveUp(_, _, let detail) = failure else { throw failure }
                    throw PackageError.frameFailed(clip: session.name, frame: "\(key).jpg", detail: detail)
                }
                sizes[key] = try await Self.write(image, key: key, in: clipURL, clip: session.name, anchors: anchors)
                written.insert(key)
            }
            resumed.framesWritten += produced + undecoded.count
            // The folder must now hold exactly the plan's frames, each the size that was written or validated.
            try await Self.verifyFolder(clipURL, clipDir: clipDir, clip: session.name, sizes: sizes, anchors: anchors)
            expectedFiles.append((clipURL, Set(needed.keys)))
            counts.frames += needed.count

            let split = session.split == "val" ? "val" : "train"
            func stored(_ box: CGRect) -> [Double] {
                let s = clip.rotation?.storedBox(box) ?? box
                // Vision boxes are bottom-up; the trainer reads top-down.
                return [s.midX, 1 - s.midY, s.width, s.height].map { Double($0) }
            }
            func present(_ keys: [Int64]) throws {
                if let key = keys.first(where: { !written.contains($0) }) {
                    throw PackageError.frameFailed(clip: session.name, frame: "\(key).jpg", detail: "needed by a window but not written")
                }
            }
            for (time, times, labels, occluded, pseudo) in tracked {
                let keys = times.map(ClipFrames.key)
                try present(keys)
                let perFrame: [[[Double]]?] = labels.map { point in
                    switch point?.state {
                    case .visible: return point?.box.map { [stored($0.rect)] }
                    case .hidden: return []
                    default: return nil
                    }
                }
                let balls = perFrame[span] ?? []
                var window = Window(clip: session.name, split: split, time: time,
                                    size: [Int(clip.outputSize.width), Int(clip.outputSize.height)],
                                    frames: keys.map { "\(clipDir)/\($0).jpg" }, target: span, balls: balls)
                window.labels = perFrame
                if occluded.contains(where: { $0 != nil }) { window.occluded = occluded.map { $0.map(stored) } }
                if pseudo.contains(true) { window.pseudo = pseudo }
                lines.append(String(decoding: try encoder.encode(window), as: UTF8.self))
                if split == "val" { counts.val += 1 } else { counts.train += 1 }
                counts.tracked += 1
                counts.balls += balls.count
                if balls.isEmpty { counts.empty += 1 }
            }
            for (time, times) in dead {
                let keys = times.map(ClipFrames.key)
                try present(keys)
                var window = Window(clip: session.name, split: split, time: time,
                                    size: [Int(clip.outputSize.width), Int(clip.outputSize.height)],
                                    frames: keys.map { "\(clipDir)/\($0).jpg" }, target: span, balls: [])
                window.dead = true
                lines.append(String(decoding: try encoder.encode(window), as: UTF8.self))
                counts.dead += 1
            }
            for (frame, times) in windows {
                defer { done += 1; progress(done, total) }
                let keys = times.map(ClipFrames.key)
                try present(keys)
                let balls = frame.boxes.map { stored($0.rect) }
                let window = Window(clip: session.name, split: split, time: frame.time,
                                    size: [Int(clip.outputSize.width), Int(clip.outputSize.height)],
                                    frames: keys.map { "\(clipDir)/\($0).jpg" }, target: span, balls: balls)
                lines.append(String(decoding: try encoder.encode(window), as: UTF8.self))
                if split == "val" { counts.val += 1 } else { counts.train += 1 }
                counts.balls += balls.count
                if balls.isEmpty { counts.empty += 1 }
            }
        }
        guard counts.val > 0 else { throw PackageError.noValidation }

        // Completion, verified before anything that says "finished" is written: the package
        // folder is still the one this export started in, and every clip folder — listed again
        // now, not remembered from when it was written — holds exactly the frames the plan needs.
        try outputAnchor.verify()
        for (folder, keys) in expectedFiles {
            let clip = folder.lastPathComponent
            let listed = try await ExportIO.retrying("listing frames/\(clip)", anchors: [outputAnchor]) { try Self.frameFiles(in: folder, clipDir: "frames/\(clip)") }
            let names = Set(listed.keys)
            let want = Set(keys.map { "\($0).jpg" })
            guard names == want, listed.values.allSatisfy({ $0 > 0 }) else {
                throw PackageError.folderIncomplete(clip: clip, detail: "\(want.subtracting(names).count) frame(s) missing, \(names.subtracting(want).count) unexpected, "
                                                    + "\(listed.values.filter { $0 == 0 }.count) empty")
            }
        }

        var summary = Summary(name: packageName, createdAt: now, clips: usable.count,
                              trainWindows: counts.train, valWindows: counts.val, balls: counts.balls,
                              noBallWindows: counts.empty, frames: counts.frames,
                              missingVideos: missing.map(\.0.name).sorted(),
                              framesWithoutVideo: missing.reduce(0) { $0 + $1.1.count },
                              framesAtEdges: counts.edges)
        summary.trackedWindows = counts.tracked
        summary.deadWindows = counts.dead
        summary.machineRallies = counts.machineRallies
        summary.machineFrames = counts.machineFrames
        if resume != nil { summary.resume = resumed }
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("windows.jsonl"), atomically: true, encoding: .utf8)
        try readme(summary).write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let summaryEncoder = JSONEncoder()
        summaryEncoder.dateEncodingStrategy = .iso8601
        summaryEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try summaryEncoder.encode(summary).write(to: dir.appendingPathComponent("summary.json"))
        // Exposure is logged at export time so it survives the package being deleted.
        try ExposureLog.record(videos: Set(usable.map { $0.0.name }), kind: .trainingPackage, ref: packageName,
                           note: valOnly ? "val-only multi-frame export (test set)" : "multi-frame package", in: store.root)
        if let beforeZip {
            do { try beforeZip(dir) } catch {
                try? fm.removeItem(at: dir)
                throw error
            }
        }
        if valOnly { return (dir, summary) }

        guard try TrainingPackage.zipFolder(dir, to: zip) else { throw PackageError.zipFailed }
        return (zip, summary)
    }

    // MARK: - Writing, resuming, verifying

    /// A folder can be resumed into only when it is an export cut short: `frames/` and nothing
    /// else (no windows.jsonl, summary, README, record or zip — a finished package is never
    /// written into), and every clip folder in it is one this export packages.
    private static func checkResumable(_ dir: URL, zip: URL, clipFolders: Set<String>) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw ResumeError.notAFolder(dir.path) }
        var entries = try fm.contentsOfDirectory(atPath: dir.path).filter { $0 != ".DS_Store" }
        if fm.fileExists(atPath: zip.path) { entries.append(zip.lastPathComponent) }
        guard entries == ["frames"] else { throw ResumeError.notResumable(dir.path, found: entries.sorted()) }
        let frames = dir.appendingPathComponent("frames", isDirectory: true)
        guard fm.fileExists(atPath: frames.path, isDirectory: &isDir), isDir.boolValue else { throw ResumeError.notResumable(dir.path, found: ["frames (a file)"]) }
        for entry in try fm.contentsOfDirectory(atPath: frames.path) where entry != ".DS_Store" {
            guard clipFolders.contains(entry) else { throw ResumeError.strayClipFolder("frames/\(entry)") }
        }
    }

    /// Encodes `image` and writes it whole as `<key>.jpg`, retrying transient I/O errors while
    /// the volumes are still there. Returns the bytes written.
    private static func write(_ image: CGImage, key: Int64, in clipURL: URL, clip: String, anchors: [ExportIO.Anchor]) async throws -> Int {
        guard let data = SamplerImageTools.jpegData(image, quality: 0.85) else {
            throw PackageError.frameFailed(clip: clip, frame: "\(key).jpg", detail: "JPEG encoding failed")
        }
        do {
            try await ExportIO.retrying("writing \(clip) frame \(key).jpg", anchors: anchors) {
                try ExportIO.writeWhole(data, to: clipURL.appendingPathComponent("\(key).jpg"))
            }
        } catch let failure as ExportIO.Failure {
            guard case .gaveUp(_, _, let detail) = failure else { throw failure }
            throw PackageError.frameFailed(clip: clip, frame: "\(key).jpg", detail: detail)
        }
        return data.count
    }

    /// The frame files of a clip folder by name with their sizes. Anything that is not a frame
    /// of this export is refused: the folder must be this export's own.
    private static func frameFiles(in clipURL: URL, clipDir: String, partials: Bool = false) throws -> [String: Int] {
        let fm = FileManager.default
        var out: [String: Int] = [:]
        for entry in try fm.contentsOfDirectory(at: clipURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) {
            let name = entry.lastPathComponent
            if name == ".DS_Store" { continue }
            let values = try entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if partials, name.hasSuffix(".jpg" + ExportIO.partialSuffix) { out[name] = values.fileSize ?? 0; continue }
            guard values.isRegularFile == true, name.hasSuffix(".jpg"), Int64(name.dropLast(4)) != nil else {
                throw ResumeError.unexpectedFile("\(clipDir)/\(name)")
            }
            out[name] = values.fileSize ?? 0
        }
        return out
    }

    private struct Retained {
        var kept: Set<Int64>
        var sizes: [Int64: Int]
        var replaced: [Int64]
        var partialFilesRemoved: Int
        var sourceCheck: ResumeReport.SourceCheck?
    }

    /// What of `needed` is already in the folder and can be trusted. Each file is read and must
    /// be a whole JPEG that decodes; its name must be a frame the plan needs; every kept frame
    /// must be one size, the size this export writes (checked against frames regenerated from
    /// the video); and a sample of them, regenerated, must show the same picture. A torn file
    /// (an interrupted write) is replaced and reported; more than a few means the folder is not
    /// trusted. Leftover `.part` files are removed: they were never frames.
    private static func retainedFrames(in clipURL: URL, clipDir: String, clip: String, needed: [Int64: CMTime],
                                       frames: ClipFrames, anchors: [ExportIO.Anchor]) async throws -> Retained {
        let fm = FileManager.default
        let listed = try await ExportIO.retrying("listing \(clipDir)", anchors: anchors) {
            try frameFiles(in: clipURL, clipDir: clipDir, partials: true)
        }
        var result = Retained(kept: [], sizes: [:], replaced: [], partialFilesRemoved: 0, sourceCheck: nil)
        var invalid: [(Int64, String)] = []
        var sizes = Set<String>()
        var images: [Int64: CGImage] = [:]
        let keys = listed.keys.sorted()
        // The source sample: first, last and three between, decided before anything is read.
        let valid = keys.filter { !$0.hasSuffix(ExportIO.partialSuffix) }.compactMap { Int64($0.dropLast(4)) }.sorted()
        var sample = Set<Int64>()
        if !valid.isEmpty {
            for i in 0..<sourceSample { sample.insert(valid[Int((Double(i) / Double(sourceSample - 1) * Double(valid.count - 1)).rounded())]) }
        }
        for name in keys {
            let url = clipURL.appendingPathComponent(name)
            if name.hasSuffix(ExportIO.partialSuffix) {
                try await ExportIO.retrying("removing \(clipDir)/\(name)", anchors: anchors) { try fm.removeItem(at: url) }
                result.partialFilesRemoved += 1
                continue
            }
            let key = Int64(name.dropLast(4))!
            guard needed[key] != nil else { throw ResumeError.unexpectedFile("\(clipDir)/\(name)") }
            let data = try await ExportIO.retrying("reading \(clipDir)/\(name)", anchors: anchors) { try Data(contentsOf: url) }
            switch ExportIO.inspectFrame(data) {
            case .invalid(let reason):
                invalid.append((key, reason))
            case .valid(let w, let h):
                sizes.insert("\(w)×\(h)")
                result.kept.insert(key)
                result.sizes[key] = data.count
                if sample.contains(key), let image = ExportIO.decodeFrame(data) { images[key] = image }
            }
        }
        guard invalid.count <= maxInvalidPerClip else { throw ResumeError.tooManyInvalid(clip: clip, count: invalid.count, limit: maxInvalidPerClip) }
        if sizes.count > 1 {
            throw ResumeError.sizeMismatch(clip: clip, retained: sizes.sorted().joined(separator: " and "), expected: "one size")
        }
        // The sample, regenerated from the video: the same size, and the same picture.
        var worst = 0.0
        for key in sample.sorted() where result.kept.contains(key) {
            guard let time = needed[key], let retained = images[key] else { continue }
            let fresh = try await ExportIO.retrying("decoding \(clip) frame \(key)", anchors: anchors) { try await frames.generator.image(at: time).image }
            guard fresh.width == retained.width, fresh.height == retained.height else {
                throw ResumeError.sizeMismatch(clip: clip, retained: "\(retained.width)×\(retained.height)", expected: "\(fresh.width)×\(fresh.height)")
            }
            let difference = ExportIO.meanDifference(fresh, retained)
            worst = max(worst, difference)
            guard difference <= ExportIO.sameFrame else { throw ResumeError.sourceMismatch(clip: clip, frame: "\(key).jpg", difference: difference) }
        }
        if !result.kept.isEmpty {
            result.sourceCheck = ResumeReport.SourceCheck(clip: clip, retained: result.kept.count, sampled: images.count, maxDifference: worst)
        }
        // Torn frames are replaced by the write that follows; the old bytes go now.
        for (key, _) in invalid {
            try await ExportIO.retrying("removing torn \(clipDir)/\(key).jpg", anchors: anchors) { try fm.removeItem(at: clipURL.appendingPathComponent("\(key).jpg")) }
            result.replaced.append(key)
        }
        return result
    }

    /// After a clip is written: the folder holds exactly the frames in `sizes`, each with the
    /// size that was written or validated.
    private static func verifyFolder(_ clipURL: URL, clipDir: String, clip: String, sizes: [Int64: Int], anchors: [ExportIO.Anchor]) async throws {
        let listed = try await ExportIO.retrying("listing \(clipDir)", anchors: anchors) { try frameFiles(in: clipURL, clipDir: clipDir) }
        let want = Dictionary(uniqueKeysWithValues: sizes.map { ("\($0.key).jpg", $0.value) })
        guard listed == want else {
            let missing = Set(want.keys).subtracting(listed.keys).count
            let extra = Set(listed.keys).subtracting(want.keys).count
            let wrong = want.filter { listed[$0.key] != nil && listed[$0.key] != $0.value }.count
            throw PackageError.folderIncomplete(clip: clip, detail: "\(missing) missing, \(extra) unexpected, \(wrong) with another size than written")
        }
    }

    /// Watches the volumes while a clip's frames are generated: checks every few seconds and,
    /// when one is gone, stops the generator so the export fails within seconds, not when the
    /// network times out. `error` is set when it tripped.
    final class VolumeWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: Error?
        private var task: Task<Void, Never>?

        fileprivate init(anchors: [ExportIO.Anchor], generator: AVAssetImageGenerator, every seconds: TimeInterval = 10) {
            task = Task.detached { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    if Task.isCancelled { return }
                    do { for anchor in anchors { try anchor.verify() } } catch {
                        self?.trip(error)
                        generator.cancelAllCGImageGeneration()
                        return
                    }
                }
            }
        }

        private func trip(_ error: Error) { lock.lock(); failure = error; lock.unlock() }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
        func stop() { task?.cancel() }
    }

    /// Hidden frames of `rally` between two sightings at most `occludedGap`
    /// apart, with where the ball must be: straight between them (upright,
    /// Vision-normalised), when that's in the picture.
    static func occluded(_ rally: TrackedRally, unreviewed: Bool) -> [(point: TrackPoint, box: CGRect)] {
        let seen = rally.points.filter { $0.state == .visible && $0.box != nil && ($0.isChecked || unreviewed) }
        guard seen.count >= 2 else { return [] }
        var result: [(TrackPoint, CGRect)] = []
        var i = 0
        for point in rally.points where point.state == .hidden && (point.isChecked || unreviewed) {
            while i + 1 < seen.count && seen[i + 1].time < point.time { i += 1 }
            guard i + 1 < seen.count, seen[i].time < point.time, let a = seen[i].box?.rect, let b = seen[i + 1].box?.rect,
                  seen[i + 1].time - seen[i].time <= Self.occludedGap else { continue }
            let f = (point.time - seen[i].time) / (seen[i + 1].time - seen[i].time)
            let lerp = { (x: CGFloat, y: CGFloat) in x + (y - x) * f }
            let w = lerp(a.width, b.width), h = lerp(a.height, b.height)
            let box = CGRect(x: lerp(a.midX, b.midX) - w / 2, y: lerp(a.midY, b.midY) - h / 2, width: w, height: h)
            guard (0...1).contains(box.midX), (0...1).contains(box.midY) else { continue }
            result.append((point, box))
        }
        return result
    }

    /// Rallies tracked frame by frame and marked done, and pre-tracked ones
    /// not said to be no rally (in val, only their frames a person checked
    /// are labels).
    static func readyTracks(_ session: VideoSession) -> [TrackedRally] {
        (session.tracks ?? []).filter(\.isReady)
    }

    static func readme(_ s: Summary) -> String {
        """
        RallyLab multi-frame package — \(s.name)

        \(s.trainWindows) train + \(s.valWindows) val windows from \(s.clips) clips: each is a reviewed
        frame with the \(span) frames before and after it (about 1/\(Int(frameRate)) s apart), \(s.balls) balls,
        \(s.noBallWindows) windows with no ball. \(s.trackedWindows) of the windows are from rallies tracked frame by
        frame, with every frame labeled; in the rest only the middle frame is.
        \(s.deadWindows) dead-time windows (no rally on, from videos with every rally marked) aren't
        trained on: they score how often the model fires when no rally is on.
        \(s.machineRallies) rallies were pre-tracked by the model: \(s.machineFrames) of their frames are the
        model's own labels ("pseudo"), used with --pseudo.
        \(s.missingVideos.isEmpty ? "" : "\(s.framesWithoutVideo) reviewed frames from \(s.missingVideos.count) clips aren't here: their videos weren't on the Mac.\n")
        \(s.resume.map { "Completed from an export cut short: \($0.framesRetained) frames were already here and validated (whole JPEGs, the planned moments, a sample regenerated and compared), \($0.framesReplaced) torn ones replaced, \($0.framesWritten) written by the resumed run; details in summary.json.\n" } ?? "")
        Train it with scripts/desktop_training/train_heatmap_model.py — it reads windows.jsonl
        directly. See that script's header for the steps.

        """
    }
}

/// One video's frames, as stored, for pulling exact neighbouring frames.
private struct ClipFrames {
    let generator: AVAssetImageGenerator
    let rotation: StoredRotation?
    let outputSize: CGSize
    let duration: Double
    private let track: AVAssetTrack
    /// Video frames between neighbours in a window.
    private let step: Int

    init(video: URL, longSide: CGFloat) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.track = track
        duration = try await asset.load(.duration).seconds
        let fps = Double(try await track.load(.nominalFrameRate))
        step = max(1, Int((fps / MultiFramePackage.frameRate).rounded()))
        let natural = try await track.load(.naturalSize)
        let scale = min(1, longSide / max(natural.width, natural.height))
        outputSize = CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
        rotation = await StoredRotation.of(video: video)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = false   // as stored, like the app's pipeline
        generator.maximumSize = outputSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }

    /// File-name key for a frame: its presentation time in microseconds.
    static func key(_ time: CMTime) -> Int64 { Int64((time.seconds * 1_000_000).rounded()) }

    /// Presentation times of the window around the frame showing at `seconds`
    /// — the frame the sampler extracted, which is the last one starting at or
    /// before that time — or nil if the video ends too soon on either side.
    /// `exact`: `seconds` is a frame's own presentation time (a tracked
    /// rally's), which rounded to the sampler's 1/600 s could land a hair
    /// before the frame (59.94 fps) and centre the window on the one before.
    func window(around seconds: Double, exact: Bool = false) -> [CMTime]? {
        let t = exact ? TrackFrameStore.request(seconds) : CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: t) else { return nil }
        if cursor.presentationTimeStamp > t, cursor.stepInPresentationOrder(byCount: -1) != -1 { return nil }
        var times: [CMTime] = []
        for offset in -MultiFramePackage.span...MultiFramePackage.span {
            let want = Int64(offset * step)
            guard let c = cursor.copy() as? AVSampleCursor, c.stepInPresentationOrder(byCount: want) == want else { return nil }
            times.append(c.presentationTimeStamp)
        }
        return times
    }
}
