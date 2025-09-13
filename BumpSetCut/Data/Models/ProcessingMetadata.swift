//
//  ProcessingMetadata.swift
//  BumpSetCut
//
//  Created for Metadata Video Processing - Task 001
//

import Foundation
import CoreGraphics
import CoreMedia

// MARK: - Processing Metadata

struct ProcessingMetadata: Codable, Identifiable {
    let id: UUID
    let videoId: UUID
    let processingVersion: String
    let processingDate: Date
    let processingConfig: ProcessorConfig

    // Core Processing Results
    let rallySegments: [RallySegment]
    let processingStats: ProcessingStats
    let qualityMetrics: QualityMetrics

    // Enhanced Data (optional for backwards compatibility)
    let trajectoryData: [TrajectoryData]?
    let classificationResults: [ClassificationResult]?
    let physicsValidation: [PhysicsValidationData]?

    // Performance Data
    let performanceMetrics: PerformanceData

    init(videoId: UUID,
         processingConfig: ProcessorConfig,
         rallySegments: [RallySegment],
         processingStats: ProcessingStats,
         qualityMetrics: QualityMetrics,
         trajectoryData: [TrajectoryData]? = nil,
         classificationResults: [ClassificationResult]? = nil,
         physicsValidation: [PhysicsValidationData]? = nil,
         performanceMetrics: PerformanceData) {
        self.id = UUID()
        self.videoId = videoId
        self.processingVersion = "1.0"
        self.processingDate = Date()
        self.processingConfig = processingConfig
        self.rallySegments = rallySegments
        self.processingStats = processingStats
        self.qualityMetrics = qualityMetrics
        self.trajectoryData = trajectoryData
        self.classificationResults = classificationResults
        self.physicsValidation = physicsValidation
        self.performanceMetrics = performanceMetrics
    }

    // Custom decoder for backwards compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        videoId = try container.decode(UUID.self, forKey: .videoId)
        processingVersion = try container.decodeIfPresent(String.self, forKey: .processingVersion) ?? "1.0"
        processingDate = try container.decode(Date.self, forKey: .processingDate)
        processingConfig = try container.decode(ProcessorConfig.self, forKey: .processingConfig)
        rallySegments = try container.decode([RallySegment].self, forKey: .rallySegments)
        processingStats = try container.decode(ProcessingStats.self, forKey: .processingStats)
        qualityMetrics = try container.decode(QualityMetrics.self, forKey: .qualityMetrics)

        // Optional enhanced data for backwards compatibility
        trajectoryData = try container.decodeIfPresent([TrajectoryData].self, forKey: .trajectoryData)
        classificationResults = try container.decodeIfPresent([ClassificationResult].self, forKey: .classificationResults)
        physicsValidation = try container.decodeIfPresent([PhysicsValidationData].self, forKey: .physicsValidation)
        performanceMetrics = try container.decode(PerformanceData.self, forKey: .performanceMetrics)
    }

    private enum CodingKeys: String, CodingKey {
        case id, videoId, processingVersion, processingDate, processingConfig
        case rallySegments, processingStats, qualityMetrics
        case trajectoryData, classificationResults, physicsValidation
        case performanceMetrics
    }
}

// MARK: - Rally Segment

struct RallySegment: Codable, Identifiable {
    let id: UUID
    let startTime: Double // CMTime converted to seconds
    let endTime: Double   // CMTime converted to seconds
    let confidence: Double
    let quality: Double
    let detectionCount: Int
    let averageTrajectoryLength: Double

    init(startTime: CMTime, endTime: CMTime, confidence: Double, quality: Double, detectionCount: Int, averageTrajectoryLength: Double) {
        self.id = UUID()
        self.startTime = CMTimeGetSeconds(startTime)
        self.endTime = CMTimeGetSeconds(endTime)
        self.confidence = confidence
        self.quality = quality
        self.detectionCount = detectionCount
        self.averageTrajectoryLength = averageTrajectoryLength
    }

    var duration: Double {
        return endTime - startTime
    }

    var startCMTime: CMTime {
        return CMTimeMakeWithSeconds(startTime, preferredTimescale: 600)
    }

    var endCMTime: CMTime {
        return CMTimeMakeWithSeconds(endTime, preferredTimescale: 600)
    }

    var timeRange: CMTimeRange {
        return CMTimeRangeMake(start: startCMTime, duration: CMTimeMakeWithSeconds(duration, preferredTimescale: 600))
    }
}

// MARK: - Processing Statistics

struct ProcessingStats: Codable {
    let totalFrames: Int
    let processedFrames: Int
    let detectionFrames: Int
    let trackingFrames: Int
    let rallyFrames: Int
    let physicsValidFrames: Int

    let totalDetections: Int
    let validTrajectories: Int
    let averageDetectionsPerFrame: Double
    let averageConfidence: Double

    let processingDuration: Double // in seconds
    let framesPerSecond: Double

    var processingCompleteness: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(processedFrames) / Double(totalFrames)
    }

    var detectionRate: Double {
        guard processedFrames > 0 else { return 0 }
        return Double(detectionFrames) / Double(processedFrames)
    }
}

// MARK: - Quality Metrics

struct QualityMetrics: Codable {
    let overallQuality: Double
    let averageRSquared: Double
    let trajectoryConsistency: Double
    let physicsValidationRate: Double
    let movementClassificationAccuracy: Double?

    let confidenceDistribution: ConfidenceDistribution
    let qualityBreakdown: QualityBreakdown

    var qualityLevel: QualityLevel {
        switch overallQuality {
        case 0.9...1.0: return .excellent
        case 0.7..<0.9: return .good
        case 0.5..<0.7: return .acceptable
        default: return .poor
        }
    }

    enum QualityLevel: String, Codable, CaseIterable {
        case excellent = "excellent"
        case good = "good"
        case acceptable = "acceptable"
        case poor = "poor"

        var displayName: String {
            switch self {
            case .excellent: return "Excellent"
            case .good: return "Good"
            case .acceptable: return "Acceptable"
            case .poor: return "Poor"
            }
        }
    }
}

struct ConfidenceDistribution: Codable {
    let high: Int       // confidence >= 0.8
    let medium: Int     // confidence 0.5-0.8
    let low: Int        // confidence < 0.5

    var total: Int {
        return high + medium + low
    }
}

struct QualityBreakdown: Codable {
    let velocityConsistency: Double
    let accelerationPattern: Double
    let smoothnessScore: Double
    let verticalMotionScore: Double
    let overallCoherence: Double
}

// MARK: - Trajectory Data

struct TrajectoryData: Codable, Identifiable {
    let id: UUID
    let startTime: Double
    let endTime: Double
    let points: [TrajectoryPoint]
    let rSquared: Double
    let movementType: MovementType?
    let confidence: Double
    let quality: Double

    var duration: Double {
        return endTime - startTime
    }

    var pointCount: Int {
        return points.count
    }
}

struct TrajectoryPoint: Codable, Identifiable {
    let id: UUID
    let timestamp: Double // CMTime converted to seconds
    let position: CGPoint
    let velocity: Double
    let acceleration: Double
    let confidence: Double

    init(timestamp: CMTime, position: CGPoint, velocity: Double, acceleration: Double, confidence: Double) {
        self.id = UUID()
        self.timestamp = CMTimeGetSeconds(timestamp)
        self.position = position
        self.velocity = velocity
        self.acceleration = acceleration
        self.confidence = confidence
    }

    var cmTime: CMTime {
        return CMTimeMakeWithSeconds(timestamp, preferredTimescale: 600)
    }
}

// MARK: - Classification Result

struct ClassificationResult: Codable, Identifiable {
    let id: UUID
    let trajectoryId: UUID
    let timestamp: Double
    let movementType: MovementType
    let confidence: Double
    let classificationDetails: ClassificationDetails

    init(trajectoryId: UUID, timestamp: CMTime, movementType: MovementType, confidence: Double, classificationDetails: ClassificationDetails) {
        self.id = UUID()
        self.trajectoryId = trajectoryId
        self.timestamp = CMTimeGetSeconds(timestamp)
        self.movementType = movementType
        self.confidence = confidence
        self.classificationDetails = classificationDetails
    }
}

// MARK: - Physics Validation Data

struct PhysicsValidationData: Codable, Identifiable {
    let id: UUID
    let trajectoryId: UUID
    let timestamp: Double
    let isValid: Bool
    let rSquared: Double
    let curvatureValid: Bool
    let accelerationValid: Bool
    let velocityConsistent: Bool
    let positionJumpsValid: Bool
    let confidenceLevel: Double

    init(trajectoryId: UUID, timestamp: CMTime, isValid: Bool, rSquared: Double, curvatureValid: Bool, accelerationValid: Bool, velocityConsistent: Bool, positionJumpsValid: Bool, confidenceLevel: Double) {
        self.id = UUID()
        self.trajectoryId = trajectoryId
        self.timestamp = CMTimeGetSeconds(timestamp)
        self.isValid = isValid
        self.rSquared = rSquared
        self.curvatureValid = curvatureValid
        self.accelerationValid = accelerationValid
        self.velocityConsistent = velocityConsistent
        self.positionJumpsValid = positionJumpsValid
        self.confidenceLevel = confidenceLevel
    }
}

// MARK: - Performance Data

struct PerformanceData: Codable {
    let processingStartTime: Date
    let processingEndTime: Date
    let averageFPS: Double
    let peakMemoryUsageMB: Double
    let averageMemoryUsageMB: Double
    let cpuUsagePercent: Double?
    let processingOverheadPercent: Double
    let detectionLatencyMs: Double?

    var totalDuration: TimeInterval {
        return processingEndTime.timeIntervalSince(processingStartTime)
    }

    var performanceLevel: PerformanceLevel {
        if processingOverheadPercent > 15 || averageFPS < 15 {
            return .poor
        } else if processingOverheadPercent > 8 || averageFPS < 25 {
            return .fair
        } else if processingOverheadPercent > 5 || averageFPS < 35 {
            return .good
        } else {
            return .excellent
        }
    }

    enum PerformanceLevel: String, Codable, CaseIterable {
        case excellent = "excellent"
        case good = "good"
        case fair = "fair"
        case poor = "poor"

        var displayName: String {
            switch self {
            case .excellent: return "Excellent"
            case .good: return "Good"
            case .fair: return "Fair"
            case .poor: return "Poor"
            }
        }
    }
}

// MARK: - Extensions

extension ProcessingMetadata {
    var hasEnhancedData: Bool {
        return trajectoryData != nil || classificationResults != nil || physicsValidation != nil
    }

    var rallyCount: Int {
        return rallySegments.count
    }

    var totalRallyDuration: Double {
        return rallySegments.reduce(0) { $0 + $1.duration }
    }

    var averageRallyDuration: Double {
        guard rallyCount > 0 else { return 0 }
        return totalRallyDuration / Double(rallyCount)
    }

    var storageEstimateKB: Int {
        // Rough estimate for JSON file size
        let baseSize = 2 // Basic metadata
        let rallySize = rallySegments.count * 1 // ~1KB per rally
        let trajectorySize = (trajectoryData?.count ?? 0) * 5 // ~5KB per trajectory
        let enhancedSize = hasEnhancedData ? 10 : 0 // Enhanced data overhead

        return baseSize + rallySize + trajectorySize + enhancedSize
    }
}

// MARK: - Factory Methods

extension ProcessingMetadata {
    static func create(for videoId: UUID,
                      with config: ProcessorConfig,
                      rallySegments: [RallySegment],
                      stats: ProcessingStats,
                      quality: QualityMetrics,
                      performance: PerformanceData) -> ProcessingMetadata {
        return ProcessingMetadata(
            videoId: videoId,
            processingConfig: config,
            rallySegments: rallySegments,
            processingStats: stats,
            qualityMetrics: quality,
            performanceMetrics: performance
        )
    }

    static func createWithEnhancedData(for videoId: UUID,
                                     with config: ProcessorConfig,
                                     rallySegments: [RallySegment],
                                     stats: ProcessingStats,
                                     quality: QualityMetrics,
                                     trajectories: [TrajectoryData],
                                     classifications: [ClassificationResult],
                                     physics: [PhysicsValidationData],
                                     performance: PerformanceData) -> ProcessingMetadata {
        return ProcessingMetadata(
            videoId: videoId,
            processingConfig: config,
            rallySegments: rallySegments,
            processingStats: stats,
            qualityMetrics: quality,
            trajectoryData: trajectories,
            classificationResults: classifications,
            physicsValidation: physics,
            performanceMetrics: performance
        )
    }
}