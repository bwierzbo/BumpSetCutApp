//
//  PlayerTracker.swift
//  RallyLab
//
//  ptrk_v1: a deliberately simple, deterministic multi-person tracker for the
//  player-feasibility research (P0). Each track keeps its last box and a
//  constant-velocity estimate of its centre; a frame's detections are matched to
//  the tracks' predicted boxes greedily by IoU (ties: lower track ID, then lower
//  detection index), within a gate. A detection nobody takes starts a tentative
//  track, confirmed after `confirmHits` observations; a track not matched for
//  `maxGapSec` ends. A detection whose second-best track overlaps it nearly as
//  well is marked ambiguous — the identity may have switched there.
//
//  It does not claim identities survive anything: `reset()` drops every track
//  and the next IDs are new (IDs are never reused within a recording), and the
//  caller resets at every segment boundary — an interval start, a time gap, a
//  cut or time-breaking span, a suspected camera cut.
//

import Foundation

struct PlayerTracker {
    struct Settings: Equatable, Sendable {
        /// A detection can join a track only when its IoU with the predicted box is at least this.
        var minIoU = 0.15
        var confirmHits = 3
        var maxGapSec = 1.0
        /// Ambiguous when the runner-up track's IoU is at least this share of the winner's (and ≥ minIoU).
        var ambiguityRatio = 0.7
        /// Weight of the newest velocity in the running estimate.
        var velocityBlend = 0.5

        var described: [String: String] {
            ["version": PlayerFeatures.trackerVersion, "association": "greedy IoU vs constant-velocity prediction; ties by track id then detection index",
             "minIoU": "\(minIoU)", "confirmHits": "\(confirmHits)", "maxGapSec": "\(maxGapSec)",
             "ambiguityRatio": "\(ambiguityRatio)", "velocityBlend": "\(velocityBlend)",
             "resets": "every segment boundary (interval start, gap, cut / time-breaking boundary, suspected camera cut); ids never reused"]
        }
    }

    struct Track: Equatable, Sendable {
        var id: Int
        var box: PlayerFeatures.Box
        /// Centre velocity, normalised units per second.
        var vx: Double = 0
        var vy: Double = 0
        var lastTime: Double
        var hits: Int = 1
        /// Sampled frames since the last match.
        var misses: Int = 0
    }

    /// What the tracker decided for one detection.
    struct Assignment: Equatable, Sendable {
        var track: Int
        var state: PlayerFeatures.TrackState
        var hits: Int
        var gap: Int
        var ambiguous: Bool
    }

    let settings: Settings
    private(set) var tracks: [Track] = []
    private(set) var nextId: Int

    init(settings: Settings = Settings(), firstId: Int = 1) {
        self.settings = settings
        nextId = firstId
    }

    /// Forget every track; the next track gets a new ID.
    mutating func reset() { tracks.removeAll() }

    private func predicted(_ t: Track, at time: Double) -> PlayerFeatures.Box {
        let dt = max(0, time - t.lastTime)
        return PlayerFeatures.Box(x: t.box.x + t.vx * dt, y: t.box.y + t.vy * dt, w: t.box.w, h: t.box.h)
    }

    /// Match `detections` (in their order) at `time` and return one assignment per detection.
    mutating func update(_ detections: [PlayerFeatures.Box], at time: Double) -> [Assignment] {
        // Tracks that have been away too long end before matching.
        tracks.removeAll { time - $0.lastTime > settings.maxGapSec + 1e-9 }
        let predictions = tracks.map { predicted($0, at: time) }
        var pairs: [(iou: Double, t: Int, d: Int)] = []
        for (ti, p) in predictions.enumerated() {
            for (di, d) in detections.enumerated() {
                let v = p.iou(d)
                if v >= settings.minIoU { pairs.append((v, ti, di)) }
            }
        }
        pairs.sort { a, b in
            if a.iou != b.iou { return a.iou > b.iou }
            if tracks[a.t].id != tracks[b.t].id { return tracks[a.t].id < tracks[b.t].id }
            return a.d < b.d
        }
        var trackTaken = Set<Int>(), detTaken = [Int: Int]()
        for p in pairs where !trackTaken.contains(p.t) && detTaken[p.d] == nil {
            trackTaken.insert(p.t)
            detTaken[p.d] = p.t
        }

        var out: [Assignment] = []
        var matched = Set<Int>()
        for (di, d) in detections.enumerated() {
            if let ti = detTaken[di] {
                let winner = predictions[ti].iou(d)
                let runnerUp = predictions.enumerated().filter { $0.offset != ti }.map { $0.element.iou(d) }.max() ?? 0
                var t = tracks[ti]
                let gap = t.misses
                let dt = time - t.lastTime
                if dt > 0 {
                    let nvx = (d.midX - t.box.midX) / dt, nvy = ((d.y + d.h / 2) - (t.box.y + t.box.h / 2)) / dt
                    let a = t.hits == 1 ? 1.0 : settings.velocityBlend
                    t.vx = a * nvx + (1 - a) * t.vx
                    t.vy = a * nvy + (1 - a) * t.vy
                }
                t.box = d
                t.lastTime = time
                t.hits += 1
                t.misses = 0
                tracks[ti] = t
                matched.insert(ti)
                out.append(Assignment(track: t.id, state: t.hits >= settings.confirmHits ? .confirmed : .tentative, hits: t.hits, gap: gap,
                                      ambiguous: runnerUp >= settings.minIoU && runnerUp >= settings.ambiguityRatio * winner))
            } else {
                let t = Track(id: nextId, box: d, lastTime: time)
                nextId += 1
                tracks.append(t)
                matched.insert(tracks.count - 1)
                out.append(Assignment(track: t.id, state: settings.confirmHits <= 1 ? .confirmed : .tentative, hits: 1, gap: 0, ambiguous: false))
            }
        }
        for i in tracks.indices where !matched.contains(i) { tracks[i].misses += 1 }
        return out
    }
}
