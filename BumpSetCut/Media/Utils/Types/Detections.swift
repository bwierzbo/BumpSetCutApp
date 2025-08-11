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
}
