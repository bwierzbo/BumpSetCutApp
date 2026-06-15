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
    var parabolaMinPoints: Int = 8
    var parabolaMinR2: Double = 0.80
    var accelConsistencyMaxStd: Double = 1.0
    var minVelocityToConsiderActive: CGFloat = 0.6
    
    /// Time window (seconds) to collect samples for projectile fit (time-based instead of fixed count)
    var projectileWindowSec: Double = 0.45
    /// Optional gravity band on quadratic curvature 'a' (normalized units); disabled by default
    var useGravityBand: Bool = false
    var gravityMinA: CGFloat = 0.002
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
    var detectionConfidence: Double = 0.70

    // Tracking association
    /// Gate radius for associating detections to existing tracks (normalized units)
    var trackGateRadius: CGFloat = 0.07
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
    /// Mahalanobis distance threshold for gating (in standard deviations)
    var kalmanGateThresholdSigma: CGFloat = 3.0
    
    // Rally detection (tuned in RallyLab 2026-06-14)
    var startBuffer: Double = 0.2203
    var endTimeout: Double = 1.8142

    /// Sky-ball grace: when the ball was last seen above this normalized height
    /// (Vision coords, 1.0 = top of frame), it likely left the top of view on a
    /// high arc, so the rally is kept alive for `skyBallTimeout` instead of the
    /// normal no-ball timeout, giving it time to come back down.
    var skyBallTopThreshold: CGFloat = 0.85
    var skyBallTimeout: Double = 2.0
    /// Number of consecutive non-projectile frames allowed before resetting projRunStart.
    /// Prevents a single dropped detection from restarting the start-buffer clock.
    var projDropGracePeriod: Int = 3

    // Export trimming (tuned in RallyLab 2026-06-14)
    var preroll: Double = 2.0
    var postroll: Double = 0.5
    var minGapToMerge: Double = 1.6727
    var minSegmentLength: Double = 2.0801
    
    // MARK: - Enhanced Physics Validation (Issue #21)
    
    /// Enhanced physics validation toggle
    var enableEnhancedPhysics: Bool = false  // Temporarily disabled to fix processing issues
    
    /// Enhanced R² correlation thresholds for trajectory quality
    var enhancedMinR2: Double = 0.75
    var excellentR2Threshold: Double = 0.95
    var goodR2Threshold: Double = 0.85
    var acceptableR2Threshold: Double = 0.60
    
    /// Physics constraint parameters
    var enablePhysicsConstraints: Bool = true
    var maxAccelerationDeviation: Double = 2.0
    var velocityConsistencyThreshold: Double = 0.5
    var trajectorySmoothnessThreshold: Double = 0.6
    
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

    /// When true, the rally gate also vetoes any track the movement classifier
    /// labels `.carried` (jumpy / inconsistent motion — e.g. a player picking up
    /// a ball), not just `.rolling` or the flat+no-gravity case.
    /// (enabled in RallyLab/app for pickup-rejection testing 2026-06-14)
    var vetoCarriedMovement: Bool = true

    /// When true, the gate runs its checks on the Kalman-FILTERED track positions
    /// instead of the raw detection centers, so single-frame detection jitter
    /// doesn't skew the jump/ROI/curvature checks. (tuned on in RallyLab 2026-06-14)
    var useSmoothedTrack: Bool = true

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
    
    // MARK: - Quality Scoring (Issue #21)
    
    /// Quality score thresholds
    var enableQualityScoring: Bool = true
    var minQualityScore: Double = 0.6
    var excellentQualityThreshold: Double = 0.8
    var goodQualityThreshold: Double = 0.7
    
    /// Quality scoring weights
    var velocityConsistencyWeight: Double = 0.25
    var accelerationPatternWeight: Double = 0.35
    var smoothnessWeight: Double = 0.25
    var verticalMotionWeight: Double = 0.15
    
    // MARK: - Metrics Collection (Issue #23)
    
    /// Metrics collection toggles
    var enableMetricsCollection: Bool = false  // Default off for production
    var metricsCollectionSamplingRate: Double = 0.1  // 10% sampling
    var enableAccuracyMetrics: Bool = false
    var enablePerformanceMetrics: Bool = true
    
    /// Performance monitoring thresholds
    var maxProcessingOverheadPercent: Double = 5.0
    var performanceAlertThreshold: Double = 10.0

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

    /// Memory pressure detection
    var enableMemoryPressureDetection: Bool = true
    var memoryPressureThresholdMB: Double = 512.0
    var reduceQualityUnderMemoryPressure: Bool = true
    
    // MARK: - Parameter Optimization (Issue #24)
    
    /// Optimization framework settings
    var enableParameterOptimization: Bool = false
    var optimizationMode: String = "disabled"  // "disabled", "grid", "random", "bayesian"
    var maxOptimizationTimeHours: Double = 24.0
    
    /// A/B testing parameters
    var enableABTesting: Bool = false
    var abTestingSplitRatio: Double = 0.5
    var statisticalSignificanceLevel: Double = 0.05
    var minimumSampleSize: Int = 30
    
    // MARK: - Validation & Safety
    
    /// Parameter validation
    func validate() throws {
        // R² thresholds validation
        guard enhancedMinR2 >= 0.0 && enhancedMinR2 <= 1.0 else {
            throw ConfigurationError.invalidParameter("enhancedMinR2 must be between 0.0 and 1.0")
        }
        
        // Classification confidence validation
        guard minClassificationConfidence >= 0.0 && minClassificationConfidence <= 1.0 else {
            throw ConfigurationError.invalidParameter("minClassificationConfidence must be between 0.0 and 1.0")
        }
        
        // Quality score weights must sum approximately to 1.0
        let weightSum = velocityConsistencyWeight + accelerationPatternWeight + smoothnessWeight + verticalMotionWeight
        guard abs(weightSum - 1.0) < 0.01 else {
            throw ConfigurationError.invalidParameter("Quality scoring weights must sum to 1.0")
        }
        
        // Sampling rate validation
        guard metricsCollectionSamplingRate >= 0.0 && metricsCollectionSamplingRate <= 1.0 else {
            throw ConfigurationError.invalidParameter("metricsCollectionSamplingRate must be between 0.0 and 1.0")
        }
        
        // Performance threshold validation
        guard maxProcessingOverheadPercent > 0 && maxProcessingOverheadPercent <= 100 else {
            throw ConfigurationError.invalidParameter("maxProcessingOverheadPercent must be between 0 and 100")
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
        guard memoryPressureThresholdMB > 0 && memoryPressureThresholdMB <= 2048 else {
            throw ConfigurationError.invalidParameter("memoryPressureThresholdMB must be between 1 and 2048")
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
            case "enhancedMinR2": config.enhancedMinR2 = value as? Double ?? config.enhancedMinR2
            case "minClassificationConfidence": config.minClassificationConfidence = value as? Double ?? config.minClassificationConfidence
            case "airbornePhysicsThreshold": config.airbornePhysicsThreshold = value as? Double ?? config.airbornePhysicsThreshold
            case "minQualityScore": config.minQualityScore = value as? Double ?? config.minQualityScore
            case "enableEnhancedPhysics": config.enableEnhancedPhysics = value as? Bool ?? config.enableEnhancedPhysics
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
