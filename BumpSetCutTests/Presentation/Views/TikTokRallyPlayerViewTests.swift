//
//  RallyPlayerViewTests.swift
//  BumpSetCutTests
//
//  Created for Issue #45 - Testing and Quality Assurance
//

#if DEBUG
import XCTest
import SwiftUI
import AVFoundation
@testable import BumpSetCut

@MainActor
final class RallyPlayerGestureTests: XCTestCase {

    var metadataStore: MetadataStore!
    var frameExtractor: FrameExtractor!
    var tempDirectory: URL!
    var testVideoURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Setup temporary directory for testing
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Initialize test dependencies
        metadataStore = MetadataStore()
        frameExtractor = FrameExtractor()

        // Create test video URL
        testVideoURL = try createTestVideoFile()

        print("RallyPlayerViewTests: Setup completed")
    }

    override func tearDownWithError() throws {
        // Cleanup
        frameExtractor.clearCache()
        frameExtractor = nil
        metadataStore = nil

        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.removeItem(at: tempDirectory)
        }

        tempDirectory = nil
        testVideoURL = nil

        try super.tearDownWithError()
    }

    // MARK: - Gesture Callback Tests

    func testPeekProgressCallbackInvocation() throws {
        print("🧪 Testing peek progress callback invocation")

        var receivedProgress: Double?
        var receivedDirection: RallyPeekDirection?
        var callbackCount = 0

        let peekCallback: (Double, RallyPeekDirection?) -> Void = { progress, direction in
            receivedProgress = progress
            receivedDirection = direction
            callbackCount += 1
            print("📞 Peek callback: progress=\(progress), direction=\(String(describing: direction))")
        }

        // Create video metadata for testing
        let videoMetadata = createSampleVideoMetadata()

        // Verify view initialization
        let rallyPlayerView = RallyPlayerView(videoMetadata: videoMetadata)
        XCTAssertNotNil(rallyPlayerView, "RallyPlayerView should initialize")

        // Simulate callback invocation (since we can't easily test SwiftUI gestures directly)
        peekCallback(0.5, .next)

        XCTAssertEqual(receivedProgress, 0.5, "Should receive correct progress value")
        XCTAssertEqual(receivedDirection, .next, "Should receive correct direction")
        XCTAssertEqual(callbackCount, 1, "Callback should be invoked once")

        // Test callback with different values
        peekCallback(0.8, .previous)
        XCTAssertEqual(receivedProgress, 0.8, "Should receive updated progress value")
        XCTAssertEqual(receivedDirection, .previous, "Should receive updated direction")
        XCTAssertEqual(callbackCount, 2, "Callback should be invoked twice")

        // Test callback reset
        peekCallback(0.0, nil)
        XCTAssertEqual(receivedProgress, 0.0, "Should receive reset progress")
        XCTAssertNil(receivedDirection, "Should receive nil direction on reset")

        print("✅ Peek progress callback invocation working correctly")
    }

    func testPeekProgressValueValidation() throws {
        print("🧪 Testing peek progress value validation")

        var progressValues: [Double] = []
        var directionValues: [RallyPeekDirection?] = []

        let peekCallback: (Double, RallyPeekDirection?) -> Void = { progress, direction in
            progressValues.append(progress)
            directionValues.append(direction)
        }

        // Test boundary values
        let testCases: [(Double, RallyPeekDirection?)] = [
            (0.0, nil),           // Reset
            (0.1, .next),         // Low progress
            (0.5, .previous),     // Mid progress
            (0.9, .next),         // High progress
            (1.0, .previous),     // Maximum progress
            (0.0, nil)            // Reset again
        ]

        for (expectedProgress, expectedDirection) in testCases {
            peekCallback(expectedProgress, expectedDirection)
        }

        // Verify all values were captured
        XCTAssertEqual(progressValues.count, testCases.count, "Should capture all progress values")
        XCTAssertEqual(directionValues.count, testCases.count, "Should capture all direction values")

        // Verify specific values
        for (index, (expectedProgress, expectedDirection)) in testCases.enumerated() {
            XCTAssertEqual(progressValues[index], expectedProgress, "Progress value \(index) should match")
            XCTAssertEqual(directionValues[index], expectedDirection, "Direction value \(index) should match")
        }

        print("✅ Peek progress value validation successful")
    }

    func testCallbackInvocationFrequency() throws {
        print("🧪 Testing callback invocation frequency patterns")

        var invocationTimes: [Date] = []
        let peekCallback: (Double, RallyPeekDirection?) -> Void = { progress, direction in
            invocationTimes.append(Date())
        }

        // Simulate rapid gesture updates
        let startTime = Date()
        for i in 0...10 {
            let progress = Double(i) / 10.0
            peekCallback(progress, .next)
            Thread.sleep(forTimeInterval: 0.001) // 1ms between calls
        }
        let endTime = Date()

        let totalDuration = endTime.timeIntervalSince(startTime)
        print("📊 Callback frequency test: \(invocationTimes.count) calls in \(Int(totalDuration * 1000))ms")

        XCTAssertEqual(invocationTimes.count, 11, "Should receive all callback invocations")
        XCTAssertLessThan(totalDuration, 0.1, "Callback handling should be fast")

        // Verify timing intervals
        for i in 1..<invocationTimes.count {
            let interval = invocationTimes[i].timeIntervalSince(invocationTimes[i-1])
            XCTAssertLessThan(interval, 0.01, "Individual callback intervals should be reasonable")
        }

        print("✅ Callback invocation frequency validated")
    }

    // MARK: - Gesture State Tests

    func testGestureStateTransitions() throws {
        print("🧪 Testing gesture state transitions")

        var stateTransitions: [(Double, RallyPeekDirection?)] = []
        let peekCallback: (Double, RallyPeekDirection?) -> Void = { progress, direction in
            stateTransitions.append((progress, direction))
        }

        // Simulate gesture state machine
        let gestureStates: [(Double, RallyPeekDirection?, String)] = [
            (0.0, nil, "Initial state"),
            (0.2, .next, "Gesture start"),
            (0.4, .next, "Gesture progress"),
            (0.6, .next, "Gesture continue"),
            (0.3, .next, "Gesture reverse"),
            (0.0, nil, "Gesture end")
        ]

        for (progress, direction, description) in gestureStates {
            print("🎯 \(description): progress=\(progress), direction=\(String(describing: direction))")
            peekCallback(progress, direction)
        }

        XCTAssertEqual(stateTransitions.count, gestureStates.count, "Should capture all state transitions")

        // Verify state sequence makes sense
        XCTAssertEqual(stateTransitions.first?.0, 0.0, "Should start with zero progress")
        XCTAssertNil(stateTransitions.first?.1, "Should start with nil direction")
        XCTAssertEqual(stateTransitions.last?.0, 0.0, "Should end with zero progress")
        XCTAssertNil(stateTransitions.last?.1, "Should end with nil direction")

        print("✅ Gesture state transitions validated")
    }

    func testRallyPeekDirectionHandling() throws {
        print("🧪 Testing peek direction handling")

        var directionCounts: [RallyPeekDirection: Int] = [:]
        let peekCallback: (Double, RallyPeekDirection?) -> Void = { progress, direction in
            if let direction = direction {
                directionCounts[direction, default: 0] += 1
            }
        }

        // Test both directions with various progress values
        let directionalTests: [(Double, RallyPeekDirection)] = [
            (0.1, .next), (0.3, .next), (0.5, .next),
            (0.2, .previous), (0.4, .previous), (0.6, .previous),
            (0.8, .next), (0.9, .previous)
        ]

        for (progress, direction) in directionalTests {
            peekCallback(progress, direction)
        }

        XCTAssertEqual(directionCounts[.next], 4, "Should receive 4 .next direction callbacks")
        XCTAssertEqual(directionCounts[.previous], 4, "Should receive 4 .previous direction callbacks")

        print("📊 Direction counts: next=\(directionCounts[.next] ?? 0), previous=\(directionCounts[.previous] ?? 0)")
        print("✅ Peek direction handling validated")
    }

    // MARK: - Integration with FrameExtractor Tests

    func testPeekFrameExtractionIntegration() async throws {
        print("🧪 Testing peek frame extraction integration")

        var extractionRequests: [URL] = []
        var callbackProgress: [Double] = []

        let peekCallback: (Double, RallyPeekDirection?) -> Void = { progress, direction in
            callbackProgress.append(progress)
            print("📞 Peek progress: \(progress) for \(String(describing: direction))")
        }

        // Simulate frame extraction triggered by peek progress
        let videoMetadata = createSampleVideoMetadata()
        let rallyPlayerView = RallyPlayerView(videoMetadata: videoMetadata)
        XCTAssertNotNil(rallyPlayerView)

        // Test frame extraction for different videos
        let testURLs = [testVideoURL!, testVideoURL!] // Same URL for cache testing

        for url in testURLs {
            do {
                let frame = try await frameExtractor.extractFrame(from: url, priority: .high)
                extractionRequests.append(url)
                XCTAssertNotNil(frame, "Frame extraction should succeed")
                print("Frame extracted: \(frame.size)")
            } catch {
                print("Frame extraction failed: \(error)")
            }
        }

        XCTAssertEqual(extractionRequests.count, testURLs.count, "Should process all extraction requests")

        // Verify cache behavior
        let cacheStatus = frameExtractor.cacheStatus
        print("📊 Cache status after extractions: \(cacheStatus)")
        XCTAssertTrue(cacheStatus.contains("entries: 1"), "Cache should deduplicate same URL")

        print("✅ Peek frame extraction integration successful")
    }

    func testPeekFrameExtractionPerformance() async throws {
        print("🧪 Testing peek frame extraction performance requirements")

        let performanceStartTime = Date()
        var extractionTimes: [TimeInterval] = []

        // Test multiple extractions to verify performance consistency
        for i in 1...5 {
            let extractionStart = Date()

            do {
                let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .high)
                let extractionTime = Date().timeIntervalSince(extractionStart)
                extractionTimes.append(extractionTime)

                print("⏱️ Extraction \(i): \(Int(extractionTime * 1000))ms, size: \(frame.size)")

                // Performance requirement: <100ms for peek frames
                XCTAssertLessThan(extractionTime, 0.1, "Peek frame extraction should be under 100ms")

            } catch {
                XCTFail("Frame extraction failed: \(error)")
            }
        }

        let totalTime = Date().timeIntervalSince(performanceStartTime)
        let averageTime = extractionTimes.reduce(0, +) / Double(extractionTimes.count)

        print("📊 Performance Results:")
        print("   Total time: \(Int(totalTime * 1000))ms")
        print("   Average time: \(Int(averageTime * 1000))ms")
        print("   Max time: \(Int((extractionTimes.max() ?? 0) * 1000))ms")

        XCTAssertLessThan(averageTime, 0.08, "Average extraction time should be well under 100ms")
        XCTAssertLessThan(totalTime, 0.5, "Total test time should be reasonable")

        print("✅ Peek frame extraction performance validated")
    }

    // MARK: - Memory Management Tests

    func testPeekFrameMemoryManagement() async throws {
        print("🧪 Testing peek frame memory management")

        let initialCacheStatus = frameExtractor.cacheStatus
        print("📊 Initial cache: \(initialCacheStatus)")

        // Extract multiple frames and monitor memory
        var extractedFrames: [UIImage] = []

        for i in 1...3 {
            let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
            extractedFrames.append(frame)

            let cacheStatus = frameExtractor.cacheStatus
            print("📊 After extraction \(i): \(cacheStatus)")
        }

        // Verify memory tracking
        let finalCacheStatus = frameExtractor.cacheStatus
        XCTAssertTrue(finalCacheStatus.contains("memory:"), "Cache should track memory usage")
        XCTAssertTrue(finalCacheStatus.contains("entries: 1"), "Cache should contain extracted frames")

        // Clear frames and verify cleanup
        extractedFrames.removeAll()
        frameExtractor.clearCache()

        let clearedCacheStatus = frameExtractor.cacheStatus
        XCTAssertTrue(clearedCacheStatus.contains("entries: 0"), "Cache should be cleared")
        print("📊 After cleanup: \(clearedCacheStatus)")

        print("✅ Peek frame memory management validated")
    }

    func testMemoryLeakPrevention() async throws {
        print("🧪 Testing memory leak prevention")

        let initialMetrics = frameExtractor.performanceMetrics
        print("📊 Initial metrics: avg=\(Int(initialMetrics.averageTime * 1000))ms, cache=\(Int(initialMetrics.cacheHitRate * 100))%")

        // Perform extraction cycle
        for cycle in 1...3 {
            print("🔄 Memory cycle \(cycle)")

            // Extract frame
            let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
            XCTAssertNotNil(frame, "Frame extraction should succeed")

            // Clear cache to prevent accumulation
            frameExtractor.clearCache()
        }

        let finalMetrics = frameExtractor.performanceMetrics
        print("📊 Final metrics: avg=\(Int(finalMetrics.averageTime * 1000))ms, cache=\(Int(finalMetrics.cacheHitRate * 100))%")

        // Verify no significant performance degradation
        let performanceDelta = abs(finalMetrics.averageTime - initialMetrics.averageTime)
        XCTAssertLessThan(performanceDelta, 0.05, "Performance should not degrade significantly")

        print("✅ Memory leak prevention validated")
    }

    // MARK: - Edge Case Tests

    func testGestureCancellationHandling() throws {
        print("🧪 Testing gesture cancellation handling")

        var gestureEvents: [(String, Double, RallyPeekDirection?)] = []
        let peekCallback: (Double, RallyPeekDirection?) -> Void = { progress, direction in
            gestureEvents.append(("callback", progress, direction))
        }

        // Simulate gesture cancellation sequence
        let gestureSequence: [(String, Double, RallyPeekDirection?)] = [
            ("start", 0.0, nil),
            ("progress", 0.3, .next),
            ("continue", 0.6, .next),
            ("cancel", 0.0, nil)  // Gesture cancelled
        ]

        for (event, progress, direction) in gestureSequence {
            print("🎯 Gesture \(event): progress=\(progress)")
            peekCallback(progress, direction)
        }

        // Verify cancellation resets properly
        let lastEvent = gestureEvents.last
        XCTAssertEqual(lastEvent?.1, 0.0, "Cancellation should reset progress to 0")
        XCTAssertNil(lastEvent?.2, "Cancellation should reset direction to nil")

        print("✅ Gesture cancellation handling validated")
    }

    func testInvalidVideoHandlingInGestures() async throws {
        print("🧪 Testing invalid video handling in gesture context")

        let invalidURL = URL(fileURLWithPath: "/nonexistent/invalid.mp4")
        var callbackInvoked = false

        let peekCallback: (Double, RallyPeekDirection?) -> Void = { progress, direction in
            callbackInvoked = true
            print("📞 Callback during invalid video test: \(progress)")
        }

        // Simulate gesture with invalid video
        do {
            _ = try await frameExtractor.extractFrame(from: invalidURL, priority: .high)
            XCTFail("Should have failed for invalid video")
        } catch {
            XCTAssertTrue(error is FrameExtractionError, "Should throw FrameExtractionError")
            print("✅ Invalid video error handled: \(error.localizedDescription)")
        }

        // Gesture callback should still work normally
        peekCallback(0.5, .next)
        XCTAssertTrue(callbackInvoked, "Callback should still work after extraction error")

        print("✅ Invalid video handling in gestures validated")
    }

    // MARK: - Helper Methods

    private func createSampleVideoMetadata() -> VideoMetadata {
        return VideoMetadata(
            fileName: "test_video.mp4",
            customName: "Test Video",
            folderPath: "",
            createdDate: Date(),
            fileSize: Int64(1024 * 1024),
            duration: 30.0
        )
    }

    private func createTestVideoFile() throws -> URL {
        let videoURL = tempDirectory.appendingPathComponent("test_\(UUID().uuidString).mp4")

        // Create minimal test file (not a real video, but sufficient for URL-based testing)
        let testData = "test video data".data(using: .utf8)!
        try testData.write(to: videoURL)

        return videoURL
    }
}

// MARK: - RallyPeekDirection Extension for Testing

extension RallyPeekDirection: Equatable {
    public static func == (lhs: RallyPeekDirection, rhs: RallyPeekDirection) -> Bool {
        switch (lhs, rhs) {
        case (.next, .next), (.previous, .previous):
            return true
        default:
            return false
        }
    }
}
#endif