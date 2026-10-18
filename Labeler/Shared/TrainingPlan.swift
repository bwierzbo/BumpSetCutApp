//
//  TrainingPlan.swift
//  RallyLab (macOS and iPhone)
//
//  The road from a few tracked rallies to the app's own multi-frame ball
//  model, in rounds: label rallies spread over indoor, grass and beach and
//  over many videos and cameras, then export and train on the desktop.
//  Rounds 1–2 fine-tuned VballNet's weights; from round 3 every model is
//  trained from scratch, grey against colour and 512 against 768 and 1024.
//  A round's frames are what training gets: every labeled frame of a
//  rally you finished, or of one the model pre-tracked that nobody said
//  isn't a rally — in a val video, only the frames a person checked, so
//  the score is people's labels only. What
//  each round trained (package, desktop runs, the frames it had) is kept in
//  the dataset's training_plan.json, so the timeline survives restarts and
//  training carries on where it stopped.
//

import Foundation

enum TrainingPlan {

    /// One model to train in a round.
    struct Run: Codable, Hashable {
        let size: Int
        let fromScratch: Bool
        /// R, G and B planes in, rather than grey.
        var color = false
        /// The model's own sure frames of pre-tracked rallies train too, at half weight.
        var pseudo = false

        init(size: Int, fromScratch: Bool, color: Bool = false, pseudo: Bool = false) {
            self.size = size
            self.fromScratch = fromScratch
            self.color = color
            self.pseudo = pseudo
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            size = try c.decode(Int.self, forKey: .size)
            fromScratch = try c.decode(Bool.self, forKey: .fromScratch)
            color = try c.decodeIfPresent(Bool.self, forKey: .color) ?? false
            pseudo = try c.decodeIfPresent(Bool.self, forKey: .pseudo) ?? false
        }

        var title: String {
            "\(fromScratch ? "From scratch" : "Fine-tune") · \(size) \(color ? "colour" : "grey")\(pseudo ? " + model's labels" : "")"
        }
    }

    struct Round {
        let number: Int
        /// Labeled frames of tracked rallies the round wants, all surfaces together.
        let frames: Int
        /// Videos with every rally's time marked: what rally cutting is scored on.
        let rallyTimeVideos: Int
        /// Val videos with a tracked rally, per surface: what a surface's ball
        /// score comes from. With one, a score is one video's.
        let valVideos: Int
        let runs: [Run]
        let why: String
    }

    static let rounds: [Round] = [
        Round(number: 1, frames: 6_000, rallyTimeVideos: 6, valVideos: 1, runs: [Run(size: 512, fromScratch: false)],
              why: "The first balanced set: every surface in, fine-tuned from VballNet's weights."),
        Round(number: 2, frames: 35_000, rallyTimeVideos: 8, valVideos: 1,
              runs: [Run(size: 512, fromScratch: false, color: true), Run(size: 512, fromScratch: false, color: true, pseudo: true)],
              why: "Colour, with and without the model's own sure frames as labels: people's labels only did better."),
        Round(number: 3, frames: 40_000, rallyTimeVideos: 10, valVideos: 1,
              runs: [Run(size: 512, fromScratch: true), Run(size: 512, fromScratch: true, color: true),
                     Run(size: 768, fromScratch: true), Run(size: 768, fromScratch: true, color: true)],
              why: "The first from-scratch models: grey against colour, 512 against 768."),
        Round(number: 4, frames: 50_000, rallyTimeVideos: 10, valVideos: 1,
              runs: [Run(size: 1024, fromScratch: true), Run(size: 768, fromScratch: true),
                     Run(size: 1024, fromScratch: true, color: true), Run(size: 768, fromScratch: true, color: true)],
              why: "Your corrected labels, and the largest size: does 1024 find more far balls?"),
        Round(number: 5, frames: 75_000, rallyTimeVideos: 20, valVideos: 4,
              runs: [Run(size: 512, fromScratch: true), Run(size: 768, fromScratch: true), Run(size: 768, fromScratch: true, color: true)],
              why: "Indoor up to a quarter of the frames, and 4 test videos per surface with tracked rallies so models can be told apart. The winner ships."),
        Round(number: 6, frames: 100_000, rallyTimeVideos: 30, valVideos: 6,
              runs: [Run(size: 768, fromScratch: true), Run(size: 768, fromScratch: true, color: true)],
              why: "The full set: the better of grey and colour becomes the app's ball finder."),
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

    /// Frames a tracked rally gives before any are tracked (about 6–7 s).
    static let defaultFramesPerRally = 200

    /// Of a rally's labeled frames, the ones that are labels: in a val video
    /// only those a person checked (the score is people's labels only, never
    /// the model's own), in a train video all of them.
    static func labels(labeled: Int, checked: Int, split: String) -> Int {
        split == "val" ? checked : labeled
    }
}

/// What a clip ID says about its video. The clip plan names videos
/// surface_camera_light_orientation_source_NN (`ind_ele_dim_land_self_02`);
/// tester footage is surface_extra_tester_NN.
struct VideoType: Hashable {
    enum Facet: String, CaseIterable, Identifiable {
        case camera = "Camera", light = "Light", orientation = "Orientation"
        var id: String { rawValue }
    }

    let camera: String
    let light: String
    let orientation: String

    init(clipID: String) {
        let parts = clipID.lowercased().split(separator: "_").map(String.init)
        let part = { (i: Int) in parts.indices.contains(i) ? parts[i] : "" }
        camera = Self.cameras[part(1)] ?? "Other"
        let tester = part(1) == "extra"
        light = tester ? "Not named" : Self.lights[part(2)] ?? "Other"
        orientation = tester ? "Not named" : Self.orientations[part(3)] ?? "Other"
    }

    func value(_ facet: Facet) -> String {
        switch facet {
        case .camera: return camera
        case .light: return light
        case .orientation: return orientation
        }
    }

    private static let cameras = ["ele": "End line, raised", "gnd": "End line, ground", "sid": "Sideline",
                                  "tri": "Corner, tripod", "hnd": "Handheld", "onl": "Online video", "extra": "Tester footage"]
    private static let lights = ["sun": "Sun", "ovc": "Overcast", "shade": "Shade", "dusk": "Dusk", "bright": "Bright", "dim": "Dim"]
    private static let orientations = ["land": "Landscape", "port": "Portrait"]
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
    /// Rallies in the package (TrackedRally.isReady): finished, or pre-tracked and not said not to be one.
    let rallies: Int
    /// Their frames that are labels (TrainingPlan.labels): what training, or in val the score, gets.
    let labeledFrames: Int
    /// Of those, the frames checked in review (or marked hidden) by a person.
    let checkedFrames: Int
    /// Rallies found or marked in it that aren't tracked yet.
    let openRallies: Int
    let ralliesMarked: Bool

    var type: VideoType { VideoType(clipID: name) }
}

/// Where the tracked frames stand against a round.
struct PlanProgress {

    struct Surface {
        var trainFrames = 0, valFrames = 0
        var frames: Int { trainFrames + valFrames }
        var rallyTimeVideos = 0
        /// Val videos with a rally that counts.
        var valVideos = 0
    }

    /// Videos, rallies and frames of one kind of video.
    struct Bucket {
        var videos = 0, rallies = 0, frames = 0, checkedFrames = 0, valFrames = 0
    }

    var surfaces: [String: Surface] = [:]
    var rallies = 0
    var checkedFrames = 0
    let videos: [PlanVideo]
    /// Videos to track a rally in next, one rally each.
    var queue: [PlanVideo] = []

    var frames: Int { surfaces.values.reduce(0) { $0 + $1.frames } }
    var rallyTimeVideos: Int { surfaces.values.reduce(0) { $0 + $1.rallyTimeVideos } }
    var framesPerRally: Int { rallies > 0 ? frames / rallies : TrainingPlan.defaultFramesPerRally }

    init(videos: [PlanVideo], round: TrainingPlan.Round?) {
        self.videos = videos
        for name in TrainingPlan.surfaces { surfaces[name] = Surface() }
        for v in videos {
            guard var surface = surfaces[v.surface] else { continue }
            if v.split == "val" { surface.valFrames += v.labeledFrames } else { surface.trainFrames += v.labeledFrames }
            if v.split == "val" && v.rallies > 0 { surface.valVideos += 1 }
            if v.ralliesMarked { surface.rallyTimeVideos += 1 }
            surfaces[v.surface] = surface
            rallies += v.rallies
            checkedFrames += v.checkedFrames
        }
        if let round { queue = Self.nextVideos(videos, surfaces: surfaces, round: round, perRally: framesPerRally) }
    }

    /// Per surface, the videos of each kind (`facet`) — every video, even one
    /// with nothing tracked yet — with their rallies and frames, most frames first.
    func breakdown(by facet: VideoType.Facet) -> [(surface: String, total: Bucket, rows: [(kind: String, bucket: Bucket)])] {
        TrainingPlan.surfaces.map { surface in
            var kinds: [String: Bucket] = [:]
            for v in videos where v.surface == surface {
                var b = kinds[v.type.value(facet)] ?? Bucket()
                b.videos += 1
                b.rallies += v.rallies
                b.frames += v.labeledFrames
                b.checkedFrames += v.checkedFrames
                if v.split == "val" { b.valFrames += v.labeledFrames }
                kinds[v.type.value(facet)] = b
            }
            let rows = kinds.map { (kind: $0.key, bucket: $0.value) }
                .sorted { ($0.bucket.frames, $1.kind) > ($1.bucket.frames, $0.kind) }
            let total = rows.reduce(into: Bucket()) { t, r in
                t.videos += r.bucket.videos; t.rallies += r.bucket.rallies; t.frames += r.bucket.frames
                t.checkedFrames += r.bucket.checkedFrames; t.valFrames += r.bucket.valFrames
            }
            return (surface, total, rows)
        }
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
            if s.valVideos < round.valVideos {
                out.append("\(name) has \(s.valVideos) val video\(s.valVideos == 1 ? "" : "s") with a tracked rally — it needs \(round.valVideos) so its score isn't one video's.")
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
                && $0.rallies < TrainingPlan.maxRalliesPerVideo && $0.labeledFrames < TrainingPlan.enoughFramesPerVideo
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
                    ((v.split == "val") == wantVal ? 0 : 1, v.rallies, v.openRallies > 0 ? 0 : 1)
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
