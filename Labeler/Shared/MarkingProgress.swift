//
//  MarkingProgress.swift
//  RallyLab (macOS and iPhone)
//
//  How far marking the rallies has got — the decision model's labels —
//  over every video in the project: marked all the way through, started,
//  and left, with the footage still to watch, by surface and by kind of
//  video. The same numbers on the Mac and the phone.
//

import Foundation

struct MarkingProgress {

    /// Videos of one kind, where their marking stands.
    struct Bucket {
        var videos = 0
        /// Marked all the way through.
        var marked = 0
        /// Some rallies marked, not finished.
        var started = 0
        /// Not finished and its footage can't be played here.
        var unreachable = 0
        /// Rallies marked so far, finished videos or not.
        var rallies = 0
        /// Seconds of video in the ones not finished (nil footage not counted).
        var footageLeft: Double = 0
        var valVideos = 0, valMarked = 0

        var left: Int { videos - marked }
        var fraction: Double { videos > 0 ? Double(marked) / Double(videos) : 0 }

        mutating func add(_ v: LabelQueue.Video, footage: Double?) {
            videos += 1
            rallies += v.marked
            if v.plan.split == "val" { valVideos += 1 }
            if v.complete {
                marked += 1
                if v.plan.split == "val" { valMarked += 1 }
            } else {
                if v.marked > 0 { started += 1 }
                if !v.plan.available { unreachable += 1 }
                footageLeft += footage ?? 0
            }
        }
    }

    let total: Bucket
    /// Indoor, Grass, Beach in plan order, then any other surface with videos.
    let surfaces: [(surface: String, bucket: Bucket)]
    private let videos: [(video: LabelQueue.Video, footage: Double?)]

    /// `footage(video)` is how long a video runs, when known — the footage
    /// still to watch is the sum over the unfinished ones.
    init(videos: [LabelQueue.Video], footage: (LabelQueue.Video) -> Double?) {
        self.videos = videos.map { ($0, footage($0)) }
        var total = Bucket()
        var bySurface: [String: Bucket] = [:]
        for (v, f) in self.videos {
            total.add(v, footage: f)
            bySurface[v.plan.surface, default: Bucket()].add(v, footage: f)
        }
        self.total = total
        let named = TrainingPlan.surfaces
        surfaces = (named + bySurface.keys.filter { !named.contains($0) }.sorted())
            .compactMap { s in bySurface[s].map { (s, $0) } }
    }

    /// Per surface, the videos of each kind (`facet`), most left first.
    func breakdown(by facet: VideoType.Facet) -> [(surface: String, total: Bucket, rows: [(kind: String, bucket: Bucket)])] {
        surfaces.map { surface, total in
            var kinds: [String: Bucket] = [:]
            for (v, f) in videos where v.plan.surface == surface {
                kinds[v.plan.type.value(facet), default: Bucket()].add(v, footage: f)
            }
            let rows = kinds.map { (kind: $0.key, bucket: $0.value) }
                .sorted { ($0.bucket.left, $1.kind) > ($1.bucket.left, $0.kind) }
            return (surface, total, rows)
        }
    }

    /// Footage as "2 h 10 min", "25 min" or "40 s".
    static func clock(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m >= 60 { return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min" }
        if m >= 1 { return "\(m) min" }
        return "\(Int(seconds.rounded())) s"
    }
}
