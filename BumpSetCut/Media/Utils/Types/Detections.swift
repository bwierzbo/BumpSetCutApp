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
    // Physics gating
    var parabolaMinPoints: Int = 6
    var parabolaMinR2: Double = 0.9
    var accelConsistencyMaxStd: Double = 2.0
    var minVelocityToConsiderActive: CGFloat = 0.5
    
    // Rally detection
    var startBuffer: Double = 0.5
    var endTimeout: Double = 2.0
    
    // Export trimming
    var preroll: Double = 0.5
    var postroll: Double = 0.5
    var minGapToMerge: Double = 0.3
    var minSegmentLength: Double = 0.5
}
