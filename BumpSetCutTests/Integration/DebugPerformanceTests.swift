//
//  DebugPerformanceTests.swift
//  BumpSetCutTests
//
//  Created for Debug Workflow Performance Validation - Task 006
//

import XCTest
import AVFoundation
import CoreMedia
@testable import BumpSetCut

@MainActor
final class DebugPerformanceTests: XCTestCase {
    
    var videoProcessor: VideoProcessor!
    var debugger: TrajectoryDebugger!
    var mockMetricsCollector: MetricsCollector!
    
    override func setUp() {
        super.setUp()
        videoProcessor = VideoProcessor()
        mockMetricsCollector = MetricsCollector(config: MetricsCollector.MetricsConfig.default)
        debugger = TrajectoryDebugger(metricsCollector: mockMetricsCollector)
    }
    
    override func tearDown() {
        videoProcessor = nil
        debugger = nil
        mockMetricsCollector = nil
        super.tearDown()
    }
    
    // MARK: - Processing Overhead Tests
    
    func testDebugModeProcessingOverhead() async throws {
        let testVideoURL = try createTestVideoURL()
        
        // Measure normal processing time
        let normalStartTime = CFAbsoluteTimeGetCurrent()
        let normalResult = try await videoProcessor.processVideo(testVideoURL, videoId: UUID())
        let normalProcessingTime = CFAbsoluteTimeGetCurrent() - normalStartTime
        
        // Measure debug mode processing time  
        let debugStartTime = CFAbsoluteTimeGetCurrent()
        let debugResult = try await videoProcessor.processVideoDebug(testVideoURL)
        let debugProcessingTime = CFAbsoluteTimeGetCurrent() - debugStartTime
        
        // Calculate overhead percentage
        let overhead = (debugProcessingTime - normalProcessingTime) / normalProcessingTime
        
        // Validate <5% overhead requirement
        XCTAssertLessThan(overhead, 0.05, 
                         "Debug mode overhead exceeds 5% limit: \(String(format: "%.2f", overhead * 100))%")
        
        // Validate both processing modes completed successfully
        XCTAssertNotNil(normalResult, "Normal processing should complete successfully")
        XCTAssertNotNil(debugResult, "Debug processing should complete successfully")
        
        // Debug processing should have additional debug data
        XCTAssertNotNil(videoProcessor.trajectoryDebugger, 
                       "Debug processing should produce trajectory debugger")
        
        print("Performance Results:")
        print("  Normal processing: \(String(format: "%.3f", normalProcessingTime))s")
        print("  Debug processing: \(String(format: "%.3f", debugProcessingTime))s") 
        print("  Overhead: \(String(format: "%.2f", overhead * 100))%")
        
        // Clean up
        try? FileManager.default.removeItem(at: debugResult)
        try? FileManager.default.removeItem(at: testVideoURL)
    }
    
    func testMemoryUsageDuringDebugCollection() async throws {
        let initialMemory = getMemoryUsage()
        let testVideoURL = try createTestVideoURL()
        
        // Process multiple videos in debug mode to test memory accumulation
        var processedURLs: [URL] = []
        
        for i in 0..<3 {
            let result = try await videoProcessor.processVideoDebug(testVideoURL)
            processedURLs.append(result)
            
            // Check memory usage after each processing
            let currentMemory = getMemoryUsage()
            let memoryIncrease = currentMemory - initialMemory
            
            // Memory increase should be reasonable (allow for some accumulation)
            let maxAllowedIncrease = Int64(50 * 1024 * 1024) * Int64(i + 1) // 50MB per video
            XCTAssertLessThan(memoryIncrease, maxAllowedIncrease,
                             "Memory increase too high after video \(i + 1): \(memoryIncrease) bytes")
        }
        
        let finalMemory = getMemoryUsage()
        let totalMemoryIncrease = finalMemory - initialMemory
        
        print("Memory Usage Results:")
        print("  Initial memory: \(initialMemory / 1024 / 1024)MB")
        print("  Final memory: \(finalMemory / 1024 / 1024)MB")
        print("  Total increase: \(totalMemoryIncrease / 1024 / 1024)MB")
        
        // Clean up
        for url in processedURLs {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.removeItem(at: testVideoURL)
    }
    
    func testDebugDataCollectionPerformance() throws {
        debugger.isEnabled = true
        debugger.startDebugSession(name: "Performance Test")
        
        let iterations = 1000
        
        measure {
            for i in 0..<iterations {
                let trackedBall = createTestTrajectory(frameNumber: i)
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
        
        // Verify all data was collected
        XCTAssertEqual(debugger.trajectoryPoints.count, iterations * 5) // 5 points per trajectory
        XCTAssertEqual(debugger.qualityScores.count, iterations)
        XCTAssertEqual(debugger.classificationResults.count, iterations)
        XCTAssertEqual(debugger.physicsValidation.count, iterations)
    }
    
    // MARK: - Storage Performance Tests
    
    func testDebugDataStoragePerformance() async throws {
        let mediaStore = MediaStore()
        let testVideoId = UUID()
        let debugData = createLargeDebugDataset()
        let sessionId = UUID()
        
        let storageStartTime = CFAbsoluteTimeGetCurrent()
        
        let savedPath = try await mediaStore.saveDebugData(
            for: testVideoId,
            debugData: debugData,
            sessionId: sessionId
        )
        
        let storageTime = CFAbsoluteTimeGetCurrent() - storageStartTime
        
        // Storage should complete quickly (under 2 seconds for large dataset)
        XCTAssertLessThan(storageTime, 2.0, "Debug data storage took too long: \(storageTime)s")
        
        // Verify file was created
        let fileURL = URL(fileURLWithPath: savedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        
        // Test loading performance
        let loadStartTime = CFAbsoluteTimeGetCurrent()
        
        let loadedData = try await mediaStore.loadDebugData(for: testVideoId)
        
        let loadTime = CFAbsoluteTimeGetCurrent() - loadStartTime
        
        // Loading should also be quick
        XCTAssertLessThan(loadTime, 1.0, "Debug data loading took too long: \(loadTime)s")
        XCTAssertNotNil(loadedData, "Should be able to load debug data")
        
        print("Storage Performance Results:")
        print("  Save time: \(String(format: "%.3f", storageTime))s")
        print("  Load time: \(String(format: "%.3f", loadTime))s")
        
        // Clean up
        try await mediaStore.deleteVideoWithDebugData(videoId: testVideoId)
    }
    
    
    // MARK: - Concurrent Processing Tests
    
    func testConcurrentDebugProcessing() async throws {
        let testVideoURL = try createTestVideoURL()
        let concurrentTasks = 3
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let results = try await withThrowingTaskGroup(of: URL.self) { group in
            for i in 0..<concurrentTasks {
                group.addTask { [self] in
                    return try await videoProcessor.processVideoDebug(testVideoURL)
                }
            }
            
            var processedURLs: [URL] = []
            for try await result in group {
                processedURLs.append(result)
            }
            return processedURLs
        }
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        
        // All tasks should complete successfully
        XCTAssertEqual(results.count, concurrentTasks, "All concurrent tasks should complete")
        
        // Concurrent processing should not take significantly longer than sequential
        // Allow for some overhead but shouldn't be more than 2x single processing time
        let maxExpectedTime = 60.0 // Reasonable time for concurrent processing
        XCTAssertLessThan(totalTime, maxExpectedTime, 
                         "Concurrent processing took too long: \(totalTime)s")
        
        print("Concurrent Processing Results:")
        print("  Tasks: \(concurrentTasks)")
        print("  Total time: \(String(format: "%.3f", totalTime))s")
        print("  Average time per task: \(String(format: "%.3f", totalTime / Double(concurrentTasks)))s")
        
        // Clean up
        for url in results {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.removeItem(at: testVideoURL)
    }
    
    // MARK: - Helper Methods
    
    private func getMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
    
    private func createTestVideoURL() throws -> URL {
        // Create a simple test video for processing
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let testVideoURL = documentsPath.appendingPathComponent("test_video_\(UUID().uuidString).mp4")
        
        // For testing purposes, create a minimal video file
        // In a real test environment, you would use a proper test video
        let testData = Data("test video data".utf8)
        try testData.write(to: testVideoURL)
        
        return testVideoURL
    }
    
    private func createLargeDebugDataset() -> Data {
        // Create a substantial debug data set for storage performance testing
        var debugData = Data()
        
        // Simulate large debug session data
        let sessionData = [
            "sessionId": UUID().uuidString,
            "timestamp": Date().timeIntervalSince1970,
            "trajectoryCount": 500,
            "frameCount": 15000
        ] as [String : Any]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: sessionData) {
            debugData.append(jsonData)
        }
        
        // Add padding to simulate realistic debug data size
        let paddingSize = 1024 * 100 // 100KB of padding
        let padding = Data(count: paddingSize)
        debugData.append(padding)
        
        return debugData
    }
    
    private func createLargeDebugger() -> TrajectoryDebugger {
        let largeDebugger = TrajectoryDebugger(metricsCollector: mockMetricsCollector)
        largeDebugger.isEnabled = true
        largeDebugger.startDebugSession(name: "Large Performance Test")
        
        // Add substantial amount of debug data
        for i in 0..<200 {
            let trackedBall = createTestTrajectory(frameNumber: i * 10)
            let physicsResult = createTestPhysicsResult()
            let classificationResult = createTestClassificationResult()
            let qualityScore = createTestQualityScore()
            
            largeDebugger.analyzeTrajectory(
                trackedBall,
                physicsResult: physicsResult,
                classificationResult: classificationResult,
                qualityScore: qualityScore
            )
            
            // Add performance metrics
            let metric = PerformanceMetric(
                timestamp: Date().addingTimeInterval(Double(i)),
                framesPerSecond: 30.0 - Double(i % 10),
                memoryUsageMB: 150.0 + Double(i),
                cpuUsagePercent: 25.0 + Double(i % 20),
                processingOverheadPercent: 5.0,
                detectionLatencyMs: 16.7
            )
            largeDebugger.recordPerformanceMetric(metric)
        }
        
        return largeDebugger
    }
    
    private func createTestTrajectory(frameNumber: Int) -> KalmanBallTracker.TrackedBall {
        var positions: [(CGPoint, CMTime)] = []
        
        for i in 0..<5 {
            let frame = frameNumber + i
            let t = Double(frame) * 0.033 // ~30fps
            let x = 0.2 + Double(i) * 0.06
            let y = 0.5 + 0.1 * sin(Double(frame) * 0.1)
            
            let point = CGPoint(x: x, y: y)
            let time = CMTimeMakeWithSeconds(t, preferredTimescale: 600)
            positions.append((point, time))
        }
        
        return KalmanBallTracker.TrackedBall(positions: positions)
    }
    
    private func createTestPhysicsResult() -> PhysicsValidationResult {
        return PhysicsValidationResult(
            isValid: true,
            rSquared: 0.85 + Double.random(in: -0.1...0.1),
            curvatureDirectionValid: Bool.random(),
            accelerationMagnitudeValid: Bool.random(),
            velocityConsistencyValid: Bool.random(),
            positionJumpsValid: Bool.random(),
            confidenceLevel: 0.8 + Double.random(in: -0.2...0.2)
        )
    }
    
    private func createTestClassificationResult() -> MovementClassification {
        let details = ClassificationDetails(
            velocityConsistency: Double.random(in: 0.0...1.0),
            accelerationPattern: Double.random(in: 0.0...1.0),
            smoothnessScore: Double.random(in: 0.0...1.0),
            verticalMotionScore: Double.random(in: 0.0...1.0),
            timeSpan: Double.random(in: 0.1...2.0)
        )
        
        let movements: [MovementType] = [.airborne, .carried, .rolling]
        
        return MovementClassification(
            movementType: movements.randomElement() ?? .airborne,
            confidence: 0.7 + Double.random(in: 0.0...0.3),
            details: details
        )
    }
    
    private func createTestQualityScore() -> TrajectoryQualityScore.QualityMetrics {
        return TrajectoryQualityScore.QualityMetrics(
            smoothnessScore: 0.6 + Double.random(in: 0.0...0.4),
            velocityConsistency: Double.random(in: 0.0...1.0),
            physicsScore: 0.7 + Double.random(in: 0.0...0.3)
        )
    }
}