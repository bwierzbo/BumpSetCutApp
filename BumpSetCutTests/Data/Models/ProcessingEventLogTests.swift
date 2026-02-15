//
//  ProcessingEventLogTests.swift
//  BumpSetCutTests
//

import XCTest
import CoreMedia
@testable import BumpSetCut

final class ProcessingEventLogTests: XCTestCase {

    // MARK: - Basic Event Logging

    func testLogCreatesEventsWithIncreasingTimestamps() {
        let log = ProcessingEventLog()

        log.log(.processingStarted, detail: "test")
        // Small delay to ensure monotonic timestamps
        Thread.sleep(forTimeInterval: 0.01)
        log.log(.sportDetected, detail: "beach")
        Thread.sleep(forTimeInterval: 0.01)
        log.log(.frameLoopStarted)

        let events = log.allEvents
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events[0].timestamp <= events[1].timestamp)
        XCTAssertTrue(events[1].timestamp <= events[2].timestamp)
    }

    func testLogEventTypes() {
        let log = ProcessingEventLog()

        log.log(.processingStarted)
        log.log(.sportDetected)
        log.log(.frameLoopStarted)
        log.log(.rallyStarted)
        log.log(.rallyEnded)
        log.log(.segmentFinalized)
        log.log(.processingCompleted)

        let types = log.allEvents.map(\.type)
        XCTAssertEqual(types, [
            .processingStarted,
            .sportDetected,
            .frameLoopStarted,
            .rallyStarted,
            .rallyEnded,
            .segmentFinalized,
            .processingCompleted
        ])
    }

    func testLogWithVideoTime() {
        let log = ProcessingEventLog()

        log.log(.rallyStarted, videoTime: 12.5, detail: "hasBall=true")

        let event = log.allEvents.first
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.videoTime, 12.5)
        XCTAssertEqual(event?.type, .rallyStarted)
        XCTAssertEqual(event?.detail, "hasBall=true")
    }

    func testLogWithCMTime() {
        let log = ProcessingEventLog()
        let cmTime = CMTimeMakeWithSeconds(30.0, preferredTimescale: 600)

        log.log(.rallyEnded, at: cmTime, detail: "timeout")

        let event = log.allEvents.first
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.videoTime ?? 0, 30.0, accuracy: 0.001)
        XCTAssertEqual(event?.type, .rallyEnded)
    }

    func testLogWithNilVideoTime() {
        let log = ProcessingEventLog()

        log.log(.processingStarted, detail: "no video time")

        let event = log.allEvents.first
        XCTAssertNotNil(event)
        XCTAssertNil(event?.videoTime)
    }

    func testLogWithNilDetail() {
        let log = ProcessingEventLog()

        log.log(.processingCompleted)

        let event = log.allEvents.first
        XCTAssertNotNil(event)
        XCTAssertNil(event?.detail)
    }

    // MARK: - Serialization

    func testEventRoundTripEncoding() throws {
        let log = ProcessingEventLog()
        log.log(.processingStarted, detail: "videoId=test")
        log.log(.sportDetected, videoTime: 0.0, detail: "beach")
        log.log(.rallyStarted, videoTime: 5.5, detail: "hasBall=true")
        log.log(.processingCompleted, detail: "rallies=3")

        let events = log.allEvents

        let encoder = JSONEncoder()
        let data = try encoder.encode(events)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode([ProcessingEvent].self, from: data)

        XCTAssertEqual(decoded.count, events.count)
        for (original, roundTripped) in zip(events, decoded) {
            XCTAssertEqual(original.type, roundTripped.type)
            XCTAssertEqual(original.timestamp, roundTripped.timestamp, accuracy: 0.0001)
            XCTAssertEqual(original.videoTime, roundTripped.videoTime)
            XCTAssertEqual(original.detail, roundTripped.detail)
        }
    }

    func testEventTypeRawValues() {
        // Ensure raw values are stable for persisted data
        XCTAssertEqual(ProcessingEvent.EventType.processingStarted.rawValue, "processingStarted")
        XCTAssertEqual(ProcessingEvent.EventType.sportDetected.rawValue, "sportDetected")
        XCTAssertEqual(ProcessingEvent.EventType.frameLoopStarted.rawValue, "frameLoopStarted")
        XCTAssertEqual(ProcessingEvent.EventType.rallyStarted.rawValue, "rallyStarted")
        XCTAssertEqual(ProcessingEvent.EventType.rallyEnded.rawValue, "rallyEnded")
        XCTAssertEqual(ProcessingEvent.EventType.segmentFinalized.rawValue, "segmentFinalized")
        XCTAssertEqual(ProcessingEvent.EventType.processingCompleted.rawValue, "processingCompleted")
        XCTAssertEqual(ProcessingEvent.EventType.processingFailed.rawValue, "processingFailed")
        XCTAssertEqual(ProcessingEvent.EventType.saveStarted.rawValue, "saveStarted")
        XCTAssertEqual(ProcessingEvent.EventType.saveCompleted.rawValue, "saveCompleted")
        XCTAssertEqual(ProcessingEvent.EventType.saveFailed.rawValue, "saveFailed")
    }

    // MARK: - Event Log in ProcessingMetadata

    func testProcessingMetadataWithEventLog() throws {
        let log = ProcessingEventLog()
        log.log(.processingStarted, detail: "test run")
        log.log(.processingCompleted, detail: "success")

        let metadata = ProcessingMetadata.createWithEnhancedData(
            for: UUID(),
            with: ProcessorConfig(),
            rallySegments: [
                RallySegment(
                    startTime: CMTimeMakeWithSeconds(10.0, preferredTimescale: 600),
                    endTime: CMTimeMakeWithSeconds(20.0, preferredTimescale: 600),
                    confidence: 0.9,
                    quality: 0.8,
                    detectionCount: 30,
                    averageTrajectoryLength: 10.0
                )
            ],
            stats: ProcessingStats(
                totalFrames: 1000,
                processedFrames: 1000,
                detectionFrames: 500,
                trackingFrames: 400,
                rallyFrames: 300,
                physicsValidFrames: 200,
                totalDetections: 600,
                validTrajectories: 50,
                averageDetectionsPerFrame: 0.6,
                averageConfidence: 0.75,
                processingDuration: 5.0,
                framesPerSecond: 30.0
            ),
            quality: QualityMetrics(
                overallQuality: 0.8,
                averageRSquared: 0.85,
                trajectoryConsistency: 0.9,
                physicsValidationRate: 0.7,
                movementClassificationAccuracy: 0.8,
                confidenceDistribution: ConfidenceDistribution(high: 30, medium: 15, low: 5),
                qualityBreakdown: QualityBreakdown(
                    velocityConsistency: 0.8,
                    accelerationPattern: 0.7,
                    smoothnessScore: 0.85,
                    verticalMotionScore: 0.75,
                    overallCoherence: 0.8
                )
            ),
            trajectories: [],
            classifications: [],
            physics: [],
            performance: PerformanceData(
                processingStartTime: Date(),
                processingEndTime: Date(),
                averageFPS: 30.0,
                peakMemoryUsageMB: 100.0,
                averageMemoryUsageMB: 80.0,
                cpuUsagePercent: nil,
                processingOverheadPercent: 5.0,
                detectionLatencyMs: nil
            ),
            eventLog: log.allEvents
        )

        XCTAssertNotNil(metadata.eventLog)
        XCTAssertEqual(metadata.eventLog?.count, 2)
        XCTAssertEqual(metadata.eventLog?.first?.type, .processingStarted)
        XCTAssertEqual(metadata.eventLog?.last?.type, .processingCompleted)
    }

    func testProcessingMetadataWithoutEventLog() throws {
        // Verify backwards compatibility — eventLog is nil when not provided
        let metadata = ProcessingMetadata.create(
            for: UUID(),
            with: ProcessorConfig(),
            rallySegments: [],
            stats: ProcessingStats(
                totalFrames: 0, processedFrames: 0, detectionFrames: 0,
                trackingFrames: 0, rallyFrames: 0, physicsValidFrames: 0,
                totalDetections: 0, validTrajectories: 0,
                averageDetectionsPerFrame: 0, averageConfidence: 0,
                processingDuration: 0, framesPerSecond: 30
            ),
            quality: QualityMetrics(
                overallQuality: 0, averageRSquared: 0, trajectoryConsistency: 0,
                physicsValidationRate: 0, movementClassificationAccuracy: nil,
                confidenceDistribution: ConfidenceDistribution(high: 0, medium: 0, low: 0),
                qualityBreakdown: QualityBreakdown(
                    velocityConsistency: 0, accelerationPattern: 0,
                    smoothnessScore: 0, verticalMotionScore: 0, overallCoherence: 0
                )
            ),
            performance: PerformanceData(
                processingStartTime: Date(), processingEndTime: Date(),
                averageFPS: 30, peakMemoryUsageMB: 0, averageMemoryUsageMB: 0,
                cpuUsagePercent: nil, processingOverheadPercent: 0, detectionLatencyMs: nil
            )
        )

        XCTAssertNil(metadata.eventLog)
    }

    func testProcessingMetadataEventLogRoundTrip() throws {
        let log = ProcessingEventLog()
        log.log(.processingStarted, detail: "roundtrip test")
        log.log(.rallyStarted, videoTime: 10.5, detail: "evidence")
        log.log(.rallyEnded, videoTime: 25.0)
        log.log(.processingCompleted, detail: "rallies=1")

        let metadata = ProcessingMetadata.createWithEnhancedData(
            for: UUID(),
            with: ProcessorConfig(),
            rallySegments: [
                RallySegment(
                    startTime: CMTimeMakeWithSeconds(10.0, preferredTimescale: 600),
                    endTime: CMTimeMakeWithSeconds(25.0, preferredTimescale: 600),
                    confidence: 0.9, quality: 0.8, detectionCount: 30, averageTrajectoryLength: 10.0
                )
            ],
            stats: ProcessingStats(
                totalFrames: 1000, processedFrames: 1000, detectionFrames: 500,
                trackingFrames: 400, rallyFrames: 300, physicsValidFrames: 200,
                totalDetections: 600, validTrajectories: 50,
                averageDetectionsPerFrame: 0.6, averageConfidence: 0.75,
                processingDuration: 5.0, framesPerSecond: 30.0
            ),
            quality: QualityMetrics(
                overallQuality: 0.8, averageRSquared: 0.85,
                trajectoryConsistency: 0.9, physicsValidationRate: 0.7,
                movementClassificationAccuracy: 0.8,
                confidenceDistribution: ConfidenceDistribution(high: 30, medium: 15, low: 5),
                qualityBreakdown: QualityBreakdown(
                    velocityConsistency: 0.8, accelerationPattern: 0.7,
                    smoothnessScore: 0.85, verticalMotionScore: 0.75, overallCoherence: 0.8
                )
            ),
            trajectories: [],
            classifications: [],
            physics: [],
            performance: PerformanceData(
                processingStartTime: Date(), processingEndTime: Date(),
                averageFPS: 30.0, peakMemoryUsageMB: 100.0, averageMemoryUsageMB: 80.0,
                cpuUsagePercent: nil, processingOverheadPercent: 5.0, detectionLatencyMs: nil
            ),
            eventLog: log.allEvents
        )

        // Encode and decode the full metadata
        let encoder = JSONEncoder()
        let data = try encoder.encode(metadata)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ProcessingMetadata.self, from: data)

        XCTAssertNotNil(decoded.eventLog)
        XCTAssertEqual(decoded.eventLog?.count, 4)
        XCTAssertEqual(decoded.eventLog?[0].type, .processingStarted)
        XCTAssertEqual(decoded.eventLog?[1].type, .rallyStarted)
        XCTAssertEqual(decoded.eventLog?[1].videoTime ?? 0, 10.5, accuracy: 0.001)
        XCTAssertEqual(decoded.eventLog?[2].type, .rallyEnded)
        XCTAssertEqual(decoded.eventLog?[3].type, .processingCompleted)
    }

    func testBackwardsCompatibility_MetadataWithoutEventLog() throws {
        // Simulate a metadata JSON that was created before eventLog was added
        let jsonWithoutEventLog = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "videoId": "87654321-4321-4321-4321-210987654321",
            "processingVersion": "1.0",
            "processingDate": 0,
            "processingConfig": {
                "parabolaMinPoints": 5,
                "parabolaMinR2": 0.7,
                "accelConsistencyMaxStd": 1.0,
                "minVelocityToConsiderActive": 1.0,
                "projectileWindowSec": 0.5,
                "useGravityBand": true,
                "gravityMinA": -15.0,
                "gravityMaxA": -5.0,
                "yIncreasingDown": true,
                "maxJumpPerFrame": 0.15,
                "roiYRadius": 0.3,
                "trackGateRadius": 0.1,
                "minTrackAgeForPhysics": 3,
                "startBuffer": 2.0,
                "endTimeout": 3.0,
                "preroll": 1.5,
                "postroll": 1.5,
                "minGapToMerge": 3.0,
                "minSegmentLength": 2.0,
                "enableEnhancedPhysics": false,
                "enhancedMinR2": 0.8,
                "excellentR2Threshold": 0.95,
                "goodR2Threshold": 0.85,
                "acceptableR2Threshold": 0.7,
                "enablePhysicsConstraints": false,
                "maxAccelerationDeviation": 2.0,
                "velocityConsistencyThreshold": 0.7,
                "trajectorySmoothnessThreshold": 0.8,
                "movementClassifierEnabled": true,
                "minClassificationConfidence": 0.6,
                "airbornePhysicsThreshold": 0.7,
                "minAccelerationPattern": 0.3,
                "minSmoothnessForAirborne": 0.5,
                "maxVerticalMotionForRolling": 0.1,
                "minSmoothnessForRolling": 0.7,
                "maxAccelerationForRolling": 0.3
            },
            "rallySegments": [],
            "processingStats": {
                "totalFrames": 100,
                "processedFrames": 100,
                "detectionFrames": 50,
                "trackingFrames": 40,
                "rallyFrames": 30,
                "physicsValidFrames": 20,
                "totalDetections": 60,
                "validTrajectories": 5,
                "averageDetectionsPerFrame": 0.6,
                "averageConfidence": 0.75,
                "processingDuration": 2.0,
                "framesPerSecond": 30.0
            },
            "qualityMetrics": {
                "overallQuality": 0.8,
                "averageRSquared": 0.85,
                "trajectoryConsistency": 0.9,
                "physicsValidationRate": 0.7,
                "confidenceDistribution": { "high": 10, "medium": 5, "low": 2 },
                "qualityBreakdown": {
                    "velocityConsistency": 0.8,
                    "accelerationPattern": 0.7,
                    "smoothnessScore": 0.85,
                    "verticalMotionScore": 0.75,
                    "overallCoherence": 0.8
                }
            },
            "performanceMetrics": {
                "processingStartTime": 0,
                "processingEndTime": 0,
                "averageFPS": 30.0,
                "peakMemoryUsageMB": 0,
                "averageMemoryUsageMB": 0,
                "processingOverheadPercent": 5.0
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let metadata = try decoder.decode(ProcessingMetadata.self, from: jsonWithoutEventLog)

        // eventLog should be nil (not present in old data)
        XCTAssertNil(metadata.eventLog)
        // Other fields should decode normally
        XCTAssertEqual(metadata.processingVersion, "1.0")
        XCTAssertEqual(metadata.processingStats.totalFrames, 100)
    }
}
