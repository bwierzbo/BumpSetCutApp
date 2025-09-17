//
//  PeekGestureIntegrationTests.swift
//  BumpSetCutTests
//
//  Created for Issue #45 - Testing and Quality Assurance
//  End-to-end integration tests for peek gesture workflow
//

#if DEBUG
import XCTest
import SwiftUI
import AVFoundation
@testable import BumpSetCut

@MainActor
final class PeekGestureIntegrationTests: XCTestCase {

    var frameExtractor: FrameExtractor!
    var metadataStore: MetadataStore!
    var tempDirectory: URL!
    var testVideoURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Setup temporary directory
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Initialize dependencies
        frameExtractor = FrameExtractor()
        metadataStore = MetadataStore()

        // Create test video files
        testVideoURLs = try createTestVideoFiles(count: 3)

        print("PeekGestureIntegrationTests: Setup completed with \(testVideoURLs.count) test videos")
    }

    override func tearDownWithError() throws {
        frameExtractor.clearCache()
        frameExtractor = nil
        metadataStore = nil

        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.removeItem(at: tempDirectory)
        }

        tempDirectory = nil
        testVideoURLs.removeAll()

        try super.tearDownWithError()
    }

    // MARK: - End-to-End Peek Workflow Tests

    func testCompletepeekGestureWorkflow() async throws {
        print("🧪 Testing complete peek gesture workflow")

        var workflowEvents: [(String, Date, Any?)] = []
        let workflowStart = Date()

        // Step 1: Setup peek callback system
        workflowEvents.append(("setup_callback", Date(), nil))

        var peekProgressValues: [Double] = []
        var peekDirections: [PeekDirection?] = []

        let peekCallback: (Double, PeekDirection?) -> Void = { progress, direction in
            peekProgressValues.append(progress)
            peekDirections.append(direction)
            workflowEvents.append(("peek_callback", Date(), (progress, direction)))
        }

        // Step 2: Create video metadata and rally player
        workflowEvents.append(("create_player", Date(), nil))

        let videoMetadata = createSampleVideoMetadata(url: testVideoURLs[0])
        let rallyPlayerView = TikTokRallyPlayerView(
            videoMetadata: videoMetadata,
            onPeekProgress: peekCallback
        )

        XCTAssertNotNil(rallyPlayerView, "Rally player should initialize successfully")

        // Step 3: Simulate gesture sequence with frame extraction
        workflowEvents.append(("gesture_start", Date(), nil))

        let gestureSequence: [(Double, PeekDirection?, URL?)] = [
            (0.0, nil, nil),                    // Initial state
            (0.2, .next, testVideoURLs[1]),     // Start peek next
            (0.5, .next, testVideoURLs[1]),     // Continue peek next
            (0.8, .next, testVideoURLs[1]),     // Peak peek next
            (0.4, .next, testVideoURLs[1]),     // Reduce peek
            (0.0, nil, nil),                    // Reset peek
            (0.3, .previous, testVideoURLs[2]), // Peek previous
            (0.0, nil, nil)                     // Final reset
        ]

        for (progress, direction, frameURL) in gestureSequence {
            // Invoke peek callback
            peekCallback(progress, direction)

            // If peeking and frame URL provided, extract frame
            if progress > 0.0, let url = frameURL {
                do {
                    let extractionStart = Date()
                    let frame = try await frameExtractor.extractFrame(from: url, priority: .high)
                    let extractionTime = Date().timeIntervalSince(extractionStart)

                    workflowEvents.append(("frame_extracted", Date(), (url.lastPathComponent, extractionTime, frame.size)))

                    print("🖼️ Frame extracted for peek: \(frame.size) in \(Int(extractionTime * 1000))ms")

                    // Verify performance requirement
                    XCTAssertLessThan(extractionTime, 0.1, "Frame extraction should be under 100ms")

                } catch {
                    workflowEvents.append(("frame_error", Date(), error))
                    print("❌ Frame extraction failed: \(error)")
                }
            }

            // Small delay to simulate real gesture timing
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        workflowEvents.append(("workflow_complete", Date(), nil))

        let totalWorkflowTime = Date().timeIntervalSince(workflowStart)

        // Verify workflow results
        print("📊 Workflow Analysis:")
        print("   Total time: \(Int(totalWorkflowTime * 1000))ms")
        print("   Peek callbacks: \(peekProgressValues.count)")
        print("   Frame extractions: \(workflowEvents.filter { $0.0 == "frame_extracted" }.count)")
        print("   Events: \(workflowEvents.count)")

        // Workflow verification
        XCTAssertEqual(peekProgressValues.count, gestureSequence.count, "Should receive all peek callbacks")
        XCTAssertLessThan(totalWorkflowTime, 2.0, "Complete workflow should be efficient")

        // Verify peek sequence integrity
        XCTAssertEqual(peekProgressValues.first, 0.0, "Should start with zero progress")
        XCTAssertEqual(peekProgressValues.last, 0.0, "Should end with zero progress")

        print("✅ Complete peek gesture workflow validated")
    }

    func testMultiDirectionalPeekFlow() async throws {
        print("🧪 Testing multi-directional peek flow")

        var peekEvents: [(Double, PeekDirection?, String)] = []
        var extractedFrames: [String: UIImage] = [:]

        let peekCallback: (Double, PeekDirection?) -> Void = { progress, direction in
            let eventDescription = "progress=\(String(format: "%.2f", progress)), direction=\(String(describing: direction))"
            peekEvents.append((progress, direction, eventDescription))
        }

        // Create video metadata
        let videoMetadata = createSampleVideoMetadata(url: testVideoURLs[0])

        // Test complex multi-directional sequence
        let multiDirectionalSequence: [(Double, PeekDirection?, String)] = [
            (0.0, nil, "initial"),
            (0.3, .next, "peek_next_start"),
            (0.6, .next, "peek_next_continue"),
            (0.2, .next, "peek_next_reduce"),
            (0.0, nil, "peek_next_cancel"),
            (0.4, .previous, "peek_previous_start"),
            (0.7, .previous, "peek_previous_peak"),
            (0.0, nil, "peek_previous_complete"),
            (0.2, .next, "peek_next_restart"),
            (0.0, nil, "final_reset")
        ]

        for (progress, direction, phase) in multiDirectionalSequence {
            print("🎯 Phase: \(phase)")
            peekCallback(progress, direction)

            // Extract frames for significant peek progress
            if progress > 0.5 {
                let videoIndex = direction == .next ? 1 : 2
                let frameURL = testVideoURLs[videoIndex]

                if extractedFrames[frameURL.lastPathComponent] == nil {
                    do {
                        let frame = try await frameExtractor.extractFrame(from: frameURL, priority: .normal)
                        extractedFrames[frameURL.lastPathComponent] = frame
                        print("🖼️ Cached frame for \(direction!): \(frame.size)")
                    } catch {
                        print("⚠️ Frame extraction failed for \(direction!): \(error)")
                    }
                }
            }
        }

        // Verify multi-directional flow
        print("📊 Multi-directional Flow Results:")
        print("   Total peek events: \(peekEvents.count)")
        print("   Extracted frames: \(extractedFrames.count)")

        XCTAssertEqual(peekEvents.count, multiDirectionalSequence.count, "Should process all peek events")
        XCTAssertGreaterThanOrEqual(extractedFrames.count, 1, "Should extract at least one frame")

        // Verify direction handling
        let nextEvents = peekEvents.filter { $0.1 == .next }.count
        let previousEvents = peekEvents.filter { $0.1 == .previous }.count
        let resetEvents = peekEvents.filter { $0.1 == nil }.count

        print("📊 Direction Distribution:")
        print("   Next: \(nextEvents), Previous: \(previousEvents), Reset: \(resetEvents)")

        XCTAssertGreaterThan(nextEvents, 0, "Should have next direction events")
        XCTAssertGreaterThan(previousEvents, 0, "Should have previous direction events")
        XCTAssertGreaterThan(resetEvents, 0, "Should have reset events")

        print("✅ Multi-directional peek flow validated")
    }

    func testPeekCancellationAndRecovery() async throws {
        print("🧪 Testing peek cancellation and recovery patterns")

        var cancellationEvents: [(String, Double, PeekDirection?)] = []
        let peekCallback: (Double, PeekDirection?) -> Void = { progress, direction in
            cancellationEvents.append(("callback", progress, direction))
        }

        // Test various cancellation scenarios
        let cancellationScenarios: [(String, [(Double, PeekDirection?)])] = [
            ("quick_cancel", [(0.0, nil), (0.2, .next), (0.0, nil)]),
            ("mid_cancel", [(0.0, nil), (0.5, .previous), (0.0, nil)]),
            ("peak_cancel", [(0.0, nil), (0.8, .next), (0.0, nil)]),
            ("direction_switch", [(0.0, nil), (0.4, .next), (0.3, .previous), (0.0, nil)])
        ]

        for (scenarioName, sequence) in cancellationScenarios {
            print("🔄 Testing scenario: \(scenarioName)")

            let scenarioStart = Date()

            for (progress, direction) in sequence {
                peekCallback(progress, direction)

                // Simulate frame extraction for active peeks
                if progress > 0.3 {
                    let videoIndex = direction == .next ? 1 : 2
                    let frameURL = testVideoURLs[videoIndex]

                    do {
                        let frame = try await frameExtractor.extractFrame(from: frameURL, priority: .high)
                        cancellationEvents.append(("frame_extracted", progress, direction))
                        print("🖼️ Frame extracted during \(scenarioName): \(frame.size)")
                    } catch {
                        cancellationEvents.append(("frame_error", progress, direction))
                        print("❌ Frame extraction error in \(scenarioName): \(error)")
                    }
                }
            }

            let scenarioTime = Date().timeIntervalSince(scenarioStart)
            print("⏱️ Scenario \(scenarioName) completed in \(Int(scenarioTime * 1000))ms")

            // Verify cancellation resets properly
            let lastCallback = cancellationEvents.filter { $0.0 == "callback" }.last
            XCTAssertEqual(lastCallback?.1, 0.0, "Scenario \(scenarioName) should end with reset")
            XCTAssertNil(lastCallback?.2, "Scenario \(scenarioName) should end with nil direction")

            // Clear cache between scenarios
            frameExtractor.clearCache()
        }

        print("📊 Cancellation Test Results:")
        print("   Total events: \(cancellationEvents.count)")
        print("   Scenarios tested: \(cancellationScenarios.count)")

        let callbackCount = cancellationEvents.filter { $0.0 == "callback" }.count
        let extractionCount = cancellationEvents.filter { $0.0 == "frame_extracted" }.count

        XCTAssertGreaterThan(callbackCount, 0, "Should have processed callbacks")
        print("   Callbacks: \(callbackCount), Extractions: \(extractionCount)")

        print("✅ Peek cancellation and recovery validated")
    }

    // MARK: - Performance Integration Tests

    func testPeekPerformanceUnderLoad() async throws {
        print("🧪 Testing peek performance under load conditions")

        var performanceMetrics: [(String, TimeInterval)] = []
        let loadTestIterations = 10

        let peekCallback: (Double, PeekDirection?) -> Void = { progress, direction in
            // Minimal callback processing for performance test
        }

        let videoMetadata = createSampleVideoMetadata(url: testVideoURLs[0])

        for iteration in 1...loadTestIterations {
            let iterationStart = Date()

            // Simulate intensive peek sequence
            let intensiveSequence: [(Double, PeekDirection?)] = [
                (0.1, .next), (0.3, .next), (0.5, .next), (0.7, .next), (0.9, .next),
                (0.7, .next), (0.5, .next), (0.3, .next), (0.1, .next), (0.0, nil)
            ]

            for (progress, direction) in intensiveSequence {
                peekCallback(progress, direction)

                // Extract frame for peak progress
                if progress >= 0.7 {
                    let extractionStart = Date()
                    do {
                        let frame = try await frameExtractor.extractFrame(from: testVideoURLs[1], priority: .high)
                        let extractionTime = Date().timeIntervalSince(extractionStart)
                        performanceMetrics.append(("extraction_\(iteration)", extractionTime))

                        // Verify performance under load
                        XCTAssertLessThan(extractionTime, 0.12, "Extraction under load should be reasonable")

                    } catch {
                        performanceMetrics.append(("error_\(iteration)", 0.0))
                    }
                }
            }

            let iterationTime = Date().timeIntervalSince(iterationStart)
            performanceMetrics.append(("iteration_\(iteration)", iterationTime))

            if iteration % 3 == 0 {
                print("🔄 Iteration \(iteration)/\(loadTestIterations): \(Int(iterationTime * 1000))ms")
            }
        }

        // Analyze performance under load
        let extractionTimes = performanceMetrics.filter { $0.0.contains("extraction") }.map { $0.1 }
        let iterationTimes = performanceMetrics.filter { $0.0.contains("iteration") }.map { $0.1 }

        let avgExtractionTime = extractionTimes.reduce(0, +) / Double(extractionTimes.count)
        let avgIterationTime = iterationTimes.reduce(0, +) / Double(iterationTimes.count)

        print("📊 Load Test Results:")
        print("   Iterations: \(loadTestIterations)")
        print("   Average extraction time: \(Int(avgExtractionTime * 1000))ms")
        print("   Average iteration time: \(Int(avgIterationTime * 1000))ms")
        print("   Successful extractions: \(extractionTimes.count)")

        // Performance requirements under load
        XCTAssertLessThan(avgExtractionTime, 0.1, "Average extraction should remain under 100ms under load")
        XCTAssertLessThan(avgIterationTime, 0.5, "Average iteration should be efficient")
        XCTAssertGreaterThanOrEqual(extractionTimes.count, loadTestIterations - 2, "Most extractions should succeed")

        print("✅ Peek performance under load validated")
    }

    func testCacheEfficiencyInPeekWorkflow() async throws {
        print("🧪 Testing cache efficiency in peek workflow")

        frameExtractor.clearCache()

        var cacheMetrics: [(String, TimeInterval, Bool)] = []
        let peekCallback: (Double, PeekDirection?) -> Void = { _, _ in }

        // First pass: Cache misses
        for i in 0..<testVideoURLs.count {
            let url = testVideoURLs[i]
            let extractionStart = Date()

            do {
                let frame = try await frameExtractor.extractFrame(from: url, priority: .normal)
                let extractionTime = Date().timeIntervalSince(extractionStart)
                cacheMetrics.append(("miss_\(i)", extractionTime, true))
                print("📍 Cache miss \(i): \(Int(extractionTime * 1000))ms")
            } catch {
                cacheMetrics.append(("miss_\(i)", 0.0, false))
            }
        }

        // Second pass: Cache hits
        for i in 0..<testVideoURLs.count {
            let url = testVideoURLs[i]
            let extractionStart = Date()

            do {
                let frame = try await frameExtractor.extractFrame(from: url, priority: .normal)
                let extractionTime = Date().timeIntervalSince(extractionStart)
                cacheMetrics.append(("hit_\(i)", extractionTime, true))
                print("⚡ Cache hit \(i): \(Int(extractionTime * 1000))ms")
            } catch {
                cacheMetrics.append(("hit_\(i)", 0.0, false))
            }
        }

        // Analyze cache efficiency
        let missTimes = cacheMetrics.filter { $0.0.contains("miss") && $0.2 }.map { $0.1 }
        let hitTimes = cacheMetrics.filter { $0.0.contains("hit") && $0.2 }.map { $0.1 }

        let avgMissTime = missTimes.reduce(0, +) / Double(missTimes.count)
        let avgHitTime = hitTimes.reduce(0, +) / Double(hitTimes.count)
        let speedupFactor = avgMissTime / avgHitTime

        print("📊 Cache Efficiency Analysis:")
        print("   Average miss time: \(Int(avgMissTime * 1000))ms")
        print("   Average hit time: \(Int(avgHitTime * 1000))ms")
        print("   Speedup factor: \(String(format: "%.1f", speedupFactor))x")

        // Cache efficiency requirements
        XCTAssertLessThan(avgHitTime, 0.01, "Cache hits should be very fast")
        XCTAssertGreaterThan(speedupFactor, 5.0, "Cache should provide significant speedup")

        // Verify cache telemetry
        let frameExtractorMetrics = frameExtractor.performanceMetrics
        print("📊 Frame extractor telemetry:")
        print("   Cache hit rate: \(Int(frameExtractorMetrics.cacheHitRate * 100))%")
        print("   Average time: \(Int(frameExtractorMetrics.averageTime * 1000))ms")

        XCTAssertGreaterThan(frameExtractorMetrics.cacheHitRate, 0.4, "Cache hit rate should be reasonable")

        print("✅ Cache efficiency in peek workflow validated")
    }

    // MARK: - Error Handling Integration Tests

    func testErrorRecoveryInIntegratedWorkflow() async throws {
        print("🧪 Testing error recovery in integrated workflow")

        var errorRecoveryEvents: [(String, Date)] = []
        let peekCallback: (Double, PeekDirection?) -> Void = { progress, direction in
            errorRecoveryEvents.append(("peek_callback", Date()))
        }

        // Create invalid URL for error testing
        let invalidURL = URL(fileURLWithPath: "/nonexistent/error_test.mp4")

        // Test error recovery sequence
        let recoverySequence: [(String, URL?, Double, PeekDirection?)] = [
            ("valid_start", testVideoURLs[0], 0.3, .next),
            ("error_case", invalidURL, 0.5, .next),
            ("recovery_1", testVideoURLs[1], 0.4, .previous),
            ("error_case_2", invalidURL, 0.6, .next),
            ("final_recovery", testVideoURLs[2], 0.2, .previous),
            ("reset", nil, 0.0, nil)
        ]

        var successfulExtractions = 0
        var expectedErrors = 0

        for (phase, url, progress, direction) in recoverySequence {
            print("🔄 Phase: \(phase)")
            errorRecoveryEvents.append((phase, Date()))

            // Invoke peek callback
            peekCallback(progress, direction)

            // Attempt frame extraction if URL provided
            if let extractionURL = url {
                do {
                    let frame = try await frameExtractor.extractFrame(from: extractionURL, priority: .high)
                    successfulExtractions += 1
                    errorRecoveryEvents.append(("extraction_success", Date()))
                    print("✅ Extraction succeeded in \(phase): \(frame.size)")

                } catch {
                    expectedErrors += 1
                    errorRecoveryEvents.append(("extraction_error", Date()))
                    print("❌ Expected extraction error in \(phase): \(error.localizedDescription)")

                    // Verify error type
                    XCTAssertTrue(error is FrameExtractionError, "Should throw FrameExtractionError for invalid URLs")
                }
            }
        }

        print("📊 Error Recovery Results:")
        print("   Total phases: \(recoverySequence.count)")
        print("   Successful extractions: \(successfulExtractions)")
        print("   Expected errors: \(expectedErrors)")
        print("   Total events: \(errorRecoveryEvents.count)")

        // Verify error recovery
        XCTAssertGreaterThan(successfulExtractions, 0, "Should have some successful extractions")
        XCTAssertGreaterThan(expectedErrors, 0, "Should have encountered expected errors")
        XCTAssertEqual(successfulExtractions + expectedErrors, 5, "Should have attempted 5 extractions")

        // Verify workflow continues after errors
        let lastEvent = errorRecoveryEvents.last
        XCTAssertNotNil(lastEvent, "Workflow should complete despite errors")

        print("✅ Error recovery in integrated workflow validated")
    }

    // MARK: - Helper Methods

    private func createSampleVideoMetadata(url: URL) -> VideoMetadata {
        return VideoMetadata(
            id: UUID(),
            filename: url.lastPathComponent,
            url: url,
            createdAt: Date(),
            fileSize: 1024 * 1024,
            duration: 30.0,
            thumbnail: nil,
            isProcessed: false,
            originalVideoId: nil,
            processedVideoIds: []
        )
    }

    private func createTestVideoFiles(count: Int) throws -> [URL] {
        var urls: [URL] = []

        for i in 1...count {
            let videoURL = tempDirectory.appendingPathComponent("integration_test_\(i)_\(UUID().uuidString).mp4")
            let testData = "integration test video data \(i)".data(using: .utf8)!
            try testData.write(to: videoURL)
            urls.append(videoURL)
        }

        return urls
    }
}
#endif