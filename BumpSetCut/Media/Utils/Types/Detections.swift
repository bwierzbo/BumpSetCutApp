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
    var parabolaMinR2: Double = 0.95
    var accelConsistencyMaxStd: Double = 1.0
    var minVelocityToConsiderActive: CGFloat = 0.6
    
    // Physics gating (ROI/coherence)
    var maxJumpPerFrame: CGFloat = 0.08   // normalized; reject if center jumps >8% per frame
    var roiYRadius: CGFloat = 0.04        // normalized; last Y must be within ±4% of predicted path
    
    // Rally detection
    var startBuffer: Double = 0.3
    var endTimeout: Double = 1.0
    
    // Export trimming
    var preroll: Double = 0.5
    var postroll: Double = 0.5
    var minGapToMerge: Double = 0.3
    var minSegmentLength: Double = 0.5
}
