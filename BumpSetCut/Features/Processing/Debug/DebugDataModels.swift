//
//  DebugDataModels.swift
//  BumpSetCut
//
//  Created for Debug Visualization Tools - Issue #26
//

import Foundation
import CoreGraphics
import CoreMedia

// MARK: - Debug Configuration

struct DebugConfiguration: Codable {
    var visualizationMode: VisualizationMode = .trajectory2D
    var showQualityScores: Bool = true
    var showClassificationLabels: Bool = true
    var showPhysicsValidation: Bool = true
    var showPerformanceOverlay: Bool = false
    var maxTrajectoryHistory: Int = 100
    var updateFrequencyHz: Double = 30.0
    var exportFormat: ExportFormat = .json
    
    enum VisualizationMode: String, CaseIterable, Codable {
        case trajectory2D = "2d_trajectory"
        case trajectory3D = "3d_trajectory"  
        case qualityHeatmap = "quality_heatmap"
        case performanceDashboard = "performance_dashboard"
        case parameterTuning = "parameter_tuning"
        
        var displayName: String {
            switch self {
            case .trajectory2D: return "2D Trajectory"
            case .trajectory3D: return "3D Trajectory"
            case .qualityHeatmap: return "Quality Heatmap"
            case .performanceDashboard: return "Performance Dashboard"
            case .parameterTuning: return "Parameter Tuning"
            }
        }
    }
    
    enum ExportFormat: String, CaseIterable, Codable {
        case json = "json"
        case csv = "csv"
        case binary = "binary"
    }
}

// MARK: - Debug Session

struct DebugSession: Codable, Identifiable {
    let id: UUID
    let name: String
    let startTime: Date
    var endTime: Date?
    let config: DebugConfiguration
    var trajectoryCount: Int = 0
    var averageQualityScore: Double = 0
    
    var duration: TimeInterval {
        return (endTime ?? Date()).timeIntervalSince(startTime)
    }
}

// MARK: - Trajectory Debug Info

struct TrajectoryDebugInfo: Identifiable, Codable {
    let id: UUID
    let startTime: Date
    let endTime: Date?
    let pointCount: Int
    let averageQuality: Double
    let movementType: MovementType
    let confidence: Double
    let physicsValid: Bool
    let rSquared: Double
}

// MARK: - Visualization Data Points

struct TrajectoryPoint: Identifiable, Codable {
    let id: UUID  // Trajectory ID
    let index: Int
    let position: CGPoint
    let timestamp: CMTime
    let velocity: Double
    let acceleration: Double
    
    // For Codable compliance
    private enum CodingKeys: String, CodingKey {
        case id, index, position, timestamp, velocity, acceleration
    }
    
    init(id: UUID, index: Int, position: CGPoint, timestamp: CMTime, velocity: Double, acceleration: Double) {
        self.id = id
        self.index = index
        self.position = position
        self.timestamp = timestamp
        self.velocity = velocity
        self.acceleration = acceleration
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        index = try container.decode(Int.self, forKey: .index)
        position = try container.decode(CGPoint.self, forKey: .position)
        velocity = try container.decode(Double.self, forKey: .velocity)
        acceleration = try container.decode(Double.self, forKey: .acceleration)
        
        let timeValue = try container.decode(Double.self, forKey: .timestamp)
        timestamp = CMTimeMakeWithSeconds(timeValue, preferredTimescale: 600)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(index, forKey: .index)
        try container.encode(position, forKey: .position)
        try container.encode(CMTimeGetSeconds(timestamp), forKey: .timestamp)
        try container.encode(velocity, forKey: .velocity)
        try container.encode(acceleration, forKey: .acceleration)
    }
}

struct QualityScore: Identifiable, Codable {
    let id: UUID
    let trajectoryId: UUID
    let timestamp: Date
    let smoothness: Double
    let consistency: Double
    let physicsScore: Double
    let overall: Double
    
    init(trajectoryId: UUID, timestamp: Date, smoothness: Double, consistency: Double, physicsScore: Double, overall: Double) {
        self.id = UUID()
        self.trajectoryId = trajectoryId
        self.timestamp = timestamp
        self.smoothness = smoothness
        self.consistency = consistency
        self.physicsScore = physicsScore
        self.overall = overall
    }
}

struct ClassificationResult: Identifiable, Codable {
    let id: UUID
    let trajectoryId: UUID
    let timestamp: Date
    let movementType: MovementType
    let confidence: Double
    let details: ClassificationDetails
    
    // Custom coding for ClassificationDetails
    private enum CodingKeys: String, CodingKey {
        case id, trajectoryId, timestamp, movementType, confidence, details
    }
    
    init(trajectoryId: UUID, timestamp: Date, movementType: MovementType, confidence: Double, details: ClassificationDetails) {
        self.id = UUID()
        self.trajectoryId = trajectoryId
        self.timestamp = timestamp
        self.movementType = movementType
        self.confidence = confidence
        self.details = details
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        trajectoryId = try container.decode(UUID.self, forKey: .trajectoryId)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        movementType = try container.decode(MovementType.self, forKey: .movementType)
        confidence = try container.decode(Double.self, forKey: .confidence)
        
        // Simplified ClassificationDetails for debugging
        let detailsDict = try container.decode([String: Double].self, forKey: .details)
        details = ClassificationDetails(
            velocityConsistency: detailsDict["velocityConsistency"] ?? 0,
            accelerationPattern: detailsDict["accelerationPattern"] ?? 0,
            smoothnessScore: detailsDict["smoothnessScore"] ?? 0,
            verticalMotionScore: detailsDict["verticalMotionScore"] ?? 0,
            timeSpan: detailsDict["timeSpan"] ?? 0
        )
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(trajectoryId, forKey: .trajectoryId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(movementType, forKey: .movementType)
        try container.encode(confidence, forKey: .confidence)
        
        let detailsDict: [String: Double] = [
            "velocityConsistency": details.velocityConsistency,
            "accelerationPattern": details.accelerationPattern,
            "smoothnessScore": details.smoothnessScore,
            "verticalMotionScore": details.verticalMotionScore,
            "timeSpan": details.timeSpan
        ]
        try container.encode(detailsDict, forKey: .details)
    }
}

struct PhysicsValidation: Identifiable, Codable {
    let id: UUID
    let trajectoryId: UUID
    let timestamp: Date
    let rSquared: Double
    let curvatureValid: Bool
    let accelerationValid: Bool
    let velocityConsistent: Bool
    let positionJumpsValid: Bool
    let overallValid: Bool
    
    init(trajectoryId: UUID, timestamp: Date, rSquared: Double, curvatureValid: Bool, accelerationValid: Bool, velocityConsistent: Bool, positionJumpsValid: Bool, overallValid: Bool) {
        self.id = UUID()
        self.trajectoryId = trajectoryId
        self.timestamp = timestamp
        self.rSquared = rSquared
        self.curvatureValid = curvatureValid
        self.accelerationValid = accelerationValid
        self.velocityConsistent = velocityConsistent
        self.positionJumpsValid = positionJumpsValid
        self.overallValid = overallValid
    }
}

struct PerformanceMetric: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let framesPerSecond: Double?
    let memoryUsageMB: Double?
    let cpuUsagePercent: Double?
    let processingOverheadPercent: Double?
    let detectionLatencyMs: Double?
    
    init(timestamp: Date, framesPerSecond: Double? = nil, memoryUsageMB: Double? = nil, cpuUsagePercent: Double? = nil, processingOverheadPercent: Double? = nil, detectionLatencyMs: Double? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.framesPerSecond = framesPerSecond
        self.memoryUsageMB = memoryUsageMB
        self.cpuUsagePercent = cpuUsagePercent
        self.processingOverheadPercent = processingOverheadPercent
        self.detectionLatencyMs = detectionLatencyMs
    }
}

// MARK: - Export Data

struct VisualizationData: Codable {
    let trajectoryPoints: [TrajectoryPoint]
    let qualityScores: [QualityScore]
    let classificationResults: [ClassificationResult]
    let physicsValidation: [PhysicsValidation]
    let performanceMetrics: [PerformanceMetric]
    let config: DebugConfiguration
    let exportTime: Date
}

// MARK: - Real-time Analysis

struct RealtimeAnalysis: Codable {
    let activeTrajectories: Int
    let averageQuality: Double
    let processingFPS: Double
    let memoryUsage: Double
    let detectionAccuracy: Double
    
    var status: AnalysisStatus {
        if processingFPS < 15 || memoryUsage > 500 {
            return .warning
        } else if detectionAccuracy < 0.7 {
            return .poor
        } else {
            return .good
        }
    }
    
    enum AnalysisStatus: String, Codable {
        case good = "good"
        case warning = "warning"
        case poor = "poor"
    }
}

// MARK: - Debug Interface Data

struct DebugInterfaceData {
    let trajectoryCount: Int
    let averageQualityScore: Double
    let classificationBreakdown: [MovementType: Int]
    let physicsValidationStats: PhysicsValidationStats
    let performanceSummary: PerformanceSummary
    let sessions: [DebugSession]
}

struct PhysicsValidationStats: Codable {
    let totalValidations: Int
    let validCount: Int
    let validPercentage: Double
    let averageRSquared: Double
    
    init(totalValidations: Int = 0, validCount: Int = 0, validPercentage: Double = 0, averageRSquared: Double = 0) {
        self.totalValidations = totalValidations
        self.validCount = validCount
        self.validPercentage = validPercentage
        self.averageRSquared = averageRSquared
    }
}

struct PerformanceSummary: Codable {
    let averageFPS: Double
    let averageMemoryMB: Double
    let processingOverhead: Double
    
    init(averageFPS: Double = 0, averageMemoryMB: Double = 0, processingOverhead: Double = 0) {
        self.averageFPS = averageFPS
        self.averageMemoryMB = averageMemoryMB
        self.processingOverhead = processingOverhead
    }
}

// MARK: - Parameter Tuning

struct ParameterTuningResult: Codable {
    let success: Bool
    let message: String
    let accuracyChange: Double?
    let performanceImpact: Double?
    let recommendations: [String]
    
    init(success: Bool, message: String, accuracyChange: Double? = nil, performanceImpact: Double? = nil, recommendations: [String] = []) {
        self.success = success
        self.message = message
        self.accuracyChange = accuracyChange
        self.performanceImpact = performanceImpact
        self.recommendations = recommendations
    }
}

// MARK: - Physics Validation Result (Mock for Debug)

struct PhysicsValidationResult {
    let isValid: Bool
    let rSquared: Double
    let curvatureDirectionValid: Bool
    let accelerationMagnitudeValid: Bool
    let velocityConsistencyValid: Bool
    let positionJumpsValid: Bool
    let confidenceLevel: Double
}