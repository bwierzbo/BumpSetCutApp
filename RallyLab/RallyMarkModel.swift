//
//  RallyMarkModel.swift
//  RallyLab
//
//  The Track tab's Rally Times mode: mark when every rally in a video
//  starts and ends, fast — the ground truth that scores missed, false and
//  merged rallies. It starts from what's already known (the Sampler's
//  rally guesses and your tracked rallies), so mostly you correct: scroll
//  or skim through dead time, accept a guess with A, Enter at a rally's
//  start and again at its end.
//
//  Saved next to the video as <name>.rallylabels.json (what the Pipeline
//  tab's scoring reads), on every change. "Whole video marked" is kept on
//  the session, so evaluation only counts videos you've finished.
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class RallyMarkModel {

    struct Mark: Identifiable, Equatable {
        let id: UUID
        var start: Double
        var end: Double
        init(id: UUID = UUID(), start: Double, end: Double) { (self.id, self.start, self.end) = (id, start, end) }
        func contains(_ t: Double) -> Bool { t >= start && t <= end }
    }

    let sampler: SamplerModel
    private(set) var sessionName: String?
    private(set) var player: AVPlayer?
    private(set) var duration: Double = 0
    private(set) var playhead: Double = 0
    private(set) var isPlaying = false
    var rate: Float = 1 { didSet { if isPlaying { player?.rate = rate } } }
    private(set) var rallies: [Mark] = []
    /// The Sampler's rallies and your tracked ones, to accept or ignore.
    private(set) var guesses: [Mark] = []
    var selectedId: UUID?
    /// Picture zoom: 1 = the whole frame; `zoomCenter` (0–1, top-left) is
    /// kept mid-view.
    private(set) var zoom: CGFloat = 1
    var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    static let maxZoom: CGFloat = 8

    func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 1), Self.maxZoom)
        pan(to: zoomCenter)
    }

    func resetZoom() {
        zoom = 1
        zoomCenter = CGPoint(x: 0.5, y: 0.5)
    }

    /// Keep the zoomed picture covering the view.
    func pan(to point: CGPoint) {
        let half = 0.5 / zoom
        zoomCenter = CGPoint(x: min(max(point.x, half), 1 - half), y: min(max(point.y, half), 1 - half))
    }

    /// Enter pressed once: the rally's start, waiting for its end.
    private(set) var pendingStart: Double?
    private(set) var status = ""

    @ObservationIgnored private var video: URL?
    @ObservationIgnored private var timeObserver: Any?
    /// One seek in flight at a time; a newer target waits and is chased
    /// when it lands (Apple's QA1820) — scrubbing stays smooth instead of
    /// queueing a seek per scroll event.
    @ObservationIgnored private var seekTarget: Double?
    @ObservationIgnored private var seekExact = true
    @ObservationIgnored private var seeking = false
    /// Settles a scrub on the exact frame once scrolling stops.
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    init(sampler: SamplerModel) {
        self.sampler = sampler
    }

    var wholeVideoMarked: Bool {
        get { sampler.sessions.first { $0.name == sessionName }?.ralliesMarked ?? false }
        set {
            guard let sessionName else { return }
            sampler.setRalliesMarked(newValue, session: sessionName)
            status = newValue ? "Whole video marked — it counts in rally scoring." : "Marked as not finished."
        }
    }

    /// Guesses not yet covered by a marked rally.
    var openGuesses: [Mark] {
        guesses.filter { g in !rallies.contains { min($0.end, g.end) - max($0.start, g.start) > 0.3 } }
    }

    // MARK: - Opening

    func open(sessionName name: String) {
        guard name != sessionName, let session = sampler.sessions.first(where: { $0.name == name }) else { return }
        close()
        sessionName = name
        let url = URL(fileURLWithPath: session.sourcePath)
        video = url
        let player = AVPlayer(url: url)
        player.isMuted = true
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                // While seeking, the playhead is where you're going, not where it was.
                guard let self, !self.seeking else { return }
                self.playhead = t.seconds
            }
        }
        Task {
            duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        }
        resetZoom()
        rallies = Self.load(Self.labelsURL(for: url))
        guesses = Self.guesses(for: session)
        pendingStart = nil
        selectedId = nil
        status = rallies.isEmpty
            ? "\(guesses.count) guesses to start from — N jumps to the next, A accepts it, Enter marks your own."
            : "\(rallies.count) rallies marked."
    }

    /// The open video's rally times changed elsewhere (a sync with the
    /// phone): take them, so a later save here doesn't put back the old ones.
    func reloadMarks(session name: String) {
        guard name == sessionName, let video else { return }
        rallies = Self.load(Self.labelsURL(for: video))
    }

    func close() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    nonisolated static func labelsURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("rallylabels.json")
    }

    nonisolated static func load(_ url: URL) -> [Mark] {
        guard let data = try? Data(contentsOf: url),
              let labels = try? JSONDecoder().decode([LabeledRally].self, from: data) else { return [] }
        return labels.map { Mark(start: $0.startTime, end: $0.endTime) }.sorted { $0.start < $1.start }
    }

    /// Where the Sampler found rallies (its burst frames), and your tracked
    /// rallies (where the ball was in play), merged where they overlap.
    private static func guesses(for session: VideoSession) -> [Mark] {
        var found = TrackLabelModel.suggestions(from: session, excluding: []).map { Mark(start: $0.start, end: $0.end) }
        for rally in session.tracks ?? [] {
            let seen = rally.points.filter { $0.state == .visible }.map(\.time)
            if let a = seen.first, let b = seen.last, b > a { found.append(Mark(start: a, end: b)) }
        }
        var merged: [Mark] = []
        for g in found.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, g.start <= last.end {
                last.end = max(last.end, g.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(g)
            }
        }
        return merged
    }

    // MARK: - Playback

    func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.rate = rate }
        isPlaying.toggle()
    }

    func seek(to t: Double, exact: Bool = true) {
        // Before the length has loaded, don't hold seeks at 0.
        let clamped = max(0, duration > 0 ? min(t, duration) : t)
        playhead = clamped
        seekTarget = clamped
        seekExact = exact
        chaseSeek()
    }

    private func chaseSeek() {
        guard !seeking, let target = seekTarget, let player else { return }
        seeking = true
        seekTarget = nil
        // While scrubbing, a frame within a tenth of a second is fine and far
        // quicker to show (no decoding from the last keyframe); exact otherwise.
        let tolerance = seekExact ? CMTime.zero : CMTime(value: 1, timescale: 10)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                self.chaseSeek()
            }
        }
    }

    func skip(by seconds: Double) { seek(to: playhead + seconds) }

    /// Scroll to scrub: pauses playback, chases the scrolled-to time loosely,
    /// then lands on the exact frame a moment after scrolling stops.
    func scrub(by seconds: Double) {
        if isPlaying { togglePlay() }
        seek(to: playhead + seconds, exact: false)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self else { return }
            self.seek(to: self.playhead)
        }
    }

    /// The next (or previous) rally or guess start from the playhead.
    func jump(forward: Bool) {
        let starts = (rallies.map(\.start) + openGuesses.map(\.start)).sorted()
        let target = forward ? starts.first { $0 > playhead + 0.3 } : starts.last { $0 < playhead - 0.3 }
        guard let target else { status = forward ? "No more rallies after this." : "No rallies before this."; return }
        seek(to: max(0, target - 1))   // a second early, to see it begin
        selectedId = rallies.first { $0.start == target }?.id
    }

    // MARK: - Marking

    /// Enter: the first press starts a rally at the playhead, the second ends it.
    func toggleMark() {
        guard let start = pendingStart else {
            pendingStart = playhead
            status = "Rally starts at \(TrackLabelModel.clock(playhead)) — Enter again at its end (Esc cancels)."
            return
        }
        guard playhead > start + 0.2 else {
            status = "The end has to be after the start (\(TrackLabelModel.clock(start))) — move on, or Esc to cancel."
            return
        }
        pendingStart = nil
        mark(start: start, end: playhead)
    }

    /// A rally from `start` to `end`, replacing any marked rally it overlaps
    /// (the same rally, marked again).
    func mark(start: Double, end: Double) {
        let mark = Mark(start: start, end: end)
        rallies.removeAll { min($0.end, mark.end) - max($0.start, mark.start) > 0.5 * min($0.end - $0.start, mark.end - mark.start) }
        rallies.append(mark)
        selectedId = mark.id
        save()
    }

    /// Mark a rally in any video — the open one in place, so its unsaved
    /// view of the file doesn't later overwrite this.
    func mark(start: Double, end: Double, session: VideoSession) {
        if session.name == sessionName { return mark(start: start, end: end) }
        let url = Self.labelsURL(for: URL(fileURLWithPath: session.sourcePath))
        var marks = Self.load(url)
        marks.removeAll { min($0.end, end) - max($0.start, start) > 0.5 * min($0.end - $0.start, end - start) }
        marks.append(Mark(start: start, end: end))
        Self.write(marks, to: url)
    }

    /// The rallies marked in a video.
    static func marks(in session: VideoSession) -> [Mark] {
        load(labelsURL(for: URL(fileURLWithPath: session.sourcePath)))
    }

    /// Esc: forget a start you didn't mean.
    func cancelPending() {
        guard pendingStart != nil else { return }
        pendingStart = nil
        status = "Start cancelled."
    }

    /// A: the guess at the playhead (or the next one) is a rally, as is.
    func acceptGuess() {
        guard let g = openGuesses.first(where: { $0.contains(playhead) }) ?? openGuesses.first(where: { $0.start > playhead }) else {
            status = "No guess here."
            return
        }
        let mark = Mark(start: g.start, end: g.end)
        rallies.append(mark)
        selectedId = mark.id
        save()
    }

    /// ⌫: remove the selected rally (or the one at the playhead).
    func delete() {
        guard let i = selectedIndex(at: playhead) else { return }
        rallies.remove(at: i)
        selectedId = nil
        save()
    }

    func setStart(_ id: UUID, to t: Double) {
        guard let i = rallies.firstIndex(where: { $0.id == id }) else { return }
        rallies[i].start = min(max(0, t), rallies[i].end - 0.2)
        save()
    }

    func setEnd(_ id: UUID, to t: Double) {
        guard let i = rallies.firstIndex(where: { $0.id == id }) else { return }
        rallies[i].end = max(min(duration, t), rallies[i].start + 0.2)
        save()
    }

    private func selectedIndex(at t: Double) -> Int? {
        if let id = selectedId, let i = rallies.firstIndex(where: { $0.id == id }) { return i }
        return rallies.firstIndex { $0.contains(t) }
    }

    private func save() {
        rallies.sort { $0.start < $1.start }
        guard let video else { return }
        if let error = Self.write(rallies, to: Self.labelsURL(for: video)) {
            status = "Couldn't save: \(error.localizedDescription)"
        } else {
            status = "\(rallies.count) rallies marked · saved."
        }
    }

    @discardableResult
    private static func write(_ marks: [Mark], to url: URL) -> Error? {
        let labels = marks.sorted { $0.start < $1.start }.map { LabeledRally(startTime: $0.start, endTime: $0.end) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(labels).write(to: url, options: .atomic)
            return nil
        } catch {
            return error
        }
    }
}
