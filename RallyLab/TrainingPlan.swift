//
//  TrainingPlan.swift
//  RallyLab
//
//  The road from a few tracked rallies to a multi-frame ball model trained
//  from scratch, in rounds: track a few thousand frames spread evenly over
//  indoor, grass and beach and over many videos, then export and train —
//  fine-tuned and from scratch side by side, so each round is a point on
//  the curve of how much data from-scratch training needs, and later 768
//  against 512. What each round trained (package, desktop runs, the frames
//  it had) is kept in the dataset's training_plan.json, so the timeline
//  survives restarts and training carries on where it stopped.
//

import Foundation
import Observation

enum TrainingPlan {

    /// One model to train in a round.
    struct Run: Codable, Hashable {
        let size: Int
        let fromScratch: Bool

        var title: String { "\(fromScratch ? "From scratch" : "Fine-tune") · \(size)" }
    }

    struct Round {
        let number: Int
        /// Labeled frames of tracked rallies the round wants, all surfaces together.
        let frames: Int
        /// Videos with every rally's time marked: what rally cutting is scored on.
        let rallyTimeVideos: Int
        let runs: [Run]
        let why: String
    }

    static let rounds: [Round] = [
        Round(number: 1, frames: 6_000, rallyTimeVideos: 6, runs: [Run(size: 512, fromScratch: false)],
              why: "The first balanced set: every surface in, fine-tuned like today's model."),
        Round(number: 2, frames: 10_000, rallyTimeVideos: 10,
              runs: [Run(size: 512, fromScratch: false), Run(size: 512, fromScratch: true)],
              why: "The first from-scratch model, next to a fine-tune on the same frames."),
        Round(number: 3, frames: 15_000, rallyTimeVideos: 15,
              runs: [Run(size: 512, fromScratch: false), Run(size: 512, fromScratch: true)],
              why: "Another point on the curve: how fast from scratch catches up."),
        Round(number: 4, frames: 20_000, rallyTimeVideos: 20,
              runs: [Run(size: 512, fromScratch: true), Run(size: 768, fromScratch: true), Run(size: 512, fromScratch: false)],
              why: "The original model's amount of data. From scratch at 512 and 768: does 768 find more far balls?"),
        Round(number: 5, frames: 30_000, rallyTimeVideos: 30,
              runs: [Run(size: 512, fromScratch: true), Run(size: 768, fromScratch: true)],
              why: "Past the original model's data: from scratch only."),
        Round(number: 6, frames: 40_000, rallyTimeVideos: 40,
              runs: [Run(size: 512, fromScratch: true), Run(size: 768, fromScratch: true)],
              why: "The full set. The better size becomes the app's ball finder."),
    ]

    static let surfaces = ["Indoor", "Grass", "Beach"]
    /// A round needs each surface to have at least this share of its frames.
    static let minShare = 0.25
    /// Of each surface's frames, about this share should be validation.
    static let valShare = 0.2
    /// More rallies than this from one video mostly repeat its court and camera.
    static let maxRalliesPerVideo = 5
    /// Frames a tracked rally gives before any are tracked (about 6–7 s).
    static let defaultFramesPerRally = 200
}

/// What a round trained, as kept in training_plan.json.
struct TrainedRound: Codable, Identifiable {
    struct RunState: Codable {
        let run: TrainingPlan.Run
        /// The desktop run's name once it's started.
        var name: String?
        var broughtBack = false
    }

    var id: Int { round }
    let round: Int
    let date: Date
    /// The multi-frame package's folder name.
    let package: String
    /// Labeled frames per surface when the package was exported.
    let frames: [String: Int]
    var runs: [RunState]

    var finished: Bool { runs.allSatisfy(\.broughtBack) }
}

/// Where the tracked frames stand against a round, from the sessions.
@MainActor
struct PlanProgress {

    struct Surface {
        var trainFrames = 0, valFrames = 0
        var frames: Int { trainFrames + valFrames }
        var rallyTimeVideos = 0
    }

    /// A video worth tracking a rally in next.
    struct NextVideo: Identifiable {
        var id: String { session.name }
        let session: VideoSession
        let surface: String
        let done: Int
        /// Rallies the Sampler found that aren't tracked yet.
        let found: Int
    }

    var surfaces: [String: Surface] = [:]
    var rallies = 0
    var queue: [NextVideo] = []

    var frames: Int { surfaces.values.reduce(0) { $0 + $1.frames } }
    var rallyTimeVideos: Int { surfaces.values.reduce(0) { $0 + $1.rallyTimeVideos } }
    var framesPerRally: Int { rallies > 0 ? frames / rallies : TrainingPlan.defaultFramesPerRally }

    init(sessions: [VideoSession], round: TrainingPlan.Round?) {
        for name in TrainingPlan.surfaces { surfaces[name] = Surface() }
        for s in sessions {
            let env = Coverage.environment(s.name)
            guard var surface = surfaces[env] else { continue }
            let done = (s.tracks ?? []).filter(\.done)
            let labeled = done.reduce(0) { $0 + $1.labeledFrames }
            if s.split == "val" { surface.valFrames += labeled } else { surface.trainFrames += labeled }
            if s.ralliesMarked ?? false { surface.rallyTimeVideos += 1 }
            surfaces[env] = surface
            rallies += done.count
        }
        if let round { queue = Self.nextVideos(sessions: sessions, surfaces: surfaces, round: round, perRally: framesPerRally) }
    }

    /// Frames each surface should reach in `round`: an even third.
    static func quota(_ round: TrainingPlan.Round) -> Int { round.frames / TrainingPlan.surfaces.count }

    /// What stops `round` from being trained, most important first.
    func blockers(_ round: TrainingPlan.Round) -> [String] {
        var out: [String] = []
        if frames < round.frames {
            out.append("\((round.frames - frames).formatted()) more frames (about \((round.frames - frames + framesPerRally - 1) / framesPerRally) rallies).")
        }
        let floor = Int(Double(round.frames) * TrainingPlan.minShare)
        for name in TrainingPlan.surfaces {
            let s = surfaces[name] ?? Surface()
            if s.frames < floor {
                out.append("\(name) has \(s.frames.formatted()) frames — every surface needs \(floor.formatted()) (a quarter) so the model isn't tuned to one.")
            }
            if s.valFrames == 0 {
                out.append("\(name) has no validation rallies — track one in a val video so its score means something.")
            }
        }
        return out
    }

    /// Up to 8 videos to track next, one rally each: the surface furthest
    /// behind its share first, then within it the video with the fewest
    /// tracked rallies (spread over many videos), a val video when the
    /// surface's validation share is short, and videos where the Sampler
    /// already found rallies before ones you'd have to search.
    private static func nextVideos(sessions: [VideoSession], surfaces: [String: Surface],
                              round: TrainingPlan.Round, perRally: Int) -> [NextVideo] {
        let fm = FileManager.default
        let candidates: [NextVideo] = sessions.compactMap { s in
            let env = Coverage.environment(s.name)
            guard TrainingPlan.surfaces.contains(env), fm.fileExists(atPath: s.sourcePath) else { return nil }
            let tracks = s.tracks ?? []
            let done = tracks.filter(\.done).count
            guard done < TrainingPlan.maxRalliesPerVideo else { return nil }
            return NextVideo(session: s, surface: env, done: done,
                             found: TrackLabelModel.suggestions(from: s, excluding: tracks).count)
        }
        var need = surfaces.mapValues { max(0, quota(round) - $0.frames) }
        var val = surfaces.mapValues(\.valFrames)
        var total = surfaces.mapValues(\.frames)
        var picked: [NextVideo] = []
        while picked.count < 8, let (env, left) = need.max(by: { $0.value < $1.value }), left > 0 {
            let wantVal = Double(val[env] ?? 0) < TrainingPlan.valShare * Double(max(total[env] ?? 0, perRally))
            let pool = candidates.filter { c in c.surface == env && !picked.contains { $0.id == c.id } }
            guard let next = pool.min(by: { a, b in
                func key(_ v: NextVideo) -> (Int, Int, Int) {
                    ((v.session.split == "val") == wantVal ? 0 : 1, v.done, v.found > 0 ? 0 : 1)
                }
                return key(a) < key(b)
            }) else {
                need[env] = 0   // nothing left to track on this surface
                continue
            }
            picked.append(next)
            need[env] = left - perRally
            total[env, default: 0] += perRally
            if next.session.split == "val" { val[env, default: 0] += perRally }
        }
        return picked
    }
}

/// Runs the plan: export and train a round, carry on with a round that
/// was stopped, and keep what was trained.
@MainActor
@Observable
final class TrainingPlanModel {

    let library: ModelLibrary
    private(set) var history: [TrainedRound] = []
    private(set) var isRunning = false
    private(set) var status = ""

    init(library: ModelLibrary) {
        self.library = library
    }

    private var lab: HeatmapLab { library.heatmaps }
    private var file: URL { library.sampler.datasetRoot.appendingPathComponent("training_plan.json") }

    func reload() {
        history = (try? Data(contentsOf: file))
            .flatMap { try? Self.decoder.decode([TrainedRound].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? Self.encoder.encode(history) { try? data.write(to: file, options: .atomic) }
    }

    /// The first round not trained yet; nil once every round has been.
    var currentRound: TrainingPlan.Round? {
        TrainingPlan.rounds.first { r in !history.contains { $0.round == r.number } }
    }

    /// A round whose runs didn't all come back (RallyLab closed, or a run stopped).
    var unfinished: TrainedRound? { history.first { !$0.finished } }

    func scores(_ name: String) -> RunScores? { lab.runScores(name) }

    /// Package every tracked rally and reviewed frame, then train the
    /// round's runs on the desktop one after another, bringing each back.
    func exportAndTrain(_ round: TrainingPlan.Round, progress: PlanProgress) {
        guard !isRunning, !library.isBusy, !lab.desktopBusy else { return }
        isRunning = true
        let before = library.lastMultiFramePackage?.zip
        library.exportMultiFramePackage()
        Task {
            defer { isRunning = false }
            status = "Exporting the multi-frame package…"
            while library.isBusy { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard let zip = library.lastMultiFramePackage?.zip, zip != before else {
                status = "The export didn't finish: \(library.status)"
                return
            }
            lab.reload()
            let record = TrainedRound(round: round.number, date: Date(),
                                      package: zip.deletingPathExtension().lastPathComponent,
                                      frames: progress.surfaces.mapValues(\.frames),
                                      runs: round.runs.map { TrainedRound.RunState(run: $0) })
            history.append(record)
            save()
            await train(round: round.number)
        }
    }

    /// Start or follow whatever of a round's runs isn't back yet.
    func resume(_ record: TrainedRound) {
        guard !isRunning, !lab.desktopBusy else { return }
        isRunning = true
        Task {
            defer { isRunning = false }
            await train(round: record.round)
        }
    }

    private func train(round number: Int) async {
        lab.desktopBusy = true
        defer { lab.desktopBusy = false }
        let package = library.sampler.datasetRoot.appendingPathComponent("exports", isDirectory: true)
        while let i = history.firstIndex(where: { $0.round == number }),
              let k = history[i].runs.firstIndex(where: { !$0.broughtBack }) {
            let state = history[i].runs[k]
            status = "Round \(number): \(state.run.title) (\(k + 1) of \(history[i].runs.count))"
            let name: String
            if let started = state.name {
                name = started
            } else {
                guard let started = await lab.startDesktopRun(package: package.appendingPathComponent(history[i].package),
                                                              size: state.run.size, fromScratch: state.run.fromScratch) else {
                    status = "Round \(number) stopped: \(lab.desktopLine)"
                    return
                }
                history[i].runs[k].name = started
                save()
                name = started
            }
            guard await lab.followDesktopRun(name) else {
                status = "Round \(number) stopped at \(name): \(lab.desktopLine)"
                return
            }
            history[i].runs[k].broughtBack = true
            save()
        }
        status = "Round \(number) is trained — scores below."
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
