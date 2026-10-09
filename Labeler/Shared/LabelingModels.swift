//
//  LabelingModels.swift
//  Labeler (also compiled into RallyLab)
//
//  The rows the Labeler app and RallyLab's Sync share (supabase/migrations/
//  028_labeling.sql): a video to label, and the rally times marked in it.
//

import CoreGraphics
import Foundation

enum LabelSurface: String, Codable, CaseIterable, Identifiable {
    case indoor = "Indoor"
    case grass = "Grass"
    case beach = "Beach"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .indoor: return "building.2"
        case .grass: return "leaf"
        case .beach: return "beach.umbrella"
        }
    }

    /// Lighting choices, matching the clip plan's.
    var lightings: [String] {
        switch self {
        case .indoor: return ["Bright gym", "Dim gym"]
        case .grass: return ["Sunny", "Shade", "Dusk"]
        case .beach: return ["Sunny", "Overcast / golden hour"]
        }
    }
}

enum LabelCamera: String, Codable, CaseIterable, Identifiable {
    case endlineRaised = "endline_raised"
    case endlineGround = "endline_ground"
    case corner
    case sideline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .endlineRaised: return "End line, raised"
        case .endlineGround: return "End line, ground"
        case .corner: return "Corner"
        case .sideline: return "Sideline"
        }
    }
}

struct LabelVideo: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        /// From a RallyLab project.
        case rallylab
        /// Recorded on the phone, waiting for RallyLab to pull it in.
        case uploaded
        /// Recorded on the phone, now in a project.
        case imported
    }

    var id: UUID
    var project: String?
    var sessionName: String?
    var title: String
    var surface: LabelSurface
    var camera: LabelCamera
    var lighting: String
    var split: String
    /// Path in the labeling bucket; nil until uploaded.
    var clipPath: String?
    var duration: Double
    /// Rallies RallyLab's pipeline found, [start, end] in seconds.
    var ralliesFound: [[Double]]
    var status: Status
    var updatedAt: Date?

    var name: String { sessionName ?? (title.isEmpty ? "Phone video" : title) }
}

/// A rally's start and end, seconds into the video.
/// A time in a video as m:ss.s.
func clockText(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00.0" }
    return String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
}

/// A rally's start and end. Two with the same times are the same rally.
struct LabelRally: Codable, Hashable, Identifiable {
    var start: Double
    var end: Double

    var id: String { "\(start)-\(end)" }
}

struct LabelRallyTimes: Codable, Hashable {
    var videoId: UUID
    var rallies: [LabelRally]
    /// Every rally in the video is marked.
    var complete: Bool
    var updatedAt: Date?
}

/// A rally tracked frame by frame, as label_tracks keeps it: the ball (or
/// hidden) on every frame. The detector's candidates aren't synced — each
/// side finds them again when it needs to re-solve.
struct LabelTrack: Codable, Identifiable, Hashable {
    var id: UUID
    var videoId: UUID
    var start: Double
    var end: Double
    var points: PackedPoints
    var done: Bool
    /// Deleted on the phone; the Mac removes its copy on the next sync.
    var deleted: Bool
    var updatedAt: Date?
    /// The frames checked in annotation review, by index in `points` (the
    /// packed rows don't carry it). Nil from an older build: left as it was.
    var reviewed: [Int]?
    /// Frames marked "not sure" in review, by index; nil from an older build.
    var unsure: [Int]?

    /// Labeled frames (ball or hidden) — what training gets.
    var labeledFrames: Int { points.points.filter { $0.state != .unknown }.count }

    /// TrackPoints as compact arrays: [time, state, origin, x, y, w, h, confidence],
    /// the box only when there is one.
    struct PackedPoints: Codable, Hashable {
        var points: [TrackPoint]

        /// One point's row, as stored.
        static func row(_ p: TrackPoint) -> [Double] {
            var row = [p.time, Double(states.firstIndex(of: p.state) ?? 0), Double(origins.firstIndex(of: p.origin) ?? 0)]
            if let b = p.box { row += [b.x, b.y, b.w, b.h, b.confidence] }
            return row
        }

        init(_ points: [TrackPoint]) { self.points = points }

        private static let states: [TrackPoint.State] = [.unknown, .visible, .hidden]
        private static let origins: [TrackPoint.Origin] = [.auto, .user, .filled]

        init(from decoder: Decoder) throws {
            let rows = try decoder.singleValueContainer().decode([[Double]].self)
            points = rows.compactMap { r in
                guard r.count >= 3 else { return nil }
                let state = Self.states[min(max(Int(r[1]), 0), 2)]
                let origin = Self.origins[min(max(Int(r[2]), 0), 2)]
                let box = r.count >= 8
                    ? TrackCandidate(rect: CGRect(x: r[3], y: r[4], width: r[5], height: r[6]), confidence: r[7]) : nil
                return TrackPoint(time: r[0], state: state, origin: origin, box: box)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(points.map(Self.row))
        }
    }
}

extension LabelTrack {
    init(_ rally: TrackedRally, videoId: UUID) {
        self.init(id: rally.id, videoId: videoId, start: rally.start, end: rally.end, points: PackedPoints(rally.points),
                  done: rally.done, deleted: false, updatedAt: rally.updatedAt,
                  reviewed: rally.points.indices.filter { rally.points[$0].reviewed },
                  unsure: rally.points.indices.filter { rally.points[$0].unsure })
    }

    /// Frames still worth a look (not yours, unsure, filled in or not found).
    var toCheck: Int { points.points.filter(\.isUncertain).count }

    /// As the Track tab and TrackSolver work with it (no candidates yet).
    var rally: TrackedRally {
        var points = points.points
        for i in reviewed ?? [] where points.indices.contains(i) { points[i].reviewed = true }
        for i in unsure ?? [] where points.indices.contains(i) { points[i].unsure = true }
        return TrackedRally(id: id, start: start, end: end, points: points, candidates: [], done: done, updatedAt: updatedAt)
    }
}

/// A project's training plan as the Mac ran it, and each run's scores
/// ({run name: {"tracked": F1, "indoor": F1, …}}), for the phone's Plan tab.
struct LabelProjectState: Codable, Hashable {
    var project: String
    var plan: [TrainedRound]
    var scores: [String: [String: Double]]
    var updatedAt: Date?
}
