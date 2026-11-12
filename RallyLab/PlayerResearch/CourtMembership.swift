//
//  CourtMembership.swift
//  RallyLab
//
//  court_polygon_v1: where each person stands against a person-confirmed court
//  (court_geometry_v1), as evidence, never as proof. The ground point is the feet when
//  the pose's ankles are reliable and sit inside the person's box, else the box's bottom
//  centre. The point goes through the court half's map to court coordinates and a zone:
//  near or far court, near or far serving area (behind the end line, a little wider
//  than the court), outside, or unknown (no confirmed court here, beyond the horizon, a
//  half with no map).
//
//  Doubt is kept, not resolved: a point within `boundaryBand` of a zone's edge, a box cut
//  by the bottom of the frame (the feet are below it), a person off the ground (the foot
//  well above its track's usual ground line: a jump) — each is `uncertain` and says why.
//  The zone a track shows is smoothed over time: an uncertain observation holds the
//  track's previous zone, and a change needs `confirmFrames` certain observations in a
//  row, so a player on a line doesn't flicker. Nobody is dropped for being one too many:
//  the number of players is not used. Players who leave the court (a server, a chase)
//  keep their track and are shown where they are.
//

import Foundation

/// One person's zone in one frame (player_features_v1, optional `zone`).
struct PersonZone: Codable, Equatable, Sendable {
    /// The smoothed zone: what `court` (in/out) is made from.
    var zone: CourtZone
    /// This frame's own zone, before smoothing.
    var raw: CourtZone
    /// `ankles` or `box`.
    var foot: String
    var u: Double?
    var v: Double?
    /// Distance to the nearest edge of the raw zone, court units.
    var margin: Double?
    var uncertain: Bool
    /// Why: `boundary`, `truncated`, `airborne`, `held` (the smoothed zone kept the previous one).
    var why: [String]
    /// The calibration segment used.
    var segment: Int
}

enum CourtGround {
    struct Settings: Equatable, Sendable {
        /// A joint score a foot must reach (Vision 0–1; RTMPose's SimCC can exceed 1).
        var minAnkleScore = 0.3
        /// The ankle sits above the sole: the ground point is this share of the box's height below it.
        var ankleToSole = 0.03
        /// Foot above the track's usual ground line by more than this share of its height: off the ground.
        var airborneLift = 0.25
    }

    /// The ground point of a person: the ankles' lower point when reliable and inside the box, else the box bottom.
    static func point(_ p: PlayerFeatures.Person, settings s: Settings = Settings()) -> (x: Double, y: Double, foot: String) {
        let box = p.box
        if let pose = p.pose {
            let ankles = [pose.j("left_ankle"), pose.j("right_ankle")].compactMap { $0 }.filter {
                $0.c >= s.minAnkleScore && box.contains($0.x, $0.y, margin: 0.1)
            }
            if !ankles.isEmpty {
                let x = ankles.map(\.x).reduce(0, +) / Double(ankles.count)
                let y = ankles.map(\.y).min()! - s.ankleToSole * box.h
                return (x, y, "ankles")
            }
        }
        return (box.midX, box.y, "box")
    }
}

/// Holds each track's zone across frames (reset at every tracker reset).
struct CourtZoneSmoother {
    var confirmFrames = 2
    private var state: [Int: (zone: CourtZone, pending: CourtZone?, count: Int)] = [:]

    mutating func reset() { state = [:] }

    /// The track's zone after this observation, and whether it held the previous zone against this frame's.
    mutating func observe(track: Int, raw: CourtZone, reliable: Bool) -> (zone: CourtZone, held: Bool) {
        guard var s = state[track] else {
            state[track] = (raw, nil, 0)
            return (raw, false)
        }
        defer { state[track] = s }
        if raw == s.zone { s.pending = nil; s.count = 0; return (raw, false) }
        if s.zone == .unknown && raw != .unknown { s = (raw, nil, 0); return (raw, false) }
        guard reliable else { return (s.zone, true) }
        if s.pending == raw { s.count += 1 } else { s.pending = raw; s.count = 1 }
        if s.count >= confirmFrames { s = (raw, nil, 0); return (raw, false) }
        return (s.zone, true)
    }
}

/// Applies court_polygon_v1 to a frame's persons, in time order, one recording at a time.
struct CourtMembershipPass {
    let classifier: (Double) -> (classifier: CourtZoneClassifier, segment: Int)?
    var ground = CourtGround.Settings()
    private var smoother = CourtZoneSmoother()
    private var lastSegment: Int?

    init(classifier: @escaping (Double) -> (classifier: CourtZoneClassifier, segment: Int)?) { self.classifier = classifier }

    /// A pass over a calibration file's confirmed segments (nil when none is confirmed).
    static func confirmed(_ file: CourtCalibrationFile, settings: CourtZoneClassifier.Settings = .init()) -> CourtMembershipPass {
        CourtMembershipPass { t in
            guard let seg = file.segments.first(where: { $0.contains(t) }), let c = file.confirmed(at: t) else { return nil }
            return (CourtZoneClassifier(geometry: c.geometry, spec: c.spec, settings: settings), seg.id)
        }
    }

    mutating func resetTracks() { smoother.reset() }

    /// The zone of each person (nil for all when no confirmed court covers `t`).
    mutating func zones(_ persons: [PlayerFeatures.Person], at t: Double) -> [PersonZone]? {
        guard let (c, segment) = classifier(t) else { lastSegment = nil; smoother.reset(); return nil }
        if segment != lastSegment { smoother.reset(); lastSegment = segment }
        return persons.map { p in
            let g = CourtGround.point(p, settings: ground)
            let r = c.classify(x: g.x, y: g.y)
            var why: [String] = []
            if r.uncertain, r.zone != .unknown { why.append("boundary") }
            let truncated = p.box.y < 0.01
            if truncated { why.append("truncated") }
            let airborne = (p.derived.lift ?? 0) > ground.airborneLift
            if airborne { why.append("airborne") }
            let reliable = !r.uncertain && !truncated && !airborne && r.zone != .unknown
            let s = smoother.observe(track: p.track, raw: r.zone, reliable: reliable)
            if s.held { why.append("held") }
            return PersonZone(zone: s.zone, raw: r.zone, foot: g.foot, u: r.u, v: r.v, margin: r.margin,
                              uncertain: !reliable || s.held, why: why, segment: segment)
        }
    }

    static func membership(_ z: PersonZone) -> PlayerFeatures.CourtMembership {
        z.zone == .unknown ? .unknown : (z.zone.isPlaying ? .inside : .outside)
    }
}
