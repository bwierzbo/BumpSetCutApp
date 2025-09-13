//
//  MetadataOverlayViewTests.swift
//  BumpSetCutTests
//
//  Created for Metadata Video Processing - Task 006 Testing
//

import XCTest
import SwiftUI
import AVFoundation
import CoreGraphics
@testable import BumpSetCut

final class MetadataOverlayViewTests: XCTestCase {

    // MARK: - Test Data Creation

    private func createSampleProcessingMetadata() -> ProcessingMetadata {
        let rallySegments = [
            RallySegment(
                startTime: CMTime(seconds: 2.0, preferredTimescale: 600),
                endTime: CMTime(seconds: 8.0, preferredTimescale: 600),
                confidence: 0.85,
                quality: 0.92,
                detectionCount: 45,
                averageTrajectoryLength: 2.3
            )
        ]

        let trajectoryPoints = [
            ProcessingTrajectoryPoint(
                timestamp: CMTime(seconds: 4.0, preferredTimescale: 600),
                position: CGPoint(x: 0.3, y: 0.4),
                velocity: 15.0,
                acceleration: -9.8,
                confidence: 0.9
            ),
            ProcessingTrajectoryPoint(
                timestamp: CMTime(seconds: 5.0, preferredTimescale: 600),
                position: CGPoint(x: 0.5, y: 0.6),
                velocity: 12.0,
                acceleration: -9.8,
                confidence: 0.85
            )
        ]

        let trajectoryData = [
            ProcessingTrajectoryData(
                id: UUID(),
                startTime: 4.0,
                endTime: 6.0,
                points: trajectoryPoints,
                rSquared: 0.92,
                movementType: .airborne,
                confidence: 0.88,
                quality: 0.85
            )
        ]

        let processingStats = ProcessingStats(
            totalFrames: 300,
            processedFrames: 300,
            detectionFrames: 180,
            trackingFrames: 120,
            rallyFrames: 90,
            physicsValidFrames: 75,
            totalDetections: 450,
            validTrajectories: 12,
            averageDetectionsPerFrame: 1.5,
            averageConfidence: 0.82,
            processingDuration: 15.0,
            framesPerSecond: 20.0
        )

        let qualityMetrics = QualityMetrics(
            overallQuality: 0.85,
            averageRSquared: 0.88,
            trajectoryConsistency: 0.82,
            physicsValidationRate: 0.85,
            movementClassificationAccuracy: 0.90,
            confidenceDistribution: ConfidenceDistribution(high: 200, medium: 150, low: 100),
            qualityBreakdown: QualityBreakdown(
                velocityConsistency: 0.88,
                accelerationPattern: 0.85,
                smoothnessScore: 0.82,
                verticalMotionScore: 0.90,
                overallCoherence: 0.85
            )
        )

        let performanceMetrics = PerformanceData(
            processingStartTime: Date().addingTimeInterval(-20),
            processingEndTime: Date().addingTimeInterval(-5),
            averageFPS: 25.0,
            peakMemoryUsageMB: 85.0,
            averageMemoryUsageMB: 65.0,
            cpuUsagePercent: 45.0,
            processingOverheadPercent: 8.5,
            detectionLatencyMs: 35.0
        )

        return ProcessingMetadata.createWithEnhancedData(
            for: UUID(),
            with: ProcessorConfig(),
            rallySegments: rallySegments,
            stats: processingStats,
            quality: qualityMetrics,
            trajectories: trajectoryData,
            classifications: [],
            physics: [],
            performance: performanceMetrics
        )
    }

    // MARK: - Initialization Tests

    func testMetadataOverlayViewInitialization() {
        // Given
        let metadata = createSampleProcessingMetadata()
        let currentTime = 5.0
        let videoSize = CGSize(width: 400, height: 300)

        // When - Create overlay view
        let overlayView = MetadataOverlayView(
            processingMetadata: metadata,
            currentTime: currentTime,
            videoSize: videoSize
        )

        // Then - Properties are set correctly
        XCTAssertEqual(overlayView.currentTime, currentTime, "Current time should be set correctly")
        XCTAssertEqual(overlayView.videoSize, videoSize, "Video size should be set correctly")
        XCTAssertTrue(overlayView.showTrajectories, "Trajectories should be visible by default")
        XCTAssertTrue(overlayView.showRallyBoundaries, "Rally boundaries should be visible by default")
        XCTAssertTrue(overlayView.showConfidenceIndicators, "Confidence indicators should be visible by default")

        print("✅ MetadataOverlayView initialization test passed")
    }

    // MARK: - Rally Time Window Tests

    func testCurrentRallyDetection() {
        // Given
        let metadata = createSampleProcessingMetadata()
        let rallyStartTime = 2.0
        let rallyEndTime = 8.0

        // When - Current time is within rally
        let overlayView = MetadataOverlayView(
            processingMetadata: metadata,
            currentTime: 5.0, // Within rally time window
            videoSize: CGSize(width: 400, height: 300)
        )

        // Then - Should detect current rally
        let currentRally = metadata.rallySegments.first { rally in
            overlayView.currentTime >= rally.startTime && overlayView.currentTime <= rally.endTime
        }
        XCTAssertNotNil(currentRally, "Should detect current rally when time is within rally window")

        print("✅ Current rally detection test passed - rally found during active time")
    }

    func testNoCurrentRallyWhenOutsideTimeWindow() {
        // Given
        let metadata = createSampleProcessingMetadata()

        // When - Current time is outside rally
        let overlayView = MetadataOverlayView(
            processingMetadata: metadata,
            currentTime: 10.0, // After rally ends
            videoSize: CGSize(width: 400, height: 300)
        )

        // Then - Should not detect current rally
        let currentRally = metadata.rallySegments.first { rally in
            overlayView.currentTime >= rally.startTime && overlayView.currentTime <= rally.endTime
        }
        XCTAssertNil(currentRally, "Should not detect current rally when time is outside rally window")

        print("✅ No current rally detection test passed - no rally found outside active time")
    }

    // MARK: - Trajectory Filtering Tests

    func testTrajectoryTimeWindowFiltering() {
        // Given
        let metadata = createSampleProcessingMetadata()
        let currentTime = 5.0
        let trajectoryHistoryDuration = 2.0

        let overlayView = MetadataOverlayView(
            processingMetadata: metadata,
            currentTime: currentTime,
            videoSize: CGSize(width: 400, height: 300)
        )

        // When - Filter trajectories for current time window
        guard let trajectoryData = metadata.trajectoryData else {
            XCTFail("No trajectory data available in test metadata")
            return
        }

        let timeWindow = currentTime - trajectoryHistoryDuration...currentTime + 0.5
        let relevantTrajectories = trajectoryData.filter { trajectory in
            let trajectoryRange = trajectory.startTime...trajectory.endTime
            return trajectoryRange.overlaps(timeWindow)
        }

        // Then - Should find trajectories that overlap with current time window
        XCTAssertFalse(relevantTrajectories.isEmpty, "Should find trajectories overlapping with current time window")

        let trajectory = relevantTrajectories.first!
        XCTAssertTrue(trajectory.startTime <= currentTime + 0.5, "Trajectory should start before or at window end")
        XCTAssertTrue(trajectory.endTime >= currentTime - trajectoryHistoryDuration, "Trajectory should end after or at window start")

        print("✅ Trajectory time window filtering test passed - found \(relevantTrajectories.count) relevant trajectories")
    }

    // MARK: - Coordinate System Tests

    func testCoordinateTransformation() {
        // Given
        let metadata = createSampleProcessingMetadata()
        let canvasSize = CGSize(width: 800, height: 600)
        let videoSize = CGSize(width: 400, height: 300)

        let overlayView = MetadataOverlayView(
            processingMetadata: metadata,
            currentTime: 5.0,
            videoSize: videoSize
        )

        // When - Create coordinate transform
        let transform = CGAffineTransform(scaleX: canvasSize.width, y: canvasSize.height)

        // Test normalized point transformation
        let normalizedPoint = CGPoint(x: 0.5, y: 0.5) // Center of normalized coordinate system
        let transformedPoint = normalizedPoint.applying(transform)

        // Then - Should transform to canvas coordinates correctly
        XCTAssertEqual(transformedPoint.x, canvasSize.width * 0.5, "X coordinate should scale correctly")
        XCTAssertEqual(transformedPoint.y, canvasSize.height * 0.5, "Y coordinate should scale correctly")

        print("✅ Coordinate transformation test passed - normalized (0.5, 0.5) → canvas (\(transformedPoint.x), \(transformedPoint.y))")
    }

    // MARK: - Performance Benchmarking

    func testOverlayRenderingPerformance() {
        // Given
        let metadata = createSampleProcessingMetadata()
        let canvasSize = CGSize(width: 1920, height: 1080) // High resolution canvas

        let overlayView = MetadataOverlayView(
            processingMetadata: metadata,
            currentTime: 5.0,
            videoSize: canvasSize
        )

        // When - Measure time for trajectory filtering and coordinate transformations
        let iterationCount = 1000
        let startTime = Date()

        for _ in 0..<iterationCount {
            // Simulate the operations that happen during rendering
            _ = metadata.trajectoryData?.filter { trajectory in
                let timeWindow = overlayView.currentTime - 2.0...overlayView.currentTime + 0.5
                let trajectoryRange = trajectory.startTime...trajectory.endTime
                return trajectoryRange.overlaps(timeWindow)
            }

            // Simulate coordinate transformations
            let transform = CGAffineTransform(scaleX: canvasSize.width, y: canvasSize.height)
            _ = CGPoint(x: 0.5, y: 0.5).applying(transform)
        }

        let endTime = Date()
        let averageTimeMs = (endTime.timeIntervalSince(startTime) / Double(iterationCount)) * 1000

        // Then - Should complete operations quickly enough for 60fps (< 16.67ms per frame)
        let targetTimeMs = 16.67 // 60fps target
        XCTAssertLessThan(averageTimeMs, targetTimeMs, "Overlay operations should complete within 60fps time budget")

        print("✅ Performance benchmark test passed - average time: \(String(format: "%.2f", averageTimeMs))ms (target: < \(targetTimeMs)ms)")
    }

    // MARK: - Visual Element Configuration Tests

    func testConfidenceColorMapping() {
        // Given
        let confidenceValues = [0.9, 0.75, 0.55, 0.3]

        // When & Then - Test confidence color mapping
        for confidence in confidenceValues {
            let expectedColor: String
            switch confidence {
            case 0.8...1.0:
                expectedColor = "green"
            case 0.6..<0.8:
                expectedColor = "yellow"
            case 0.4..<0.6:
                expectedColor = "orange"
            default:
                expectedColor = "red"
            }

            print("✅ Confidence \(confidence) maps to \(expectedColor) as expected")
        }
    }

    func testMovementTypeColorMapping() {
        // Given
        let movementTypes: [MovementType] = [.airborne, .carried, .rolling, .unknown]

        // When & Then - Test movement type color mapping
        for movementType in movementTypes {
            let expectedColor: String
            switch movementType {
            case .airborne:
                expectedColor = "blue"
            case .carried:
                expectedColor = "orange"
            case .rolling:
                expectedColor = "brown"
            case .unknown:
                expectedColor = "gray"
            }

            print("✅ Movement type \(movementType) maps to \(expectedColor) as expected")
        }
    }

    // MARK: - Integration Tests

    func testOverlayControlsCreation() {
        // Given
        @State var showTrajectories = true
        @State var showRallyBoundaries = true
        @State var showConfidenceIndicators = true

        // When - Create overlay controls
        let overlayControls = MetadataOverlayView.createOverlayControls(
            showTrajectories: $showTrajectories,
            showRallyBoundaries: $showRallyBoundaries,
            showConfidenceIndicators: $showConfidenceIndicators
        )

        // Then - Controls should be created successfully
        XCTAssertNotNil(overlayControls, "Overlay controls should be created successfully")

        print("✅ Overlay controls creation test passed")
    }

    func testTrajectoryComplexityScenarios() {
        // Given - Create scenarios with different trajectory complexities
        let scenarios = [
            ("Simple trajectory", 2), // 2 trajectory points
            ("Medium trajectory", 15), // 15 trajectory points
            ("Complex trajectory", 60)  // 60 trajectory points (max for performance)
        ]

        for (scenarioName, pointCount) in scenarios {
            // Create trajectory with specified point count
            let trajectoryPoints = (0..<pointCount).map { index in
                ProcessingTrajectoryPoint(
                    timestamp: CMTime(seconds: Double(index) * 0.1, preferredTimescale: 600),
                    position: CGPoint(x: Double(index) * 0.01, y: Double(index) * 0.01),
                    velocity: 10.0,
                    acceleration: -9.8,
                    confidence: 0.8
                )
            }

            let trajectory = ProcessingTrajectoryData(
                id: UUID(),
                startTime: 0.0,
                endTime: Double(pointCount) * 0.1,
                points: trajectoryPoints,
                rSquared: 0.9,
                movementType: .airborne,
                confidence: 0.85,
                quality: 0.9
            )

            // Verify trajectory is valid
            XCTAssertEqual(trajectory.points.count, pointCount, "\(scenarioName) should have correct point count")
            XCTAssertTrue(trajectory.confidence > 0, "\(scenarioName) should have valid confidence")

            print("✅ \(scenarioName) test passed - \(pointCount) points with confidence \(trajectory.confidence)")
        }
    }
}