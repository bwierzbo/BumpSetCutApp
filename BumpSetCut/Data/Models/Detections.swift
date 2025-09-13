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

enum ProcessingError: Error {
    case modelNotFound
    case exportFailed
    case exportCancelled
}

struct ProcessorConfig {
    // Physics gating (tighter)
    var parabolaMinPoints: Int = 8
    var parabolaMinR2: Double = 0.85
    var accelConsistencyMaxStd: Double = 1.0
    var minVelocityToConsiderActive: CGFloat = 0.6
    
    /// Time window (seconds) to collect samples for projectile fit (time-based instead of fixed count)
    var projectileWindowSec: Double = 0.45
    /// Optional gravity band on quadratic curvature 'a' (normalized units); disabled by default
    var useGravityBand: Bool = false
    var gravityMinA: CGFloat = 0.002
    var gravityMaxA: CGFloat = 0.060

    /// Whether Y increases downward in the coordinate space fed to physics (false for Vision's default bottom-left)
    var yIncreasingDown: Bool = false
    
    // Physics gating (ROI/coherence)
    var maxJumpPerFrame: CGFloat = 0.08   // normalized; reject if center jumps >8% per frame
    var roiYRadius: CGFloat = 0.04        // normalized; last Y must be within ±4% of predicted path

    // Tracking association
    /// Gate radius for associating detections to existing tracks (normalized units)
    var trackGateRadius: CGFloat = 0.05
    /// Minimum track age (frames) before it can influence physics gating
    var minTrackAgeForPhysics: Int = 5
    
    // Rally detection
    var startBuffer: Double = 0.3
    var endTimeout: Double = 1.0
    
    // Export trimming
    var preroll: Double = 2.0
    var postroll: Double = 0.5
    var minGapToMerge: Double = 0.3
    var minSegmentLength: Double = 0.5
    
    // MARK: - Enhanced Physics Validation (Issue #21)
    
    /// Enhanced physics validation toggle
    var enableEnhancedPhysics: Bool = false  // Temporarily disabled to fix processing issues
    
    /// Enhanced R² correlation thresholds for trajectory quality
    var enhancedMinR2: Double = 0.85
    var excellentR2Threshold: Double = 0.95
    var goodR2Threshold: Double = 0.85
    var acceptableR2Threshold: Double = 0.70
    
    /// Physics constraint parameters
    var enablePhysicsConstraints: Bool = true
    var maxAccelerationDeviation: Double = 2.0
    var velocityConsistencyThreshold: Double = 0.5
    var trajectorySmoothnessThreshold: Double = 0.6
    
    // MARK: - Movement Classification (Issue #21)
    
    /// Movement classifier confidence thresholds
    var movementClassifierEnabled: Bool = true
    var minClassificationConfidence: Double = 0.7
    
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
