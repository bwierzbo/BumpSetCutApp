//
//  LabelQueue.swift
//  RallyLab (macOS and iPhone)
//
//  What to label next, the same on the Mac and the phone. Marking leads:
//  every video not marked all the way through is a job, the ones started
//  and left first, then round-robin over the surfaces (the one with the
//  fewest marked videos first) so the decision model's labels stay mixed.
//  Between them, rallies to track from the videos the plan wants frames
//  from (one each, so they spread over many videos).
//

import Foundation

enum LabelQueue {

    enum Job: Hashable {
        /// Track this rally of the named video.
        case track(String, LabelRally)
        /// Mark every rally in the named video.
        case review(String)

        var video: String {
            switch self { case .track(let v, _), .review(let v): return v }
        }
    }

    /// A video as the queue sees it.
    struct Video {
        let plan: PlanVideo
        /// The next rally to track in it, if any.
        let nextRally: LabelRally?
        /// Rallies RallyLab found in it.
        let found: Int
        /// Rallies marked in it so far.
        let marked: Int
        /// Every rally in it is marked.
        let complete: Bool
    }

    /// Track jobs between marking jobs.
    static let tracksPerReview = 3

    static func jobs(_ videos: [Video], round: TrainingPlan.Round?) -> [Job] {
        let progress = PlanProgress(videos: videos.map(\.plan), round: round)
        let byName = Dictionary(videos.map { ($0.plan.name, $0) }) { a, _ in a }
        var track: [Job] = progress.queue.compactMap { p in
            byName[p.name]?.nextRally.map { .track(p.name, $0) }
        }
        var review = markingJobs(videos)
        var out: [Job] = []
        while !track.isEmpty || !review.isEmpty {
            if !review.isEmpty { out.append(review.removeFirst()) }
            out += track.prefix(tracksPerReview)
            track.removeFirst(min(tracksPerReview, track.count))
        }
        return out
    }

    /// Every available video not marked through: started ones first, then
    /// one surface at a time, the surface with the fewest marked videos
    /// leading, within a surface the most found rallies first.
    static func markingJobs(_ videos: [Video]) -> [Job] {
        let open = videos.filter { $0.plan.available && !$0.complete }
        let started = open.filter { $0.marked > 0 }.sorted { ($0.marked, $0.found) > ($1.marked, $1.found) }
        var fresh: [String: [Video]] = [:]
        for v in open where v.marked == 0 { fresh[v.plan.surface, default: []].append(v) }
        for k in fresh.keys { fresh[k]!.sort { $0.found > $1.found } }
        var done = Dictionary(grouping: videos.filter(\.complete), by: \.plan.surface).mapValues(\.count)
        var ordered: [Video] = []
        while fresh.values.contains(where: { !$0.isEmpty }) {
            // The surface with the fewest marked videos, ties by name.
            let surface = fresh.filter { !$0.value.isEmpty }.keys.min { (done[$0, default: 0], $0) < (done[$1, default: 0], $1) }!
            ordered.append(fresh[surface]!.removeFirst())
            done[surface, default: 0] += 1
        }
        return (started + ordered).map { .review($0.plan.name) }
    }
}
