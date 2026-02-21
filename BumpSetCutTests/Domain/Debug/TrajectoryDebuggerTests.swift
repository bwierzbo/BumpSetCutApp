//
//  TrajectoryDebuggerTests.swift
//  BumpSetCutTests
//
//  Created for Debug Visualization Tools - Issue #26
//

import XCTest
import CoreGraphics
import CoreMedia
@testable import BumpSetCut

@MainActor
final class TrajectoryDebuggerTests: XCTestCase {
    
    var debugger: TrajectoryDebugger!
    var mockMetricsCollector: MetricsCollector!
    
    override func setUp() {
        super.setUp()
        mockMetricsCollector = MetricsCollector(config: MetricsCollector.MetricsConfig.default)
        debugger = TrajectoryDebugger(metricsCollector: mockMetricsCollector)
    }
    
    override func tearDown() {
        debugger = nil
        mockMetricsCollector = nil
        super.tearDown()
    }
    
    // MARK: - Debug Session Tests
    
    func testDebugSessionLifecycle() {
        XCTAssertFalse(debugger.isRecording, "Should not be recording initially")
        XCTAssertEqual(debugger.debugHistory.count, 0, "Should have no sessions initially")
        
        debugger.startDebugSession(name: "Test Session")
        
        XCTAssertTrue(debugger.isRecording, "Should be recording after start")
        XCTAssertEqual(debugger.debugHistory.count, 1, "Should have one session")
        XCTAssertEqual(debugger.debugHistory[0].name, "Test Session", "Session should have correct name")
        
        debugger.stopDebugSession()
        
        XCTAssertFalse(debugger.isRecording, "Should not be recording after stop")
        XCTAssertNotNil(debugger.debugHistory[0].endTime, "Session should have end time")
    }
    
    func testMultipleDebugSessions() {
        debugger.startDebugSession(name: "Session 1")
        debugger.stopDebugSession()
        
        debugger.startDebugSession(name: "Session 2")
        debugger.stopDebugSession()
        
        XCTAssertEqual(debugger.debugHistory.count, 2, "Should have two sessions")
        XCTAssertEqual(debugger.debugHistory[0].name, "Session 1", "First session should have correct name")
        XCTAssertEqual(debugger.debugHistory[1].name, "Session 2", "Second session should have correct name")
    }
    
    func testCannotStartMultipleSessions() {
        debugger.startDebugSession(name: "Session 1")
        debugger.startDebugSession(name: "Session 2")  // Should be ignored
        
        XCTAssertEqual(debugger.debugHistory.count, 1, "Should have only one session")
        XCTAssertEqual(debugger.debugHistory[0].name, "Session 1", "Should keep first session")
    }
    
    // MARK: - Trajectory Analysis Tests
    
    func testTrajectoryAnalysis() {
        debugger.isEnabled = true
        debugger.startDebugSession(name: "Trajectory Test")
        
        let trackedBall = createTestTrajectory()
        let physicsResult = createTestPhysicsResult()
        let classificationResult = createTestClassificationResult()
        let qualityScore = createTestQualityScore()
        
        debugger.analyzeTrajectory(
            trackedBall,
            physicsResult: physicsResult,
            classificationResult: classificationResult,
            qualityScore: qualityScore
        )
        
        XCTAssertEqual(debugger.trajectoryPoints.count, trackedBall.positions.count, "Should record all trajectory points")
        XCTAssertEqual(debugger.qualityScores.count, 1, "Should record quality score")
        XCTAssertEqual(debugger.classificationResults.count, 1, "Should record classification")
        XCTAssertEqual(debugger.physicsValidation.count, 1, "Should record physics validation")
    }
    
    func testAnalysisOnlyWhenEnabled() {
        debugger.isEnabled = false  // Disabled
        debugger.startDebugSession(name: "Disabled Test")
        
        let trackedBall = createTestTrajectory()
        let physicsResult = createTestPhysicsResult()
        let classificationResult = createTestClassificationResult()
        let qualityScore = createTestQualityScore()
        
        debugger.analyzeTrajectory(
            trackedBall,
            physicsResult: physicsResult,
            classificationResult: classificationResult,
            qualityScore: qualityScore
        )
        
        XCTAssertEqual(debugger.trajectoryPoints.count, 0, "Should not record when disabled")
        XCTAssertEqual(debugger.qualityScores.count, 0, "Should not record when disabled")
        XCTAssertEqual(debugger.classificationResults.count, 0, "Should not record when disabled")
        XCTAssertEqual(debugger.physicsValidation.count, 0, "Should not record when disabled")
    }
    
    func testAnalysisOnlyWhenRecording() {
        debugger.isEnabled = true
        // Not recording
        
        let trackedBall = createTestTrajectory()
        let physicsResult = createTestPhysicsResult()
        let classificationResult = createTestClassificationResult()
        let qualityScore = createTestQualityScore()
        
        debugger.analyzeTrajectory(
            trackedBall,
            physicsResult: physicsResult,
            classificationResult: classificationResult,
            qualityScore: qualityScore
        )
        
        XCTAssertEqual(debugger.trajectoryPoints.count, 0, "Should not record when not recording session")
    }
    
    // MARK: - Performance Monitoring Tests
    
    func testPerformanceMetricRecording() {
        debugger.isEnabled = true
        debugger.startDebugSession(name: "Performance Test")
        
        let metric = PerformanceMetric(
            timestamp: Date(),
            framesPerSecond: 30.0,
            memoryUsageMB: 150.0,
            cpuUsagePercent: 25.0,
            processingOverheadPercent: 5.0,
            detectionLatencyMs: 16.7
        )
        
        debugger.recordPerformanceMetric(metric)
        
        XCTAssertEqual(debugger.performanceMetrics.count, 1, "Should record performance metric")
        XCTAssertEqual(debugger.performanceMetrics[0].framesPerSecond, 30.0, "Should record correct FPS")
    }
    
    // MARK: - Export Tests
    
    func testJSONExport() {
        debugger.isEnabled = true
        debugger.startDebugSession(name: "Export Test")
        
        // Add some test data
        let trackedBall = createTestTrajectory()
        let physicsResult = createTestPhysicsResult()
        let classificationResult = createTestClassificationResult()
        let qualityScore = createTestQualityScore()
        
        debugger.analyzeTrajectory(
            trackedBall,
            physicsResult: physicsResult,
            classificationResult: classificationResult,
            qualityScore: qualityScore
        )
        
        let jsonData = debugger.exportToJSON()
        
        XCTAssertNotNil(jsonData, "Should export JSON data")
        
        // Test deserialization
        if let data = jsonData {
            let decoder = JSONDecoder()
            XCTAssertNoThrow(try decoder.decode(VisualizationData.self, from: data), "JSON should be valid")
        }
    }
    
    func testCSVExport() {
        debugger.isEnabled = true
        debugger.startDebugSession(name: "CSV Export Test")
        
        // Add test data
        let trackedBall = createTestTrajectory()
        let physicsResult = createTestPhysicsResult()
        let classificationResult = createTestClassificationResult()
        let qualityScore = createTestQualityScore()
        
        debugger.analyzeTrajectory(
            trackedBall,
            physicsResult: physicsResult,
            classificationResult: classificationResult,
            qualityScore: qualityScore
        )
        
        let csvString = debugger.exportToCSV()
        
        XCTAssertTrue(csvString.contains("TrajectoryID"), "CSV should contain header")
        XCTAssertTrue(csvString.contains("airborne"), "CSV should contain classification data")
        XCTAssertGreaterThan(csvString.components(separatedBy: "\n").count, 1, "CSV should have multiple lines")
    }
    
    // MARK: - Real-time Analysis Tests
    
    func testRealtimeAnalysis() {
        debugger.isEnabled = true
        debugger.startDebugSession(name: "Realtime Test")
        
        // Add test data
        addMultipleTrajectories()
        
        let analysis = debugger.getRealtimeAnalysis()
        
        XCTAssertGreaterThan(analysis.activeTrajectories, 0, "Should have active trajectories")
        XCTAssertGreaterThanOrEqual(analysis.averageQuality, 0, "Should have quality score")
        XCTAssertNotEqual(analysis.status, .good, "Analysis status should be determined") // Will be .warning due to no actual performance data
    }
    
    // MARK: - Debug Interface Tests
    
    func testDebugInterfaceData() {
        debugger.isEnabled = true
        debugger.startDebugSession(name: "Interface Test")
        
        addMultipleTrajectories()
        
        let interfaceData = debugger.getDebugInterfaceData()
        
        XCTAssertGreaterThan(interfaceData.trajectoryCount, 0, "Should have trajectory count")
        XCTAssertGreaterThanOrEqual(interfaceData.averageQualityScore, 0, "Should have quality score")
        XCTAssertFalse(interfaceData.classificationBreakdown.isEmpty, "Should have classification breakdown")
        XCTAssertEqual(interfaceData.sessions.count, 1, "Should have session data")
    }
    
    // MARK: - Configuration Tests
    
    func testDebugConfiguration() {
        let config = DebugConfiguration()
        
        XCTAssertEqual(config.visualizationMode, .trajectory2D, "Default visualization mode should be 2D")
        XCTAssertTrue(config.showQualityScores, "Should show quality scores by default")
        XCTAssertEqual(config.maxTrajectoryHistory, 100, "Default history should be 100")
        XCTAssertEqual(config.updateFrequencyHz, 30.0, "Default update frequency should be 30Hz")
    }
    
    // MARK: - Performance Tests
    
    func testDebuggerPerformance() {
        debugger.isEnabled = true
        debugger.startDebugSession(name: "Performance Test")
        
        measure {
            for _ in 0..<100 {
                let trackedBall = createTestTrajectory()
                let physicsResult = createTestPhysicsResult()
                let classificationResult = createTestClassificationResult()
                let qualityScore = createTestQualityScore()
                
                debugger.analyzeTrajectory(
                    trackedBall,
                    physicsResult: physicsResult,
                    classificationResult: classificationResult,
                    qualityScore: qualityScore
                )
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestTrajectory() -> KalmanBallTracker.TrackedBall {
        var positions: [(CGPoint, CMTime)] = []
        
        for i in 0..<10 {
            let t = Double(i) * 0.033  // ~30fps
            let x = 0.2 + Double(i) * 0.06
            let y = 0.5 + 0.1 * sin(Double(i) * 0.5)  // Slight curve
            
            let point = CGPoint(x: x, y: y)
            let time = CMTimeMakeWithSeconds(t, preferredTimescale: 600)
            positions.append((point, time))
        }
        
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createTestPhysicsResult() -> PhysicsValidationResult {
        return PhysicsValidationResult(
            isValid: true,
            rSquared: 0.87,
            curvatureDirectionValid: true,
            accelerationMagnitudeValid: true,
            velocityConsistencyValid: true,
            positionJumpsValid: true,
            confidenceLevel: 0.8
        )
    }
    
    private func createTestClassificationResult() -> MovementClassification {
        let details = ClassificationDetails(
            velocityConsistency: 0.3,
            accelerationPattern: 0.8,
            smoothnessScore: 0.9,
            verticalMotionScore: 0.6,
            timeSpan: 0.33
        )
        
        return MovementClassification(
            movementType: .airborne,
            confidence: 0.85,
            details: details
        )
    }
    
    private func createTestQualityScore() -> TrajectoryQualityScore.QualityMetrics {
        return TrajectoryQualityScore.QualityMetrics(
            smoothnessScore: 0.8,
            velocityConsistency: 0.3,
            physicsScore: 0.85
        )
    }
    
    private func addMultipleTrajectories() {
        for _ in 0..<5 {
            let trackedBall = createTestTrajectory()
            let physicsResult = createTestPhysicsResult()
            let classificationResult = createTestClassificationResult()
            let qualityScore = createTestQualityScore()
            
            debugger.analyzeTrajectory(
                trackedBall,
                physicsResult: physicsResult,
                classificationResult: classificationResult,
                qualityScore: qualityScore
            )
        }
    }
}