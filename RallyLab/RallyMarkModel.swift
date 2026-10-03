//
//  RallyMarkModel.swift
//  RallyLab
//
//  The Track tab's Rally Times mode: mark when every rally in a video
//  starts and ends, fast — the ground truth that scores missed, false and
//  merged rallies. It starts from what's already known (the Sampler's
//  rally guesses and your tracked rallies), so mostly you correct: skim
//  dead time at 2–4×, accept a guess with A, set an end with O.
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
    /// I pressed, O not yet.
    private(set) var pendingStart: Double?
    private(set) var status = ""

    @ObservationIgnored private var video: URL?
    @ObservationIgnored private var timeObserver: Any?

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
            MainActor.assumeIsolated { self?.playhead = t.seconds }
        }
        Task {
            duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        }
        rallies = Self.load(Self.labelsURL(for: url))
        guesses = Self.guesses(for: session)
        pendingStart = nil
        selectedId = nil
        status = rallies.isEmpty
            ? "\(guesses.count) guesses to start from — N jumps to the next, A accepts it."
            : "\(rallies.count) rallies marked."
    }

    func close() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    static func labelsURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("rallylabels.json")
    }

    private static func load(_ url: URL) -> [Mark] {
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

    func seek(to t: Double) {
        let clamped = min(max(0, t), max(duration, 0))
        playhead = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) { seek(to: playhead + seconds) }

    /// The next (or previous) rally or guess start from the playhead.
    func jump(forward: Bool) {
        let starts = (rallies.map(\.start) + openGuesses.map(\.start)).sorted()
        let target = forward ? starts.first { $0 > playhead + 0.3 } : starts.last { $0 < playhead - 0.3 }
        guard let target else { status = forward ? "No more rallies after this." : "No rallies before this."; return }
        seek(to: max(0, target - 1))   // a second early, to see it begin
        selectedId = rallies.first { $0.start == target }?.id
    }

    // MARK: - Marking

    /// I: a rally starts here. Inside a selected rally, moves its start.
    func markStart() {
        if let i = selectedIndex(at: playhead) {
            rallies[i].start = min(playhead, rallies[i].end - 0.2)
            save()
        } else {
            pendingStart = playhead
            status = "Start set at \(TrackLabelModel.clock(playhead)) — O at the end."
        }
    }

    /// O: the rally ends here — the one started with I, or the one you're in.
    func markEnd() {
        if let start = pendingStart, playhead > start + 0.2 {
            let mark = Mark(start: start, end: playhead)
            rallies.append(mark)
            selectedId = mark.id
            pendingStart = nil
            save()
        } else if let i = selectedIndex(at: playhead) ?? rallies.lastIndex(where: { $0.start < playhead }) {
            rallies[i].end = max(playhead, rallies[i].start + 0.2)
            selectedId = rallies[i].id
            save()
        }
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
        let labels = rallies.map { LabeledRally(startTime: $0.start, endTime: $0.end) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(labels).write(to: Self.labelsURL(for: video), options: .atomic)
            status = "\(rallies.count) rallies marked · saved."
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
