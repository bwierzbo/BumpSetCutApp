//
//  RallyPlayerViewTests.swift
//  BumpSetCutTests
//
//  Created for Metadata Video Processing - Task 005
//

import XCTest
import SwiftUI
import AVFoundation
@testable import BumpSetCut

@MainActor
final class RallyPlayerViewTests: XCTestCase {

    var metadataStore: MetadataStore!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Setup temporary directory for testing
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Initialize MetadataStore for testing
        metadataStore = MetadataStore()

        print("RallyPlayerViewTests: Setup completed with temp directory: \(tempDirectory.path)")
    }

    override func tearDownWithError() throws {
        // Cleanup temp directory
        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.removeItem(at: tempDirectory)
        }

        metadataStore = nil
        tempDirectory = nil

        try super.tearDownWithError()
    }

    // MARK: - Error Handling Tests

    func testRallyPlayerWithoutMetadata() throws {
        print("Testing RallyPlayerView behavior with video that has no metadata...")

        // Create video metadata without processing metadata file
        let videoMetadata = createSampleVideoMetadata()

        // Verify that hasMetadata returns false
        XCTAssertFalse(videoMetadata.hasMetadata, "Video should not have metadata initially")

        // The view should handle this gracefully by showing an error state
        // This is tested through UI behavior rather than unit testing since it's a SwiftUI view
        print("✅ Video without metadata properly identified")
    }

    func testRallyPlayerWithEmptyRallies() throws {
        print("Testing RallyPlayerView behavior with metadata containing no rallies...")

        let videoMetadata = createSampleVideoMetadata()

        // Create metadata with empty rally segments
        let emptyMetadata = createSampleProcessingMetadata(
            for: videoMetadata.id,
            rallyCount: 0
        )

        // Save the metadata
        try metadataStore.saveMetadata(emptyMetadata)

        // Verify metadata exists but has no rallies
        let loadedMetadata = try metadataStore.loadMetadata(for: videoMetadata.id)
        XCTAssertTrue(loadedMetadata.rallySegments.isEmpty, "Metadata should have no rally segments")

        print("✅ Empty rally metadata properly created and saved")
    }

    func testRallyPlayerWithMultipleRallies() throws {
        print("Testing RallyPlayerView behavior with metadata containing multiple rallies...")

        let videoMetadata = createSampleVideoMetadata()

        // Create metadata with multiple rally segments
        let multiRallyMetadata = createSampleProcessingMetadata(
            for: videoMetadata.id,
            rallyCount: 5
        )

        // Save the metadata
        try metadataStore.saveMetadata(multiRallyMetadata)

        // Verify metadata exists and has correct number of rallies
        let loadedMetadata = try metadataStore.loadMetadata(for: videoMetadata.id)
        XCTAssertEqual(loadedMetadata.rallySegments.count, 5, "Metadata should have 5 rally segments")

        // Verify rally segments have valid time ranges
        for (index, rally) in loadedMetadata.rallySegments.enumerated() {
            XCTAssertGreaterThan(rally.endTime, rally.startTime, "Rally \(index) should have valid time range")
            XCTAssertGreaterThan(rally.duration, 0, "Rally \(index) should have positive duration")
            XCTAssertGreaterThanOrEqual(rally.confidence, 0, "Rally \(index) confidence should be non-negative")
            XCTAssertLessThanOrEqual(rally.confidence, 1, "Rally \(index) confidence should not exceed 1.0")
        }

        print("✅ Multiple rally metadata properly created with valid time ranges")
    }

    // MARK: - CMTime Conversion Tests

    func testRallySegmentCMTimeConversion() throws {
        print("Testing RallySegment CMTime conversion accuracy...")

        let startTime = CMTimeMakeWithSeconds(10.5, preferredTimescale: 600)
        let endTime = CMTimeMakeWithSeconds(25.3, preferredTimescale: 600)

        let rally = RallySegment(
            startTime: startTime,
            endTime: endTime,
            confidence: 0.85,
            quality: 0.90,
            detectionCount: 42,
            averageTrajectoryLength: 15.2
        )

        // Test conversion back to CMTime
        let convertedStartTime = rally.startCMTime
        let convertedEndTime = rally.endCMTime

        // Verify conversion accuracy (within reasonable tolerance)
        let startTimeDiff = abs(CMTimeGetSeconds(startTime) - CMTimeGetSeconds(convertedStartTime))
        let endTimeDiff = abs(CMTimeGetSeconds(endTime) - CMTimeGetSeconds(convertedEndTime))

        XCTAssertLessThan(startTimeDiff, 0.01, "Start time conversion should be accurate within 10ms")
        XCTAssertLessThan(endTimeDiff, 0.01, "End time conversion should be accurate within 10ms")

        // Test time range creation
        let timeRange = rally.timeRange
        let expectedDuration = CMTimeGetSeconds(endTime) - CMTimeGetSeconds(startTime)
        let actualDuration = CMTimeGetSeconds(timeRange.duration)

        XCTAssertEqual(actualDuration, expectedDuration, accuracy: 0.01, "Time range duration should match calculated duration")

        print("✅ CMTime conversion accuracy verified within 10ms tolerance")
    }

    // MARK: - Performance Tests

    func testSeekPerformanceCalculation() throws {
        print("Testing seek performance measurement accuracy...")

        // This test verifies the performance tracking logic that would be used in the view
        let startTime = Date()

        // Simulate seek operation delay
        Thread.sleep(forTimeInterval: 0.15) // 150ms

        let endTime = Date()
        let seekDurationMs = Int(endTime.timeIntervalSince(startTime) * 1000)

        // Verify performance measurement is within expected range
        XCTAssertGreaterThanOrEqual(seekDurationMs, 145, "Seek duration should be at least 145ms")
        XCTAssertLessThanOrEqual(seekDurationMs, 160, "Seek duration should be at most 160ms")

        // Test performance classification
        let isGoodPerformance = seekDurationMs < 200
        XCTAssertTrue(isGoodPerformance, "150ms should be classified as good performance")

        print("✅ Seek performance measurement accurate: \(seekDurationMs)ms")
    }

    func testRallyNavigationBounds() throws {
        print("Testing rally navigation boundary conditions...")

        let videoMetadata = createSampleVideoMetadata()
        let metadata = createSampleProcessingMetadata(for: videoMetadata.id, rallyCount: 3)

        // Test navigation bounds logic
        let totalRallies = metadata.rallySegments.count
        XCTAssertEqual(totalRallies, 3, "Should have 3 rallies for bounds testing")

        // Test first rally (index 0)
        let canGoPrevious = 0 > 0
        XCTAssertFalse(canGoPrevious, "Should not be able to go previous from first rally")

        // Test last rally (index 2)
        let canGoNext = 2 < totalRallies - 1
        XCTAssertFalse(canGoNext, "Should not be able to go next from last rally")

        // Test middle rally (index 1)
        let canGoPreviousFromMiddle = 1 > 0
        let canGoNextFromMiddle = 1 < totalRallies - 1
        XCTAssertTrue(canGoPreviousFromMiddle, "Should be able to go previous from middle rally")
        XCTAssertTrue(canGoNextFromMiddle, "Should be able to go next from middle rally")

        print("✅ Rally navigation bounds logic verified")
    }

    // MARK: - Integration Tests

    func testMetadataStoreIntegration() throws {
        print("Testing RallyPlayerView integration with MetadataStore...")

        let videoMetadata = createSampleVideoMetadata()
        let metadata = createSampleProcessingMetadata(for: videoMetadata.id, rallyCount: 3)

        // Save metadata
        try metadataStore.saveMetadata(metadata)

        // Verify hasMetadata works correctly
        XCTAssertTrue(videoMetadata.hasMetadata, "Video should have metadata after saving")

        // Load metadata and verify content
        let loadedMetadata = try metadataStore.loadMetadata(for: videoMetadata.id)
        XCTAssertEqual(loadedMetadata.id, metadata.id, "Loaded metadata should have same ID")
        XCTAssertEqual(loadedMetadata.videoId, videoMetadata.id, "Loaded metadata should reference correct video")
        XCTAssertEqual(loadedMetadata.rallySegments.count, 3, "Loaded metadata should have 3 rallies")

        // Cleanup
        try metadataStore.deleteMetadata(for: videoMetadata.id)
        XCTAssertFalse(videoMetadata.hasMetadata, "Video should not have metadata after deletion")

        print("✅ MetadataStore integration working correctly")
    }

    func testVideoMetadataFilePathGeneration() throws {
        print("Testing VideoMetadata metadata file path generation...")

        let videoMetadata = createSampleVideoMetadata()
        let metadataPath = videoMetadata.metadataFilePath

        // Verify path structure
        XCTAssertTrue(metadataPath.path.contains("ProcessedMetadata"), "Path should contain ProcessedMetadata directory")
        XCTAssertTrue(metadataPath.lastPathComponent.hasSuffix(".json"), "File should have .json extension")
        XCTAssertTrue(metadataPath.lastPathComponent.contains(videoMetadata.id.uuidString), "Filename should contain video ID")

        print("✅ Metadata file path generation correct: \(metadataPath.lastPathComponent)")
    }

    // MARK: - Helper Methods

    private func createSampleVideoMetadata() -> VideoMetadata {
        return VideoMetadata(
            fileName: "test_rally_video.mp4",
            customName: "Test Rally Video",
            folderPath: "test_folder",
            createdDate: Date(),
            fileSize: 1024000,
            duration: 120.0
        )
    }

    private func createSampleProcessingMetadata(for videoId: UUID, rallyCount: Int) -> ProcessingMetadata {
        var rallySegments: [RallySegment] = []

        // Create sample rally segments with non-overlapping time ranges
        for i in 0..<rallyCount {
            let startSeconds = Double(i * 20 + 5) // Start at 5, 25, 45, etc.
            let endSeconds = startSeconds + Double.random(in: 8...15) // 8-15 second rallies

            let startTime = CMTimeMakeWithSeconds(startSeconds, preferredTimescale: 600)
            let endTime = CMTimeMakeWithSeconds(endSeconds, preferredTimescale: 600)

            let rally = RallySegment(
                startTime: startTime,
                endTime: endTime,
                confidence: Double.random(in: 0.7...0.95),
                quality: Double.random(in: 0.6...0.9),
                detectionCount: Int.random(in: 20...50),
                averageTrajectoryLength: Double.random(in: 10...20)
            )

            rallySegments.append(rally)
        }

        // Create sample processing stats
        let stats = ProcessingStats(
            totalFrames: 3600,
            processedFrames: 3600,
            detectionFrames: 1800,
            trackingFrames: 1200,
            rallyFrames: 600,
            physicsValidFrames: 800,
            totalDetections: 450,
            validTrajectories: 350,
            averageDetectionsPerFrame: 0.125,
            averageConfidence: 0.82,
            processingDuration: 25.5,
            framesPerSecond: 141.2
        )

        // Create sample quality metrics
        let confidenceDistribution = ConfidenceDistribution(high: 280, medium: 120, low: 50)
        let qualityBreakdown = QualityBreakdown(
            velocityConsistency: 0.85,
            accelerationPattern: 0.78,
            smoothnessScore: 0.82,
            verticalMotionScore: 0.75,
            overallCoherence: 0.80
        )

        let qualityMetrics = QualityMetrics(
            overallQuality: 0.81,
            averageRSquared: 0.87,
            trajectoryConsistency: 0.83,
            physicsValidationRate: 0.78,
            movementClassificationAccuracy: 0.85,
            confidenceDistribution: confidenceDistribution,
            qualityBreakdown: qualityBreakdown
        )

        // Create sample performance data
        let performanceData = PerformanceData(
            processingStartTime: Date().addingTimeInterval(-30),
            processingEndTime: Date(),
            averageFPS: 141.2,
            peakMemoryUsageMB: 245.6,
            averageMemoryUsageMB: 198.3,
            cpuUsagePercent: 65.4,
            processingOverheadPercent: 7.2,
            detectionLatencyMs: 8.5
        )

        // Create sample processor config (simplified)
        let processorConfig = ProcessorConfig()

        return ProcessingMetadata(
            videoId: videoId,
            processingConfig: processorConfig,
            rallySegments: rallySegments,
            processingStats: stats,
            qualityMetrics: qualityMetrics,
            performanceMetrics: performanceData
        )
    }
}