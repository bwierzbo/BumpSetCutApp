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
//  Videos with every rally marked also give dead-time windows ("dead": true,
//  no labels), well away from any rally: where the app runs the model on
//  the whole video but no rally is on, scored as how often it fires there.
//
//  windows.jsonl, one line per window:
//    {"clip", "split", "time", "size": [w, h], "frames": [2·span+1 paths],
//     "target": span, "balls": [[cx, cy, w, h], …],      (fractions, top-down)
//     "labels": [[[cx, cy, w, h], …] or null, …],      (tracked rallies only)
//     "occluded": [[cx, cy, w, h] or null, …],         (tracked, when any is hidden between sightings)
//     "dead": true}                                    (dead-time windows only)
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
    /// Frames are scaled down to fit this on their long side.
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
        let balls: Int
        let noBallWindows: Int
        let frames: Int
        /// Clips whose reviewed frames couldn't go in because the video is gone.
        let missingVideos: [String]
        let framesWithoutVideo: Int
        /// Reviewed frames too close to the start or end of their video.
        let framesAtEdges: Int
    }

    enum PackageError: LocalizedError {
        case nothingReviewed, noVideos, noValidation, zipFailed
        var errorDescription: String? {
            switch self {
            case .nothingReviewed: return "No reviewed frames yet — review some before packaging."
            case .noVideos: return "None of the reviewed frames' videos are on this Mac — the frames around each one come from the video."
            case .noValidation: return "No reviewed frames from a val clip whose video is here. Set a clip with its video to Val."
            case .zipFailed: return "The package folder was written, but zipping it failed."
            }
        }
    }

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
    }

    /// `unreviewed`: every labeled frame of a finished rally is a label, not
    /// only the ones checked in annotation review — for a quick look at where
    /// the footage gets, never for a training round.
    static func export(sessions: [VideoSession], store: DatasetStore, name: String, unreviewed: Bool = false,
                       progress: @escaping @Sendable (Int, Int) -> Void) async throws -> (zip: URL, summary: Summary) {
        let fm = FileManager.default
        let reviewed = sessions.map { session in
            (session, session.frames.filter { $0.keep && $0.reviewed && $0.source != "file" })
        }.filter { !$0.1.isEmpty || !Self.doneTracks($0.0).isEmpty || $0.0.ralliesMarked == true }
        guard !reviewed.isEmpty else { throw PackageError.nothingReviewed }
        let usable = reviewed.filter { fm.fileExists(atPath: $0.0.sourcePath) }
        let missing = reviewed.filter { !fm.fileExists(atPath: $0.0.sourcePath) }
        guard !usable.isEmpty else { throw PackageError.noVideos }
        guard usable.contains(where: { $0.0.split == "val" }) else { throw PackageError.noValidation }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let now = Date()
        let packageName = "\(DatasetStore.safeName(name))\(unreviewed ? "-unreviewed" : "")-multiframe-\(stamp.string(from: now))"
        let exports = store.root.appendingPathComponent("exports", isDirectory: true)
        let dir = exports.appendingPathComponent(packageName, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let total = usable.reduce(0) { $0 + $1.1.count }
        var done = 0
        var lines: [String] = []
        var counts = (train: 0, val: 0, balls: 0, empty: 0, frames: 0, edges: 0, tracked: 0, dead: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for (session, frames) in usable {
            let clipDir = "frames/\(DatasetStore.safeName(session.name))"
            try fm.createDirectory(at: dir.appendingPathComponent(clipDir, isDirectory: true), withIntermediateDirectories: true)
            let clip = try await ClipFrames(video: URL(fileURLWithPath: session.sourcePath))

            var needed: [Int64: CMTime] = [:]
            var windows: [(FrameRecord, [CMTime])] = []
            for frame in frames {
                guard let times = clip.window(around: frame.time) else { counts.edges += 1; continue }
                windows.append((frame, times))
                for t in times { needed[ClipFrames.key(t)] = t }
            }
            // Tracked rallies: a window on every `trackStride`-th labeled frame.
            var tracked: [(time: Double, times: [CMTime], labels: [TrackPoint?], occluded: [CGRect?])] = []
            for rally in Self.doneTracks(session) {
                // Only frames checked in annotation review are labels; the rest
                // are still frames the model sees around them.
                let key = { (p: TrackPoint) in ClipFrames.key(CMTime(seconds: p.time, preferredTimescale: 600_000)) }
                let byKey = Dictionary(rally.points.filter { $0.isChecked || unreviewed }.map { (key($0), $0) },
                                       uniquingKeysWith: { a, _ in a })
                let occluded = Dictionary(Self.occluded(rally, unreviewed: unreviewed).map { (key($0.point), $0.box) },
                                          uniquingKeysWith: { a, _ in a })
                for point in rally.points.enumerated().filter({ $0.offset % Self.trackStride == 0 }).map(\.element)
                where point.state != .unknown && (point.isChecked || unreviewed) {
                    guard let times = clip.window(around: point.time, exact: true) else { counts.edges += 1; continue }
                    tracked.append((point.time, times, times.map { byKey[ClipFrames.key($0)] }, times.map { occluded[ClipFrames.key($0)] }))
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

            var written = Set<Int64>()
            for await result in clip.generator.images(for: needed.values.sorted { $0 < $1 }) {
                let key = ClipFrames.key(result.requestedTime)
                guard let image = try? result.image,
                      SamplerImageTools.writeJPEG(image, to: dir.appendingPathComponent("\(clipDir)/\(key).jpg"), quality: 0.85)
                else { continue }
                written.insert(key)
            }
            counts.frames += written.count

            let split = session.split == "val" ? "val" : "train"
            func stored(_ box: CGRect) -> [Double] {
                let s = clip.rotation?.storedBox(box) ?? box
                // Vision boxes are bottom-up; the trainer reads top-down.
                return [s.midX, 1 - s.midY, s.width, s.height].map { Double($0) }
            }
            for (time, times, labels, occluded) in tracked {
                let keys = times.map(ClipFrames.key)
                guard keys.allSatisfy(written.contains) else { counts.edges += 1; continue }
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
                lines.append(String(decoding: try encoder.encode(window), as: UTF8.self))
                if split == "val" { counts.val += 1 } else { counts.train += 1 }
                counts.tracked += 1
                counts.balls += balls.count
                if balls.isEmpty { counts.empty += 1 }
            }
            for (time, times) in dead {
                let keys = times.map(ClipFrames.key)
                guard keys.allSatisfy(written.contains) else { continue }
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
                guard keys.allSatisfy(written.contains) else { counts.edges += 1; continue }
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

        var summary = Summary(name: packageName, createdAt: now, clips: usable.count,
                              trainWindows: counts.train, valWindows: counts.val, balls: counts.balls,
                              noBallWindows: counts.empty, frames: counts.frames,
                              missingVideos: missing.map(\.0.name).sorted(),
                              framesWithoutVideo: missing.reduce(0) { $0 + $1.1.count },
                              framesAtEdges: counts.edges)
        summary.trackedWindows = counts.tracked
        summary.deadWindows = counts.dead
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("windows.jsonl"), atomically: true, encoding: .utf8)
        try readme(summary).write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let summaryEncoder = JSONEncoder()
        summaryEncoder.dateEncodingStrategy = .iso8601
        summaryEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try summaryEncoder.encode(summary).write(to: dir.appendingPathComponent("summary.json"))

        let zip = exports.appendingPathComponent("\(packageName).zip")
        try? fm.removeItem(at: zip)
        guard try TrainingPackage.zipFolder(dir, to: zip) else { throw PackageError.zipFailed }
        return (zip, summary)
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

    /// Rallies tracked frame by frame and marked done.
    static func doneTracks(_ session: VideoSession) -> [TrackedRally] {
        (session.tracks ?? []).filter(\.done)
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
        \(s.missingVideos.isEmpty ? "" : "\(s.framesWithoutVideo) reviewed frames from \(s.missingVideos.count) clips aren't here: their videos weren't on the Mac.\n")
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

    init(video: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.track = track
        duration = try await asset.load(.duration).seconds
        let fps = Double(try await track.load(.nominalFrameRate))
        step = max(1, Int((fps / MultiFramePackage.frameRate).rounded()))
        let natural = try await track.load(.naturalSize)
        let scale = min(1, MultiFramePackage.longSide / max(natural.width, natural.height))
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
