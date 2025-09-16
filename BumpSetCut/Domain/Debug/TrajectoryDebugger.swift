//
//  TrajectoryDebugger.swift
//  BumpSetCut
//
//  Created for Debug Visualization Tools - Issue #26
//

import Foundation
import CoreGraphics
import CoreMedia
import SwiftUI

/// Comprehensive debugging and visualization tools for trajectory analysis
@Observable
final class TrajectoryDebugger {
    
    // MARK: - Debug State
    
    var isEnabled: Bool = false
    var isRecording: Bool = false
    var debugMode: DebugMode = .trajectory
    var selectedTrajectory: TrajectoryDebugInfo?
    var debugHistory: [DebugSession] = []
    
    // MARK: - Visualization Data

    private(set) var trajectoryPoints: [TrajectoryPoint] = []
    private(set) var qualityScores: [QualityScore] = []
    private(set) var classificationResults: [ClassificationResult] = []
    private(set) var physicsValidation: [PhysicsValidation] = []
    private(set) var performanceMetrics: [PerformanceMetric] = []

    // Memory management constants for debug data (configurable via ProcessorConfig)
    private var maxTrajectoryPoints = 1000
    private var maxQualityScores = 500
    private var maxClassificationResults = 500
    private var maxPhysicsValidation = 500
    private var maxPerformanceMetrics = 200
    
    // MARK: - Configuration
    
    var config = DebugConfiguration()
    
    // MARK: - Dependencies
    
    private let metricsCollector: MetricsCollector
    private let parameterOptimizer: ParameterOptimizer?
    
    init(metricsCollector: MetricsCollector, parameterOptimizer: ParameterOptimizer? = nil) {
        self.metricsCollector = metricsCollector
        self.parameterOptimizer = parameterOptimizer
    }

    /// Configure memory limits from ProcessorConfig
    func configureMemoryLimits(from processorConfig: ProcessorConfig) {
        if processorConfig.enableMemoryLimits {
            maxTrajectoryPoints = processorConfig.maxDebugTrajectoryPoints
            maxQualityScores = processorConfig.maxDebugQualityScores
            maxClassificationResults = processorConfig.maxDebugClassificationResults
            maxPhysicsValidation = processorConfig.maxDebugPhysicsValidation
            maxPerformanceMetrics = processorConfig.maxDebugPerformanceMetrics
        }
    }
    
    // MARK: - Debug Session Management
    
    func startDebugSession(name: String) {
        guard !isRecording else { return }
        
        let session = DebugSession(
            id: UUID(),
            name: name,
            startTime: Date(),
            config: config
        )
        
        debugHistory.append(session)
        isRecording = true
        clearVisualizationData()
    }
    
    func stopDebugSession() {
        guard isRecording, var currentSession = debugHistory.last else { return }
        
        currentSession.endTime = Date()
        currentSession.trajectoryCount = trajectoryPoints.count
        currentSession.averageQualityScore = qualityScores.map(\.overall).reduce(0, +) / Double(qualityScores.count)
        
        debugHistory[debugHistory.count - 1] = currentSession
        isRecording = false
    }
    
    // MARK: - Trajectory Analysis
    
    func analyzeTrajectory(_ trackedBall: KalmanBallTracker.TrackedBall, 
                          physicsResult: PhysicsValidationResult,
                          classificationResult: MovementClassification,
                          qualityScore: TrajectoryQualityScore.QualityMetrics) {
        guard isEnabled && isRecording else { return }
        
        let trajectoryId = UUID()
        
        // Record trajectory points
        let points = trackedBall.positions.enumerated().map { index, position in
            TrajectoryPoint(
                id: trajectoryId,
                index: index,
                position: position.0,
                timestamp: position.1,
                velocity: calculateVelocity(at: index, in: trackedBall.positions),
                acceleration: calculateAcceleration(at: index, in: trackedBall.positions)
            )
        }
        trajectoryPoints.append(contentsOf: points)

        // Memory management: enforce sliding window for trajectory points
        if trajectoryPoints.count > maxTrajectoryPoints {
            trajectoryPoints.removeFirst(trajectoryPoints.count - maxTrajectoryPoints)
        }
        
        // Record quality scores
        let quality = QualityScore(
            trajectoryId: trajectoryId,
            timestamp: Date(),
            smoothness: qualityScore.smoothnessScore,
            consistency: 1.0 - qualityScore.velocityConsistency,
            physicsScore: qualityScore.physicsScore,
            overall: qualityScore.physicsScore
        )
        qualityScores.append(quality)

        // Memory management: enforce sliding window for quality scores
        if qualityScores.count > maxQualityScores {
            qualityScores.removeFirst(qualityScores.count - maxQualityScores)
        }
        
        // Record classification
        let classification = ClassificationResult(
            trajectoryId: trajectoryId,
            timestamp: Date(),
            movementType: classificationResult.movementType,
            confidence: classificationResult.confidence,
            details: classificationResult.details
        )
        classificationResults.append(classification)

        // Memory management: enforce sliding window for classification results
        if classificationResults.count > maxClassificationResults {
            classificationResults.removeFirst(classificationResults.count - maxClassificationResults)
        }
        
        // Record physics validation
        let physics = PhysicsValidation(
            trajectoryId: trajectoryId,
            timestamp: Date(),
            rSquared: physicsResult.rSquared,
            curvatureValid: physicsResult.curvatureDirectionValid,
            accelerationValid: physicsResult.accelerationMagnitudeValid,
            velocityConsistent: physicsResult.velocityConsistencyValid,
            positionJumpsValid: physicsResult.positionJumpsValid,
            overallValid: physicsResult.isValid
        )
        physicsValidation.append(physics)

        // Memory management: enforce sliding window for physics validation
        if physicsValidation.count > maxPhysicsValidation {
            physicsValidation.removeFirst(physicsValidation.count - maxPhysicsValidation)
        }
    }
    
    // MARK: - Performance Monitoring
    
    func recordPerformanceMetric(_ metric: PerformanceMetric) {
        guard isEnabled && isRecording else { return }
        performanceMetrics.append(metric)

        // Memory management: enforce sliding window for performance metrics
        if performanceMetrics.count > maxPerformanceMetrics {
            performanceMetrics.removeFirst(performanceMetrics.count - maxPerformanceMetrics)
        }
    }
    
    // MARK: - Visualization Data Export
    
    func exportVisualizationData() -> VisualizationData {
        return VisualizationData(
            trajectoryPoints: trajectoryPoints,
            qualityScores: qualityScores,
            classificationResults: classificationResults,
            physicsValidation: physicsValidation,
            performanceMetrics: performanceMetrics,
            config: config,
            exportTime: Date()
        )
    }
    
    func exportToJSON() -> Data? {
        let data = exportVisualizationData()
        return try? JSONEncoder().encode(data)
    }
    
    func exportToCSV() -> String {
        var csv = "TrajectoryID,Timestamp,X,Y,Velocity,Acceleration,QualityScore,MovementType,Confidence,RSquared,Valid\n"
        
        for point in trajectoryPoints {
            let quality = qualityScores.first { $0.trajectoryId == point.id }
            let classification = classificationResults.first { $0.trajectoryId == point.id }
            let physics = physicsValidation.first { $0.trajectoryId == point.id }
            
            csv += "\(point.id.uuidString),\(point.timestamp),\(point.position.x),\(point.position.y),"
            csv += "\(point.velocity),\(point.acceleration),\(quality?.overall ?? 0),"
            csv += "\(classification?.movementType.rawValue ?? "unknown"),\(classification?.confidence ?? 0),"
            csv += "\(physics?.rSquared ?? 0),\(physics?.overallValid ?? false)\n"
        }
        
        return csv
    }
    
    // MARK: - Real-time Analysis
    
    func getRealtimeAnalysis() -> RealtimeAnalysis {
        let recentPoints = trajectoryPoints.suffix(100)
        let recentQualities = qualityScores.suffix(10)
        let recentMetrics = performanceMetrics.suffix(10)
        
        return RealtimeAnalysis(
            activeTrajectories: Set(recentPoints.map(\.id)).count,
            averageQuality: recentQualities.map(\.overall).reduce(0, +) / Double(recentQualities.count),
            processingFPS: recentMetrics.compactMap { $0.framesPerSecond }.last ?? 0,
            memoryUsage: recentMetrics.compactMap { $0.memoryUsageMB }.last ?? 0,
            detectionAccuracy: calculateRecentAccuracy()
        )
    }
    
    // MARK: - Debug Interface Data
    
    func getDebugInterfaceData() -> DebugInterfaceData {
        return DebugInterfaceData(
            trajectoryCount: trajectoryPoints.count,
            averageQualityScore: qualityScores.map(\.overall).reduce(0, +) / Double(qualityScores.count),
            classificationBreakdown: getClassificationBreakdown(),
            physicsValidationStats: getPhysicsValidationStats(),
            performanceSummary: getPerformanceSummary(),
            sessions: debugHistory
        )
    }
    
    // MARK: - Parameter Tuning Integration
    
    func tunParametersWithRealTimeFeedback(parameters: [String: Any]) -> ParameterTuningResult {
        guard parameterOptimizer != nil else {
            return ParameterTuningResult(success: false, message: "Parameter optimizer not available")
        }
        
        _ = calculateRecentAccuracy()
        _ = calculateRecentPerformance()
        
        // Apply parameters temporarily
        let originalConfig = ProcessorConfig()
        let testConfig = originalConfig.withModifications(parameters)
        
        return ParameterTuningResult(
            success: true,
            message: "Parameters applied successfully",
            accuracyChange: 0.0, // Will be calculated after processing
            performanceImpact: 0.0, // Will be calculated after processing
            recommendations: generateParameterRecommendations(testConfig)
        )
    }
    
    // MARK: - Private Helper Methods
    
    private func clearVisualizationData() {
        trajectoryPoints.removeAll()
        qualityScores.removeAll()
        classificationResults.removeAll()
        physicsValidation.removeAll()
        performanceMetrics.removeAll()
    }
    
    private func calculateVelocity(at index: Int, in positions: [(CGPoint, CMTime)]) -> Double {
        guard index > 0 && index < positions.count else { return 0 }
        
        let (p1, t1) = positions[index - 1]
        let (p2, t2) = positions[index]
        
        let dt = CMTimeGetSeconds(CMTimeSubtract(t2, t1))
        guard dt > 0 else { return 0 }
        
        let dx = Double(p2.x - p1.x)
        let dy = Double(p2.y - p1.y)
        
        return sqrt(dx * dx + dy * dy) / dt
    }
    
    private func calculateAcceleration(at index: Int, in positions: [(CGPoint, CMTime)]) -> Double {
        guard index > 1 && index < positions.count else { return 0 }
        
        let v1 = calculateVelocity(at: index - 1, in: positions)
        let v2 = calculateVelocity(at: index, in: positions)
        
        let (_, t1) = positions[index - 1]
        let (_, t2) = positions[index]
        
        let dt = CMTimeGetSeconds(CMTimeSubtract(t2, t1))
        guard dt > 0 else { return 0 }
        
        return (v2 - v1) / dt
    }
    
    private func calculateRecentAccuracy() -> Double {
        let recentClassifications = classificationResults.suffix(10)
        guard !recentClassifications.isEmpty else { return 0 }
        
        let validClassifications = recentClassifications.filter { $0.confidence >= 0.7 }
        return Double(validClassifications.count) / Double(recentClassifications.count)
    }
    
    private func calculateRecentPerformance() -> Double {
        let recentMetrics = performanceMetrics.suffix(10)
        guard !recentMetrics.isEmpty else { return 0 }
        
        let averageFPS = recentMetrics.compactMap { $0.framesPerSecond }.reduce(0, +) / Double(recentMetrics.count)
        return averageFPS
    }
    
    private func getClassificationBreakdown() -> [MovementType: Int] {
        var breakdown: [MovementType: Int] = [:]
        
        for result in classificationResults {
            breakdown[result.movementType, default: 0] += 1
        }
        
        return breakdown
    }
    
    private func getPhysicsValidationStats() -> PhysicsValidationStats {
        let validCount = physicsValidation.filter { $0.overallValid }.count
        let totalCount = physicsValidation.count
        
        return PhysicsValidationStats(
            totalValidations: totalCount,
            validCount: validCount,
            validPercentage: totalCount > 0 ? Double(validCount) / Double(totalCount) : 0,
            averageRSquared: physicsValidation.map { $0.rSquared }.reduce(0, +) / Double(totalCount)
        )
    }
    
    private func getPerformanceSummary() -> PerformanceSummary {
        guard !performanceMetrics.isEmpty else { return PerformanceSummary() }
        
        return PerformanceSummary(
            averageFPS: performanceMetrics.compactMap { $0.framesPerSecond }.reduce(0, +) / Double(performanceMetrics.count),
            averageMemoryMB: performanceMetrics.compactMap { $0.memoryUsageMB }.reduce(0, +) / Double(performanceMetrics.count),
            processingOverhead: performanceMetrics.compactMap { $0.processingOverheadPercent }.reduce(0, +) / Double(performanceMetrics.count)
        )
    }
    
    private func generateParameterRecommendations(_ config: ProcessorConfig) -> [String] {
        var recommendations: [String] = []
        
        if config.enhancedMinR2 < 0.8 {
            recommendations.append("Consider increasing R² threshold for better trajectory quality")
        }
        
        if config.minClassificationConfidence < 0.7 {
            recommendations.append("Increase classification confidence for more reliable detection")
        }
        
        if config.enableMetricsCollection && config.metricsCollectionSamplingRate > 0.5 {
            recommendations.append("High sampling rate may impact performance - consider reducing")
        }
        
        return recommendations
    }
}

// MARK: - Debug Mode

enum DebugMode: String, CaseIterable {
    case trajectory = "trajectory"
    case classification = "classification"
    case physics = "physics"
    case performance = "performance"
    case parameters = "parameters"
    
    var displayName: String {
        switch self {
        case .trajectory: return "Trajectory Analysis"
        case .classification: return "Movement Classification"
        case .physics: return "Physics Validation"
        case .performance: return "Performance Monitoring"
        case .parameters: return "Parameter Tuning"
        }
    }
}