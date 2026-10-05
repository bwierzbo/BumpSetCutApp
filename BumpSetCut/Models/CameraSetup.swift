//
//  CameraSetup.swift
//  BumpSetCut
//
//  Where a video was filmed from, picked on a top-down court diagram before
//  processing. Rules that depend on the viewing angle read it: the pipeline's
//  net-geometry rules assume an end-line camera, and serve-side scoring reads
//  a different signal from the side (ball position against the net) than
//  from an end line (ball growing or shrinking). Compiled into RallyLab too.
//

import CoreGraphics
import Foundation

/// The kind of view a camera position gives, from its viewing angle.
enum CameraZone: String, Codable, CaseIterable {
    /// Behind an end line, looking down the court: the net runs across the frame.
    case endline
    /// Diagonal, from around a corner.
    case corner
    /// Side-on: the net is a near-vertical band and the court runs left–right.
    case sideline
}

enum CameraHeight: String, Codable, CaseIterable {
    /// Stands, a tripod or a fence — about 2 m or higher.
    case raised
    /// Standing or sitting height.
    case ground
}

struct CameraSetup: Codable, Equatable, Hashable {
    /// Court coordinates: the court spans -1…1 in both axes — `x` from one
    /// sideline to the other, `y` from one end line to the other — with the net
    /// at `y = 0`. The camera sits outside the court, so |x| > 1 or |y| > 1.
    var position: CGPoint
    var height: CameraHeight

    /// A volleyball court is twice as long as it is wide.
    static let courtLengthToWidth: CGFloat = 2

    /// The most room around the court the diagram offers, in court units.
    static let maxReach = CGSize(width: 2.4, height: 1.7)

    /// Centred behind an end line, a few metres back, raised: the whole court
    /// in frame with the net running across it — what the pipeline is built for.
    static let recommended = CameraSetup(position: CGPoint(x: 0, y: -1.35), height: .raised)

    init(position: CGPoint, height: CameraHeight) {
        self.position = Self.placed(position)
        self.height = height
    }

    /// Degrees between the camera's line of sight to the court centre and the
    /// court's long axis: 0 = straight down the court, 90 = side-on.
    var viewingAngleDegrees: Double {
        let across = abs(position.x)
        let along = abs(position.y) * Self.courtLengthToWidth
        guard across > 0 || along > 0 else { return 0 }
        return atan2(across, along) * 180 / .pi
    }

    var zone: CameraZone {
        switch viewingAngleDegrees {
        case ..<25: return .endline
        case ...60: return .corner
        default: return .sideline
        }
    }

    /// A pin dropped on the court moves to just outside the nearest edge, and
    /// one dropped far away comes back within reach of the diagram.
    static func placed(_ point: CGPoint) -> CGPoint {
        var p = CGPoint(x: min(max(point.x, -maxReach.width), maxReach.width),
                        y: min(max(point.y, -maxReach.height), maxReach.height))
        let margin: CGFloat = 0.12
        if abs(p.x) < 1 + margin && abs(p.y) < 1 + margin {
            // Inside (or on) the court: push out through the nearer edge,
            // measured in metres so the long axis isn't favoured.
            let toSideline = (1 + margin - abs(p.x))
            let toEndline = (1 + margin - abs(p.y)) * courtLengthToWidth
            if toSideline < toEndline {
                p.x = (p.x < 0 ? -1 : 1) * (1 + margin)
            } else {
                p.y = (p.y < 0 ? -1 : 1) * (1 + margin)
            }
        }
        return p
    }
}

extension CameraZone {
    var title: String {
        switch self {
        case .endline: return String(localized: "End line")
        case .corner: return String(localized: "Corner")
        case .sideline: return String(localized: "Sideline")
        }
    }

    /// A representative camera spot for the zone: centred behind the near end
    /// line (the recommended spot), off the near-right corner, or level with
    /// the net on the right.
    var presetPosition: CGPoint {
        switch self {
        case .endline: return CameraSetup.recommended.position
        case .corner: return CGPoint(x: 1.4, y: -1.25)
        case .sideline: return CGPoint(x: 1.7, y: 0)
        }
    }
}
