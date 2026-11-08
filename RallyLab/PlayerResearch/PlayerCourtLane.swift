//
//  PlayerCourtLane.swift
//  RallyLab
//
//  court_net_lane_v1: whether a person stands on the selected court, as evidence
//  only, from the one court geometry the project has — a person's net label (the
//  net's four corners, net-labels.json). No court lines are labeled anywhere, so
//  this is a perspective lane around the net, and it is applied only where its
//  assumption holds: a camera behind the end line (card camera "End line, …"),
//  a net label made on this very file. Anywhere else every person's membership
//  is `unknown`, with the reason in the manifest — never guessed.
//
//  The lane at the net's foot line is the posts' span widened by `margin` of the
//  net's width on each side. Below that line (toward the camera: the near court)
//  it widens linearly to `nearGain` × the net's half-width more at the bottom of
//  the frame; above it (the far court) it narrows by `farShrink` toward the top.
//  A person is `in` when the foot point (the box's bottom centre) lies in the lane
//  at its own height.
//

import Foundation

struct PlayerCourtLane: Equatable, Sendable {
    struct Settings: Equatable, Sendable {
        var margin = 0.15
        var nearGain = 1.0
        var farShrink = 0.3
        var described: [String: String] {
            ["version": PlayerFeatures.courtVersion, "geometry": "person-labeled net quad only (net-labels.json, same file fingerprint)",
             "applies": "card camera beginning \"End line\"; otherwise unknown",
             "margin": "\(margin)", "nearGain": "\(nearGain)", "farShrink": "\(farShrink)",
             "meaning": "evidence of on-court position, not proof; neighbouring courts and spectators inside the lane are counted in"]
        }
    }

    let settings: Settings
    /// Net foot line height and the posts' x span there.
    let footY: Double
    let left: Double
    let right: Double

    /// The lane for this recording, or the reason there is none.
    static func make(net: PlayerFeatures.NetGeometry?, camera: String?, recordingFingerprint: String?,
                     settings: Settings = Settings()) -> (lane: PlayerCourtLane?, unknownReason: String?) {
        guard let net else { return (nil, "no person net label for this recording") }
        guard let fp = recordingFingerprint, fp == net.labelFingerprint else { return (nil, "the net label was made on another file") }
        guard let camera, camera.hasPrefix("End line") else { return (nil, "camera \"\(camera ?? "unknown")\" is not behind the end line: the lane assumes it is") }
        guard net.corners.count == 4, net.corners.allSatisfy({ $0.count == 2 }) else { return (nil, "the net label has no four corners") }
        let bl = net.corners[3], br = net.corners[2]
        let l = min(bl[0], br[0]), r = max(bl[0], br[0])
        guard r - l > 0.01 else { return (nil, "the net label is too narrow to define a lane") }
        return (PlayerCourtLane(settings: settings, footY: (bl[1] + br[1]) / 2, left: l, right: r), nil)
    }

    /// The lane's x span at height `y`.
    func span(atY y: Double) -> (lo: Double, hi: Double) {
        let mid = (left + right) / 2
        var half = (right - left) / 2 * (1 + 2 * settings.margin)
        if y < footY {
            half *= 1 + settings.nearGain * (footY - y) / max(footY, 1e-6)
        } else {
            half *= 1 - settings.farShrink * (y - footY) / max(1 - footY, 1e-6)
        }
        return (mid - half, mid + half)
    }

    func membership(_ box: PlayerFeatures.Box) -> PlayerFeatures.CourtMembership {
        let (x, y) = box.foot
        let s = span(atY: y)
        return x >= s.lo && x <= s.hi ? .inside : .outside
    }
}
