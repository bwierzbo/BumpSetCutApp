//
//  PlayerFeaturesFormat.swift
//  RallyLab
//
//  `player_features_v1` (docs/ml-roadmap/PLAYER_FEATURES_V1_CONTRACT.md): what the
//  player-feasibility research tool (Phase P0) writes for each recording it reads —
//  the people Apple Vision found on sampled frames, their 2D poses, the deterministic
//  tracker's identities, court membership as evidence, and the compact derived
//  features, all on the scoring contract's 600-tick time base in the same upright,
//  Vision-normalised frame space as the ball evidence (`FrameEvidence.upright`), so a
//  later fusion step can join it to `rcf_v1` steps by recording and tick.
//
//  Research only: nothing here is read by the iOS app, the processing pipeline, the
//  rally-classifier exporter or its dataset contract. Missing data stays missing:
//  a joint Vision did not report is null, a person without a pose has a null pose,
//  a frame the tool did not analyse says so (`ran: false`) — none of these is ever
//  turned into a label, and nothing here is ground truth.
//

import Foundation

enum PlayerFeatures {
    static let schemaVersion = "player_features_v1"
    static let trackerVersion = "ptrk_v1"
    static let courtVersion = "court_net_lane_v1"
    static let derivedVersion = "pfd_v1"
    static let interactionVersion = "bpi_v1"
    static let timescale = 600
    static let coordinateSpace = "vision_normalized_upright"
    static let ledgerRef = "--player-lab-run"

    /// The 19 joints of VNDetectHumanBodyPoseRequest revision 1, in the order every
    /// `joints` array is written (the manifest repeats it).
    static let jointNames: [String] = [
        "nose", "left_eye", "right_eye", "left_ear", "right_ear",
        "neck", "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
        "left_wrist", "right_wrist", "root", "left_hip", "right_hip",
        "left_knee", "right_knee", "left_ankle", "right_ankle",
    ]
    static func joint(_ name: String) -> Int { jointNames.firstIndex(of: name)! }

    static func tick(_ seconds: Double) -> Int { Int((seconds * Double(timescale)).rounded()) }

    // MARK: - Per-frame line (frames/<recordingId>.jsonl)

    /// A box in the upright frame, Vision-normalised (origin bottom-left, y up).
    struct Box: Codable, Equatable, Sendable {
        var x: Double, y: Double, w: Double, h: Double
        var midX: Double { x + w / 2 }
        var maxY: Double { y + h }
        /// Where the person stands: the bottom centre of the box.
        var foot: (x: Double, y: Double) { (x + w / 2, y) }
        var area: Double { max(0, w) * max(0, h) }

        func iou(_ o: Box) -> Double {
            let ix = max(0, min(x + w, o.x + o.w) - max(x, o.x))
            let iy = max(0, min(y + h, o.y + o.h) - max(y, o.y))
            let inter = ix * iy
            let union = area + o.area - inter
            return union > 0 ? inter / union : 0
        }

        func contains(_ px: Double, _ py: Double, margin: Double = 0) -> Bool {
            px >= x - margin * w && px <= x + w + margin * w && py >= y - margin * h && py <= y + h + margin * h
        }
    }

    /// One joint: position (upright, Vision-normalised) and the detector's score for it (Vision: confidence 0–1;
    /// RTMPose: the raw SimCC score, which can exceed 1). A joint the detector did not report is null in its slot,
    /// never zeros.
    struct Joint: Codable, Equatable, Sendable {
        var x: Double, y: Double, c: Double
    }

    struct Pose: Codable, Equatable, Sendable {
        /// The observation's own confidence.
        var conf: Double
        /// `jointNames.count` slots, null where Vision reported nothing usable.
        var joints: [Joint?]
        func j(_ name: String) -> Joint? { joints[PlayerFeatures.joint(name)] }
        var reported: Int { joints.compactMap { $0 }.count }
        /// The smallest box around the reported joints, nil when fewer than two.
        var bounds: Box? {
            let pts = joints.compactMap { $0 }
            guard pts.count >= 2 else { return nil }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            return Box(x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!)
        }
    }

    enum CourtMembership: String, Codable, Sendable {
        /// The foot point lies inside the selected court's lane, or (court_polygon_v1) on the court or a serving area
        /// of a person-confirmed court (evidence, not proof).
        case inside = "in"
        case outside = "out"
        /// No usable court geometry for this recording, or this camera.
        case unknown
    }

    /// Where the tracker is with a person's identity.
    enum TrackState: String, Codable, Sendable {
        /// Seen fewer than `confirmHits` times since it began: may be a false detection.
        case tentative
        case confirmed
    }

    /// The per-person derived features (pfd_v1): causal — from this track's history within the
    /// segment up to and including this frame. null when the inputs are missing.
    struct PersonDerived: Codable, Equatable, Sendable {
        /// Foot-point speed, normalised frame units per second (aspect-dependent; the
        /// manifest's `aspect` converts).
        var speed: Double?
        /// Change in speed per second since the previous observation of this track.
        var accel: Double?
        /// Turn of the foot-point velocity since the previous observation, radians in [0, π];
        /// null when either velocity is below `minMovingSpeed`.
        var turn: Double?
        /// max over both arms of (wrist.y − shoulder.y) / torso length; > 0 = a wrist above its
        /// shoulder.
        var armElevation: Double?
        /// The neck→root axis's angle from vertical, degrees.
        var torsoLeanDeg: Double?
        /// The smaller hip–knee–ankle angle of the two legs, degrees (180 = straight).
        var kneeAngleDeg: Double?
        /// This box's height over the track's trailing median height (< 1: crouched or partly hidden).
        var heightRatio: Double?
        /// (foot y − the track's trailing median foot y) / median height; > 0 = above its usual ground line.
        var lift: Double?
    }

    struct Person: Codable, Equatable, Sendable {
        var box: Box
        /// VNHumanObservation confidence.
        var conf: Double
        /// Unique within the recording; a reset never reuses an ID.
        var track: Int
        var state: TrackState
        /// Observations of this track so far (this one included).
        var hits: Int
        /// Sampled frames since this track was last matched before this one (0 = matched on the previous frame).
        var gap: Int
        /// Another track's prediction overlapped this detection almost as well: the identity may have switched.
        var ambiguous: Bool
        var court: CourtMembership
        /// court_polygon_v1: the zone against a person-confirmed court, nil where none covers the frame (then `court`
        /// comes from the net lane, or is unknown). Absent from lines written before it existed.
        var zone: PersonZone? = nil
        /// The detector's pose for this person, nil when it has none (Vision: none associated; RTMPose: not posed).
        var pose: Pose?
        var derived: PersonDerived
    }

    /// Frame-level summary (pfd_v1), over confirmed tracks; `inCourt…` over those whose court is `in`.
    struct SceneDerived: Codable, Equatable, Sendable {
        var persons: Int
        var confirmed: Int
        var inCourt: Int
        var meanSpeedInCourt: Double?
        /// Share of in-court confirmed tracks moving faster than `minMovingSpeed`.
        var movingShareInCourt: Double?
        /// Length of the mean unit velocity of the moving in-court tracks: 1 = all the same way,
        /// near 0 = no common direction; null with fewer than two moving.
        var coherenceInCourt: Double?
        var posesInCourt: Int
    }

    /// What the frame's analysis could and could not do.
    struct Masks: Codable, Equatable, Sendable {
        /// Vision was run on this frame. False inside cut ranges and time-breaking spans.
        var ran: Bool
        /// Why it was not run: "cut", "time_break", nil when it ran.
        var skipped: String?
        var rectFailed: Bool
        var poseFailed: Bool
    }

    struct Frame: Codable, Equatable, Sendable {
        var t: Double
        var tick: Int
        var interval: String
        /// Contiguous-segment index within the recording: a new one at each interval start, a gap
        /// over `gapSec`, a cut or time-breaking boundary, a suspected camera cut. The tracker starts
        /// afresh at every new segment.
        var seg: Int
        /// The reason this frame began a new segment, nil when it didn't.
        var reset: String?
        /// Mean absolute difference of the 32×18 luminance thumbnail from the previous sampled frame (0–1),
        /// null on a segment's first frame. A camera-cut and camera-motion indicator, nothing more.
        var frameDiff: Double?
        var persons: [Person]
        /// Poses no person box took (people the rectangle request may have missed).
        var unmatchedPoses: [Pose]
        var scene: SceneDerived
        var masks: Masks
        /// Milliseconds: decode-to-thumbnail, rectangles request, pose request.
        var ms: [String: Double]
    }

    // MARK: - Manifest

    struct Interval: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case activePlay = "active_play", betweenRallies = "between_rallies", difficult }
        var name: String
        var kind: Kind
        var startSec: Double
        var endSec: Double
        /// How it was chosen ("auto: …" or "manual: …").
        var selection: String
    }

    struct TickSpan: Codable, Equatable, Sendable { var startTick: Int; var endTick: Int; var kind: String }

    struct DecodedFile: Codable, Equatable, Sendable {
        /// `scrub_proxy` (ScrubProxy: the original's frame times, 960 px long side) or `original`.
        var kind: String
        var fileName: String
        var fingerprint: String
        /// Upright pixel size.
        var width: Int
        var height: Int
        /// The CGImagePropertyOrientation (EXIF raw value) applied to make frames upright.
        var orientation: UInt32
        var nominalFrameRate: Double
        var durationSec: Double
    }

    struct NetGeometry: Codable, Equatable, Sendable {
        /// topLeft, topRight, bottomRight, bottomLeft — upright, Vision-normalised.
        var corners: [[Double]]
        /// "person_label" (net-labels.json), the only source used.
        var origin: String
        var labelFingerprint: String
    }

    struct Recording: Codable, Equatable, Sendable {
        var recordingId: String
        var groupId: String
        var split: String
        var surface: String?
        var camera: String?
        var cardOrientation: String?
        var sourceId: String?
        /// The original's identity as project.json stores it (no file read).
        var fingerprint: String?
        var decoded: DecodedFile
        var aspect: Double
        var recordingType: String
        var eligibility: [String: String]
        var eligibilityReasons: [String]
        var net: NetGeometry?
        /// Why court membership is `unknown` for every person here, nil when the lane or a confirmed court was applied.
        var courtUnknownReason: String?
        /// Which court method set membership (`court_polygon_v1` with the calibration file's SHA-256 and its confirmed
        /// segments, or `court_net_lane_v1`), and why a calibration wasn't used. Absent from runs before P2.
        var courtMethod: [String: String]? = nil
        var cutRanges: [TickSpan]
        var timeBreakingSpans: [TickSpan]
        var intervals: [Interval]
        var framesFile: String
        var framesSha256: String
        var frameCount: Int
    }

    struct Withheld: Codable, Equatable, Sendable {
        var names: [String]
        var sourceIds: [String]
        var fingerprints: [String]
        var closureSha256: String
    }

    struct Manifest: Codable, Equatable, Sendable {
        var schemaVersion: String
        var createdAt: String
        var generator: [String: String]
        var project: String
        var splitManifest: [String: String]
        var withheld: Withheld
        var timescale: Int
        var coordinateSpace: String
        var jointNames: [String]
        var detector: [String: String]
        var sampling: [String: String]
        var tracker: [String: String]
        var court: [String: String]
        /// court_polygon_v1 settings, when the run read court calibrations. Absent from runs before P2.
        var courtPolygon: [String: String]? = nil
        var derived: [String: String]
        var recordings: [Recording]
    }
}
