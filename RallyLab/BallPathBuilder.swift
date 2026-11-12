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
//  A job belongs to the opening of the project it was queued under
//  (`ProjectsModel.Opening`: one generation per open, so the same folder
//  opened again is another opening), from the queue to its file: its footage
//  and output path, the reservations it is checked against, the ledger its
//  run goes on, and its failed/refused state are all that opening's — two
//  projects can hold a recording of the same name, and the open project can
//  change while a job waits or runs. Policy on a switch, close or reopen: a
//  job not yet started for an opening that has ended is dropped the moment
//  it ends (nothing was started for it, nothing recorded; it runs again only
//  if queued afresh under the new opening — also after A → B → A); the job
//  already running finishes and saves into its own dataset's folder — its
//  own footage's sightings, whose exposure its own ledger recorded when the
//  run started — and nothing of it is ever read as, or written into, the
//  project open by then.
//

import Foundation
import Observation

@MainActor
@Observable
final class BallPathBuilder {

    /// One video, under the opening it was queued under.
    struct Job: Hashable, Sendable {
        let opening: ProjectsModel.Opening
        let name: String
        var root: URL { opening.root }
    }

    private struct Queued {
        let job: Job
        let session: VideoSession
    }

    /// The run over one video: the footage to play, its session, a progress sink (0–1), and the sightings back.
    /// The app's pipeline in RallyLab; a test's stand-in decides when the run ends.
    typealias Runner = @MainActor (_ playback: URL, _ session: VideoSession, _ progress: @escaping @MainActor (Double) -> Void) async throws -> [BallPath.Sample]

    private let sampler: SamplerModel
    private let projects: ProjectsModel
    private let runner: Runner
    /// The open dataset, for the views' reads of the open project's files.
    private var datasetRoot: URL { sampler.datasetRoot }
    /// The video being run, and how far through it the pipeline is.
    private(set) var building: Job?
    private(set) var fraction = 0.0
    /// Bumps when a path is finished, so an open marking screen picks it up.
    private(set) var finished = 0
    private var waiting: [Queued] = []
    private var failed: Set<Job> = []
    /// Videos the pipeline was not run over, and why (reserved as final_test, or the ledger refused).
    private var refused: [Job: String] = [:]
    private var running = false

    init(sampler: SamplerModel, projects: ProjectsModel, runner: @escaping Runner = BallPathBuilder.pipeline) {
        self.sampler = sampler
        self.projects = projects
        self.runner = runner
        // Its opening over: every job still waiting under it is dropped now (the running one finishes, see above).
        projects.onOpeningEnded { [weak self] ended in self?.waiting.removeAll { $0.job.opening == ended } }
    }

    static func url(for name: String, in datasetRoot: URL) -> URL {
        datasetRoot.appendingPathComponent("ballpaths", isDirectory: true).appendingPathComponent(name + ".ballpath.json")
    }

    func url(for session: VideoSession) -> URL { Self.url(for: session.name, in: datasetRoot) }

    /// The video's sightings, when they've been made.
    func samples(for session: VideoSession) -> [BallPath.Sample]? {
        BallPathFile.load(url(for: session))?.samples
    }

    /// Whether this video of the open project is the one being run now.
    func isBuilding(_ session: VideoSession) -> Bool { building != nil && building == projects.opening.map { Job(opening: $0, name: session.name) } }

    /// Why this video of the open project got no ball path, if it was refused under this opening.
    func refusal(for session: VideoSession) -> String? { projects.opening.flatMap { refused[Job(opening: $0, name: session.name)] } }

    /// Make the paths these videos of the open project don't have yet, in this
    /// order — the first ahead of anything already waiting. Nothing without an open project.
    func ensure(_ sessions: [VideoSession]) {
        guard let opening = projects.opening else { return }
        let root = opening.root
        // Queued under an opening that has ended: dropped, never started (see the policy above).
        waiting.removeAll { $0.job.opening != opening }
        let wanted = sessions.map { Queued(job: Job(opening: opening, name: $0.name), session: $0) }.filter { q in
            !FileManager.default.fileExists(atPath: Self.url(for: q.job.name, in: root).path) && !failed.contains(q.job)
                && q.session.playbackURL(in: root) != nil
        }
        guard !wanted.isEmpty else { return }
        waiting.removeAll { w in wanted.contains { $0.job == w.job } }
        waiting = wanted + waiting
        if !running { Task { await run() } }
    }

    /// Why `name` may not get a ball path, or nil once its run is admitted and on the ledger.
    /// Running the pipeline over a video is exposure (D-002): a reserved recording is refused, and
    /// the run is recorded before it starts; a ledger that cannot be read or written refuses too.
    nonisolated static func admission(of name: String, in datasetRoot: URL) -> String? {
        do {
            try ScoringExposure.admit([name], kind: .ballPath, ref: "BallPathBuilder", note: "ball path for marking (Label / Live-tag)", root: datasetRoot)
            return nil
        } catch is ScoringExposure.Reserved {
            return "\(name) is reserved as final_test (D-002) — the pipeline is not run over it, so presses don't snap."
        } catch {
            return "\(name): \(error.localizedDescription)"
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        while !waiting.isEmpty {
            let queued = waiting.removeFirst()
            let job = queued.job, root = job.root
            // Everything of this job is its own opening's: the footage, the reservations, the ledger, the file
            // (all under `root`). Not started once that opening has ended — not even with the same folder open again.
            guard job.opening == projects.opening else { continue }
            let out = Self.url(for: job.name, in: root)
            guard !FileManager.default.fileExists(atPath: out.path),
                  let playback = queued.session.playbackURL(in: root) else { continue }
            if let why = Self.admission(of: job.name, in: root) {
                refused[job] = why
                failed.insert(job)
                continue
            }
            building = job
            fraction = 0
            var ok = true
            var samples: [BallPath.Sample] = []
            do {
                samples = try await runner(playback, queued.session) { [weak self] p in self?.fraction = p }
            } catch {
                ok = false
            }
            if ok {
                do {
                    try BallPathFile(samples: samples).save(to: out)
                    finished += 1
                } catch {
                    ok = false
                }
            }
            if !ok { failed.insert(job) }
            building = nil
        }
    }

    /// The app's pipeline over the whole video, with the frame evidence kept.
    static func pipeline(_ playback: URL, _ session: VideoSession, progress: @escaping @MainActor (Double) -> Void) async throws -> [BallPath.Sample] {
        let processor = VideoProcessor()
        processor.config = ProcessorConfig().withCamera(of: session)
        processor.collectFrameEvidence = true
        let watch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                progress(processor.progress)
            }
        }
        defer { watch.cancel() }
        do {
            _ = try await processor.analyzeVideo(playback)
        } catch ProcessingError.noRalliesDetected {
            // Still saw the ball, most likely — the sightings are what we want.
        }
        return samples(from: processor.frameEvidence)
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
