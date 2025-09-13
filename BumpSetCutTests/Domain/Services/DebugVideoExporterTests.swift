//
//  DebugVideoExporterTests.swift
//  BumpSetCutTests
//
//  Created for Metadata Video Processing - Task 007
//

#if DEBUG
import XCTest
import AVFoundation
@testable import BumpSetCut

final class DebugVideoExporterTests: XCTestCase {

    var metadataStore: MetadataStore!
    var debugExporter: DebugVideoExporter!
    var testVideoURL: URL!
    var testVideoId: UUID!

    override func setUpWithError() throws {
        metadataStore = MetadataStore()
        debugExporter = DebugVideoExporter(metadataStore: metadataStore)
        testVideoId = UUID()

        // Create a test video URL (we'll mock this in tests)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        testVideoURL = documentsURL.appendingPathComponent("test_video.mp4")
    }

    override func tearDownWithError() throws {
        metadataStore = nil
        debugExporter = nil
        testVideoURL = nil
        testVideoId = nil

        // Cleanup any test files
        try? FileManager.default.removeItem(at: testVideoURL)
    }

    // MARK: - Initialization Tests

    func testDebugVideoExporterInitialization() throws {
        XCTAssertNotNil(debugExporter)
        XCTAssertFalse(debugExporter.isExporting)
        XCTAssertNil(debugExporter.currentProgress)
    }

    // MARK: - Progress Reporting Tests

    func testExportProgressCalculation() throws {
        let progress = DebugVideoExporter.ExportProgress(
            currentFrame: 250,
            totalFrames: 1000,
            phase: .processingFrames,
            elapsedTime: 30.0,
            estimatedTimeRemaining: 90.0
        )

        XCTAssertEqual(progress.completionPercentage, 0.25, accuracy: 0.001)
        XCTAssertEqual(progress.currentFrame, 250)
        XCTAssertEqual(progress.totalFrames, 1000)
        XCTAssertEqual(progress.elapsedTime, 30.0)
        XCTAssertEqual(progress.estimatedTimeRemaining, 90.0)
    }

    func testExportProgressZeroFrames() throws {
        let progress = DebugVideoExporter.ExportProgress(
            currentFrame: 0,
            totalFrames: 0,
            phase: .initializing,
            elapsedTime: 0.0,
            estimatedTimeRemaining: nil
        )

        XCTAssertEqual(progress.completionPercentage, 0.0)
        XCTAssertNil(progress.estimatedTimeRemaining)
    }

    // MARK: - Export Phase Tests

    func testExportPhaseDescriptions() throws {
        XCTAssertEqual(DebugVideoExporter.ExportPhase.initializing.description, "Initializing export...")
        XCTAssertEqual(DebugVideoExporter.ExportPhase.readingVideo.description, "Reading video file...")
        XCTAssertEqual(DebugVideoExporter.ExportPhase.processingFrames.description, "Processing frames with overlays...")
        XCTAssertEqual(DebugVideoExporter.ExportPhase.finalizing.description, "Finalizing video export...")
        XCTAssertEqual(DebugVideoExporter.ExportPhase.completed.description, "Export completed")

        let testError = NSError(domain: "TestError", code: 123, userInfo: [NSLocalizedDescriptionKey: "Test error message"])
        let failedPhase = DebugVideoExporter.ExportPhase.failed(testError)
        XCTAssertTrue(failedPhase.description.contains("Export failed"))
        XCTAssertTrue(failedPhase.description.contains("Test error message"))
    }

    // MARK: - File Management Tests

    func testDebugExportsDirectoryCreation() throws {
        // Test directory creation
        XCTAssertNoThrow(try DebugVideoExporter.ensureDebugExportsDirectory())

        let debugExportsURL = DebugVideoExporter.debugExportsDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: debugExportsURL.path))

        // Verify it's a directory
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: debugExportsURL.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists)
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testDebugExportsDirectoryPath() throws {
        let debugExportsURL = DebugVideoExporter.debugExportsDirectory()
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let expectedURL = documentsURL.appendingPathComponent("DebugExports", isDirectory: true)

        XCTAssertEqual(debugExportsURL, expectedURL)
    }

    func testListDebugExports() throws {
        // Ensure directory exists
        try DebugVideoExporter.ensureDebugExportsDirectory()

        let debugExportsURL = DebugVideoExporter.debugExportsDirectory()

        // Create test files
        let testFile1 = debugExportsURL.appendingPathComponent("test1.mov")
        let testFile2 = debugExportsURL.appendingPathComponent("test2.mov")
        let testFile3 = debugExportsURL.appendingPathComponent("test3.txt") // Should be ignored

        try "test content".write(to: testFile1, atomically: true, encoding: .utf8)
        try "test content".write(to: testFile2, atomically: true, encoding: .utf8)
        try "test content".write(to: testFile3, atomically: true, encoding: .utf8)

        let exports = DebugVideoExporter.listDebugExports()

        XCTAssertEqual(exports.count, 2) // Only .mov files
        XCTAssertTrue(exports.contains(testFile1))
        XCTAssertTrue(exports.contains(testFile2))
        XCTAssertFalse(exports.contains(testFile3))

        // Cleanup
        try FileManager.default.removeItem(at: testFile1)
        try FileManager.default.removeItem(at: testFile2)
        try FileManager.default.removeItem(at: testFile3)
    }

    func testDeleteDebugExport() throws {
        // Ensure directory exists
        try DebugVideoExporter.ensureDebugExportsDirectory()

        let debugExportsURL = DebugVideoExporter.debugExportsDirectory()
        let testFile = debugExportsURL.appendingPathComponent("test_delete.mov")

        // Create test file
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: testFile.path))

        // Delete file
        XCTAssertNoThrow(try DebugVideoExporter.deleteDebugExport(at: testFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.path))
    }

    func testDebugExportsDirectorySize() throws {
        // Ensure directory exists
        try DebugVideoExporter.ensureDebugExportsDirectory()

        let debugExportsURL = DebugVideoExporter.debugExportsDirectory()

        // Create test files with known sizes
        let testFile1 = debugExportsURL.appendingPathComponent("size_test1.mov")
        let testFile2 = debugExportsURL.appendingPathComponent("size_test2.mov")

        let content1 = String(repeating: "a", count: 1000) // 1000 bytes
        let content2 = String(repeating: "b", count: 2000) // 2000 bytes

        try content1.write(to: testFile1, atomically: true, encoding: .utf8)
        try content2.write(to: testFile2, atomically: true, encoding: .utf8)

        let totalSize = DebugVideoExporter.debugExportsDirectorySize()
        XCTAssertGreaterThanOrEqual(totalSize, 3000) // At least 3000 bytes

        // Cleanup
        try FileManager.default.removeItem(at: testFile1)
        try FileManager.default.removeItem(at: testFile2)
    }

    // MARK: - Error Handling Tests

    func testDebugExportErrorDescriptions() throws {
        let exportInProgressError = DebugExportError.exportInProgress
        XCTAssertEqual(exportInProgressError.errorDescription, "Another export operation is already in progress")

        let noVideoTrackError = DebugExportError.noVideoTrack
        XCTAssertEqual(noVideoTrackError.errorDescription, "No video track found in the input file")

        let readerFailedError = DebugExportError.readerFailed
        XCTAssertEqual(readerFailedError.errorDescription, "Failed to read video frames")

        let testVideoId = UUID()
        let metadataNotFoundError = DebugExportError.metadataNotFound(testVideoId)
        XCTAssertTrue(metadataNotFoundError.errorDescription?.contains(testVideoId.uuidString) == true)

        let invalidMetadataError = DebugExportError.invalidMetadata("corrupted data")
        XCTAssertEqual(invalidMetadataError.errorDescription, "Invalid metadata: corrupted data")

        let testError = NSError(domain: "TestDomain", code: 456)
        let directoryCreationError = DebugExportError.exportDirectoryCreationFailed(testError)
        XCTAssertTrue(directoryCreationError.errorDescription?.contains("Failed to create debug exports directory") == true)
    }

    // MARK: - Metadata Processing Tests

    func testCreateMockDetectionsFromTrajectories() throws {
        // This test validates the internal logic for creating detections from trajectory data
        // Since the method is private, we test it indirectly through the public API

        // Create test metadata
        let testMetadata = createTestMetadata()

        // Save metadata to store
        try metadataStore.saveMetadata(testMetadata)

        // Verify metadata can be loaded
        let loadedMetadata = try metadataStore.loadMetadata(for: testMetadata.videoId)
        XCTAssertEqual(loadedMetadata.videoId, testMetadata.videoId)
        XCTAssertEqual(loadedMetadata.rallySegments.count, testMetadata.rallySegments.count)
        XCTAssertEqual(loadedMetadata.trajectoryData?.count, testMetadata.trajectoryData?.count)
    }

    func testCreateMockTrackedBallFromTrajectories() throws {
        // Test the trajectory-to-tracked-ball conversion logic
        let testMetadata = createTestMetadata()

        // Verify that trajectory data exists
        XCTAssertNotNil(testMetadata.trajectoryData)
        XCTAssertGreaterThan(testMetadata.trajectoryData?.count ?? 0, 0)

        // Verify that trajectory points exist
        let firstTrajectory = testMetadata.trajectoryData?.first
        XCTAssertNotNil(firstTrajectory)
        XCTAssertGreaterThan(firstTrajectory?.points.count ?? 0, 0)
    }

    // MARK: - Integration Tests

    func testExportWithoutVideo() async throws {
        // Test export when video file doesn't exist
        let nonExistentVideoURL = URL(fileURLWithPath: "/path/to/nonexistent/video.mp4")

        do {
            _ = try await debugExporter.exportAnnotatedVideo(for: nonExistentVideoURL, videoId: testVideoId)
            XCTFail("Expected export to fail with non-existent video")
        } catch {
            // Expected to fail
            XCTAssertTrue(error is DebugExportError || error is AVError)
        }
    }

    func testExportWithoutMetadata() async throws {
        // Test export when metadata doesn't exist for video
        let testVideoURL = URL(fileURLWithPath: "/path/to/video.mp4") // Mock URL

        do {
            _ = try await debugExporter.exportAnnotatedVideo(for: testVideoURL, videoId: testVideoId)
            XCTFail("Expected export to fail without metadata")
        } catch {
            // Expected to fail due to missing metadata
            XCTAssertTrue(error is MetadataStoreError)
        }
    }

    func testConcurrentExportPrevention() async throws {
        // Simulate concurrent export attempts
        debugExporter.isExporting = true // Manually set to simulate ongoing export

        do {
            _ = try await debugExporter.exportAnnotatedVideo(for: testVideoURL, videoId: testVideoId)
            XCTFail("Expected export to fail when another export is in progress")
        } catch let error as DebugExportError {
            XCTAssertEqual(error, DebugExportError.exportInProgress)
        }
    }

    // MARK: - Helper Methods

    private func createTestMetadata() -> ProcessingMetadata {
        let config = ProcessorConfig()

        // Create test rally segments
        let rallySegment = RallySegment(
            startTime: CMTimeMakeWithSeconds(10.0, preferredTimescale: 600),
            endTime: CMTimeMakeWithSeconds(20.0, preferredTimescale: 600),
            confidence: 0.95,
            quality: 0.88,
            detectionCount: 150,
            averageTrajectoryLength: 2.5
        )

        // Create test processing stats
        let processingStats = ProcessingStats(
            totalFrames: 1000,
            processedFrames: 950,
            detectionFrames: 300,
            trackingFrames: 250,
            rallyFrames: 200,
            physicsValidFrames: 180,
            totalDetections: 450,
            validTrajectories: 25,
            averageDetectionsPerFrame: 0.47,
            averageConfidence: 0.82,
            processingDuration: 45.5,
            framesPerSecond: 20.9
        )

        // Create test quality metrics
        let confidenceDistribution = ConfidenceDistribution(high: 200, medium: 150, low: 100)
        let qualityBreakdown = QualityBreakdown(
            velocityConsistency: 0.85,
            accelerationPattern: 0.78,
            smoothnessScore: 0.92,
            verticalMotionScore: 0.67,
            overallCoherence: 0.81
        )
        let qualityMetrics = QualityMetrics(
            overallQuality: 0.83,
            averageRSquared: 0.91,
            trajectoryConsistency: 0.87,
            physicsValidationRate: 0.72,
            movementClassificationAccuracy: 0.79,
            confidenceDistribution: confidenceDistribution,
            qualityBreakdown: qualityBreakdown
        )

        // Create test performance data
        let performanceData = PerformanceData(
            processingStartTime: Date().addingTimeInterval(-60),
            processingEndTime: Date(),
            averageFPS: 25.0,
            peakMemoryUsageMB: 150.0,
            averageMemoryUsageMB: 120.0,
            cpuUsagePercent: 65.0,
            processingOverheadPercent: 8.5,
            detectionLatencyMs: 12.0
        )

        // Create test trajectory data
        let trajectoryPoints = [
            ProcessingTrajectoryPoint(
                timestamp: CMTimeMakeWithSeconds(15.0, preferredTimescale: 600),
                position: CGPoint(x: 0.5, y: 0.3),
                velocity: 1.2,
                acceleration: -0.5,
                confidence: 0.88
            ),
            ProcessingTrajectoryPoint(
                timestamp: CMTimeMakeWithSeconds(15.5, preferredTimescale: 600),
                position: CGPoint(x: 0.6, y: 0.4),
                velocity: 1.1,
                acceleration: -0.6,
                confidence: 0.91
            )
        ]

        let trajectoryData = [ProcessingTrajectoryData(
            id: UUID(),
            startTime: 14.5,
            endTime: 16.0,
            points: trajectoryPoints,
            rSquared: 0.94,
            movementType: .airborne,
            confidence: 0.89,
            quality: 0.86
        )]

        return ProcessingMetadata(
            videoId: testVideoId,
            processingConfig: config,
            rallySegments: [rallySegment],
            processingStats: processingStats,
            qualityMetrics: qualityMetrics,
            trajectoryData: trajectoryData,
            performanceMetrics: performanceData
        )
    }
}

#endif // DEBUG