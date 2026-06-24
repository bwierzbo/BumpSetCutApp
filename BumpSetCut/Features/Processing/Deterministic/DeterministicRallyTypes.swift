//
//  DeterministicRallyTypes.swift
//  BumpSetCut
//
//  Phase 1 deterministic rally detection (ball + net + court geometry, no ML
//  scoring, no player/action inference). Shared types for the engine, the dense
//  detection sampler, and the RallyLab debug UI. All geometry is Vision-normalized
//  (origin bottom-left, [0,1]) in the RAW frame space the detectors output.
//

import CoreGraphics
import Foundation

/// One ball detection in a frame.
struct BallObservation {
    let rect: CGRect
    let confidence: Float
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

/// All ball detections in one processed frame.
struct BallSample {
    let frameIndex: Int
    let time: Double
    let observations: [BallObservation]
}

/// The net, fixed for the whole video. The net plane (`lineY`) is the primary
/// spatial reference for side/crossing logic.
struct DetectedNet {
    let box: CGRect
    let confidence: Double
    /// Net plane in Vision y (vertical center of the detected band).
    var lineY: CGFloat { box.midY }
    var leftX: CGFloat { box.minX }
    var rightX: CGFloat { box.maxX }
}

enum CourtSide { case near, far }

/// Court regions derived from the fixed net. Near side = below the net plane
/// (lower Vision y, closer to a baseline camera); far side = above it.
struct CourtGeometry {
    let net: DetectedNet
    let playRegion: CGRect       // x = net extent, full vertical
    let expandedRegion: CGRect   // play region + buffer (prevents accidental termination)

    init(net: DetectedNet, bufferX: CGFloat, bufferY: CGFloat) {
        self.net = net
        let x = max(0, net.leftX)
        let w = min(1, net.rightX) - x
        let play = CGRect(x: x, y: 0, width: max(0, w), height: 1)
        self.playRegion = play
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        self.expandedRegion = play.insetBy(dx: -bufferX, dy: -bufferY).intersection(unit)
    }

    func side(ofY y: CGFloat) -> CourtSide { y < net.lineY ? .near : .far }
    func inPlay(_ p: CGPoint) -> Bool { playRegion.contains(p) }
    func inExpanded(_ p: CGPoint) -> Bool { expandedRegion.contains(p) }
    var center: CGPoint { CGPoint(x: net.box.midX, y: net.lineY) }
}

/// Finite-state-machine states. Every processed frame is labeled with one.
enum RallyState: String {
    case idle, tracking, active, lost, ended
}

/// Per-frame log entry — drives the color-coded timeline and the live overlay.
struct FrameState {
    let frameIndex: Int
    let time: Double
    let state: RallyState
    let ballPoint: CGPoint?   // tracked ball center (Vision-normalized), nil if none
    let ballBox: CGRect?
}

/// A completed rally with its explainable summary.
struct RallyRecord: Identifiable {
    let id: Int
    let startFrame: Int
    let endFrame: Int
    let startTime: Double
    let endTime: Double
    let netCrossings: Int
    let sideChanges: Int
    let lostTrackEvents: Int
    let confidence: Int        // 0–100, for user review only
    let endReason: String
    var duration: Double { max(0, endTime - startTime) }
}

/// Tunable thresholds — all deterministic, exposed in the Phase 1 tab.
struct EngineConfig {
    var ballConfidence: Float = 0.5         // min detection confidence to consider
    var minTrackFrames: Int = 3             // stable frames before IDLE → TRACKING
    var motionThreshold: CGFloat = 0.004    // min per-frame motion (normalized) TRACKING → ACTIVE
    var lostTimeoutSec: Double = 1.2        // LOST → ENDED
    var stationaryTimeoutSec: Double = 1.5  // ball stationary too long → end
    var stationaryEps: CGFloat = 0.008      // per-frame movement below this counts as stationary
    var maxAssocDist: CGFloat = 0.12        // max distance to associate a detection to the track
    var switchCollapseFrames: Int = 6       // frames w/o plausible detection before continuity collapse
    var bufferX: CGFloat = 0.06             // play-region X buffer
    var bufferY: CGFloat = 0.06             // play-region Y buffer
    var minRallySec: Double = 0.6           // drop rallies shorter than this
    var trailSeconds: Double = 0.6          // overlay trail window
}

/// Everything the engine produces — rallies for the summary, per-frame states for
/// the timeline/overlay, plus the court + raw samples for drawing.
struct EngineResult {
    let rallies: [RallyRecord]
    let frameStates: [FrameState]
    let court: CourtGeometry
    let samples: [BallSample]
}
