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
import Observation

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
    @ObservationIgnored private var display: AVAssetImageGenerator?
    @ObservationIgnored private var cache: [Double: CGImage] = [:]
    @ObservationIgnored private var cacheOrder: [Double] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var trackTask: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private let snapDetector = SnapDetector()

    /// Frames are read about this often, whatever the video's frame rate —
    /// the same spacing as the multi-frame package.
    static let frameRate = MultiFramePackage.frameRate
    private static let displayMaxPixel: CGFloat = 1920
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
        cache.removeAll(); cacheOrder.removeAll()
        let asset = AVURLAsset(url: URL(fileURLWithPath: session.sourcePath))
        video = asset
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Self.displayMaxPixel, height: Self.displayMaxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        display = generator
        suggestions = Self.suggestions(from: session, excluding: rallies)
        status = rallies.isEmpty && suggestions.isEmpty
            ? "No rallies found in this video yet — add one with New Rally."
            : "\(suggestions.count) rallies to track, \(rallies.filter(\.done).count) done."
        Task {
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
        centreOnBall()
        showFrame()
    }

    func deleteRally(_ id: UUID) {
        guard let removed = rallies.first(where: { $0.id == id }) else { return }
        if selectedId == id { stop(); trackTask?.cancel(); selectedId = nil; image = nil }
        rallies.removeAll { $0.id == id }
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
        guard let rally, let video else { return }
        trackTask?.cancel()
        stop()
        let id = rally.id
        let times = rally.points.map(\.time)
        let model = sampler.prelabelModel
        trackingProgress = 0
        status = "Finding the ball on \(times.count) frames…"
        trackTask = Task {
            let candidates = await Task.detached(priority: .userInitiated) { () -> [[TrackCandidate]]? in
                let detector = SamplerModel.detector(model: model, confidence: Self.candidateConfidence)
                let generator = AVAssetImageGenerator(asset: video)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                var found = [[TrackCandidate]](repeating: [], count: times.count)
                let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600_000) }
                var done = 0
                for await result in generator.images(for: cmTimes) {
                    if Task.isCancelled { return nil }
                    done += 1
                    guard let image = try? result.image,
                          let i = times.firstIndex(where: { abs($0 - result.requestedTime.seconds) < 0.0005 }) else { continue }
                    found[i] = detector.detect(in: image, at: result.requestedTime)
                        .map { TrackCandidate(rect: $0.bbox, confidence: Double($0.confidence)) }
                    if done % 10 == 0 {
                        let fraction = Double(done) / Double(times.count)
                        await MainActor.run { [weak self] in self?.trackingProgress = fraction }
                    }
                }
                return found
            }.value
            trackingProgress = nil
            guard let candidates, !Task.isCancelled, rallies.contains(where: { $0.id == id }) else { return }
            update(id) { r in
                r.candidates = candidates
                r.points = TrackSolver.solve(r)
            }
            report()
        }
    }

    private func report() {
        guard let rally else { return }
        let n = rally.points.count
        let visible = rally.points.filter { $0.state == .visible }.count
        let check = rally.points.filter(\.isUncertain).count
        status = "Ball found on \(visible) of \(n) frames · \(check) to check."
    }

    // MARK: - Editing

    /// You clicked the ball (top-left normalised in the frame): box it and
    /// re-solve the frames around it.
    func place(at point: CGPoint) {
        guard let image, let current = self.point, snapping == nil else { return }
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
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                go(to: index + 1)
                if pauseOnUncertain, self.rally?.points[index].isUncertain == true { break }
            }
            isPlaying = false
        }
    }

    // MARK: - Frames

    private func showFrame() {
        guard let p = point else { image = nil; return }
        if let cached = cache[p.time] { image = cached } else { load(p.time) }
        prefetch()
    }

    private func load(_ time: Double) {
        guard let display else { return }
        loadTask?.cancel()
        loadTask = Task {
            let image = await Self.frame(display, at: time)
            guard !Task.isCancelled, let image else { return }
            remember(time, image)
            if point?.time == time { self.image = image }
        }
    }

    /// The next frames, so playback doesn't wait on decoding.
    private func prefetch() {
        guard let display, let points = rally?.points else { return }
        let ahead = points[min(index + 1, points.count)..<min(index + 12, points.count)].map(\.time).filter { cache[$0] == nil }
        guard !ahead.isEmpty else { return }
        Task {
            for t in ahead where cache[t] == nil {
                if let image = await Self.frame(display, at: t) { remember(t, image) }
            }
        }
    }

    private func remember(_ time: Double, _ image: CGImage) {
        cache[time] = image
        cacheOrder.append(time)
        if cacheOrder.count > Self.cacheSize {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private nonisolated static func frame(_ generator: AVAssetImageGenerator, at seconds: Double) async -> CGImage? {
        try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600_000)).image
    }

    /// Presentation times from `start` to `end`, about 1/30 s apart, from
    /// the video's own frames.
    private func frameTimes(start: Double, end: Double) -> [Double]? {
        guard let videoTrack, end > start,
              let cursor = videoTrack.makeSampleCursor(presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 600_000))
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
