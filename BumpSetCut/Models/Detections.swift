//
//  Detections.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreGraphics
import CoreMedia

struct DetectionResult {
    let bbox: CGRect
    let confidence: Float
    let timestamp: CMTime
}

enum DetectionType {
    case ball
}

struct VolleyballRallyEvidence {
    var lastActiveTime: CMTime?
    var isActive: Bool = false
}

enum ProcessingError: Error, LocalizedError {
    case modelNotFound
    case noVideoTrack
    case noRalliesDetected
    case assetReaderFailed(Error?)
    case exportSessionFailed(String)
    case compositionFailed
    case metadataStoreUnavailable
    case exportCancelled

    // Legacy alias — migrate callers to specific cases
    static let exportFailed = exportSessionFailed("Unknown export failure")

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "AI model not found. Please reinstall the app."
        case .noVideoTrack:
            return "No video track found in the file. The file may be corrupted."
        case .noRalliesDetected:
            return "No volleyball rallies were detected in this video."
        case .assetReaderFailed(let underlying):
            return "Failed to read video: \(underlying?.localizedDescription ?? "unknown error")"
        case .exportSessionFailed(let reason):
            return "Video export failed: \(reason)"
        case .compositionFailed:
            return "Failed to create video composition."
        case .metadataStoreUnavailable:
            return "Unable to save processing results."
        case .exportCancelled:
            return "Export was cancelled."
        }
    }
}

struct ProcessorConfig {
    // Physics gating. Defaults are the tuning the app has always shipped (the
    // former "beach" preset — the only one ever used in production); there is
    // no longer a per-sport config.
    var parabolaMinPoints: Int = 4
    var parabolaMinR2: Double = 0.80
    var minVelocityToConsiderActive: CGFloat = 0.6
    
    /// Time window (seconds) to collect samples for projectile fit (time-based instead of fixed count)
    var projectileWindowSec: Double = 0.7452
    /// Optional gravity band on quadratic curvature 'a' (normalized units); disabled by default
    var useGravityBand: Bool = false
    var gravityMaxA: CGFloat = 0.060

    /// Minimum curvature magnitude |a| for a track to count as a projectile.
    /// A held/carried ball moves in a near-straight line (a ≈ 0), which is a
    /// degenerate parabola that still fits with high R² and a coin-flip curvature
    /// sign — so this magnitude floor is the real discriminator that rejects a
    /// ball sitting in a server's hands. Tune up to reject more held-ball clips.
    var minCurvatureMagnitude: CGFloat = 0.004
    /// Minimum vertical travel (fraction of frame height) over the fit window.
    /// A held ball barely moves vertically; a real arc traverses more.
    var minProjectileSpanY: CGFloat = 0.04

    /// Whether Y increases downward in the coordinate space fed to physics (false for Vision's default bottom-left)
    var yIncreasingDown: Bool = false
    
    // Physics gating (ROI/coherence)
    var maxJumpPerFrame: CGFloat = 0.10   // normalized; reject if center jumps >10% per frame
    var roiYRadius: CGFloat = 0.06        // normalized; last Y must be within ±6% of predicted path

    /// Minimum YOLO confidence for a "volleyball" detection to be kept.
    /// Lower it to surface marginal detections (more recall, more noise),
    /// raise it to keep only confident hits. Default mirrors the historical
    /// hard-coded threshold in YOLODetector.
    var detectionConfidence: Double = 0.6021

    /// Letterbox frames into the model (`.scaleFit`) instead of stretching them
    /// (`.scaleFill`). Preserves aspect ratio so the ball stays round, matching
    /// YOLO training preprocessing — can recover confidence on non-square / 0.5x
    /// ultrawide footage. Off by default; A/B it in RallyLab before flipping.
    /// Ignored when `adaptiveLetterbox` is on.
    var useScaleFitLetterbox: Bool = false

    /// Auto-pick scaleFit vs scaleFill per frame from the source aspect ratio:
    /// letterbox for portrait / ultrawide (where scaleFill squishes the ball into an
    /// ellipse and the landscape-trained model fails), stretch for normal landscape
    /// / near-square. On by default — fixes handheld portrait footage with no
    /// regression to existing landscape clips. Overrides useScaleFitLetterbox.
    var adaptiveLetterbox: Bool = true
    var adaptiveLetterboxWideRatio: CGFloat = 2.0

    // Tracking association
    /// Minimum track age (frames) before it can influence physics gating
    var minTrackAgeForPhysics: Int = 5

    /// Frame stride used while a ball is actively tracked: 1 = process every
    /// frame (densest sampling for the parabola fit), 2 = every other, etc.
    /// Higher saves compute during rallies but under-samples the gate's fit
    /// window and can make the projectile decision flicker. (tuned in RallyLab)
    var activeTrackingStride: Int = 2

    // MARK: - Kalman Filter Configuration

    /// Process noise for position (how much position changes unexpectedly)
    var kalmanProcessNoisePosition: CGFloat = 0.0003
    /// Process noise for velocity (how much velocity changes between frames)
    var kalmanProcessNoiseVelocity: CGFloat = 0.003
    /// Measurement noise (detection uncertainty from YOLO)
    var kalmanMeasurementNoise: CGFloat = 0.01
    /// Initial position uncertainty
    var kalmanInitialPositionUncertainty: CGFloat = 0.05
    /// Initial velocity uncertainty
    var kalmanInitialVelocityUncertainty: CGFloat = 0.1

    // Rally detection (tuned in RallyLab 2026-06-14)
    var startBuffer: Double = 0.1685
    var endTimeout: Double = 0.3978

    /// Sky-ball grace: when the ball was last seen above this normalized height
    /// (Vision coords, 1.0 = top of frame), it likely left the top of view on a
    /// high arc, so the rally is kept alive for `skyBallTimeout` instead of the
    /// normal no-ball timeout, giving it time to come back down.
    var skyBallTopThreshold: CGFloat = 0.85
    var skyBallTimeout: Double = 2.0
    /// Number of consecutive non-projectile frames allowed before resetting projRunStart.
    /// Prevents a single dropped detection from restarting the start-buffer clock.
    var projDropGracePeriod: Int = 5

    // Export trimming (tuned in RallyLab 2026-06-14)
    var preroll: Double = 2.0
    var postroll: Double = 0.5
    var minGapToMerge: Double = 1.3513
    var minSegmentLength: Double = 2.6131

    // MARK: - Movement Classification (Issue #21)
    
    /// Movement classifier confidence thresholds
    var movementClassifierEnabled: Bool = true
    var minClassificationConfidence: Double = 0.7

    /// Gravity-signature (direction-aligned acceleration) floor used by the rally gate's
    /// supported-ball veto. Only applied to FLAT windows (vertical-motion score below
    /// maxVerticalMotionForRolling) so it can't veto an arcing serve/rally whose
    /// instantaneous signature dips at the impulsive start or a mid-rally contact. Free
    /// flight scores high (synthetic ~0.84–1.0); a low, supported ball scores ~0.0–0.1.
    /// Used only when movementClassifierEnabled is true.
    var minGravitySignature: Double = 0.3
    
    /// Airborne detection parameters
    var airbornePhysicsThreshold: Double = 0.7
    var minAccelerationPattern: Double = 0.6
    var minSmoothnessForAirborne: Double = 0.6
    
    /// Carried/Rolling detection parameters
    var maxVerticalMotionForRolling: Double = 0.3
    var minSmoothnessForRolling: Double = 0.7
    var maxAccelerationForRolling: Double = 0.4
    var minInconsistencyForCarried: Double = 0.6
    var maxSmoothnessForCarried: Double = 0.4

    /// Reference curvature for the gravity signature: the fitted parabola's |a|
    /// (its vertical-acceleration term) at which gravity reads ~1.0. Computed
    /// from a least-squares fit (robust), not noisy frame-to-frame acceleration.
    /// Lower = clean arcs saturate to full gravity sooner; tune so real arcs read
    /// high and straight/carried paths (a≈0) read low.
    var gravityReferenceCurvature: Double = 0.02

    /// When true, the rally gate also vetoes any track the movement classifier
    /// labels `.carried` (jumpy / inconsistent motion — e.g. a player picking up
    /// a ball), not just `.rolling` or the flat+no-gravity case.
    /// (enabled in RallyLab/app for pickup-rejection testing 2026-06-14)
    var vetoCarriedMovement: Bool = true

    /// When true, the gate runs its checks on the Kalman-FILTERED track positions
    /// instead of the raw detection centers, so single-frame detection jitter
    /// doesn't skew the jump/ROI/curvature checks. (tuned on in RallyLab 2026-06-14)
    var useSmoothedTrack: Bool = true

    // MARK: - Multi-track trajectory selection
    /// With multiple courts, several balls are tracked at once. The rally follows
    /// the highest-scoring *valid* trajectory (quality-first). These tune the
    /// tiebreakers that pick the main-court ball when arcs are close in quality.

    /// How much a track's relative ball size (bigger = closer = main court) adds to
    /// its selection score. Small, so it only decides near-ties — a clearly better
    /// (even distant) arc still wins. 0 = ignore size.
    var trajectorySizeTiebreak: Double = 0.10
    /// Hysteresis margin: keep the currently-selected trajectory unless another
    /// track beats its score by more than this, to stop the rally flickering
    /// between courts frame to frame.
    var trajectorySelectionStickiness: Double = 0.10

    /// Hard size gate: drop a fresh track whose ball side-length (√area) is below
    /// this fraction of the BIGGEST fresh ball's — a far / other-court ball, which
    /// is smaller because it's farther from the camera. The biggest ball always
    /// survives (ratio 1.0). 1.0 = keep only the biggest; 0 = disable filtering.
    /// Unlike `trajectorySizeTiebreak` (a soft score nudge), this excludes a small
    /// ball from selection entirely even if it traces a clean arc.
    var multiCourtSizeGateEnabled: Bool = true
    var multiCourtMinSizeRatio: Double = 0.5
    /// Absolute minimum ball size (mean bbox side length √area, normalized) for a
    /// track to drive the rally — independent of the other balls present. A back /
    /// other-field ball is physically small in frame; this rejects it even when it's
    /// the only ball on screen (which the relative ratio above can't). 0 = off; tune
    /// up just under this court's smallest real ball.
    var multiCourtMinBallSize: CGFloat = 0.0
    /// Spatial lock: once a rally is locked to a court, reject candidates whose
    /// current position is more than this normalized Euclidean distance from the
    /// selected ball — keeps the rally on one court. Only applies while the
    /// selected track is still live; if it disappears the lock releases and
    /// re-selection is free anywhere.
    var multiCourtSpatialLockEnabled: Bool = true
    var multiCourtMaxLateralDistance: CGFloat = 0.25

    // MARK: - Off-court rejection (net horizontal extent)
    /// Reject detections whose center falls outside the net's horizontal span (the
    /// posts define THIS court's width) plus `offCourtMarginX`. A ball on an
    /// adjacent court is laterally beyond the posts, so this drops it before it can
    /// form a track or get pulled into the rally trajectory. Needs net detection;
    /// skipped if no net is found. The strongest discriminator for "another court".
    var enableOffCourtRejection: Bool = true
    /// Slack beyond each net post (fraction of frame width) before a detection is
    /// treated as off-court — allows a wide serve/ball that drifts just past a post.
    var offCourtMarginX: CGFloat = 0.05

    // MARK: - Above-net requirement (multi-contact rallies)
    /// A rally with MULTIPLE ball contacts (≥2 arcs) must put the ball above this
    /// net's top edge (`net.box.maxY`) at least once — a real multi-touch rally on
    /// this court sends the ball over the net, while a background/other-court rally
    /// stays low and never clears this net's top in the frame. SINGLE-trajectory
    /// events (one arc, e.g. a missed far-side serve that never makes it over) are
    /// EXEMPT, since a lone contact legitimately may not clear the net. Segment-level
    /// (counts arcs across the rally), so it never rejects the low digs/passes within
    /// a real rally. Needs net detection.
    var enableAboveNetRequirement: Bool = true
    /// Leniency below the net top that still counts as "cleared" (fraction of frame
    /// height). Larger = more forgiving. The ball must peak above `net.box.maxY -
    /// aboveNetMarginY` on some arc for a multi-contact rally to be kept.
    var aboveNetMarginY: CGFloat = 0.0
    /// Minimum up-then-down amplitude (fraction of frame height) for a peak to count
    /// as a distinct arc/contact — filters tracking jitter so noise isn't read as
    /// extra contacts. Two real arcs ⇒ a multi-contact rally subject to the rule.
    var aboveNetArcProminence: CGFloat = 0.03

    // MARK: - Under-net rejection
    /// Trash a trajectory whose highest point never rises above the net's bottom
    /// edge (`net.box.minY`): a ball rolled or carried along the ground to the other
    /// side never arcs over the net, but its low, near-flat path can otherwise pass
    /// the physics gate. Needs net detection; skipped if no net is found.
    var enableUnderNetRejection: Bool = true
    /// Buffer below the net bottom before trashing — a trajectory must peak below
    /// `net.box.minY - underNetMarginY` to be rejected (avoids nipping low real digs).
    var underNetMarginY: CGFloat = 0.02
    /// Number of processed frames whose net detections are medianed into the fixed
    /// per-video net box.
    var netSampleFrameCount: Int = 8
    /// Minimum confidence for a net detection to be sampled.
    var netDetectionConfidence: Float = 0.5
    /// Letterbox (`.scaleFit`) the net detector's input. Off = `.scaleFill` (stretch),
    /// which the net model was trained on and yields a tighter box.
    var netUseScaleFitLetterbox: Bool = false
    /// Each track owns a spatial association ROI of radius `ballSize × this`
    /// (ballSize = the detection's mean bbox side length) around its predicted
    /// position: a detection inside is matched to the track, one outside starts
    /// its own track — that's how a ball on another court stays separate. This is
    /// the actual association gate AND what RallyLab draws, so they always agree.
    /// Bigger = more forgiving association (fast balls, sparse detection) but
    /// nearby courts can merge; too small = ID churn when a ball moves quickly.
    var trajectoryRoiScale: Double = 3.0

    /// When true, reject a track that "doubles back" — makes a meaningful sideways
    /// excursion but returns near its horizontal start (a pickup/scoop loop). A
    /// real ball in play travels across; a loop comes back. Catches loops the
    /// short-window parabola checks can't see, regardless of the movement class.
    /// (enabled in RallyLab/app for pickup-rejection testing 2026-06-14)
    var enableLoopRejection: Bool = true
    /// Lookback (seconds) over which the doubling-back is measured — long enough
    /// to span a full pickup loop.
    var loopCheckWindowSec: Double = 1.0
    /// Reject when net horizontal displacement ≤ this fraction of the horizontal
    /// excursion (i.e. the ball returned at least this far back). Lower = stricter.
    var loopReturnRatio: Double = 0.5
    /// Minimum horizontal excursion (fraction of frame width) before the loop
    /// check applies — keeps it from flagging near-vertical tosses or tiny motion.
    var loopMinExcursion: Double = 0.05

    // MARK: - Rally-score verdict (per-segment confidence gate)
    /// When true, each decided rally is scored by `RallyScorer` (serve depth-trend +
    /// court travel + ball continuity + size dynamics) and dropped if its score is
    /// below `rallyScoreMinConfidence`. This is the per-segment verdict that replaces
    /// dense per-frame physics vetoes with one interpretable confidence. Off by
    /// default; validate the threshold against labeled F1 in RallyLab before enabling.
    var enableRallyScoreGate: Bool = false
    /// Minimum rally-score (0…1) to keep a rally when the gate is on. Higher = stricter
    /// (drops more borderline/false rallies, risks dropping weak real ones).
    var rallyScoreMinConfidence: Double = 0.45
    /// Feature weights for the rally score (need not sum to 1; the score normalizes
    /// by total weight). Shared by the gate and RallyLab's display so they agree.
    var rallyScoreServeWeight: Double = 0.40
    var rallyScoreTravelWeight: Double = 0.25
    var rallyScoreContinuityWeight: Double = 0.20
    var rallyScoreSizeWeight: Double = 0.15

    // MARK: - Metrics Collection (Issue #23)

    /// Metrics collection toggles
    var enableMetricsCollection: Bool = false  // Default off for production
    var metricsCollectionSamplingRate: Double = 0.1  // 10% sampling

    // MARK: - Memory Management (Issue #25)

    /// Memory management for large video processing
    var enableMemoryLimits: Bool = true
    var maxTrajectoryDataEntries: Int = 500
    var maxClassificationEntries: Int = 1000
    var maxPhysicsValidationEntries: Int = 2000
    var maxTrackPositions: Int = 100
    var maxDebugTrajectoryPoints: Int = 1000
    var maxDebugQualityScores: Int = 500
    var maxDebugClassificationResults: Int = 500
    var maxDebugPhysicsValidation: Int = 500
    var maxDebugPerformanceMetrics: Int = 200

    // MARK: - Validation & Safety
    
    /// Parameter validation
    func validate() throws {
        // Classification confidence validation
        guard minClassificationConfidence >= 0.0 && minClassificationConfidence <= 1.0 else {
            throw ConfigurationError.invalidParameter("minClassificationConfidence must be between 0.0 and 1.0")
        }
        
        // Sampling rate validation
        guard metricsCollectionSamplingRate >= 0.0 && metricsCollectionSamplingRate <= 1.0 else {
            throw ConfigurationError.invalidParameter("metricsCollectionSamplingRate must be between 0.0 and 1.0")
        }

        // Memory management validation
        guard maxTrajectoryDataEntries > 0 && maxTrajectoryDataEntries <= 10000 else {
            throw ConfigurationError.invalidParameter("maxTrajectoryDataEntries must be between 1 and 10000")
        }
        guard maxClassificationEntries > 0 && maxClassificationEntries <= 10000 else {
            throw ConfigurationError.invalidParameter("maxClassificationEntries must be between 1 and 10000")
        }
        guard maxPhysicsValidationEntries > 0 && maxPhysicsValidationEntries <= 10000 else {
            throw ConfigurationError.invalidParameter("maxPhysicsValidationEntries must be between 1 and 10000")
        }
        guard maxTrackPositions > 0 && maxTrackPositions <= 1000 else {
            throw ConfigurationError.invalidParameter("maxTrackPositions must be between 1 and 1000")
        }
    }
    
    /// Reset to default values (for testing/optimization)
    mutating func resetToDefaults() {
        self = ProcessorConfig()
    }
    
    /// Create a copy with modified parameters (for optimization testing)
    func withModifications(_ modifications: [String: Any]) -> ProcessorConfig {
        var config = self
        
        for (key, value) in modifications {
            switch key {
            case "minClassificationConfidence": config.minClassificationConfidence = value as? Double ?? config.minClassificationConfidence
            case "airbornePhysicsThreshold": config.airbornePhysicsThreshold = value as? Double ?? config.airbornePhysicsThreshold
            case "enableMetricsCollection": config.enableMetricsCollection = value as? Bool ?? config.enableMetricsCollection
            case "metricsCollectionSamplingRate": config.metricsCollectionSamplingRate = value as? Double ?? config.metricsCollectionSamplingRate
            default:
                break  // Ignore unknown parameters
            }
        }
        
        return config
    }
}

// MARK: - Configuration Errors

enum ConfigurationError: Error, LocalizedError {
    case invalidParameter(String)
    case incompatibleSettings(String)
    case validationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidParameter(let message):
            return "Invalid parameter: \(message)"
        case .incompatibleSettings(let message):
            return "Incompatible settings: \(message)"
        case .validationFailed(let message):
            return "Validation failed: \(message)"
        }
    }
}
