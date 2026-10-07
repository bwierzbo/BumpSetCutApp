//
//  LabelingModels.swift
//  Labeler (also compiled into RallyLab)
//
//  The rows the Labeler app and RallyLab's Sync share (supabase/migrations/
//  028_labeling.sql): a video to label, and the rally times marked in it.
//

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
struct LabelRally: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double

    private enum CodingKeys: String, CodingKey { case start, end }
}

struct LabelRallyTimes: Codable, Hashable {
    var videoId: UUID
    var rallies: [LabelRally]
    /// Every rally in the video is marked.
    var complete: Bool
    var updatedAt: Date?
}
