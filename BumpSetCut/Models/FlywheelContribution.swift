//
//  FlywheelContribution.swift
//  BumpSetCut
//
//  Data-flywheel model types. A "contribution" is one processed video's
//  rallies, uploaded once as clips of the original footage plus the detector's
//  per-frame evidence, so they can be labeled and fed back into training. Flags
//  (a rally the user removed, trimmed or reported) ride along as events. See
//  FlywheelCaptureService for staging/upload.
//

import Foundation
import CoreGraphics

// MARK: - Consent

enum FlywheelConsent {
    /// Bump when the consent copy materially changes so we can tell which
    /// version a user agreed to. Stored alongside the opt-in date.
    static let currentVersion = "2.0"
    /// Recorded for testers, who share footage by default rather than through
    /// the consent sheet (see `AppSettings.applyTesterFlywheelDefault`).
    static let testerDefault = "tester-2.0"
}

// MARK: - Trigger

/// Why a contribution was captured. Mirrors the `trigger_type` check on the
/// `flywheel_contributions` table.
enum FlywheelTrigger: String, Codable {
    case processed = "processed"       // passive: every rally of a processed video
    case userRemoved = "user_removed"  // user swiped a rally away in review
    case userTrimmed = "user_trimmed"  // user corrected the rally's start/end
    case reported = "reported"         // explicit "report a mistake"
    case noRallies = "no_rallies"      // passive: detector found NO rallies in the video
}

// MARK: - Flag Event

/// One time the user (or passive capture) flagged a rally in a video. A video's
/// clips are uploaded once; each additional flag just appends one of these and
/// bumps the server-side count.
struct FlywheelFlagEvent: Codable {
    let rallyIndex: Int
    let trigger: String
    let reason: String?
    let at: Date
}

// MARK: - Stored Frame Evidence

/// Codable mirror of one row of `VideoProcessor.FrameEvidence`, trimmed to the
/// signals that matter for relabeling: the detector's boxes + confidences, the
/// selected track point, and why the physics gate accepted/rejected the frame.
struct StoredBallDetection: Codable {
    let x: Double      // Vision-normalized bbox (origin bottom-left, [0,1])
    let y: Double
    let width: Double
    let height: Double
    let confidence: Double
}

struct StoredFrameEvidence: Codable {
    let time: Double                 // PTS in seconds
    let hasBall: Bool
    let isProjectile: Bool
    let detections: [StoredBallDetection]
    let trackX: Double?
    let trackY: Double?
    let rSquared: Double?
    let gravitySignature: Double?
    let movementType: String?
    let rejectionReason: String?
    /// Boxes and track point are in the upright frame (rotation applied).
    /// nil — evidence from before this was recorded — is stored-frame space.
    let upright: Bool?
}

extension StoredFrameEvidence {
    /// Map one row of the processor's in-memory evidence into its storable form.
    init(_ e: VideoProcessor.FrameEvidence) {
        self.time = e.time
        self.hasBall = e.hasBall
        self.isProjectile = e.isProjectile
        self.detections = e.detections.map { det -> StoredBallDetection in
            let box: CGRect = det.bbox
            return StoredBallDetection(
                x: Double(box.origin.x),
                y: Double(box.origin.y),
                width: Double(box.size.width),
                height: Double(box.size.height),
                confidence: Double(det.confidence)
            )
        }
        self.trackX = e.trackPoint.map { Double($0.x) }
        self.trackY = e.trackPoint.map { Double($0.y) }
        self.rSquared = e.rSquared
        self.gravitySignature = e.gravitySignature
        self.movementType = e.movementType?.rawValue
        self.rejectionReason = e.rejectionReason
        self.upright = e.upright
    }
}

// MARK: - Clip

/// Where a clip sits in the original video, seconds.
struct FlywheelClipWindow: Codable, Equatable {
    let start: Double
    let end: Double
}

/// One stretch of the original video, staged as an .mp4 next to the index.
struct FlywheelClip: Codable, Equatable {
    let fileName: String
    let window: FlywheelClipWindow
}

// MARK: - Staged Contribution (local disk record)

/// A contribution staged on disk under `ProcessedMetadata/Flywheel/`, awaiting
/// upload, with its clips next to it.
struct FlywheelContribution: Codable, Identifiable {
    let id: UUID
    let videoId: UUID
    let rallyIndex: Int
    let startTime: Double
    let endTime: Double
    let trigger: FlywheelTrigger
    let userReason: String?
    /// The video's rallies (each padded a little), in order. Empty for
    /// "repeat" flags on a video whose clips were already uploaded.
    let clips: [FlywheelClip]
    /// Every flag accumulated for this video while staged (sent together on drain).
    var flagEvents: [FlywheelFlagEvent]
    let evidence: [StoredFrameEvidence]
    let rallyConfidence: Double
    let rallyQuality: Double
    let appVersion: String
    let osVersion: String
    let deviceModel: String
    let consentVersion: String
    let createdAt: Date
}

// MARK: - RPC Params

/// Arguments for the `record_flywheel_flag` RPC (insert-or-increment). The user
/// id is resolved server-side via `auth.uid()`, so it's not sent. Keys map to the
/// function's `p_*` argument names via the Supabase snake_case encoder.
struct FlywheelFlagRPCParams: Encodable {
    let pLocalVideoId: UUID
    let pRallyIndex: Int
    let pTrigger: String
    let pReason: String?
    let pClipUrls: [String]
    let pClipWindows: [FlywheelClipWindow]
    let pEvidence: [StoredFrameEvidence]
    let pRallyConfidence: Double
    let pRallyQuality: Double
    let pAppVersion: String
    let pOsVersion: String
    let pDeviceModel: String
    let pConsentVersion: String
    let pEvents: [FlywheelFlagEvent]

    init(contribution: FlywheelContribution, clipUrls: [String]) {
        self.pLocalVideoId = contribution.videoId
        self.pRallyIndex = contribution.rallyIndex
        self.pTrigger = contribution.trigger.rawValue
        self.pReason = contribution.userReason
        self.pClipUrls = clipUrls
        self.pClipWindows = contribution.clips.map(\.window)
        self.pEvidence = contribution.evidence
        self.pRallyConfidence = contribution.rallyConfidence
        self.pRallyQuality = contribution.rallyQuality
        self.pAppVersion = contribution.appVersion
        self.pOsVersion = contribution.osVersion
        self.pDeviceModel = contribution.deviceModel
        self.pConsentVersion = contribution.consentVersion
        self.pEvents = contribution.flagEvents
    }
}
