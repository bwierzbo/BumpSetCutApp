//
//  PlayerFrameAssembler.swift
//  RallyLab
//
//  Turns the extractor's raw frames into `player_features_v1` lines: segments
//  (and so tracker resets), track identities, court membership and the derived
//  features (each detector pairs its own poses with its boxes, PlayerDetectors). Pure and deterministic — the same raw
//  frames give the same lines — so it is tested without Vision or video.
//
//  A new segment starts, and the tracker and the derived history forget
//  everything, at: an interval's first frame; a gap over `gapSec` since the
//  previous sampled frame; a cut-range or time-breaking-span boundary in
//  (previous tick, tick] (the contract's rule, by boundaries, not membership);
//  a frame difference over `cutDiff` (a suspected camera cut). Frames inside
//  excluded time are written, not analysed, and sit in their own segment.
//

import Foundation

struct PlayerFrameAssembler {
    struct Settings: Equatable, Sendable {
        var gapSec = 0.5
        /// Mean absolute luminance difference of the 32×18 thumbnails above which a camera cut is suspected.
        var cutDiff = 0.2
        var described: [String: String] {
            ["gapSec": "\(gapSec)", "cutDiff": "\(cutDiff)", "thumbnail": "32x18 luminance, 4x4 patch means"]
        }
    }

    let settings: Settings
    /// Boundaries (seconds) of cut ranges and time-breaking spans, with their kind.
    let boundaries: [(t: Double, kind: String)]
    let lane: PlayerCourtLane?
    private var tracker: PlayerTracker
    private var derived: PlayerDerivedFeatures
    private var seg = -1
    private var previous: (t: Double, interval: String, thumb: [Double], skipped: Bool)?

    init(settings: Settings = Settings(), tracker: PlayerTracker.Settings = .init(), derived: PlayerDerivedFeatures.Settings = .init(),
         excluded: [PlayerFeatures.TickSpan], lane: PlayerCourtLane?) {
        self.settings = settings
        self.tracker = PlayerTracker(settings: tracker)
        self.derived = PlayerDerivedFeatures(settings: derived)
        self.lane = lane
        let s = Double(PlayerFeatures.timescale)
        boundaries = excluded.flatMap { [(Double($0.startTick) / s, $0.kind), (Double($0.endTick) / s, $0.kind)] }
    }

    static func meanAbsDiff(_ a: [Double], _ b: [Double]) -> Double? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        return zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count)
    }

    mutating func add(_ raw: PlayerVisionExtractor.RawFrame) -> PlayerFeatures.Frame {
        let tick = PlayerFeatures.tick(raw.t)
        var reset: String?
        var diff: Double?
        if let prev = previous, prev.interval == raw.interval {
            let prevTick = PlayerFeatures.tick(prev.t)
            if raw.t - prev.t > settings.gapSec { reset = "gap" }
            else if let b = boundaries.first(where: { PlayerFeatures.tick($0.t) > prevTick && PlayerFeatures.tick($0.t) <= tick }) { reset = "\(b.kind)_boundary" }
            else if raw.skipped == nil, !prev.skipped, let d = Self.meanAbsDiff(prev.thumb, raw.thumb) {
                diff = d
                if d > settings.cutDiff { reset = "suspected_camera_cut" }
            }
        } else {
            reset = "interval_start"
        }
        if reset != nil {
            seg += 1
            tracker.reset()
            derived.reset()
        }
        previous = (raw.t, raw.interval, raw.thumb, raw.skipped != nil)

        let masks = PlayerFeatures.Masks(ran: raw.skipped == nil, skipped: raw.skipped, rectFailed: raw.detections.rectFailed, poseFailed: raw.detections.poseFailed)
        guard raw.skipped == nil else {
            return PlayerFeatures.Frame(t: raw.t, tick: tick, interval: raw.interval, seg: seg, reset: reset, frameDiff: nil, persons: [], unmatchedPoses: [],
                                        scene: derived.scene([]), masks: masks, ms: raw.ms)
        }
        let found = raw.detections.persons
        let assignments = tracker.update(found.map(\.box), at: raw.t)
        var persons: [PlayerFeatures.Person] = []
        for (i, a) in assignments.enumerated() {
            let p = found[i]
            persons.append(PlayerFeatures.Person(
                box: p.box, conf: p.conf, track: a.track, state: a.state, hits: a.hits, gap: a.gap, ambiguous: a.ambiguous,
                court: lane?.membership(p.box) ?? .unknown, pose: p.pose,
                derived: derived.observe(track: a.track, at: raw.t, box: p.box, pose: p.pose)))
        }
        return PlayerFeatures.Frame(t: raw.t, tick: tick, interval: raw.interval, seg: seg, reset: reset, frameDiff: diff, persons: persons,
                                    unmatchedPoses: raw.detections.unpairedPoses, scene: derived.scene(persons), masks: masks, ms: raw.ms)
    }
}
