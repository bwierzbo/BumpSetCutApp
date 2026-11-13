//
//  TrackSession.swift
//  RallyLab (iPhone)
//
//  One rally being tracked on the phone, the same way the Mac's Track tab
//  does it: the same frames (every frame ~1/30 s apart, read from the
//  clip's own sample times), the same detectors (YOLO + the multi-frame
//  model, merged by TrackFinder) and the same path solver (TrackSolver).
//  You only look at the frames worth a look; every fix re-solves the rest,
//  then looks again near it for a ball the first pass missed.
//
//  A rally tracked before, of a recording its project now withholds from
//  every model (or whose state isn't known), opens by hand for a lead
//  (TrackWork.byHand): its frames and its boxes, each fix changing that
//  frame only — no detector is built, nothing is solved, and looking again
//  and reading more frames are off, with the reason on screen. A rally not
//  tracked yet doesn't open there at all.
//

import AVFoundation
import CoreGraphics
import Observation
import UIKit

@MainActor
@Observable
final class TrackSession {

    enum Phase: Equatable {
        case preparing(String, Double)
        case reviewing
        case failed(String)
    }

    let video: LabelVideo
    private(set) var rally: TrackedRally
    private(set) var phase = Phase.preparing("Getting the clip…", 0)
    /// The frame on screen (kept, so coming back opens it again).
    var index = 0 {
        didSet {
            if rally.points.indices.contains(index) { LocalStore.setPosition(rally.points[index].time, for: rally.id) }
        }
    }
    /// Each frame as JPEG, upright, in time order.
    private(set) var frames: [Data] = []
    private var undoStack: [TrackedRally] = []
    private let model: LabelerModel
    /// The rally itself — serve to dead ball — inside the tracked frames
    /// (which run a little longer each side). Goes into the rally times.
    var bounds: LabelRally
    /// The found rally this started from, if any (for "not a rally").
    let found: [Double]?
    /// Your points kept across an extension (re-found on the new frames).
    private var keptPoints: [TrackPoint] = []
    /// Searching near your last fix (TrackFinder.lookAgain).
    private(set) var isLookingAgain = false
    /// How this rally is worked on: with the detectors, by hand, or not at all — by what its recording's access
    /// allows, asked in `prepare` and again before more frames are read. Every detector here is built through
    /// `work.models`, every fix applied through `work.fixed`.
    private(set) var work = TrackWork.unchecked

    /// Why this rally is worked on by hand, when it is: shown, and the detector-backed controls are off.
    var byHandReason: String? {
        if case .byHand(let why) = work { return why }
        return nil
    }
    @ObservationIgnored private let lookAgainDetector = LookAgainDetector()
    @ObservationIgnored private let lookAgainHeat = LookAgainHeat()

    /// Detections this sure or more are candidates (as on the Mac).
    static let candidateConfidence: Float = 0.15
    /// Frames are read about this often, whatever the video's rate.
    static let frameRate = 30.0

    /// A new rally over `span` (tracked `TrackedRally.margin` past it each side), or an
    /// existing track (its rally from the rally times, if marked).
    init(model: LabelerModel, video: LabelVideo, span: LabelRally? = nil, found: [Double]? = nil, track: LabelTrack? = nil) {
        self.model = model
        self.video = video
        if let track {
            rally = track.rally
            bounds = model.rallyTimes(for: video).rallies.first { min($0.end, track.end) - max($0.start, track.start) > 0.3 }
                ?? LabelRally(start: min(track.start + TrackedRally.margin, track.end), end: max(track.end - TrackedRally.margin, track.start))
            self.found = nil
        } else {
            let s = span ?? LabelRally(start: 0, end: 1)
            rally = TrackedRally(id: UUID(), start: max(0, s.start - TrackedRally.margin), end: min(video.duration, s.end + TrackedRally.margin),
                                 points: [], candidates: [], done: false)
            bounds = s
            self.found = found
        }
    }

    // MARK: - Reading

    var point: TrackPoint? { rally.points.indices.contains(index) ? rally.points[index] : nil }

    /// Frames worth a look, in order.
    var toCheck: [Int] { rally.points.indices.filter { rally.points[$0].isUncertain } }

    var canUndo: Bool { !undoStack.isEmpty }

    func image(_ i: Int) -> UIImage? { frames.indices.contains(i) ? UIImage(data: frames[i]) : nil }

    /// Where the ball is (or was last seen) around frame `i`, Vision-normalised.
    func focus(around i: Int) -> CGPoint? {
        let order = [i] + (1...30).flatMap { [i - $0, i + $0] }
        for k in order where rally.points.indices.contains(k) {
            if let b = rally.points[k].box, rally.points[k].state == .visible { return CGPoint(x: b.x + b.w / 2, y: b.y + b.h / 2) }
        }
        return nil
    }

    // MARK: - Preparing

    func prepare() async {
        guard await decideWork() != nil else { return }
        await read()
    }

    /// Asks what the recording's access is now (the withheld list fetched again; not fetched = not known) and
    /// sets how the rally is worked on. Tracking runs the ball detectors — when the frames are read, and again
    /// near every fix — so it is assisted only for a recording no model is kept from, whoever is signed in; a
    /// rally tracked before opens by hand where annotation by hand goes on; anything else is refused, with the
    /// reason on screen. Returns nil when refused.
    private func decideWork() async -> TrackWork? {
        work = TrackWork(access: await model.modelAccess(for: video), existingTrack: !rally.points.isEmpty)
        if case .refused(let why) = work {
            phase = .failed(why)
            return nil
        }
        return work
    }

    private func read() async {
        let assisted = work == .assisted
        // Left part way through: its frames and candidates are on the phone. By hand, the frames only.
        if !rally.points.isEmpty, let kept = LocalStore.tracking(rally.id, times: rally.points.map(\.time)) {
            frames = kept.frames
            if assisted {
                rally.candidates = kept.candidates
                rally.points = TrackSolver.solve(rally)
            }
            let left = LocalStore.position(rally.id).flatMap { t in rally.points.firstIndex { abs($0.time - t) < 0.002 } }
            index = left ?? toCheck.first ?? 0
            phase = .reviewing
            return
        }
        do {
            let file = try await model.localClip(for: video)
            let asset = AVURLAsset(url: file)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ClipEncoder.Failure.noVideo }
            let times = try await Self.frameTimes(track, start: rally.start, end: rally.end)
            guard !times.isEmpty else { throw ClipEncoder.Failure.cantRead }
            if rally.points.isEmpty {
                rally.start = times.first!
                rally.end = times.last!
                rally.points = times.map { t in
                    keptPoints.first { abs($0.time - t) < 0.002 } ?? TrackPoint(time: t, state: .unknown, origin: .auto, box: nil)
                }
                keptPoints = []
                // Saved now, trimmed: leaving at any point from here comes back
                // to this rally in tracking, never to trimming it again.
                save()
            }
            // An existing track's own frame times win (they're what was labeled).
            let wanted = rally.points.map(\.time)
            let what = assisted ? "Finding the ball on \(wanted.count) frames…" : "Reading \(wanted.count) frames…"
            phase = .preparing(what, 0)
            let found = try await Self.readFrames(asset: asset, times: wanted, work: work) { done in
                Task { @MainActor [weak self] in
                    self?.phase = .preparing(what, Double(done) / Double(wanted.count))
                }
            }
            frames = found.frames
            if assisted {
                rally.candidates = found.candidates
                rally.points = TrackSolver.solve(rally)
            }
            let left = LocalStore.position(rally.id).flatMap { t in rally.points.firstIndex { abs($0.time - t) < 0.002 } }
            index = left ?? toCheck.first ?? 0
            phase = .reviewing
            // Kept for coming back to an assisted rally; a rally worked on by hand has no candidates to keep, and
            // an empty set must not stand in for them if its recording is opened to the models again.
            if assisted {
                let id = rally.id, candidates = rally.candidates
                Task.detached(priority: .utility) { LocalStore.saveTracking(id, times: wanted, frames: found.frames, candidates: candidates) }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The clip's frames from `start` to `end`, one per 1/30 s (every other
    /// frame of a 60 fps video), from its own sample times — stepping from the
    /// last frame at or before `start` as the Mac's sample cursor does — so a
    /// frame here is the same frame there. (iOS has no sample cursors: the
    /// times come from reading the samples without decoding them.)
    private static func frameTimes(_ track: AVAssetTrack, start: Double, end: Double) async throws -> [Double] {
        let fps = Double(try await track.load(.nominalFrameRate))
        let step = max(1, Int((fps / frameRate).rounded()))
        guard let asset = track.asset else { throw ClipEncoder.Failure.cantRead }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start - 1), preferredTimescale: 600),
                                       end: CMTime(seconds: end + 0.1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw ClipEncoder.Failure.cantRead }
        var all: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sample)
            if t.isValid, CMSampleBufferGetNumSamples(sample) > 0 { all.append(t.seconds) }
        }
        all.sort()
        guard let first = all.lastIndex(where: { $0 <= start + 0.0005 }) ?? all.indices.first else { return [] }
        return stride(from: first, to: all.count, by: step).map { all[$0] }.filter { $0 <= end }
    }

    private struct Found: Sendable {
        var frames: [Data]
        var candidates: [[TrackCandidate]]
    }

    /// Every frame read once, in order. Assisted: YOLO's candidates and the
    /// frame for the multi-frame model, then the multi-frame model's peaks
    /// merged in. By hand: the frames only — the detectors are built through
    /// `work.models`, so none is for a recording no model may run over, and
    /// no candidate comes back.
    private static func readFrames(asset: AVURLAsset, times: [Double], work: TrackWork,
                                   progress: @escaping @Sendable (Int) -> Void) async throws -> Found {
        try await Task.detached(priority: .userInitiated) {
            let models = try? work.models { () -> (yolo: YOLODetector, heat: HeatmapBallDetector?) in
                let yolo = YOLODetector(modelName: "ball_v2_small", computeUnits: .cpuAndNeuralEngine)
                yolo.minConfidence = candidateConfidence
                yolo.suppressesStaticObjects = false
                // Portrait frames letterboxed, as the pipeline does: stretched into
                // the square input the ball goes oval and is mostly missed.
                yolo.adaptiveLetterbox = true
                let heat = Bundle.main.url(forResource: "ball_heat", withExtension: "mlmodelc")
                    .flatMap { HeatmapBallDetector(modelURL: $0, computeUnits: .cpuAndNeuralEngine) }
                return (yolo, heat)
            }
            let heat = models?.heat
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            var frames = [Data](repeating: Data(), count: times.count)
            var found = [[TrackCandidate]](repeating: [], count: times.count)
            var grays = [HeatmapBallDetector.Frame?](repeating: nil, count: times.count)
            var done = 0
            func read(_ indices: [Int]) async throws {
                let requests = indices.map { CMTime(seconds: times[$0], preferredTimescale: 600_000) }
                for await result in generator.images(for: requests) {
                    try Task.checkCancellation()
                    guard let image = try? result.image,
                          let i = indices.first(where: { abs(times[$0] - result.requestedTime.seconds) < 0.0005 }) else { continue }
                    // Each frame's buffers drained before the next: hundreds of
                    // frames otherwise pile up past what iOS allows an app.
                    autoreleasepool {
                        if let yolo = models?.yolo {
                            found[i] = yolo.detect(in: image, at: .zero).map { TrackCandidate(rect: $0.bbox, confidence: Double($0.confidence)) }
                        }
                        grays[i] = heat?.frame(image)
                        frames[i] = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) ?? Data()
                    }
                    done += 1
                    progress(done)
                }
            }
            try await read(Array(times.indices))
            // A few frames can fail an exact read; take the nearest decoded
            // frame within a quarter of a frame instead.
            let missed = times.indices.filter { frames[$0].isEmpty }
            if !missed.isEmpty {
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25 / frameRate, preferredTimescale: 600_000)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25 / frameRate, preferredTimescale: 600_000)
                try await read(missed)
            }
            if let heat { TrackFinder.addHeatmapCandidates(heat, grays: grays, to: &found) }
            return Found(frames: frames, candidates: models == nil ? [] : found)
        }.value
    }

    // MARK: - Fixing

    /// The pick on this frame is right.
    func confirm() {
        guard let p = point, p.state != .unknown else { return }
        change { $0.points[index].origin = .user }
        lookAgain(from: index)
    }

    /// The ball is here (Vision-normalised, upright frame): exactly where
    /// you put it, at `size` if you sized it, else the box's size if it had
    /// one, else the size of the balls on the frames around it. Then it
    /// looks again either side.
    func setBall(at location: CGPoint, size: CGSize? = nil) {
        let i = index
        let side = size ?? point.flatMap { $0.state == .visible ? $0.box : nil }.map { CGSize(width: $0.w, height: $0.h) }
            ?? boxSide(near: i)
        change { r in
            r.points[i].state = .visible
            r.points[i].origin = .user
            r.points[i].box = TrackCandidate(rect: CGRect(x: location.x - side.width / 2, y: location.y - side.height / 2,
                                                          width: side.width, height: side.height), confidence: 1)
            r.points[i].reviewed = false
        }
        lookAgain(from: i)
    }

    /// Search near the fix on frame `fix` for the ball the first pass missed
    /// either side, then re-solve with what's found. In the background: you
    /// can keep going, and a newer edit wins over a stale result.
    private func lookAgain(from fix: Int) {
        guard stillAssisted() else { return }
        let snapshot = rally, frames = frames, holder = lookAgainDetector, heatHolder = lookAgainHeat, work = work
        isLookingAgain = true
        Task {
            let added = await Task.detached(priority: .userInitiated) { () -> [Int: [TrackCandidate]] in
                let models = try? work.models {
                    (yolo: holder.detector, heat: heatHolder.detector(for: Bundle.main.url(forResource: "ball_heat", withExtension: "mlmodelc")))
                }
                guard let detector = models?.yolo else { return [:] }
                let heat = models?.heat
                return TrackFinder.lookAgain(from: fix, in: snapshot, detector: detector, heat: heat) { i in
                    autoreleasepool { frames.indices.contains(i) ? UIImage(data: frames[i])?.cgImage : nil }
                }
            }.value
            isLookingAgain = false
            guard !added.isEmpty, self.work == .assisted, rally.id == snapshot.id, rally.candidates.count == snapshot.candidates.count else { return }
            for (k, found) in added { rally.candidates[k] += found }
            rally.points = TrackSolver.solve(rally)
            save()
            let id = rally.id, candidates = rally.candidates
            Task.detached(priority: .utility) { LocalStore.saveCandidates(id, candidates) }
        }
    }

    /// Whether the detectors may still run in this session. A list pulled since the rally was opened may have
    /// withheld its recording: from then on it goes on by hand (or closes, for an account it is closed to).
    private func stillAssisted() -> Bool {
        guard work == .assisted else { return false }
        let access = model.access(for: video)
        guard access != .open else { return true }
        work = TrackWork(access: access, existingTrack: !rally.points.isEmpty)
        if case .refused(let why) = work { phase = .failed(why) }
        return false
    }

    /// The ball can't be seen on this frame.
    func markHidden() {
        change { r in
            r.points[index].state = .hidden
            r.points[index].origin = .user
            r.points[index].box = nil
            r.points[index].reviewed = false
        }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        rally = last
        save()
    }

    /// Go to the next frame worth a look after this one (wrapping round).
    func nextToCheck() {
        let list = toCheck
        index = list.first { $0 > index } ?? list.first ?? index
    }

    func setDone(_ done: Bool) {
        change(resolve: false) { $0.done = done }
        if done {
            model.markRally(bounds, in: video)
            LocalStore.removeTracking(rally.id)
        }
    }

    /// The rally starts (the serve) or ends (the ball is dead) on this frame.
    func setBound(start: Bool) {
        guard let t = point?.time else { return }
        if start { bounds.start = min(t, bounds.end - 0.2) } else { bounds.end = max(t, bounds.start + 0.2) }
    }

    /// More frames before or after (the rally runs past what was read):
    /// your points stay, the rest is found again — by the detectors, so only
    /// in an assisted session (a rally worked on by hand keeps its frames).
    func extend(before: Double = 0, after: Double = 0) async {
        // Asked before anything of the rally is cleared: not assisted, it stays as it was saved.
        guard await decideWork() == .assisted else { return }
        keptPoints = rally.points.filter { $0.origin == .user }
        rally.start = max(0, rally.start - before)
        rally.end = min(video.duration, rally.end + after)
        rally.points = []
        rally.candidates = []
        frames = []
        undoStack = []
        phase = .preparing("Reading more frames…", 0)
        await read()
        save()
    }

    /// Not a rally after all: forget it (and any track of it so far).
    func discard() {
        if let found { model.rejectFound(found, in: video) }
        model.update(video) { $0.rallies.removeAll { abs($0.start - self.bounds.start) < 0.05 && abs($0.end - self.bounds.end) < 0.05 } }
        if model.tracks(for: video).contains(where: { $0.id == rally.id }) { model.delete(LabelTrack(rally, videoId: video.id)) }
        LocalStore.removeTracking(rally.id)
    }

    /// The ball's size near frame `i`: the detector's boxes on the closest
    /// frames either side (up to 3 each way, within 10 frames), averaged —
    /// the ball grows and shrinks with its distance from the camera, but
    /// barely in a third of a second. Else the rally's usual size.
    private func boxSide(near i: Int) -> CGSize {
        let detected = { (k: Int) -> TrackCandidate? in
            let p = self.rally.points[k]
            return p.state == .visible && p.origin == .auto ? p.box : nil
        }
        let before = stride(from: i - 1, through: max(0, i - 10), by: -1).compactMap(detected).prefix(3)
        let after = (min(i + 1, rally.points.count)..<min(rally.points.count, i + 11)).compactMap(detected).prefix(3)
        let near = Array(before) + Array(after)
        if !near.isEmpty {
            return CGSize(width: near.map(\.w).reduce(0, +) / Double(near.count), height: near.map(\.h).reduce(0, +) / Double(near.count))
        }
        let boxes = rally.points.compactMap { $0.state == .visible ? $0.box : nil }
        guard !boxes.isEmpty else { return CGSize(width: 0.02, height: 0.035) }
        let w = boxes.map(\.w).sorted()[boxes.count / 2], h = boxes.map(\.h).sorted()[boxes.count / 2]
        return CGSize(width: w, height: h)
    }

    private func change(resolve: Bool = true, _ edit: (inout TrackedRally) -> Void) {
        guard rally.points.indices.contains(index) else { return }
        undoStack.append(rally)
        if undoStack.count > 50 { undoStack.removeFirst() }
        rally = work.fixed(rally, resolve: resolve, edit)
        save()
    }

    private func save() {
        model.save(LabelTrack(rally, videoId: video.id))
    }
}

/// The ball detector for looking again, loaded once, at a low threshold:
/// it's only asked about the spot where the ball should be.
private final class LookAgainDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: YOLODetector?

    var detector: YOLODetector? {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        let yolo = YOLODetector(modelName: "ball_v2_small", computeUnits: .cpuAndNeuralEngine)
        yolo.minConfidence = 0.05
        yolo.suppressesStaticObjects = false
        guard yolo.isLoaded else { return nil }
        loaded = yolo
        return yolo
    }
}
