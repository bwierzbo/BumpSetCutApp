//
//  TrainingPlanModel.swift
//  RallyLab
//
//  Runs the training plan (Labeler/Shared/TrainingPlan.swift) on the Mac:
//  export and train a round on the desktop, carry on with a stopped one,
//  and keep what was trained in the dataset's training_plan.json.
//

import Foundation
import Observation

extension PlanVideo {
    /// A RallyLab session as the plan sees it.
    @MainActor
    init(session s: VideoSession) {
        let tracks = s.tracks ?? []
        let done = tracks.filter(\.done)
        self.init(name: s.name, surface: Coverage.environment(s.name), split: s.split,
                  available: FileManager.default.fileExists(atPath: s.sourcePath),
                  doneTracks: done.count, labeledFrames: done.reduce(0) { $0 + $1.labeledFrames },
                  openRallies: TrackLabelModel.suggestions(from: s, excluding: tracks).count,
                  ralliesMarked: s.ralliesMarked ?? false)
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
