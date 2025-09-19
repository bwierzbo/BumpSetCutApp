//
//  MetricsCollector.swift
//  BumpSetCut
//
//  Created for Detection Logic Upgrades - Issue #23
//

import Foundation
import CoreMedia
import Combine

@MainActor
final class MetricsCollector: ObservableObject {
    
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

// MARK: - Rally Performance Monitoring Extension (Issue #51)
extension MetricsCollector {

    // MARK: - Rally Performance Types
    struct RallyGestureTimer {
        let id: UUID = UUID()
        let startTime: Date = Date()
        let type: String
    }

    struct RallyAnimationTimer {
        let id: UUID = UUID()
        let startTime: Date = Date()
        let type: String
    }

    struct RallyInitializationTimer {
        let id: UUID = UUID()
        let startTime: Date = Date()
        let component: String
    }

    struct RallyPerformanceStatus {
        let gestureResponseHealthy: Bool
        let animationPerformanceHealthy: Bool
        let initializationHealthy: Bool
        let isHealthy: Bool
        let averageGestureResponseMs: Double
        let averageAnimationFPS: Double
        let averageInitializationMs: Double
        let timestamp: Date

        init(gestureResponseMs: Double, animationFPS: Double, initializationMs: Double) {
            self.gestureResponseHealthy = gestureResponseMs <= 50.0
            self.animationPerformanceHealthy = animationFPS >= 55.0
            self.initializationHealthy = initializationMs <= 500.0
            self.isHealthy = gestureResponseHealthy && animationPerformanceHealthy && initializationHealthy
            self.averageGestureResponseMs = gestureResponseMs
            self.averageAnimationFPS = animationFPS
            self.averageInitializationMs = initializationMs
            self.timestamp = Date()
        }
    }

    // MARK: - Gesture Response Time Tracking
    func startGestureTimer(type: String) -> RallyGestureTimer {
        return RallyGestureTimer(type: type)
    }

    func recordGestureResponse(timer: RallyGestureTimer, success: Bool) {
        let responseTime = Date().timeIntervalSince(timer.startTime) * 1000 // Convert to ms

        #if DEBUG
        let threshold: Double = 50.0
        let status = responseTime <= threshold ? "✓" : "⚠️"
        print("RallyGesture[\(timer.type)]: \(String(format: "%.1f", responseTime))ms - \(status)")

        if responseTime > threshold {
            print("⚠️ Gesture response time exceeded: \(String(format: "%.1f", responseTime))ms > \(String(format: "%.1f", threshold))ms")
        }
        #endif

        // Store in performance metrics for trending
        recordPerformance(
            framesPerSecond: nil,
            memoryUsageMB: nil,
            cpuUsagePercent: nil
        )
    }

    // MARK: - Animation Performance Tracking
    func startAnimationTimer(type: String) -> RallyAnimationTimer {
        return RallyAnimationTimer(type: type)
    }

    func recordAnimationPerformance(timer: RallyAnimationTimer, frameCount: Int) {
        let duration = Date().timeIntervalSince(timer.startTime)
        let fps = duration > 0 ? Double(frameCount) / duration : 0.0

        #if DEBUG
        let threshold: Double = 55.0
        let status = fps >= threshold ? "✓" : "⚠️"
        print("RallyAnimation[\(timer.type)]: \(String(format: "%.1f", fps))fps over \(String(format: "%.1f", duration * 1000))ms - \(status)")

        if fps < threshold {
            print("⚠️ Animation FPS below target: \(String(format: "%.1f", fps)) < 60.0")
        }
        #endif

        // Store in performance metrics
        recordPerformance(
            framesPerSecond: fps,
            memoryUsageMB: nil,
            cpuUsagePercent: nil
        )
    }

    // MARK: - Initialization Time Tracking
    func startInitializationTimer(component: String) -> RallyInitializationTimer {
        return RallyInitializationTimer(component: component)
    }

    func recordInitializationComplete(timer: RallyInitializationTimer, memoryUsageMB: Double? = nil) {
        let initTime = Date().timeIntervalSince(timer.startTime) * 1000 // Convert to ms

        #if DEBUG
        let threshold: Double = 500.0
        let status = initTime <= threshold ? "✓" : "⚠️"
        print("RallyInit[\(timer.component)]: \(String(format: "%.1f", initTime))ms - \(status)")

        if initTime > threshold {
            print("⚠️ Initialization time exceeded: \(String(format: "%.1f", initTime))ms > \(String(format: "%.1f", threshold))ms")
        }
        #endif

        // Store in performance metrics
        recordPerformance(
            framesPerSecond: nil,
            memoryUsageMB: memoryUsageMB,
            cpuUsagePercent: nil
        )
    }

    // MARK: - Performance Status Reporting
    func getCurrentPerformanceStatus() -> RallyPerformanceStatus {
        let recentWindow: TimeInterval = 60.0 // Last minute
        let cutoff = Date().addingTimeInterval(-recentWindow)
        let recentMetrics = performanceMetrics.filter { $0.timestamp >= cutoff }

        // Calculate averages
        let avgGestureResponse = getAverageProcessingTime(timeWindow: recentWindow)

        let fpsMetrics = recentMetrics.compactMap { $0.framesPerSecond }
        let avgFPS = fpsMetrics.isEmpty ? 60.0 : fpsMetrics.reduce(0, +) / Double(fpsMetrics.count)

        let avgInitialization = avgGestureResponse // Placeholder - would need separate tracking

        return RallyPerformanceStatus(
            gestureResponseMs: avgGestureResponse,
            animationFPS: avgFPS,
            initializationMs: avgInitialization
        )
    }

    // MARK: - Performance Regression Detection
    func detectGestureRegression(baselineResponseMs: Double = 30.0) -> Bool {
        let currentStatus = getCurrentPerformanceStatus()
        let degradationThreshold = baselineResponseMs * 1.2 // 20% degradation threshold

        if currentStatus.averageGestureResponseMs > degradationThreshold {
            #if DEBUG
            print("🚨 Performance Regression Detected!")
            print("   Gesture Response: \(String(format: "%.1f", currentStatus.averageGestureResponseMs))ms > \(String(format: "%.1f", degradationThreshold))ms")
            #endif
            return true
        }

        return false
    }

    // MARK: - Rally Performance Report
    func getRallyPerformanceReport() -> String {
        let status = getCurrentPerformanceStatus()

        return """

        📊 Rally Performance Report
        ==========================

        Gesture Response: \(String(format: "%.1f", status.averageGestureResponseMs))ms \(status.gestureResponseHealthy ? "✅" : "❌")
        Animation FPS: \(String(format: "%.1f", status.averageAnimationFPS)) \(status.animationPerformanceHealthy ? "✅" : "❌")
        Initialization: \(String(format: "%.1f", status.averageInitializationMs))ms \(status.initializationHealthy ? "✅" : "❌")

        Overall Health: \(status.isHealthy ? "✅ HEALTHY" : "❌ NEEDS ATTENTION")
        Report Time: \(status.timestamp)

        """
    }
}