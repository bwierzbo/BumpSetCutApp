//
//  LabelQueue.swift
//  RallyLab (macOS and iPhone)
//
//  What to label next, the same on the Mac and the phone: a rally to track
//  from each video the plan wants frames from (one each, so they spread
//  over many videos; a video is enough at ~20 s of tracked rally), and every
//  few of those a video to mark all the way through — only while a surface
//  is short of those for scoring rally cutting this round.
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
        /// Every rally in it is marked.
        let complete: Bool
    }

    /// Track jobs between review jobs.
    static let tracksPerReview = 3

    static func jobs(_ videos: [Video], round: TrainingPlan.Round?) -> [Job] {
        let progress = PlanProgress(videos: videos.map(\.plan), round: round)
        let byName = Dictionary(videos.map { ($0.plan.name, $0) }) { a, _ in a }
        var track: [Job] = progress.queue.compactMap { p in
            byName[p.name]?.nextRally.map { .track(p.name, $0) }
        }
        guard let round else { return track }
        var review: [Job] = []
        let wanted = TrainingPlan.rallyTimeVideosPerSurface(round)
        for surface in TrainingPlan.surfaces {
            let mine = videos.filter { $0.plan.surface == surface && $0.plan.available }
            let have = mine.filter(\.complete).count
            let open = mine.filter { !$0.complete }.sorted { $0.found > $1.found }
            review += open.prefix(max(0, wanted - have)).map { .review($0.plan.name) }
        }
        var out: [Job] = []
        while !track.isEmpty || !review.isEmpty {
            out += track.prefix(tracksPerReview)
            track.removeFirst(min(tracksPerReview, track.count))
            if !review.isEmpty { out.append(review.removeFirst()) }
        }
        return out
    }
}
