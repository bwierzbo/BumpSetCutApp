//
//  PlayerLabModel.swift
//  RallyLab
//
//  The Player Lab window's state (player-feasibility research, P0): the runs of one
//  experiment folder, a run's recordings and intervals, the sampled frames of the
//  chosen interval, the decoded frame at the chosen index with the chosen overlay
//  layers, per-interval statistics and each track's lifespan. It reads only the
//  experiment folder (the run's frame lines and the experiment's copy of the
//  footage) — never a RallyLab project, never the footage share — and writes only
//  snapshots into the run's gui-snapshots/ folder.
//

import AVFoundation
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PlayerLabModel {
    struct RunEntry: Identifiable, Hashable { var id: String { name }; let name: String; let folder: URL }
    enum Mode: String, CaseIterable { case players = "Players", court = "Court calibration" }

    let experiment: URL
    private(set) var runs: [RunEntry] = []
    private(set) var manifest: PlayerFeatures.Manifest?
    var run: RunEntry? { didSet { if run != oldValue { loadRun() } } }
    var recordingId: String? { didSet { if recordingId != oldValue { loadRecording() } } }
    var intervalName: String? { didSet { if intervalName != oldValue { selectInterval() } } }
    private(set) var frames: [PlayerFeatures.Frame] = []
    private(set) var index = 0
    var options = PlayerOverlay.Options() { didSet { if options != oldValue { recompose() } } }
    private(set) var composed: CGImage?
    private(set) var stats = PlayerFeaturesSummary.Stats()
    private(set) var tracks: [PlayerFeaturesSummary.TrackSpan] = []
    private(set) var status = ""
    private(set) var playing = false
    var mode = Mode.players { didSet { if mode != oldValue { recompose() } } }
    /// The recording's court calibration (experiment folder only).
    private(set) var court: CourtCalibrationModel?
    /// Per frame of the interval, each person's zone against the court on screen; nil where no court covers it.
    private(set) var zones: [[PersonZone?]?] = []

    private var allFrames: [PlayerFeatures.Frame] = []
    private var raw: [Int: CGImage] = [:]
    private var generator: AVAssetImageGenerator?
    private var lane: PlayerCourtLane?
    private var playTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    init(experiment: URL) {
        self.experiment = experiment
        reloadRuns()
    }

    var recording: PlayerFeatures.Recording? { manifest?.recordings.first { $0.recordingId == recordingId } }
    var frame: PlayerFeatures.Frame? { frames.indices.contains(index) ? frames[index] : nil }
    var hz: Double { manifest.flatMap { Double($0.sampling["hz"] ?? "") } ?? 5 }

    func reloadRuns() {
        let dir = experiment.appendingPathComponent("runs", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        runs = names.map { RunEntry(name: $0, folder: dir.appendingPathComponent($0, isDirectory: true)) }
            .filter { FileManager.default.fileExists(atPath: $0.folder.appendingPathComponent("features/player-features-manifest.json").path) }
        if run == nil { run = runs.last }
        status = runs.isEmpty ? "No runs in \(dir.path)" : status
    }

    private func loadRun() {
        manifest = nil
        recordingId = nil
        guard let run else { return }
        do {
            manifest = try JSONDecoder().decode(PlayerFeatures.Manifest.self, from: Data(contentsOf: run.folder.appendingPathComponent("features/player-features-manifest.json")))
            recordingId = manifest?.recordings.first?.recordingId
        } catch { status = "Can't read \(run.name): \(error.localizedDescription)" }
    }

    private func loadRecording() {
        stop()
        allFrames = []
        raw = [:]
        generator = nil
        intervalName = nil
        guard let run, let rec = recording else { return }
        do {
            let data = try Data(contentsOf: run.folder.appendingPathComponent("features").appendingPathComponent(rec.framesFile))
            let decoder = JSONDecoder()
            allFrames = try data.split(separator: 0x0A).map { try decoder.decode(PlayerFeatures.Frame.self, from: Data($0)) }
        } catch { status = "Can't read \(rec.framesFile): \(error.localizedDescription)"; return }
        let footage = PlayerFeaturesRun.experimentFootage(experiment, rec.recordingId)
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: footage))
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        generator = g
        lane = PlayerCourtLane.make(net: rec.net, camera: rec.camera, recordingFingerprint: rec.fingerprint).lane
        let calibration = CourtCalibrationModel(experiment: experiment, recording: rec, footage: footage)
        calibration.onChange = { [weak self] in self?.courtChanged() }
        court = calibration
        intervalName = rec.intervals.first?.name
    }

    private func selectInterval() {
        stop()
        frames = allFrames.filter { $0.interval == intervalName }
        raw = [:]
        stats = PlayerFeaturesSummary.stats(frames, laneKnown: recording?.courtUnknownReason == nil)
        tracks = PlayerFeaturesSummary.tracks(frames)
        zones = court?.zones(for: frames) ?? []
        index = 0
        show()
    }

    private func courtChanged() {
        zones = court?.zones(for: frames) ?? []
        recompose()
    }

    /// The current frame's time (for splitting a calibration segment).
    var time: Double? { frame?.t }

    /// Counts of the current frame's zones (confirmed tracks).
    var zoneCounts: [CourtZone: Int] {
        guard zones.indices.contains(index), let z = zones[index], let f = frame else { return [:] }
        var out: [CourtZone: Int] = [:]
        for (p, zone) in zip(f.persons, z) where p.state == .confirmed { if let zone { out[zone.zone, default: 0] += 1 } }
        return out
    }

    func go(to i: Int) {
        guard !frames.isEmpty else { return }
        index = min(max(0, i), frames.count - 1)
        show()
    }

    func step(_ d: Int) { stop(); go(to: index + d) }

    func togglePlay() {
        if playing { stop(); return }
        playing = true
        let period = 1 / hz
        playTask = Task { [weak self] in
            while let self, self.playing, !Task.isCancelled {
                if self.index >= self.frames.count - 1 { self.stop(); break }
                self.go(to: self.index + 1)
                try? await Task.sleep(for: .seconds(period))
            }
        }
    }

    func stop() {
        playing = false
        playTask?.cancel()
        playTask = nil
    }

    /// The decoded frame for the current index (cached), then the overlay.
    private func show() {
        guard let f = frame else { composed = nil; return }
        let i = index
        if raw[i] != nil { recompose(); return }
        guard let generator else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = try? await generator.image(at: CMTime(seconds: f.t, preferredTimescale: 600)).image
            guard let self, !Task.isCancelled else { return }
            if let image { self.raw[i] = image } else { self.status = "Can't decode t=\(f.t)" }
            if self.raw.count > 200 { self.raw = self.raw.filter { abs($0.key - self.index) < 50 } }
            if self.index == i { self.recompose() }
        }
    }

    /// Waits until the current frame's picture is drawn (scripted runs).
    func waitUntilShown() async {
        for _ in 0..<200 where composed == nil || raw[index] == nil { try? await Task.sleep(for: .milliseconds(25)) }
    }

    private func recompose() {
        guard let f = frame, let image = raw[index], let rec = recording else { composed = nil; return }
        var o = options
        var drawn: (geometry: CourtLayout, spec: CourtSpec, color: CGColor, dashed: Bool)?
        if let court, let shown = court.shown, court.segment(at: f.t)?.id == court.segmentId {
            drawn = (shown.geometry, court.spec, Self.courtColor(shown.style), shown.style != .confirmed)
        }
        // In court mode the editor draws the court itself (beyond the frame's edges too).
        if mode == .court { o.court = false }
        let frameZones = zones.indices.contains(index) ? zones[index] : nil
        composed = PlayerOverlay.compose(image, frame: f, recording: rec.recordingId, net: rec.net, lane: lane, options: o, court: drawn,
                                         zones: frameZones)
    }

    nonisolated static func courtColor(_ s: CourtCalibrationModel.Style) -> CGColor {
        switch s {
        case .proposal: return CGColor(red: 1, green: 0.55, blue: 0.1, alpha: 0.95)
        case .adjusted: return CGColor(red: 0.2, green: 0.9, blue: 1, alpha: 0.95)
        case .confirmed: return CGColor(red: 0.3, green: 1, blue: 0.4, alpha: 0.95)
        }
    }

    // MARK: - Snapshots

    /// Writes the composed frame (exactly the pixels shown) as PNG and, beside it, the frame's facts and the interval's
    /// numbers as JSON, into the run's gui-snapshots/ folder. (A capture of the whole window is taken from outside with
    /// `screencapture -l <window>`: AppKit's own view caching leaves SwiftUI controls and text out.)
    @discardableResult
    func snapshot(name: String) -> URL? {
        guard let run, let composed, let frame else { status = "Nothing to snapshot"; return nil }
        let dir = run.folder.appendingPathComponent("gui-snapshots", isDirectory: true)
        let safe = name.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        let png = dir.appendingPathComponent("\(safe)-frame.png")
        struct Facts: Encodable { let recording: String?, interval: String?, index: Int, frame: PlayerFeatures.Frame, interval_stats: PlayerFeaturesSummary.Stats, options: [String: Bool] }
        let o = options
        let facts = Facts(recording: recordingId, interval: intervalName, index: index, frame: frame, interval_stats: stats,
                          options: ["boxes": o.boxes, "labels": o.labels, "skeletons": o.skeletons, "unmatchedPoses": o.unmatchedPoses,
                                    "net": o.net, "lane": o.lane, "tentative": o.tentative, "outOfCourt": o.outOfCourt, "header": o.header,
                                    "court": o.court])
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: png)
            try RallyClassifierExporter.encode(facts, pretty: true).write(to: dir.appendingPathComponent("\(safe)-facts.json"))
            status = "Saved \(png.lastPathComponent)"
            return png
        } catch {
            status = "Snapshot failed: \(error.localizedDescription)"
            return nil
        }
    }
}
