//
//  TrainingPlan.swift
//  RallyLab (macOS and iPhone)
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
    /// A video has given enough at about this many labeled frames (~20 s of
    /// rally, usually 3 rallies): the queue moves on to other videos.
    static let enoughFramesPerVideo = 600

    /// A video's rally times are marked through (for scoring rally cutting)
    /// in about this many videos per surface per round.
    static func rallyTimeVideosPerSurface(_ round: Round) -> Int {
        (round.rallyTimeVideos + surfaces.count - 1) / surfaces.count
    }
    /// Frames a tracked rally gives before any are tracked (about 6–7 s).
    static let defaultFramesPerRally = 200
}

/// What a round trained, as kept in training_plan.json.
struct TrainedRound: Codable, Identifiable, Hashable {
    struct RunState: Codable, Hashable {
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

/// One video as the plan sees it — from a RallyLab session on the Mac, or a
/// synced video on the iPhone.
struct PlanVideo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    /// "Indoor", "Grass" or "Beach".
    let surface: String
    let split: String
    /// Its footage can be tracked here (on the Mac: the video is on disk).
    let available: Bool
    let doneTracks: Int
    /// Labeled frames of its done tracked rallies.
    let labeledFrames: Int
    /// Rallies found or marked in it that aren't tracked yet.
    let openRallies: Int
    let ralliesMarked: Bool
}

/// Where the tracked frames stand against a round.
struct PlanProgress {

    struct Surface {
        var trainFrames = 0, valFrames = 0
        var frames: Int { trainFrames + valFrames }
        var rallyTimeVideos = 0
    }

    var surfaces: [String: Surface] = [:]
    var rallies = 0
    /// Videos to track a rally in next, one rally each.
    var queue: [PlanVideo] = []

    var frames: Int { surfaces.values.reduce(0) { $0 + $1.frames } }
    var rallyTimeVideos: Int { surfaces.values.reduce(0) { $0 + $1.rallyTimeVideos } }
    var framesPerRally: Int { rallies > 0 ? frames / rallies : TrainingPlan.defaultFramesPerRally }

    init(videos: [PlanVideo], round: TrainingPlan.Round?) {
        for name in TrainingPlan.surfaces { surfaces[name] = Surface() }
        for v in videos {
            guard var surface = surfaces[v.surface] else { continue }
            if v.split == "val" { surface.valFrames += v.labeledFrames } else { surface.trainFrames += v.labeledFrames }
            if v.ralliesMarked { surface.rallyTimeVideos += 1 }
            surfaces[v.surface] = surface
            rallies += v.doneTracks
        }
        if let round { queue = Self.nextVideos(videos, surfaces: surfaces, round: round, perRally: framesPerRally) }
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
    /// surface's validation share is short, and videos with rallies found
    /// before ones you'd have to search.
    private static func nextVideos(_ videos: [PlanVideo], surfaces: [String: Surface],
                                   round: TrainingPlan.Round, perRally: Int) -> [PlanVideo] {
        let candidates = videos.filter {
            TrainingPlan.surfaces.contains($0.surface) && $0.available
                && $0.doneTracks < TrainingPlan.maxRalliesPerVideo && $0.labeledFrames < TrainingPlan.enoughFramesPerVideo
        }
        var need = surfaces.mapValues { max(0, quota(round) - $0.frames) }
        var val = surfaces.mapValues(\.valFrames)
        var total = surfaces.mapValues(\.frames)
        var picked: [PlanVideo] = []
        while picked.count < 8, let (env, left) = need.max(by: { $0.value < $1.value }), left > 0 {
            let wantVal = Double(val[env] ?? 0) < TrainingPlan.valShare * Double(max(total[env] ?? 0, perRally))
            let pool = candidates.filter { c in c.surface == env && !picked.contains(c) }
            guard let next = pool.min(by: { a, b in
                func key(_ v: PlanVideo) -> (Int, Int, Int) {
                    ((v.split == "val") == wantVal ? 0 : 1, v.doneTracks, v.openRallies > 0 ? 0 : 1)
                }
                return key(a) < key(b)
            }) else {
                need[env] = 0   // nothing left to track on this surface
                continue
            }
            picked.append(next)
            need[env] = left - perRally
            total[env, default: 0] += perRally
            if next.split == "val" { val[env, default: 0] += perRally }
        }
        return picked
    }
}
