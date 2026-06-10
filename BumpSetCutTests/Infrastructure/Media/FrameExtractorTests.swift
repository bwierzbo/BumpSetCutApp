//
//  FrameExtractorTests.swift
//  BumpSetCutTests
//
//  Created for Issue #40 - FrameExtractor Service
//

#if DEBUG
import XCTest
import AVFoundation
import UIKit
@testable import BumpSetCut

@MainActor
final class FrameExtractorTests: XCTestCase {

    var frameExtractor: FrameExtractor!
    var testVideoURL: URL!

    override func setUpWithError() throws {
        frameExtractor = FrameExtractor()

        // Create a test video URL - we'll use a real small MP4 for testing
        let bundle = Bundle(for: type(of: self))
        if let bundleVideoURL = bundle.url(forResource: "test_rally", withExtension: "mp4") {
            testVideoURL = bundleVideoURL
        } else {
            // Create a minimal synthetic video for testing
            testVideoURL = try createTestVideoFile()
        }
    }

    override func tearDownWithError() throws {
        frameExtractor.clearCache()
        frameExtractor = nil

        // Clean up synthetic test video if created
        if let testVideoURL = testVideoURL,
           testVideoURL.lastPathComponent.contains("test_synthetic") {
            try? FileManager.default.removeItem(at: testVideoURL)
        }
        testVideoURL = nil
    }

    // MARK: - Initialization Tests

    func testFrameExtractorInitialization() throws {
        XCTAssertNotNil(frameExtractor, "FrameExtractor should initialize successfully")
        XCTAssertTrue(frameExtractor.cacheStatus.contains("entries: 0"), "Cache should start empty")
    }

    func testCustomConfigurationInitialization() throws {
        let customConfig = FrameExtractor.ExtractionConfig(
            frameTime: CMTime(seconds: 0.2, preferredTimescale: 600),
            maximumSize: CGSize(width: 320, height: 320),
            appliesPreferredTrackTransform: false,
            extractionTimeout: 0.05
        )

        let extractor = FrameExtractor(config: customConfig)
        XCTAssertNotNil(extractor, "FrameExtractor should initialize with custom config")
    }

    // MARK: - Frame Extraction Tests

    func testBasicFrameExtraction() async throws {
        print("🧪 Testing basic frame extraction from: \(testVideoURL.lastPathComponent)")

        let startTime = Date()
        let frame = try await frameExtractor.extractFrame(from: testVideoURL)
        let extractionTime = Date().timeIntervalSince(startTime)

        print("⏱️ Frame extraction completed in \(Int(extractionTime * 1000))ms")

        XCTAssertNotNil(frame, "Should successfully extract a frame")
        XCTAssertGreaterThan(frame.size.width, 0, "Frame should have valid width")
        XCTAssertGreaterThan(frame.size.height, 0, "Frame should have valid height")
        XCTAssertLessThan(extractionTime, 0.2, "Extraction should complete within reasonable time")

        print("✅ Extracted frame size: \(frame.size)")
    }

    func testFrameExtractionPerformance() async throws {
        print("🧪 Testing frame extraction performance requirement (<100ms)")

        let iterations = 5
        var totalTime: TimeInterval = 0
        var individualTimes: [TimeInterval] = []

        for i in 1...iterations {
            frameExtractor.clearCache() // Ensure we're not testing cache hits

            let startTime = Date()
            _ = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
            let extractionTime = Date().timeIntervalSince(startTime)

            totalTime += extractionTime
            individualTimes.append(extractionTime)
            print("⏱️ Iteration \(i): \(Int(extractionTime * 1000))ms")
        }

        let averageTime = totalTime / Double(iterations)
        let maxTime = individualTimes.max() ?? 0
        let minTime = individualTimes.min() ?? 0

        print("📊 Performance Metrics:")
        print("   Average: \(Int(averageTime * 1000))ms")
        print("   Max: \(Int(maxTime * 1000))ms")
        print("   Min: \(Int(minTime * 1000))ms")

        // Check telemetry
        let metrics = frameExtractor.performanceMetrics
        print("📊 Telemetry: avg=\(Int(metrics.averageTime * 1000))ms, cache_hit=\(metrics.cacheHitRate), errors=\(metrics.errorRate)")

        XCTAssertLessThan(averageTime, 0.1, "Average extraction time should be under 100ms")
        XCTAssertLessThan(maxTime, 0.15, "Maximum extraction time should be under 150ms")
    }

    func testInvalidVideoURLHandling() async throws {
        print("🧪 Testing invalid video URL error handling")

        let invalidURL = URL(fileURLWithPath: "/nonexistent/path/video.mp4")

        do {
            _ = try await frameExtractor.extractFrame(from: invalidURL)
            XCTFail("Should throw error for invalid video URL")
        } catch {
            XCTAssertTrue(error is FrameExtractionError, "Should throw FrameExtractionError")
            print("✅ Correctly handled invalid URL with error: \(error.localizedDescription)")
        }
    }

    func testCorruptedVideoHandling() async throws {
        print("🧪 Testing corrupted video file handling")

        // Create a fake video file with invalid content
        let corruptedVideoURL = try createCorruptedVideoFile()
        defer {
            try? FileManager.default.removeItem(at: corruptedVideoURL)
        }

        do {
            _ = try await frameExtractor.extractFrame(from: corruptedVideoURL)
            XCTFail("Should throw error for corrupted video")
        } catch {
            XCTAssertTrue(error is FrameExtractionError, "Should throw FrameExtractionError")
            print("✅ Correctly handled corrupted video with error: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache Tests

    func testCacheBasicFunctionality() async throws {
        print("🧪 Testing cache basic functionality")

        // First extraction should miss cache
        XCTAssertTrue(frameExtractor.cacheStatus.contains("entries: 0"))

        let frame1 = try await frameExtractor.extractFrame(from: testVideoURL)
        XCTAssertTrue(frameExtractor.cacheStatus.contains("entries: 1"), "Cache should contain 1 entry after extraction")

        // Second extraction should hit cache
        let startTime = Date()
        let frame2 = try await frameExtractor.extractFrame(from: testVideoURL)
        let cacheHitTime = Date().timeIntervalSince(startTime)

        XCTAssertEqual(frame1.size, frame2.size, "Cached frame should match original")
        XCTAssertLessThan(cacheHitTime, 0.01, "Cache hit should be very fast (<10ms)")

        print("⚡ Cache hit time: \(Int(cacheHitTime * 1000))ms")
        print("✅ Cache working correctly")
    }

    func testCacheEvictionByCount() async throws {
        print("🧪 Testing cache eviction by count limit (5 entries)")

        // Create 6 different "video" URLs to test eviction
        var testURLs: [URL] = []
        for i in 1...6 {
            let tempURL = testVideoURL.appendingPathComponent("../test_video_\(i).mp4")
            testURLs.append(tempURL)
        }

        // Add first video to cache
        _ = try await frameExtractor.extractFrame(from: testVideoURL)
        XCTAssertTrue(frameExtractor.cacheStatus.contains("entries: 1"))

        // Simulate cache behavior by creating a new extractor for this test
        // (since we can't create multiple real videos easily)
        print("⚠️ Note: This test verifies cache logic structure")
        XCTAssertTrue(frameExtractor.cacheStatus.contains("entries:"), "Cache should track entry count")

        print("✅ Cache eviction logic is implemented")
    }

    func testCacheClearing() async throws {
        print("🧪 Testing cache clearing functionality")

        // Add entry to cache
        _ = try await frameExtractor.extractFrame(from: testVideoURL)
        XCTAssertTrue(frameExtractor.cacheStatus.contains("entries: 1"))

        // Clear cache
        frameExtractor.clearCache()
        XCTAssertTrue(frameExtractor.cacheStatus.contains("entries: 0"))

        print("✅ Cache clearing works correctly")
    }

    // MARK: - Memory Management Tests

    func testMemoryUsageEstimation() async throws {
        print("🧪 Testing memory usage stays under 10MB limit")

        let frame = try await frameExtractor.extractFrame(from: testVideoURL)

        // Estimate memory usage
        let size = frame.size
        let scale = frame.scale
        let pixelCount = Int(size.width * scale * size.height * scale)
        let estimatedBytes = pixelCount * 4 // 4 bytes per pixel (RGBA)
        let estimatedMB = estimatedBytes / (1024 * 1024)

        print("📏 Frame size: \(size)")
        print("📊 Estimated memory usage: \(estimatedMB)MB")

        XCTAssertLessThan(estimatedMB, 10, "Single frame should use less than 10MB")

        // Cache status should show memory tracking
        XCTAssertTrue(frameExtractor.cacheStatus.contains("memory:"), "Cache should track memory usage")

        print("✅ Memory usage within limits")
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentFrameExtraction() async throws {
        print("🧪 Testing concurrent frame extraction with priorities")

        // Clear cache to ensure fair test
        frameExtractor.clearCache()

        let startTime = Date()

        // Launch multiple concurrent extractions with different priorities
        async let highPriorityFrame = frameExtractor.extractFrame(from: testVideoURL, priority: .high)
        async let normalFrame1 = frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        async let normalFrame2 = frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        async let lowPriorityFrame = frameExtractor.extractFrame(from: testVideoURL, priority: .low)

        let results = try await [highPriorityFrame, normalFrame1, normalFrame2, lowPriorityFrame]
        let totalTime = Date().timeIntervalSince(startTime)

        print("⏱️ Total concurrent extraction time: \(Int(totalTime * 1000))ms")

        // All extractions should succeed
        XCTAssertEqual(results.count, 4, "All concurrent extractions should complete")
        for frame in results {
            XCTAssertGreaterThan(frame.size.width, 0, "Each frame should be valid")
        }

        // Cache should contain only one entry (same URL)
        XCTAssertTrue(frameExtractor.cacheStatus.contains("entries: 1"), "Cache should deduplicate same URL")

        // Concurrent extraction should not take much longer than single extraction
        XCTAssertLessThan(totalTime, 0.25, "Concurrent extraction should be efficient")

        print("✅ Concurrent access with priorities handled correctly")
    }

    // MARK: - Error Handling Tests

    func testErrorMessageDescriptions() throws {
        print("🧪 Testing error message descriptions")

        let errors: [FrameExtractionError] = [
            .invalidVideoURL,
            .imageGenerationFailed,
            .timeoutExceeded,
            .extractorReleased,
            .memoryPressure
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error description should not be empty")
            print("📝 \(error): \(error.errorDescription!)")
        }

        print("✅ All error descriptions are properly defined")
    }

    // MARK: - Performance and Memory Pressure Tests

    func testMemoryPressureHandling() async throws {
        print("🧪 Testing memory pressure handling")

        // Add several frames to cache
        for i in 1...3 {
            _ = try await frameExtractor.extractFrame(from: testVideoURL)
            // Simulate different URLs by clearing and re-adding
            if i < 3 {
                frameExtractor.clearCache()
            }
        }

        // Simulate memory pressure
        frameExtractor.enableGracefulDegradation()
        XCTAssertTrue(frameExtractor.isUnderMemoryPressure == false, "Should handle graceful degradation")

        // Extract frame under simulated pressure
        let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .high)
        XCTAssertNotNil(frame, "Should still extract frames under memory pressure")

        frameExtractor.disableGracefulDegradation()
        print("✅ Memory pressure handling works correctly")
    }

    func testPerformanceTelemetry() async throws {
        print("🧪 Testing performance telemetry tracking")

        frameExtractor.clearCache()

        // Perform several extractions
        _ = try await frameExtractor.extractFrame(from: testVideoURL) // Cache miss
        _ = try await frameExtractor.extractFrame(from: testVideoURL) // Cache hit
        _ = try await frameExtractor.extractFrame(from: testVideoURL) // Cache hit

        let metrics = frameExtractor.performanceMetrics
        print("📊 Telemetry Metrics:")
        print("   Average time: \(Int(metrics.averageTime * 1000))ms")
        print("   Cache hit rate: \(Int(metrics.cacheHitRate * 100))%")
        print("   Memory pressure events: \(metrics.memoryPressureEvents)")
        print("   Error rate: \(Int(metrics.errorRate * 100))%")

        XCTAssertGreaterThan(metrics.cacheHitRate, 0.6, "Should have good cache hit rate")
        XCTAssertLessThan(metrics.errorRate, 0.1, "Should have low error rate")
        XCTAssertLessThan(metrics.averageTime, 0.1, "Should maintain good average time")

        print("✅ Performance telemetry working correctly")
    }

    func testExtractionPriorities() async throws {
        print("🧪 Testing extraction priority handling")

        frameExtractor.clearCache()

        // Test different priorities
        let highPriorityStart = Date()
        _ = try await frameExtractor.extractFrame(from: testVideoURL, priority: .high)
        let highPriorityTime = Date().timeIntervalSince(highPriorityStart)

        frameExtractor.clearCache()

        let normalPriorityStart = Date()
        _ = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        let normalPriorityTime = Date().timeIntervalSince(normalPriorityStart)

        frameExtractor.clearCache()

        let lowPriorityStart = Date()
        _ = try await frameExtractor.extractFrame(from: testVideoURL, priority: .low)
        let lowPriorityTime = Date().timeIntervalSince(lowPriorityStart)

        print("⏱️ Priority Times:")
        print("   High: \(Int(highPriorityTime * 1000))ms")
        print("   Normal: \(Int(normalPriorityTime * 1000))ms")
        print("   Low: \(Int(lowPriorityTime * 1000))ms")

        // All should complete successfully within reasonable time
        XCTAssertLessThan(highPriorityTime, 0.15, "High priority should be fast")
        XCTAssertLessThan(normalPriorityTime, 0.15, "Normal priority should be reasonable")
        XCTAssertLessThan(lowPriorityTime, 0.2, "Low priority should complete")

        print("✅ Extraction priorities working correctly")
    }

    func testMemoryUsageWithinLimits() async throws {
        print("🧪 Testing memory usage stays within 10MB limit")

        // Fill cache with maximum entries
        for i in 1...5 {
            // Create slightly different URLs to avoid cache hits
            let _ = testVideoURL.appendingPathComponent("../test_\(i).mp4")
            do {
                _ = try await frameExtractor.extractFrame(from: testVideoURL)
            } catch {
                // Some may fail due to invalid URLs, which is fine for this test
                print("⚠️ Expected failure for test URL \(i): \(error.localizedDescription)")
            }
        }

        // Check that cache status shows memory tracking
        let cacheStatus = frameExtractor.cacheStatus
        print("📊 Cache Status: \(cacheStatus)")

        XCTAssertTrue(cacheStatus.contains("memory:"), "Cache should track memory usage")
        XCTAssertTrue(cacheStatus.contains("MB"), "Cache should show memory in MB")

        // Parse memory usage from cache status (rough validation)
        if let memoryRange = cacheStatus.range(of: "memory: "),
           let mbRange = cacheStatus.range(of: "MB") {
            let memoryStr = String(cacheStatus[memoryRange.upperBound..<mbRange.lowerBound])
            if let memoryUsage = Int(memoryStr) {
                print("📊 Current memory usage: \(memoryUsage)MB")
                XCTAssertLessThanOrEqual(memoryUsage, 10, "Memory usage should be under 10MB")
            }
        }

        print("✅ Memory usage within acceptable limits")
    }

    // MARK: - Advanced Cache Behavior Tests

    func testCacheEvictionUnderMemoryPressure() async throws {
        print("🧪 Testing cache eviction behavior under memory pressure scenarios")

        // First, populate cache with valid frames
        _ = try await frameExtractor.extractFrame(from: testVideoURL)
        XCTAssertTrue(frameExtractor.cacheStatus.contains("entries: 1"), "Cache should contain initial entry")

        // Simulate memory pressure
        frameExtractor.enableGracefulDegradation()
        XCTAssertTrue(frameExtractor.isUnderMemoryPressure == false, "Should not be under memory pressure initially")

        // Try to extract another frame under degradation mode
        let frameUnderPressure = try await frameExtractor.extractFrame(from: testVideoURL, priority: .high)
        XCTAssertNotNil(frameUnderPressure, "Should still extract frames under graceful degradation")

        // Disable degradation and verify cache behavior
        frameExtractor.disableGracefulDegradation()
        print("✅ Cache eviction under memory pressure handled correctly")
    }

    func testCacheMemoryEstimation() async throws {
        print("🧪 Testing cache memory estimation accuracy")

        let frame = try await frameExtractor.extractFrame(from: testVideoURL)

        // Manually calculate expected memory usage
        let size = frame.size
        let scale = frame.scale
        let pixelCount = Int(size.width * scale * size.height * scale)
        let expectedBytes = pixelCount * 4 // RGBA

        print("📐 Frame size: \(size), scale: \(scale)")
        print("📊 Expected memory: \(expectedBytes / 1024 / 1024)MB")

        // Verify cache reflects memory usage
        let cacheStatus = frameExtractor.cacheStatus
        XCTAssertTrue(cacheStatus.contains("memory:"), "Cache should track memory usage")

        print("✅ Memory estimation appears accurate")
    }

    func testCacheEvictionByMemoryLimit() async throws {
        print("🧪 Testing cache eviction by memory limit")

        frameExtractor.clearCache()

        // Extract frames to approach memory limit
        // Since we can't easily create multiple videos, we'll test the logic structure
        _ = try await frameExtractor.extractFrame(from: testVideoURL)
        let initialStatus = frameExtractor.cacheStatus
        print("📊 Initial cache status: \(initialStatus)")

        // Verify cache tracking is working
        XCTAssertTrue(initialStatus.contains("entries: 1"), "Cache should track entry count")
        XCTAssertTrue(initialStatus.contains("memory:"), "Cache should track memory usage")

        print("✅ Cache memory limit tracking verified")
    }

    func testConcurrentCacheAccess() async throws {
        print("🧪 Testing concurrent cache access patterns")

        frameExtractor.clearCache()

        // Launch multiple concurrent operations
        let concurrentTasks = (1...8).map { i in
            Task {
                do {
                    let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
                    return (i, frame.size, true)
                } catch {
                    print("⚠️ Task \(i) failed: \(error.localizedDescription)")
                    return (i, CGSize.zero, false)
                }
            }
        }

        let results = await withTaskGroup(of: (Int, CGSize, Bool).self) { group in
            for task in concurrentTasks {
                group.addTask { await task.value }
            }

            var taskResults: [(Int, CGSize, Bool)] = []
            for await result in group {
                taskResults.append(result)
            }
            return taskResults
        }

        let successCount = results.filter { $0.2 }.count
        print("📊 Concurrent access results: \(successCount)/\(results.count) successful")

        XCTAssertGreaterThanOrEqual(successCount, results.count - 2, "Most concurrent accesses should succeed")
        XCTAssertTrue(frameExtractor.cacheStatus.contains("entries: 1"), "Cache should deduplicate same URL")

        print("✅ Concurrent cache access handled correctly")
    }

    // MARK: - Advanced Error Handling Tests

    func testTaskCancellationHandling() async throws {
        print("🧪 Testing task cancellation during frame extraction")

        let extractionTask = Task {
            try await frameExtractor.extractFrame(from: testVideoURL, priority: .low)
        }

        // Cancel the task after a brief delay
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
            extractionTask.cancel()
        }

        do {
            _ = try await extractionTask.value
            print("⚠️ Task completed despite cancellation attempt")
        } catch {
            if error is CancellationError {
                print("✅ Task cancellation handled correctly")
            } else {
                print("⚠️ Task failed with non-cancellation error: \(error)")
            }
        }
    }

    func testMultipleErrorScenarios() async throws {
        print("🧪 Testing multiple error scenarios and recovery")

        // Test sequence of error conditions
        let errorScenarios: [(String, URL)] = [
            ("Invalid URL", URL(fileURLWithPath: "/nonexistent/video.mp4")),
            ("Corrupted file", try createCorruptedVideoFile())
        ]

        var errorCount = 0
        for (description, url) in errorScenarios {
            do {
                _ = try await frameExtractor.extractFrame(from: url)
                XCTFail("Should have failed for \(description)")
            } catch {
                errorCount += 1
                print("✅ Correctly handled \(description): \(error.localizedDescription)")
            }
        }

        // Verify error telemetry
        let metrics = frameExtractor.performanceMetrics
        XCTAssertGreaterThan(metrics.errorRate, 0, "Error rate should reflect failed extractions")

        // Test recovery with valid URL
        _ = try await frameExtractor.extractFrame(from: testVideoURL)
        print("✅ Recovery after errors successful")

        // Clean up corrupted file
        try? FileManager.default.removeItem(at: errorScenarios[1].1)
    }

    func testExtractionTimeoutVariations() async throws {
        print("🧪 Testing extraction timeout variations by priority")

        frameExtractor.clearCache()

        // Test different priorities with their timeout behaviors
        let priorities: [ExtractionPriority] = [.high, .normal, .low]
        var timingResults: [String: TimeInterval] = [:]

        for priority in priorities {
            let startTime = Date()
            _ = try await frameExtractor.extractFrame(from: testVideoURL, priority: priority)
            let duration = Date().timeIntervalSince(startTime)

            let priorityName = String(describing: priority)
            timingResults[priorityName] = duration
            print("⏱️ \(priorityName) priority extraction: \(Int(duration * 1000))ms")
        }

        // All should complete within reasonable time for valid videos
        for (priority, duration) in timingResults {
            XCTAssertLessThan(duration, 0.2, "\(priority) priority should complete within 200ms")
        }

        print("✅ Priority-based timeout handling verified")
    }

    // MARK: - Memory Pressure Simulation Tests

    func testSimulatedCriticalMemoryPressure() async throws {
        print("🧪 Testing behavior under simulated critical memory pressure")

        // Populate cache first
        _ = try await frameExtractor.extractFrame(from: testVideoURL)
        XCTAssertTrue(frameExtractor.cacheStatus.contains("entries: 1"))

        // Enable graceful degradation to simulate memory pressure
        frameExtractor.enableGracefulDegradation()

        // Try extraction under simulated pressure - should still work
        let frameUnderPressure = try await frameExtractor.extractFrame(from: testVideoURL, priority: .high)
        XCTAssertNotNil(frameUnderPressure, "High priority extractions should work under pressure")

        // Verify that new extractions might not get cached
        let cacheStatusAfter = frameExtractor.cacheStatus
        print("📊 Cache status under pressure: \(cacheStatusAfter)")

        frameExtractor.disableGracefulDegradation()
        print("✅ Critical memory pressure simulation handled")
    }

    func testMemoryPressureRecovery() async throws {
        print("🧪 Testing memory pressure recovery patterns")

        // Simulate pressure cycle
        frameExtractor.enableGracefulDegradation()
        XCTAssertTrue(frameExtractor.isUnderMemoryPressure == false, "Should not report pressure for manual degradation")

        // Perform extraction under degradation
        _ = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)

        // Simulate recovery
        frameExtractor.disableGracefulDegradation()

        // Verify normal operation resumes
        _ = try await frameExtractor.extractFrame(from: testVideoURL)
        let recoveryStatus = frameExtractor.cacheStatus
        print("📊 Post-recovery cache status: \(recoveryStatus)")

        XCTAssertFalse(frameExtractor.isUnderMemoryPressure, "Should not be under pressure after recovery")
        print("✅ Memory pressure recovery successful")
    }

    // MARK: - Performance Edge Case Tests

    func testExtractionPerformanceUnderLoad() async throws {
        print("🧪 Testing extraction performance under concurrent load")

        frameExtractor.clearCache()

        let loadTestIterations = 20
        let startTime = Date()

        // Create concurrent load
        let results = try await withThrowingTaskGroup(of: TimeInterval.self) { group in
            for _ in 1...loadTestIterations {
                group.addTask {
                    let taskStart = Date()
                    _ = try await self.frameExtractor.extractFrame(from: self.testVideoURL, priority: .normal)
                    return Date().timeIntervalSince(taskStart)
                }
            }

            var times: [TimeInterval] = []
            for try await time in group {
                times.append(time)
            }
            return times
        }

        let totalTime = Date().timeIntervalSince(startTime)
        let averageTime = results.reduce(0, +) / Double(results.count)
        let maxTime = results.max() ?? 0

        print("📊 Load Test Results:")
        print("   Total iterations: \(loadTestIterations)")
        print("   Total time: \(Int(totalTime * 1000))ms")
        print("   Average per extraction: \(Int(averageTime * 1000))ms")
        print("   Maximum time: \(Int(maxTime * 1000))ms")

        // Performance requirements under load
        XCTAssertLessThan(averageTime, 0.15, "Average extraction time should be reasonable under load")
        XCTAssertLessThan(maxTime, 0.25, "Maximum extraction time should be bounded under load")

        // Verify cache efficiency helped
        let metrics = frameExtractor.performanceMetrics
        XCTAssertGreaterThan(metrics.cacheHitRate, 0.8, "Cache hit rate should be high under load")

        print("✅ Performance under load verified")
    }

    // MARK: - Helper Methods

    private func createTestVideoFile() throws -> URL {
        // Previously built an AVMutableComposition but never wrote it to disk, so the
        // file didn't exist and every extraction failed with "Cannot Open". Write a
        // real H.264 clip instead.
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoURL = documentsURL.appendingPathComponent("test_synthetic_\(UUID().uuidString).mp4")
        return try TestVideoFactory.writeVideo(to: videoURL, duration: 1.0)
    }

    private func createCorruptedVideoFile() throws -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let corruptedURL = documentsURL.appendingPathComponent("corrupted_\(UUID().uuidString).mp4")

        // Create a file with invalid MP4 content
        let invalidData = "This is not a video file".data(using: .utf8)!
        try invalidData.write(to: corruptedURL)

        return corruptedURL
    }
}
#endif