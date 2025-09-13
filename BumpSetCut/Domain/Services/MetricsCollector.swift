//
//  MetricsCollector.swift
//  BumpSetCut
//
//  Created for Detection Logic Upgrades - Issue #23
//

import Foundation
import CoreMedia

@MainActor
final class MetricsCollector {
    
    struct MetricsConfig {
        let enableCollection: Bool
        let samplingRate: Double
        let maxStoredMetrics: Int
        
        static let `default` = MetricsConfig(
            enableCollection: true,
            samplingRate: 0.1,
            maxStoredMetrics: 1000
        )
    }
    
    private let config: MetricsConfig
    private var detectionMetrics: [DetectionMetric] = []
    private var performanceMetrics: [PerformanceMetric] = []
    
    init(config: MetricsConfig) {
        self.config = config
    }
    
    func recordDetection(
        timestamp: CMTime,
        detected: Bool,
        confidence: Double,
        processingTimeMs: Double
    ) {
        guard config.enableCollection && shouldSample() else { return }
        
        let metric = DetectionMetric(
            timestamp: Date(),
            detected: detected,
            confidence: confidence,
            processingTimeMs: processingTimeMs
        )
        
        detectionMetrics.append(metric)
        maintainStorageLimit()
    }
    
    func recordPerformance(
        framesPerSecond: Double?,
        memoryUsageMB: Double?,
        cpuUsagePercent: Double?
    ) {
        guard config.enableCollection else { return }
        
        let metric = PerformanceMetric(
            timestamp: Date(),
            framesPerSecond: framesPerSecond,
            memoryUsageMB: memoryUsageMB,
            cpuUsagePercent: cpuUsagePercent,
            processingOverheadPercent: nil,
            detectionLatencyMs: nil
        )
        
        performanceMetrics.append(metric)
        maintainStorageLimit()
    }
    
    func getDetectionAccuracy(timeWindow: TimeInterval = 300) -> Double {
        let cutoff = Date().addingTimeInterval(-timeWindow)
        let recentMetrics = detectionMetrics.filter { $0.timestamp >= cutoff }
        
        guard !recentMetrics.isEmpty else { return 0 }
        
        let accurateDetections = recentMetrics.filter { $0.detected && $0.confidence >= 0.7 }
        return Double(accurateDetections.count) / Double(recentMetrics.count)
    }
    
    func getAverageProcessingTime(timeWindow: TimeInterval = 300) -> Double {
        let cutoff = Date().addingTimeInterval(-timeWindow)
        let recentMetrics = detectionMetrics.filter { $0.timestamp >= cutoff }
        
        guard !recentMetrics.isEmpty else { return 0 }
        
        return recentMetrics.map(\.processingTimeMs).reduce(0, +) / Double(recentMetrics.count)
    }
    
    private func shouldSample() -> Bool {
        return Double.random(in: 0...1) < config.samplingRate
    }
    
    private func maintainStorageLimit() {
        if detectionMetrics.count > config.maxStoredMetrics {
            detectionMetrics.removeFirst(detectionMetrics.count - config.maxStoredMetrics)
        }
        
        if performanceMetrics.count > config.maxStoredMetrics {
            performanceMetrics.removeFirst(performanceMetrics.count - config.maxStoredMetrics)
        }
    }
}

struct DetectionMetric {
    let timestamp: Date
    let detected: Bool
    let confidence: Double
    let processingTimeMs: Double
}