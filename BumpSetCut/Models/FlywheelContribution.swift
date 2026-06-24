//
//  FlywheelContribution.swift
//  BumpSetCut
//
//  Data-flywheel model types. A "contribution" is one rally where the detector
//  struggled (or the user corrected it), packaged as a short clip plus the
//  detector's per-frame evidence so the frames can be relabeled and fed back
//  into training. See FlywheelCaptureService for staging/upload.
//

import Foundation
import CoreGraphics

// MARK: - Consent

enum FlywheelConsent {
    /// Bump when the consent copy materially changes so we can tell which
    /// version a user agreed to. Stored alongside the opt-in date.
    static let currentVersion = "1.0"
}

// MARK: - Trigger

/// Why a contribution was captured. Mirrors the `trigger_type` check on the
/// `flywheel_contributions` table.
enum FlywheelTrigger: String, Codable {
    case lowScore = "low_score"        // passive: borderline-confidence rally
    case userRemoved = "user_removed"  // user swiped a rally away in review
    case userTrimmed = "user_trimmed"  // user corrected the rally's start/end
    case reported = "reported"         // explicit "report a mistake"
}

// MARK: - Flag Event

/// One time the user (or passive capture) flagged a rally in a video. Whole-video
/// frames are uploaded once per video; each additional flag just appends one of
/// these and bumps the server-side count.
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
    }
}

// MARK: - Staged Contribution (local disk record)

/// A contribution staged on disk under `ProcessedMetadata/Flywheel/`, awaiting
/// upload. The clip lives next to it as `clipFileName`.
struct FlywheelContribution: Codable, Identifiable {
    let id: UUID
    let videoId: UUID
    let rallyIndex: Int
    let startTime: Double
    let endTime: Double
    let trigger: FlywheelTrigger
    let userReason: String?
    /// Local staged JPEG frame files (full-res annotation stills), in order.
    /// Empty for "repeat" flags on a video whose frames were already uploaded.
    let frameFileNames: [String]
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
    let pFrameUrls: [String]
    let pEvidence: [StoredFrameEvidence]
    let pRallyConfidence: Double
    let pRallyQuality: Double
    let pAppVersion: String
    let pOsVersion: String
    let pDeviceModel: String
    let pConsentVersion: String
    let pEvents: [FlywheelFlagEvent]

    init(contribution: FlywheelContribution, frameUrls: [String]) {
        self.pLocalVideoId = contribution.videoId
        self.pRallyIndex = contribution.rallyIndex
        self.pTrigger = contribution.trigger.rawValue
        self.pReason = contribution.userReason
        self.pFrameUrls = frameUrls
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
