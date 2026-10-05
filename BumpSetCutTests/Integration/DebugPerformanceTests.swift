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
    
    override func setUp() {
        super.setUp()
        videoProcessor = VideoProcessor()
        debugger = TrajectoryDebugger()
    }
    
    override func tearDown() {
        videoProcessor = nil
        debugger = nil
        super.tearDown()
    }
    
    // MARK: - Debug Data Bounds

    // Removed: testDebugModeProcessingOverhead (a blank synthetic clip can't
    // produce rallies, and a 5% wall-clock bound is flaky by nature) and
    // testMemoryUsageDuringDebugCollection (its baseline was taken before the
    // CoreML model loaded, so it measured model load, not debug collection).

    /// The debugger keeps a bounded window, whatever a long session feeds it.
    func testDebugDataCollectionIsBounded() {
        debugger.isEnabled = true
        debugger.startDebugSession(name: "Bounds Test")

        for i in 0..<1000 {
            debugger.analyzeTrajectory(
                createTestTrajectory(frameNumber: i),
                physicsResult: createTestPhysicsResult(),
                classificationResult: createTestClassificationResult(),
                qualityScore: createTestQualityScore()
            )
        }

        XCTAssertEqual(debugger.trajectoryPoints.count, 1000)   // 5 per trajectory, capped
        XCTAssertEqual(debugger.qualityScores.count, 500)
        XCTAssertEqual(debugger.classificationResults.count, 500)
        XCTAssertEqual(debugger.physicsValidation.count, 500)
    }

    // MARK: - Storage Performance Tests

    func testDebugDataStoragePerformance() async throws {
        // Isolated library: debug data is saved against a video in the manifest.
        let storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugStorageTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = storageDir
        defer {
            StorageManager.storageDirectoryOverride = nil
            try? FileManager.default.removeItem(at: storageDir)
        }
        let mediaStore = MediaStore()
        let clip = try TestVideoFactory.writeVideo(
            to: storageDir.appendingPathComponent("clip_\(UUID().uuidString).mp4"), duration: 1.0)
        XCTAssertTrue(mediaStore.addVideo(at: clip))
        let testVideoId = try XCTUnwrap(mediaStore.getAllVideos().first?.id)
        let debugData = createLargeDebugDataset()
        let sessionId = UUID()

        let storageStartTime = CFAbsoluteTimeGetCurrent()

        let savedPath = try mediaStore.saveDebugData(
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

        let loadedData = mediaStore.loadDebugData(for: testVideoId)

        let loadTime = CFAbsoluteTimeGetCurrent() - loadStartTime

        // Loading should also be quick
        XCTAssertLessThan(loadTime, 1.0, "Debug data loading took too long: \(loadTime)s")
        XCTAssertNotNil(loadedData, "Should be able to load debug data")

        // Clean up
        mediaStore.deleteVideoWithDebugData(videoId: testVideoId)
    }


    // MARK: - Concurrent Processing Tests
    
    func testConcurrentDebugProcessing() async throws {
        let testVideoURL = try createTestVideoURL()
        let concurrentTasks = 3
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let results = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<concurrentTasks {
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
    
    
    private func createTestVideoURL() throws -> URL {
        // Create a simple test video for processing
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let testVideoURL = documentsPath.appendingPathComponent("test_video_\(UUID().uuidString).mp4")
        // Write a REAL playable clip so processing/extraction code paths actually run.
        return try TestVideoFactory.writeVideo(to: testVideoURL, duration: 1.0)
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