//
//  ProcessingMetadataTests.swift
//  BumpSetCutTests
//
//  Created for Metadata Video Processing - Task 001 Unit Tests
//

import XCTest
import CoreMedia
import CoreGraphics
@testable import BumpSetCut

final class ProcessingMetadataTests: XCTestCase {

    var sampleVideoId: UUID!
    var sampleConfig: ProcessorConfig!
    var sampleRallySegments: [RallySegment]!
    var sampleProcessingStats: ProcessingStats!
    var sampleQualityMetrics: QualityMetrics!
    var samplePerformanceData: PerformanceData!

    override func setUp() {
        super.setUp()
        setupSampleData()
    }

    override func tearDown() {
        sampleVideoId = nil
        sampleConfig = nil
        sampleRallySegments = nil
        sampleProcessingStats = nil
        sampleQualityMetrics = nil
        samplePerformanceData = nil
        super.tearDown()
    }

    private func setupSampleData() {
        sampleVideoId = UUID()
        sampleConfig = ProcessorConfig()

        // Sample rally segments
        sampleRallySegments = [
            RallySegment(
                startTime: CMTimeMakeWithSeconds(10.0, preferredTimescale: 600),
                endTime: CMTimeMakeWithSeconds(25.0, preferredTimescale: 600),
                confidence: 0.85,
                quality: 0.78,
                detectionCount: 45,
                averageTrajectoryLength: 12.5
            ),
            RallySegment(
                startTime: CMTimeMakeWithSeconds(50.0, preferredTimescale: 600),
                endTime: CMTimeMakeWithSeconds(68.0, preferredTimescale: 600),
                confidence: 0.92,
                quality: 0.83,
                detectionCount: 52,
                averageTrajectoryLength: 15.2
            )
        ]

        // Sample processing stats
        sampleProcessingStats = ProcessingStats(
            totalFrames: 18000,
            processedFrames: 17800,
            detectionFrames: 8900,
            trackingFrames: 7200,
            rallyFrames: 1980,
            physicsValidFrames: 6500,
            totalDetections: 2340,
            validTrajectories: 156,
            averageDetectionsPerFrame: 0.13,
            averageConfidence: 0.82,
            processingDuration: 45.6,
            framesPerSecond: 390.4
        )

        // Sample quality metrics
        let confidenceDistribution = ConfidenceDistribution(high: 1250, medium: 890, low: 200)
        let qualityBreakdown = QualityBreakdown(
            velocityConsistency: 0.79,
            accelerationPattern: 0.82,
            smoothnessScore: 0.76,
            verticalMotionScore: 0.81,
            overallCoherence: 0.80
        )
        sampleQualityMetrics = QualityMetrics(
            overallQuality: 0.80,
            averageRSquared: 0.87,
            trajectoryConsistency: 0.84,
            physicsValidationRate: 0.78,
            movementClassificationAccuracy: 0.73,
            confidenceDistribution: confidenceDistribution,
            qualityBreakdown: qualityBreakdown
        )

        // Sample performance data
        samplePerformanceData = PerformanceData(
            processingStartTime: Date().addingTimeInterval(-60),
            processingEndTime: Date(),
            averageFPS: 28.5,
            peakMemoryUsageMB: 512.3,
            averageMemoryUsageMB: 387.2,
            cpuUsagePercent: 45.6,
            processingOverheadPercent: 4.2,
            detectionLatencyMs: 12.8
        )
    }

    // MARK: - Basic Initialization Tests

    func testBasicInitialization() {
        let metadata = ProcessingMetadata.create(
            for: sampleVideoId,
            with: sampleConfig,
            rallySegments: sampleRallySegments,
            stats: sampleProcessingStats,
            quality: sampleQualityMetrics,
            performance: samplePerformanceData
        )

        XCTAssertNotNil(metadata.id, "Metadata should have a unique ID")
        XCTAssertEqual(metadata.videoId, sampleVideoId, "Video ID should match input")
        XCTAssertEqual(metadata.processingVersion, "1.0", "Processing version should be 1.0")
        XCTAssertNotNil(metadata.processingDate, "Processing date should be set")
        XCTAssertEqual(metadata.rallySegments.count, 2, "Should have 2 rally segments")
        XCTAssertNil(metadata.trajectoryData, "Trajectory data should be nil for basic init")
        XCTAssertNil(metadata.classificationResults, "Classification results should be nil for basic init")
        XCTAssertNil(metadata.physicsValidation, "Physics validation should be nil for basic init")
    }

    func testEnhancedInitialization() {
        let sampleTrajectories = createSampleTrajectories()
        let sampleClassifications = createSampleClassifications()
        let samplePhysicsValidation = createSamplePhysicsValidation()

        let metadata = ProcessingMetadata.createWithEnhancedData(
            for: sampleVideoId,
            with: sampleConfig,
            rallySegments: sampleRallySegments,
            stats: sampleProcessingStats,
            quality: sampleQualityMetrics,
            trajectories: sampleTrajectories,
            classifications: sampleClassifications,
            physics: samplePhysicsValidation,
            performance: samplePerformanceData
        )

        XCTAssertNotNil(metadata.trajectoryData, "Trajectory data should be present")
        XCTAssertNotNil(metadata.classificationResults, "Classification results should be present")
        XCTAssertNotNil(metadata.physicsValidation, "Physics validation should be present")
        XCTAssertTrue(metadata.hasEnhancedData, "Should indicate enhanced data is present")
        XCTAssertEqual(metadata.trajectoryData?.count, 3, "Should have 3 trajectory data entries")
        XCTAssertEqual(metadata.classificationResults?.count, 2, "Should have 2 classification results")
        XCTAssertEqual(metadata.physicsValidation?.count, 3, "Should have 3 physics validation entries")
    }

    // MARK: - JSON Encoding/Decoding Tests

    func testBasicJSONEncodingDecoding() throws {
        let originalMetadata = ProcessingMetadata.create(
            for: sampleVideoId,
            with: sampleConfig,
            rallySegments: sampleRallySegments,
            stats: sampleProcessingStats,
            quality: sampleQualityMetrics,
            performance: samplePerformanceData
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(originalMetadata)

        XCTAssertGreaterThan(jsonData.count, 0, "JSON data should not be empty")

        // Decode from JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedMetadata = try decoder.decode(ProcessingMetadata.self, from: jsonData)

        // Verify decoded data matches original
        XCTAssertEqual(decodedMetadata.id, originalMetadata.id, "ID should match after encoding/decoding")
        XCTAssertEqual(decodedMetadata.videoId, originalMetadata.videoId, "Video ID should match")
        XCTAssertEqual(decodedMetadata.processingVersion, originalMetadata.processingVersion, "Processing version should match")
        XCTAssertEqual(decodedMetadata.rallySegments.count, originalMetadata.rallySegments.count, "Rally segment count should match")
        XCTAssertEqual(decodedMetadata.processingStats.totalFrames, originalMetadata.processingStats.totalFrames, "Processing stats should match")
    }

    func testEnhancedJSONEncodingDecoding() throws {
        let originalMetadata = ProcessingMetadata.createWithEnhancedData(
            for: sampleVideoId,
            with: sampleConfig,
            rallySegments: sampleRallySegments,
            stats: sampleProcessingStats,
            quality: sampleQualityMetrics,
            trajectories: createSampleTrajectories(),
            classifications: createSampleClassifications(),
            physics: createSamplePhysicsValidation(),
            performance: samplePerformanceData
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(originalMetadata)

        // Decode from JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedMetadata = try decoder.decode(ProcessingMetadata.self, from: jsonData)

        // Verify enhanced data is preserved
        XCTAssertNotNil(decodedMetadata.trajectoryData, "Trajectory data should be preserved")
        XCTAssertNotNil(decodedMetadata.classificationResults, "Classification results should be preserved")
        XCTAssertNotNil(decodedMetadata.physicsValidation, "Physics validation should be preserved")
        XCTAssertTrue(decodedMetadata.hasEnhancedData, "Enhanced data flag should be preserved")

        XCTAssertEqual(decodedMetadata.trajectoryData?.count, originalMetadata.trajectoryData?.count, "Trajectory count should match")
        XCTAssertEqual(decodedMetadata.classificationResults?.count, originalMetadata.classificationResults?.count, "Classification count should match")
        XCTAssertEqual(decodedMetadata.physicsValidation?.count, originalMetadata.physicsValidation?.count, "Physics validation count should match")
    }

    // MARK: - Backwards Compatibility Tests

    func testBackwardsCompatibilityWithMissingFields() throws {
        // Create JSON without optional fields
        let minimalJSON = """
        {
            "id": "\(UUID().uuidString)",
            "videoId": "\(sampleVideoId.uuidString)",
            "processingDate": "\(ISO8601DateFormatter().string(from: Date()))",
            "processingConfig": {
                "parabolaMinPoints": 8,
                "parabolaMinR2": 0.85,
                "enableEnhancedPhysics": false
            },
            "rallySegments": [],
            "processingStats": {
                "totalFrames": 1000,
                "processedFrames": 950,
                "detectionFrames": 500,
                "trackingFrames": 400,
                "rallyFrames": 200,
                "physicsValidFrames": 300,
                "totalDetections": 150,
                "validTrajectories": 25,
                "averageDetectionsPerFrame": 0.15,
                "averageConfidence": 0.8,
                "processingDuration": 30.0,
                "framesPerSecond": 31.67
            },
            "qualityMetrics": {
                "overallQuality": 0.75,
                "averageRSquared": 0.85,
                "trajectoryConsistency": 0.8,
                "physicsValidationRate": 0.7,
                "confidenceDistribution": {
                    "high": 100,
                    "medium": 40,
                    "low": 10
                },
                "qualityBreakdown": {
                    "velocityConsistency": 0.8,
                    "accelerationPattern": 0.75,
                    "smoothnessScore": 0.7,
                    "verticalMotionScore": 0.8,
                    "overallCoherence": 0.76
                }
            },
            "performanceMetrics": {
                "processingStartTime": "\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)))",
                "processingEndTime": "\(ISO8601DateFormatter().string(from: Date()))",
                "averageFPS": 30.0,
                "peakMemoryUsageMB": 400.0,
                "averageMemoryUsageMB": 300.0,
                "processingOverheadPercent": 5.0
            }
        }
        """

        let jsonData = minimalJSON.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let metadata = try decoder.decode(ProcessingMetadata.self, from: jsonData)

        // Verify defaults are applied for missing fields
        XCTAssertEqual(metadata.processingVersion, "1.0", "Should default to version 1.0")
        XCTAssertNil(metadata.trajectoryData, "Trajectory data should be nil when missing")
        XCTAssertNil(metadata.classificationResults, "Classification results should be nil when missing")
        XCTAssertNil(metadata.physicsValidation, "Physics validation should be nil when missing")
        XCTAssertFalse(metadata.hasEnhancedData, "Should not have enhanced data")
    }

    // MARK: - RallySegment Tests

    func testRallySegmentTimeConversion() {
        let startTime = CMTimeMakeWithSeconds(15.5, preferredTimescale: 600)
        let endTime = CMTimeMakeWithSeconds(32.8, preferredTimescale: 600)

        let segment = RallySegment(
            startTime: startTime,
            endTime: endTime,
            confidence: 0.9,
            quality: 0.85,
            detectionCount: 50,
            averageTrajectoryLength: 20.0
        )

        XCTAssertEqual(segment.startTime, 15.5, accuracy: 0.001, "Start time should be converted to seconds")
        XCTAssertEqual(segment.endTime, 32.8, accuracy: 0.001, "End time should be converted to seconds")
        XCTAssertEqual(segment.duration, 17.3, accuracy: 0.001, "Duration should be calculated correctly")

        // Test conversion back to CMTime
        let reconvertedStart = segment.startCMTime
        let reconvertedEnd = segment.endCMTime

        XCTAssertEqual(CMTimeGetSeconds(reconvertedStart), 15.5, accuracy: 0.001, "CMTime conversion should be accurate")
        XCTAssertEqual(CMTimeGetSeconds(reconvertedEnd), 32.8, accuracy: 0.001, "CMTime conversion should be accurate")

        // Test time range
        let timeRange = segment.timeRange
        XCTAssertEqual(CMTimeGetSeconds(timeRange.start), 15.5, accuracy: 0.001, "Time range start should match")
        XCTAssertEqual(CMTimeGetSeconds(timeRange.duration), 17.3, accuracy: 0.001, "Time range duration should match")
    }

    func testRallySegmentJSONEncoding() throws {
        let segment = sampleRallySegments[0]

        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(segment)

        let decoder = JSONDecoder()
        let decodedSegment = try decoder.decode(RallySegment.self, from: jsonData)

        XCTAssertEqual(decodedSegment.startTime, segment.startTime, accuracy: 0.001, "Start time should be preserved")
        XCTAssertEqual(decodedSegment.endTime, segment.endTime, accuracy: 0.001, "End time should be preserved")
        XCTAssertEqual(decodedSegment.confidence, segment.confidence, accuracy: 0.001, "Confidence should be preserved")
        XCTAssertEqual(decodedSegment.quality, segment.quality, accuracy: 0.001, "Quality should be preserved")
        XCTAssertEqual(decodedSegment.detectionCount, segment.detectionCount, "Detection count should be preserved")
    }

    // MARK: - TrajectoryPoint Tests

    func testTrajectoryPointTimeConversion() {
        let timestamp = CMTimeMakeWithSeconds(42.7, preferredTimescale: 600)
        let position = CGPoint(x: 0.5, y: 0.3)

        let point = ProcessingTrajectoryPoint(
            timestamp: timestamp,
            position: position,
            velocity: 15.2,
            acceleration: 2.8,
            confidence: 0.87
        )

        XCTAssertEqual(point.timestamp, 42.7, accuracy: 0.001, "Timestamp should be converted to seconds")
        XCTAssertEqual(point.position.x, 0.5, accuracy: 0.001, "Position X should be preserved")
        XCTAssertEqual(point.position.y, 0.3, accuracy: 0.001, "Position Y should be preserved")

        // Test conversion back to CMTime
        let reconvertedTime = point.cmTime
        XCTAssertEqual(CMTimeGetSeconds(reconvertedTime), 42.7, accuracy: 0.001, "CMTime conversion should be accurate")
    }

    // MARK: - Quality Metrics Tests

    func testQualityLevel() {
        let excellentMetrics = QualityMetrics(
            overallQuality: 0.95,
            averageRSquared: 0.9,
            trajectoryConsistency: 0.9,
            physicsValidationRate: 0.9,
            movementClassificationAccuracy: 0.9,
            confidenceDistribution: ConfidenceDistribution(high: 100, medium: 0, low: 0),
            qualityBreakdown: QualityBreakdown(velocityConsistency: 0.9, accelerationPattern: 0.9, smoothnessScore: 0.9, verticalMotionScore: 0.9, overallCoherence: 0.9)
        )

        XCTAssertEqual(excellentMetrics.qualityLevel, .excellent, "Should be excellent quality")

        let goodMetrics = QualityMetrics(
            overallQuality: 0.8,
            averageRSquared: 0.8,
            trajectoryConsistency: 0.8,
            physicsValidationRate: 0.8,
            movementClassificationAccuracy: 0.8,
            confidenceDistribution: ConfidenceDistribution(high: 80, medium: 20, low: 0),
            qualityBreakdown: QualityBreakdown(velocityConsistency: 0.8, accelerationPattern: 0.8, smoothnessScore: 0.8, verticalMotionScore: 0.8, overallCoherence: 0.8)
        )

        XCTAssertEqual(goodMetrics.qualityLevel, .good, "Should be good quality")

        let poorMetrics = QualityMetrics(
            overallQuality: 0.3,
            averageRSquared: 0.3,
            trajectoryConsistency: 0.3,
            physicsValidationRate: 0.3,
            movementClassificationAccuracy: 0.3,
            confidenceDistribution: ConfidenceDistribution(high: 10, medium: 30, low: 60),
            qualityBreakdown: QualityBreakdown(velocityConsistency: 0.3, accelerationPattern: 0.3, smoothnessScore: 0.3, verticalMotionScore: 0.3, overallCoherence: 0.3)
        )

        XCTAssertEqual(poorMetrics.qualityLevel, .poor, "Should be poor quality")
    }

    // MARK: - Performance Data Tests

    func testPerformanceLevel() {
        let excellentPerformance = PerformanceData(
            processingStartTime: Date().addingTimeInterval(-30),
            processingEndTime: Date(),
            averageFPS: 45.0,
            peakMemoryUsageMB: 200.0,
            averageMemoryUsageMB: 150.0,
            cpuUsagePercent: 30.0,
            processingOverheadPercent: 3.0,
            detectionLatencyMs: 8.0
        )

        XCTAssertEqual(excellentPerformance.performanceLevel, .excellent, "Should be excellent performance")

        let poorPerformance = PerformanceData(
            processingStartTime: Date().addingTimeInterval(-120),
            processingEndTime: Date(),
            averageFPS: 10.0,
            peakMemoryUsageMB: 800.0,
            averageMemoryUsageMB: 600.0,
            cpuUsagePercent: 80.0,
            processingOverheadPercent: 20.0,
            detectionLatencyMs: 50.0
        )

        XCTAssertEqual(poorPerformance.performanceLevel, .poor, "Should be poor performance")
    }

    // MARK: - Extension Tests

    func testMetadataExtensions() {
        let basicMetadata = ProcessingMetadata.create(
            for: sampleVideoId,
            with: sampleConfig,
            rallySegments: sampleRallySegments,
            stats: sampleProcessingStats,
            quality: sampleQualityMetrics,
            performance: samplePerformanceData
        )

        XCTAssertFalse(basicMetadata.hasEnhancedData, "Basic metadata should not have enhanced data")
        XCTAssertEqual(basicMetadata.rallyCount, 2, "Should have 2 rallies")
        XCTAssertEqual(basicMetadata.totalRallyDuration, 33.0, accuracy: 0.1, "Total rally duration should be ~33 seconds")
        XCTAssertEqual(basicMetadata.averageRallyDuration, 16.5, accuracy: 0.1, "Average rally duration should be ~16.5 seconds")

        let estimatedSize = basicMetadata.storageEstimateKB
        XCTAssertGreaterThan(estimatedSize, 0, "Storage estimate should be positive")
        XCTAssertLessThan(estimatedSize, 50, "Storage estimate should be reasonable for basic metadata")
    }

    // MARK: - Error Handling Tests

    func testInvalidJSONDecoding() {
        let invalidJSON = """
        {
            "id": "not-a-uuid",
            "videoId": "also-not-a-uuid",
            "processingDate": "invalid-date"
        }
        """

        let jsonData = invalidJSON.data(using: .utf8)!
        let decoder = JSONDecoder()

        XCTAssertThrowsError(try decoder.decode(ProcessingMetadata.self, from: jsonData)) { error in
            XCTAssertTrue(error is DecodingError, "Should throw DecodingError for invalid JSON")
        }
    }

    // MARK: - Performance Tests

    func testJSONEncodingPerformance() {
        let metadata = ProcessingMetadata.createWithEnhancedData(
            for: sampleVideoId,
            with: sampleConfig,
            rallySegments: sampleRallySegments,
            stats: sampleProcessingStats,
            quality: sampleQualityMetrics,
            trajectories: createLargeProcessingTrajectoryDataset(),
            classifications: createSampleClassifications(),
            physics: createSamplePhysicsValidation(),
            performance: samplePerformanceData
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(metadata)
            }
        }
    }

    func testJSONDecodingPerformance() throws {
        let metadata = ProcessingMetadata.createWithEnhancedData(
            for: sampleVideoId,
            with: sampleConfig,
            rallySegments: sampleRallySegments,
            stats: sampleProcessingStats,
            quality: sampleQualityMetrics,
            trajectories: createLargeProcessingTrajectoryDataset(),
            classifications: createSampleClassifications(),
            physics: createSamplePhysicsValidation(),
            performance: samplePerformanceData
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(metadata)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        measure {
            for _ in 0..<100 {
                _ = try! decoder.decode(ProcessingMetadata.self, from: jsonData)
            }
        }
    }

    // MARK: - Helper Methods

    private func createSampleTrajectories() -> [ProcessingTrajectoryData] {
        return [
            ProcessingTrajectoryData(
                id: UUID(),
                startTime: 10.0,
                endTime: 12.5,
                points: createSampleTrajectoryPoints(count: 5),
                rSquared: 0.92,
                movementType: .airborne,
                confidence: 0.85,
                quality: 0.88
            ),
            ProcessingTrajectoryData(
                id: UUID(),
                startTime: 20.0,
                endTime: 21.8,
                points: createSampleTrajectoryPoints(count: 3),
                rSquared: 0.78,
                movementType: .rolling,
                confidence: 0.72,
                quality: 0.75
            ),
            ProcessingTrajectoryData(
                id: UUID(),
                startTime: 55.0,
                endTime: 57.2,
                points: createSampleTrajectoryPoints(count: 7),
                rSquared: 0.94,
                movementType: .airborne,
                confidence: 0.91,
                quality: 0.89
            )
        ]
    }

    private func createLargeProcessingTrajectoryDataset() -> [ProcessingTrajectoryData] {
        return (0..<50).map { _ in
            ProcessingTrajectoryData(
                id: UUID(),
                startTime: Double.random(in: 0...300),
                endTime: Double.random(in: 301...600),
                points: createSampleTrajectoryPoints(count: Int.random(in: 5...20)),
                rSquared: Double.random(in: 0.7...0.95),
                movementType: MovementType.allCases.randomElement()!,
                confidence: Double.random(in: 0.6...0.95),
                quality: Double.random(in: 0.6...0.9)
            )
        }
    }

    private func createSampleTrajectoryPoints(count: Int) -> [ProcessingTrajectoryPoint] {
        return (0..<count).map { _ in
            ProcessingTrajectoryPoint(
                timestamp: CMTimeMakeWithSeconds(Double.random(in: 0...10), preferredTimescale: 600),
                position: CGPoint(x: Double.random(in: 0...1), y: Double.random(in: 0...1)),
                velocity: Double.random(in: 5...25),
                acceleration: Double.random(in: -5...5),
                confidence: Double.random(in: 0.7...0.95)
            )
        }
    }

    private func createSampleClassifications() -> [ProcessingClassificationResult] {
        let trajectoryId = UUID()
        return [
            ProcessingClassificationResult(
                trajectoryId: trajectoryId,
                timestamp: CMTimeMakeWithSeconds(10.5, preferredTimescale: 600),
                movementType: .airborne,
                confidence: 0.87,
                classificationDetails: ClassificationDetails(
                    velocityConsistency: 0.85,
                    accelerationPattern: 0.89,
                    smoothnessScore: 0.82,
                    verticalMotionScore: 0.91,
                    timeSpan: 2.5
                )
            ),
            ProcessingClassificationResult(
                trajectoryId: UUID(),
                timestamp: CMTimeMakeWithSeconds(25.3, preferredTimescale: 600),
                movementType: .rolling,
                confidence: 0.73,
                classificationDetails: ClassificationDetails(
                    velocityConsistency: 0.78,
                    accelerationPattern: 0.65,
                    smoothnessScore: 0.81,
                    verticalMotionScore: 0.45,
                    timeSpan: 1.8
                )
            )
        ]
    }

    private func createSamplePhysicsValidation() -> [PhysicsValidationData] {
        let trajectoryId = UUID()
        return [
            PhysicsValidationData(
                trajectoryId: trajectoryId,
                timestamp: CMTimeMakeWithSeconds(11.0, preferredTimescale: 600),
                isValid: true,
                rSquared: 0.92,
                curvatureValid: true,
                accelerationValid: true,
                velocityConsistent: true,
                positionJumpsValid: true,
                confidenceLevel: 0.89
            ),
            PhysicsValidationData(
                trajectoryId: trajectoryId,
                timestamp: CMTimeMakeWithSeconds(12.0, preferredTimescale: 600),
                isValid: false,
                rSquared: 0.65,
                curvatureValid: false,
                accelerationValid: true,
                velocityConsistent: true,
                positionJumpsValid: false,
                confidenceLevel: 0.42
            ),
            PhysicsValidationData(
                trajectoryId: UUID(),
                timestamp: CMTimeMakeWithSeconds(26.0, preferredTimescale: 600),
                isValid: true,
                rSquared: 0.88,
                curvatureValid: true,
                accelerationValid: true,
                velocityConsistent: false,
                positionJumpsValid: true,
                confidenceLevel: 0.76
            )
        ]
    }
}