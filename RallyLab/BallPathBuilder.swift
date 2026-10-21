//
//  BallPathBuilder.swift
//  RallyLab
//
//  Runs the app's pipeline over a whole video once, in the background, and
//  keeps where it saw the ball (BallPathFile, under the dataset's
//  ballpaths/) so marking the rallies snaps presses to the ball changing
//  course anywhere in the video. Works from the review copy when the
//  footage has moved to the desktop. One video at a time: the one being
//  marked first, then the next marking jobs, so they're ready in turn.
//

import Foundation
import Observation

@MainActor
@Observable
final class BallPathBuilder {

    private let sampler: SamplerModel
    private var datasetRoot: URL { sampler.datasetRoot }
    /// The video being run, and how far through it the pipeline is.
    private(set) var building: String?
    private(set) var fraction = 0.0
    /// Bumps when a path is finished, so an open marking screen picks it up.
    private(set) var finished = 0
    private var waiting: [VideoSession] = []
    private var failed: Set<String> = []
    /// Videos the pipeline was not run over, and why (reserved as final_test, or the ledger refused).
    private(set) var refused: [String: String] = [:]
    private var running = false

    init(sampler: SamplerModel) {
        self.sampler = sampler
    }

    static func url(for name: String, in datasetRoot: URL) -> URL {
        datasetRoot.appendingPathComponent("ballpaths", isDirectory: true).appendingPathComponent(name + ".ballpath.json")
    }

    func url(for session: VideoSession) -> URL { Self.url(for: session.name, in: datasetRoot) }

    /// The video's sightings, when they've been made.
    func samples(for session: VideoSession) -> [BallPath.Sample]? {
        BallPathFile.load(url(for: session))?.samples
    }

    /// Make the paths these videos don't have yet, in this order — the first
    /// ahead of anything already waiting.
    func ensure(_ sessions: [VideoSession]) {
        let wanted = sessions.filter { s in
            !FileManager.default.fileExists(atPath: url(for: s).path) && !failed.contains(s.name)
                && s.playbackURL(in: datasetRoot) != nil
        }
        guard !wanted.isEmpty else { return }
        waiting.removeAll { w in wanted.contains { $0.name == w.name } }
        waiting = wanted + waiting
        if !running { Task { await run() } }
    }

    /// Why `name` may not get a ball path, or nil once its run is admitted and on the ledger.
    /// Running the pipeline over a video is exposure (D-002): a reserved recording is refused, and
    /// the run is recorded before it starts; a ledger that cannot be read or written refuses too.
    nonisolated static func admission(of name: String, in datasetRoot: URL) -> String? {
        do {
            if try PipelineTuner.ValidationSet.finalTestNames(in: datasetRoot).contains(name) {
                return "\(name) is reserved as final_test (D-002) — the pipeline is not run over it, so presses don't snap."
            }
            try ExposureLog.record(videos: [name], kind: .ballPath, ref: "BallPathBuilder",
                                   note: "ball path for marking (Label / Live-tag)", in: datasetRoot)
            return nil
        } catch {
            return "\(name): \(error.localizedDescription)"
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        while !waiting.isEmpty {
            let session = waiting.removeFirst()
            guard !FileManager.default.fileExists(atPath: url(for: session).path),
                  let playback = session.playbackURL(in: datasetRoot) else { continue }
            if let why = Self.admission(of: session.name, in: datasetRoot) {
                refused[session.name] = why
                failed.insert(session.name)
                continue
            }
            building = session.name
            fraction = 0
            let processor = VideoProcessor()
            processor.config = ProcessorConfig().withCamera(of: session)
            processor.collectFrameEvidence = true
            let watch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self?.fraction = processor.progress
                }
            }
            var ok = true
            do {
                _ = try await processor.processVideo(playback, videoId: UUID())
            } catch ProcessingError.noRalliesDetected {
                // Still saw the ball, most likely — the sightings are what we want.
            } catch {
                ok = false
            }
            watch.cancel()
            if ok {
                let file = BallPathFile(samples: Self.samples(from: processor.frameEvidence))
                do {
                    try file.save(to: url(for: session))
                    finished += 1
                } catch {
                    ok = false
                }
            }
            if !ok { failed.insert(session.name) }
            building = nil
        }
    }

    /// Where the ball was each frame: the track the pipeline followed when
    /// it had one, else its best sighting that frame (not an adjacent court's).
    static func samples(from evidence: [VideoProcessor.FrameEvidence]) -> [BallPath.Sample] {
        evidence.compactMap { e in
            if let c = e.candidates.first(where: { $0.isSelected }) {
                return BallPath.Sample(time: e.time, center: c.point, size: Double(c.ballSize))
            }
            guard let d = e.detections.filter({ !$0.isOffCourt }).max(by: { $0.confidence < $1.confidence }) else { return nil }
            return BallPath.Sample(time: e.time, center: CGPoint(x: d.bbox.midX, y: d.bbox.midY),
                                   size: Double((d.bbox.width + d.bbox.height) / 2))
        }
    }
}
