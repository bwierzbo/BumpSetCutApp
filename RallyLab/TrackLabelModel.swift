//
//  TrackLabelModel.swift
//  RallyLab
//
//  The Track tab: label a rally frame by frame. Pick a rally (the ones
//  the Sampler found when it took frames from the video, or your own),
//  the detector proposes the ball on every frame and TrackSolver picks
//  the path, then you play it back slowly and fix what's wrong — a click
//  puts the ball where it is (and the path re-solves around it), H marks
//  it hidden. Saved with the video's session as you go.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class TrackLabelModel {

    struct Suggestion: Identifiable, Equatable {
        var id: String { "\(start)-\(end)" }
        let start: Double
        let end: Double
    }

    let sampler: SamplerModel

    private(set) var sessionName: String?
    private(set) var rallies: [TrackedRally] = []
    /// Rallies the Sampler found in this video that aren't tracked yet.
    private(set) var suggestions: [Suggestion] = []
    private(set) var selectedId: UUID?
    private(set) var index = 0
    private(set) var image: CGImage?
    /// The frame `image` is. Drawing and clicks go by this, so they always
    /// match the picture even while the next frame is still loading.
    private(set) var shownIndex: Int?
    /// What's running while `trackingProgress` is set.
    private(set) var progressLabel = ""
    /// 0…1 while the detector runs over a rally.
    private(set) var trackingProgress: Double?
    private(set) var snapping: CGPoint?
    private(set) var isPlaying = false
    var speed = 0.25
    /// Playback stops on frames worth a look.
    var pauseOnUncertain = true
    /// 1 = fit. `zoomCenter` is the image point (top-left normalised) at
    /// the middle of the view.
    private(set) var zoom: CGFloat = 1
    private(set) var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    /// Zoomed in, keep the ball in the middle as the frames go by.
    var followBall = true {
        didSet { if followBall { centreOnBall() } }
    }
    private(set) var status = ""

    @ObservationIgnored private var video: AVURLAsset?
    @ObservationIgnored private var videoTrack: AVAssetTrack?
    @ObservationIgnored private var step = 1
    @ObservationIgnored private var frames: TrackFrameStore?
    @ObservationIgnored private var cache: [Double: CGImage] = [:]
    @ObservationIgnored private var cacheOrder: [Double] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Reading the open video's track (frame times need it).
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var trackTask: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private let snapDetector = SnapDetector()

    /// Frames are read about this often, whatever the video's frame rate —
    /// the same spacing as the multi-frame package.
    static let frameRate = MultiFramePackage.frameRate
    static let maxZoom: CGFloat = 8
    private static let cacheSize = 90
    nonisolated private static let candidateConfidence: Float = 0.15

    init(sampler: SamplerModel) {
        self.sampler = sampler
    }

    var rally: TrackedRally? { rallies.first { $0.id == selectedId } }
    var point: TrackPoint? { rally.flatMap { index < $0.points.count ? $0.points[index] : nil } }

    /// Sessions whose video is on this Mac — the frames come from it.
    var trackableSessions: [VideoSession] {
        sampler.sessions.filter { FileManager.default.fileExists(atPath: $0.sourcePath) }
    }

    // MARK: - Opening

    func open(sessionName name: String) {
        guard name != sessionName, let session = sampler.sessions.first(where: { $0.name == name }) else { return }
        stop()
        trackTask?.cancel()
        sessionName = name
        rallies = session.tracks ?? []
        selectedId = nil
        index = 0
        image = nil
        shownIndex = nil
        cache.removeAll(); cacheOrder.removeAll()
        let asset = AVURLAsset(url: URL(fileURLWithPath: session.sourcePath))
        video = asset
        frames = TrackFrameStore(session: name)
        suggestions = Self.suggestions(from: session, excluding: rallies)
        status = rallies.isEmpty && suggestions.isEmpty
            ? "No rallies found in this video yet — add one with New Rally."
            : "\(suggestions.count) rallies to track, \(rallies.filter(\.done).count) done."
        openTask = Task {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
                status = "Couldn't read \(session.sourcePath)."
                return
            }
            videoTrack = track
            let fps = Double((try? await track.load(.nominalFrameRate)) ?? 30)
            step = max(1, Int((fps / Self.frameRate).rounded()))
            if let first = rallies.first { select(first.id) }
        }
    }

    /// Open a video and wait until its rallies can be tracked.
    func openAndWait(sessionName name: String) async {
        open(sessionName: name)
        await openTask?.value
    }

    /// The rally stretches the Sampler took burst frames from, as ranges
    /// (each frame's time is inside its rally, padded by the burst padding).
    static func suggestions(from session: VideoSession, excluding tracked: [TrackedRally]) -> [Suggestion] {
        let byRally = Dictionary(grouping: session.frames.filter { $0.source.hasPrefix("rally:") }, by: \.source)
        return byRally.values.compactMap { frames -> Suggestion? in
            let times = frames.map(\.time)
            guard let lo = times.min(), let hi = times.max(), hi > lo else { return nil }
            let s = Suggestion(start: lo, end: hi)
            let overlapsTracked = tracked.contains { min($0.end, s.end) - max($0.start, s.start) > 0.5 }
            return overlapsTracked ? nil : s
        }
        .sorted { $0.start < $1.start }
    }

    // MARK: - Rallies

    func track(_ suggestion: Suggestion) {
        startRally(start: suggestion.start, end: suggestion.end)
    }

    /// A rally of your own, `length` seconds from `start`.
    func startRally(start: Double, end: Double) {
        guard let times = frameTimes(start: start, end: end), !times.isEmpty else {
            status = "Couldn't read frames between \(Self.clock(start)) and \(Self.clock(end))."
            return
        }
        let rally = TrackedRally(id: UUID(), start: times.first!, end: times.last!,
                                 points: times.map { TrackPoint(time: $0, state: .unknown, origin: .auto, box: nil) },
                                 candidates: [], done: false)
        rallies.append(rally)
        rallies.sort { $0.start < $1.start }
        suggestions.removeAll { min(rally.end, $0.end) - max(rally.start, $0.start) > 0.5 }
        select(rally.id)
        autoTrack()
    }

    func select(_ id: UUID) {
        guard rallies.contains(where: { $0.id == id }) else { return }
        stop()
        selectedId = id
        // Start where there's most to check.
        index = rally?.points.firstIndex(where: \.isUncertain) ?? 0
        image = nil
        shownIndex = nil
        centreOnBall()
        if let rally, let frames, !rally.points.allSatisfy({ frames.has($0.time) }), trackingProgress == nil {
            prepareFrames()
        } else {
            showFrame()
        }
    }

    func deleteRally(_ id: UUID) {
        guard let removed = rallies.first(where: { $0.id == id }) else { return }
        if selectedId == id { stop(); trackTask?.cancel(); selectedId = nil; image = nil; shownIndex = nil }
        rallies.removeAll { $0.id == id }
        let kept = Set(rallies.flatMap { $0.points.map(\.time) })
        frames?.remove(removed.points.map(\.time).filter { !kept.contains($0) })
        save()
        if let session = sampler.sessions.first(where: { $0.name == sessionName }) {
            suggestions = Self.suggestions(from: session, excluding: rallies)
        }
        status = "Removed the rally at \(Self.clock(removed.start))."
    }

    /// Moves the rally's start or end by `seconds`, keeping your points.
    func extend(start: Double = 0, end: Double = 0) {
        guard let rally, let times = frameTimes(start: max(0, rally.start + start), end: rally.end + end),
              !times.isEmpty else { return }
        let mine = rally.points.filter { $0.origin == .user }
        let currentTime = point?.time
        update { r in
            r.start = times.first!
            r.end = times.last!
            r.points = times.map { t in
                mine.first { abs($0.time - t) < 0.002 } ?? TrackPoint(time: t, state: .unknown, origin: .auto, box: nil)
            }
            r.candidates = []
            r.done = false
        }
        if let currentTime, let i = self.rally?.points.firstIndex(where: { abs($0.time - currentTime) < 0.002 }) { index = i }
        autoTrack()
    }

    func toggleDone() {
        update { $0.done.toggle() }
        if rally?.done == true {
            let next = rallies.first { !$0.done }
            status = next == nil && suggestions.isEmpty ? "Every rally in this video is done." : "Rally done."
        }
    }

    // MARK: - Auto-track

    /// Runs the detector over every frame of the selected rally, then solves.
    func autoTrack() {
        guard let rally, let video, let frames else { return }
        trackTask?.cancel()
        stop()
        let id = rally.id
        let times = rally.points.map(\.time)
        let model = sampler.prelabelModel
        let heatModel = newestHeatModel
        trackingProgress = 0
        progressLabel = heatModel == nil ? "Finding the ball on every frame…"
            : "Finding the ball on every frame (YOLO + multi-frame)…"
        status = "Finding the ball on \(times.count) frames…"
        trackTask = Task {
            let candidates = await Task.detached(priority: .userInitiated) { () -> [[TrackCandidate]]? in
                let detector = SamplerModel.detector(model: model, confidence: Self.candidateConfidence)
                let heat = heatModel.flatMap { HeatmapBallDetector(modelURL: $0) }
                var grays = [HeatmapBallDetector.Frame?](repeating: nil, count: times.count)
                let generator = AVAssetImageGenerator(asset: video)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                var found = [[TrackCandidate]](repeating: [], count: times.count)
                var done = 0
                for await result in generator.images(for: times.map(TrackFrameStore.request)) {
                    if Task.isCancelled { return nil }
                    done += 1
                    guard let image = try? result.image,
                          let i = times.firstIndex(where: { abs($0 - result.requestedTime.seconds) < 0.0005 }) else { continue }
                    found[i] = detector.detect(in: image, at: result.requestedTime)
                        .map { TrackCandidate(rect: $0.bbox, confidence: Double($0.confidence)) }
                    grays[i] = heat?.grayscale(image)
                    // The same frame, kept for review: no seeking in the video later.
                    if !frames.has(times[i]) { frames.write(image, time: times[i]) }
                    if done % 10 == 0 {
                        let fraction = Double(done) / Double(times.count)
                        await MainActor.run { [weak self] in self?.trackingProgress = fraction }
                    }
                }
                if let heat { TrackFinder.addHeatmapCandidates(heat, grays: grays, to: &found) }
                return found
            }.value
            trackingProgress = nil
            guard let candidates, !Task.isCancelled, rallies.contains(where: { $0.id == id }) else { return }
            update(id) { r in
                r.candidates = candidates
                r.points = TrackSolver.solve(r)
            }
            report()
            if selectedId == id { showFrame() }
        }
    }

    /// The newest multi-frame model added in the Models tab, if any.
    private var newestHeatModel: URL? {
        let dir = sampler.datasetRoot.appendingPathComponent("models/heatmap", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "mlpackage" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da < db
            }
    }

    /// Rallies tracked before frames were kept: read their frames out of the
    /// video once, in order, so review never seeks.
    private func prepareFrames() {
        guard let rally, let video, let frames else { return }
        let id = rally.id
        let missing = rally.points.map(\.time).filter { !frames.has($0) }
        trackingProgress = 0
        progressLabel = "Preparing frames…"
        trackTask = Task {
            await Task.detached(priority: .userInitiated) {
                let generator = AVAssetImageGenerator(asset: video)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                var done = 0
                for await result in generator.images(for: missing.map(TrackFrameStore.request)) {
                    if Task.isCancelled { return }
                    done += 1
                    if let image = try? result.image,
                       let t = missing.first(where: { abs($0 - result.requestedTime.seconds) < 0.0005 }) {
                        frames.write(image, time: t)
                    }
                    if done % 10 == 0 {
                        let fraction = Double(done) / Double(missing.count)
                        await MainActor.run { [weak self] in self?.trackingProgress = fraction }
                    }
                }
            }.value
            trackingProgress = nil
            if selectedId == id, !Task.isCancelled { showFrame() }
        }
    }

    private func report() {
        guard let rally else { return }
        let n = rally.points.count
        let visible = rally.points.filter { $0.state == .visible }.count
        let check = rally.points.filter(\.isUncertain).count
        status = "Ball found on \(visible) of \(n) frames · \(check) to check."
            + (newestHeatModel.map { " · multi-frame: \($0.deletingPathExtension().lastPathComponent)" } ?? "")
    }

    // MARK: - Editing

    /// You clicked the ball (top-left normalised in the frame): box it and
    /// re-solve the frames around it.
    func place(at point: CGPoint) {
        guard let image, let shownIndex, let current = rally?.points[shownIndex], snapping == nil else { return }
        snapping = point
        let model = sampler.prelabelModel
        let holder = snapDetector
        let usual = usualWidth()
        let id = selectedId
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                BallSnapper.snap(at: point, in: image, detector: holder.detector(for: model), usualSize: usual)
            }.value
            snapping = nil
            guard id == selectedId, let i = rally?.points.firstIndex(where: { $0.time == current.time }) else { return }
            update { r in
                r.points[i] = TrackPoint(time: current.time, state: .visible, origin: .user,
                                         box: TrackCandidate(rect: result.rect, confidence: 1))
                r.points = TrackSolver.solve(r)
            }
            report()
        }
    }

    /// Ball out of sight on this frame (H).
    func markHidden() {
        let i = index
        update { r in
            r.points[i] = TrackPoint(time: r.points[i].time, state: .hidden, origin: .user, box: nil)
            r.points = TrackSolver.solve(r)
        }
        report()
    }

    /// The solver's pick is right (↩ on an uncertain frame): make it yours.
    func confirm() {
        let i = index
        guard let p = point, p.state == .visible else { return }
        update { r in
            r.points[i].origin = .user
            r.points[i].box?.confidence = 1
            r.points = TrackSolver.solve(r)
        }
    }

    /// Back to the solver's choice (⌫).
    func revert() {
        let i = index
        guard point?.origin == .user else { return }
        update { r in
            r.points[i].origin = .auto
            r.points = TrackSolver.solve(r)
        }
        report()
    }

    private func usualWidth() -> CGFloat? {
        let widths = (rally?.points ?? []).compactMap { $0.state == .visible ? $0.box?.w : nil }.sorted()
        return widths.isEmpty ? nil : CGFloat(widths[widths.count / 2])
    }

    // MARK: - Moving

    func go(to i: Int) {
        guard let rally else { return }
        index = min(max(0, i), rally.points.count - 1)
        centreOnBall()
        showFrame()
    }

    // MARK: - Zoom

    func setZoom(_ value: CGFloat, around point: CGPoint? = nil) {
        zoom = min(max(value, 1), Self.maxZoom)
        if let point { zoomCenter = point }
        clampZoomCenter()
    }

    func zoom(by factor: CGFloat) {
        setZoom(zoom * factor)
        centreOnBall()
    }

    func resetZoom() {
        zoom = 1
        zoomCenter = CGPoint(x: 0.5, y: 0.5)
    }

    /// Pan by a fraction of the image (top-left normalised). Panning by hand
    /// stops following the ball.
    func pan(dx: CGFloat, dy: CGFloat) {
        followBall = false
        zoomCenter.x += dx
        zoomCenter.y += dy
        clampZoomCenter()
    }

    private func centreOnBall() {
        guard followBall, zoom > 1.01, let p = point, p.state == .visible, let box = p.box else { return }
        zoomCenter = CGPoint(x: box.rect.midX, y: 1 - box.rect.midY)
        clampZoomCenter()
    }

    private func clampZoomCenter() {
        let half = 0.5 / zoom
        zoomCenter.x = min(max(zoomCenter.x, half), 1 - half)
        zoomCenter.y = min(max(zoomCenter.y, half), 1 - half)
    }

    func stepBy(_ delta: Int) {
        stop()
        go(to: index + delta)
    }

    /// The next (or previous) frame worth a look.
    func jumpToUncertain(forward: Bool) {
        guard let points = rally?.points else { return }
        stop()
        let range = forward ? Array((index + 1)..<points.count) : Array((0..<index).reversed())
        if let i = range.first(where: { points[$0].isUncertain }) { go(to: i) }
        else { status = forward ? "Nothing left to check after this frame." : "Nothing to check before this frame." }
    }

    func togglePlay() {
        isPlaying ? stop() : play()
    }

    func stop() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    private func play() {
        guard let rally, !rally.points.isEmpty else { return }
        if index >= rally.points.count - 1 { index = 0 }
        isPlaying = true
        playTask = Task {
            while !Task.isCancelled, let points = self.rally?.points, index < points.count - 1 {
                let interval = 1 / (Self.frameRate * speed)
                let started = Date()
                let next = index + 1
                let frame = await image(for: points[next].time)   // wait for it rather than run ahead
                let wait = interval - Date().timeIntervalSince(started)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard !Task.isCancelled, let frame else { break }
                index = next
                centreOnBall()
                image = frame
                shownIndex = next
                prefetch()
                if pauseOnUncertain, self.rally?.points[index].isUncertain == true { break }
            }
            isPlaying = false
        }
    }

    // MARK: - Frames

    private func showFrame() {
        guard let p = point else { image = nil; shownIndex = nil; return }
        let i = index
        if let cached = cache[p.time] {
            image = cached
            shownIndex = i
        } else {
            loadTask?.cancel()
            loadTask = Task {
                guard let frame = await image(for: p.time), !Task.isCancelled, index == i else { return }
                image = frame
                shownIndex = i
            }
        }
        prefetch()
    }

    /// A frame from the kept JPEGs (a few milliseconds), via the memory cache.
    private func image(for time: Double) async -> CGImage? {
        if let cached = cache[time] { return cached }
        guard let frames else { return nil }
        let frame = await Task.detached(priority: .userInitiated) { frames.read(time) }.value
        if let frame { remember(time, frame) }
        return frame
    }

    /// The next frames, so stepping and playback don't wait.
    private func prefetch() {
        guard let points = rally?.points else { return }
        let ahead = points[min(index + 1, points.count)..<min(index + 8, points.count)].map(\.time).filter { cache[$0] == nil }
        guard !ahead.isEmpty else { return }
        Task { for t in ahead { _ = await image(for: t) } }
    }

    private func remember(_ time: Double, _ image: CGImage) {
        guard cache[time] == nil else { return }
        cache[time] = image
        cacheOrder.append(time)
        if cacheOrder.count > Self.cacheSize {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    /// Presentation times from `start` to `end`, about 1/30 s apart, from
    /// the video's own frames.
    private func frameTimes(start: Double, end: Double) -> [Double]? {
        guard let videoTrack, end > start,
              let cursor = videoTrack.makeSampleCursor(presentationTimeStamp: TrackFrameStore.request(start))
        else { return nil }
        var times: [Double] = []
        while cursor.presentationTimeStamp.seconds <= end {
            times.append(cursor.presentationTimeStamp.seconds)
            if cursor.stepInPresentationOrder(byCount: Int64(step)) != Int64(step) { break }
        }
        return times
    }

    // MARK: - Saving

    private func update(_ id: UUID? = nil, _ change: (inout TrackedRally) -> Void) {
        guard let i = rallies.firstIndex(where: { $0.id == (id ?? selectedId) }) else { return }
        change(&rallies[i])
        save()
    }

    private func save() {
        guard let sessionName else { return }
        sampler.setTracks(rallies, session: sessionName)
    }

    static func clock(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

/// A rally's frames as JPEGs in Caches, written while the detector reads
/// them, so reviewing never seeks in the video (a seek decodes from the last
/// keyframe — slow, and the picture fell behind the overlay).
struct TrackFrameStore: Sendable {
    let dir: URL
    static let maxPixel = 1920

    init(session: String) {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RallyLab/TrackFrames/\(DatasetStore.safeName(session))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// The time to ask a generator for: just after the frame starts. Seconds
    /// can round to a hair before a frame's presentation time, which with zero
    /// tolerance returns the frame before it.
    static func request(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds + 0.0001, preferredTimescale: 600_000)
    }

    private func url(_ time: Double) -> URL {
        dir.appendingPathComponent("\(Int64((time * 1_000_000).rounded())).jpg")
    }

    func has(_ time: Double) -> Bool { FileManager.default.fileExists(atPath: url(time).path) }

    func write(_ image: CGImage, time: Double) {
        guard let dest = CGImageDestinationCreateWithURL(url(time) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88,
                                                 kCGImageDestinationImageMaxPixelSize: Self.maxPixel] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    func read(_ time: Double) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(time) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func remove(_ times: [Double]) {
        for t in times { try? FileManager.default.removeItem(at: url(t)) }
    }
}
