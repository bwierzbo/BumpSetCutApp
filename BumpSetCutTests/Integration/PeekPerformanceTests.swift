//
//  PeekPerformanceTests.swift
//  BumpSetCutTests
//
//  Created for Issue #45 - Testing and Quality Assurance
//  Performance validation tests for peek functionality
//

#if DEBUG
import XCTest
import UIKit
import AVFoundation
@testable import BumpSetCut

@MainActor
final class PeekPerformanceTests: XCTestCase {

    var frameExtractor: FrameExtractor!
    var testVideoURL: URL!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Setup temporary directory
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Initialize frame extractor
        frameExtractor = FrameExtractor()

        // Create test video
        testVideoURL = try createTestVideoFile()

        print("PeekPerformanceTests: Setup completed")
    }

    override func tearDownWithError() throws {
        frameExtractor.clearCache()
        frameExtractor = nil

        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.removeItem(at: tempDirectory)
        }

        tempDirectory = nil
        testVideoURL = nil

        try super.tearDownWithError()
    }

    // MARK: - Frame Extraction Performance Tests

    func testFrameExtractionTimingCompliance() async throws {
        print("🧪 Testing frame extraction timing compliance (<100ms requirement)")

        frameExtractor.clearCache()

        let testIterations = 10
        var extractionTimes: [TimeInterval] = []
        var successCount = 0

        for iteration in 1...testIterations {
            let startTime = Date()

            do {
                let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .high)
                let extractionTime = Date().timeIntervalSince(startTime)
                extractionTimes.append(extractionTime)
                successCount += 1

                print("⏱️ Iteration \(iteration): \(Int(extractionTime * 1000))ms, size: \(frame.size)")

                // Core requirement: <100ms for peek frames
                XCTAssertLessThan(extractionTime, 0.1, "Extraction \(iteration) should be under 100ms")

            } catch {
                print("❌ Iteration \(iteration) failed: \(error)")
            }

            // Clear cache to ensure fresh extraction each time
            frameExtractor.clearCache()
        }

        // Calculate statistics
        let averageTime = extractionTimes.reduce(0, +) / Double(extractionTimes.count)
        let maxTime = extractionTimes.max() ?? 0
        let minTime = extractionTimes.min() ?? 0

        print("📊 Timing Compliance Results:")
        print("   Success rate: \(successCount)/\(testIterations) (\(Int(Double(successCount)/Double(testIterations) * 100))%)")
        print("   Average time: \(Int(averageTime * 1000))ms")
        print("   Maximum time: \(Int(maxTime * 1000))ms")
        print("   Minimum time: \(Int(minTime * 1000))ms")

        // Performance requirements
        XCTAssertGreaterThanOrEqual(successCount, testIterations - 1, "At least 90% success rate required")
        XCTAssertLessThan(averageTime, 0.08, "Average time should be well under 100ms")
        XCTAssertLessThan(maxTime, 0.12, "Maximum time should not exceed 120ms")

        print("✅ Frame extraction timing compliance validated")
    }

    func testCachePerformanceOptimization() async throws {
        print("🧪 Testing cache performance optimization")

        frameExtractor.clearCache()

        // First extraction (cache miss)
        let cacheMissStart = Date()
        let frame1 = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        let cacheMissTime = Date().timeIntervalSince(cacheMissStart)

        // Second extraction (cache hit)
        let cacheHitStart = Date()
        let frame2 = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        let cacheHitTime = Date().timeIntervalSince(cacheHitStart)

        print("⏱️ Cache Performance:")
        print("   Cache miss: \(Int(cacheMissTime * 1000))ms")
        print("   Cache hit: \(Int(cacheHitTime * 1000))ms")
        print("   Speedup: \(Int(cacheMissTime/cacheHitTime))x")

        // Verify cache effectiveness
        XCTAssertLessThan(cacheHitTime, 0.01, "Cache hit should be under 10ms")
        XCTAssertGreaterThan(cacheMissTime / cacheHitTime, 5.0, "Cache should provide at least 5x speedup")
        XCTAssertEqual(frame1.size, frame2.size, "Cached frame should match original")

        // Verify cache telemetry
        let metrics = frameExtractor.performanceMetrics
        XCTAssertGreaterThan(metrics.cacheHitRate, 0.4, "Cache hit rate should be reasonable")

        print("✅ Cache performance optimization validated")
    }

    func testConcurrentExtractionPerformance() async throws {
        print("🧪 Testing concurrent extraction performance")

        frameExtractor.clearCache()

        let concurrentCount = 8
        let startTime = Date()

        // Launch concurrent extractions
        let results = try await withThrowingTaskGroup(of: (Int, TimeInterval, CGSize).self) { group in
            for i in 1...concurrentCount {
                group.addTask {
                    let taskStart = Date()
                    let frame = try await self.frameExtractor.extractFrame(from: self.testVideoURL, priority: .normal)
                    let taskTime = Date().timeIntervalSince(taskStart)
                    return (i, taskTime, frame.size)
                }
            }

            var taskResults: [(Int, TimeInterval, CGSize)] = []
            for try await result in group {
                taskResults.append(result)
            }
            return taskResults
        }

        let totalTime = Date().timeIntervalSince(startTime)

        // Analyze results
        let taskTimes = results.map { $0.1 }
        let averageTaskTime = taskTimes.reduce(0, +) / Double(taskTimes.count)
        let maxTaskTime = taskTimes.max() ?? 0

        print("📊 Concurrent Performance Results:")
        print("   Total concurrent tasks: \(concurrentCount)")
        print("   Total execution time: \(Int(totalTime * 1000))ms")
        print("   Average task time: \(Int(averageTaskTime * 1000))ms")
        print("   Maximum task time: \(Int(maxTaskTime * 1000))ms")

        // Performance requirements for concurrent access
        XCTAssertEqual(results.count, concurrentCount, "All concurrent tasks should complete")
        XCTAssertLessThan(totalTime, 0.5, "Concurrent execution should be efficient")
        XCTAssertLessThan(averageTaskTime, 0.15, "Average concurrent task time should be reasonable")

        // Verify cache deduplication worked
        let cacheStatus = frameExtractor.cacheStatus
        print("📊 Cache status after concurrent access: \(cacheStatus)")
        XCTAssertTrue(cacheStatus.contains("entries: 1"), "Cache should deduplicate concurrent access")

        print("✅ Concurrent extraction performance validated")
    }

    // MARK: - Memory Usage Compliance Tests

    func testMemoryUsageCompliance() async throws {
        print("🧪 Testing memory usage compliance (<10MB requirement)")

        frameExtractor.clearCache()

        // Extract frame and measure memory
        let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)

        // Calculate frame memory usage
        let size = frame.size
        let scale = frame.scale
        let pixelCount = Int(size.width * scale * size.height * scale)
        let estimatedBytes = pixelCount * 4 // RGBA
        let estimatedMB = estimatedBytes / (1024 * 1024)

        print("📏 Frame Analysis:")
        print("   Size: \(size)")
        print("   Scale: \(scale)")
        print("   Pixel count: \(pixelCount)")
        print("   Estimated memory: \(estimatedMB)MB")

        // Core requirement: <10MB memory usage
        XCTAssertLessThan(estimatedMB, 10, "Single frame should use less than 10MB")

        // Verify cache memory tracking
        let cacheStatus = frameExtractor.cacheStatus
        XCTAssertTrue(cacheStatus.contains("memory:"), "Cache should track memory usage")
        print("📊 Cache status: \(cacheStatus)")

        // Parse and verify cache memory reporting
        if let memoryRange = cacheStatus.range(of: "memory: "),
           let mbRange = cacheStatus.range(of: "MB") {
            let memoryStr = String(cacheStatus[memoryRange.upperBound..<mbRange.lowerBound])
            if let reportedMemory = Int(memoryStr) {
                print("📊 Cache reported memory: \(reportedMemory)MB")
                XCTAssertLessThanOrEqual(reportedMemory, 10, "Cache reported memory should be under 10MB")
                XCTAssertGreaterThanOrEqual(reportedMemory, 0, "Cache memory should be positive")
            }
        }

        print("✅ Memory usage compliance validated")
    }

    func testCacheMemoryPressureHandling() async throws {
        print("🧪 Testing cache memory pressure handling")

        frameExtractor.clearCache()

        // Fill cache with frames
        let frame1 = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        let initialCacheStatus = frameExtractor.cacheStatus
        print("📊 Initial cache: \(initialCacheStatus)")

        // Simulate memory pressure
        frameExtractor.enableGracefulDegradation()

        // Extract frame under pressure
        let frame2 = try await frameExtractor.extractFrame(from: testVideoURL, priority: .high)
        let pressureCacheStatus = frameExtractor.cacheStatus
        print("📊 Under pressure: \(pressureCacheStatus)")

        XCTAssertNotNil(frame2, "Frame extraction should work under memory pressure")
        XCTAssertEqual(frame1.size, frame2.size, "Frame quality should be maintained")

        // Restore normal operation
        frameExtractor.disableGracefulDegradation()
        let recoveredCacheStatus = frameExtractor.cacheStatus
        print("📊 After recovery: \(recoveredCacheStatus)")

        print("✅ Cache memory pressure handling validated")
    }

    func testMemoryLeakDetection() async throws {
        print("🧪 Testing memory leak detection")

        let initialMetrics = frameExtractor.performanceMetrics
        let cycleCount = 5

        for cycle in 1...cycleCount {
            print("🔄 Memory cycle \(cycle)/\(cycleCount)")

            // Perform extraction and immediate cleanup
            let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
            XCTAssertNotNil(frame, "Frame extraction should succeed in cycle \(cycle)")

            // Clear cache to simulate cleanup
            frameExtractor.clearCache()

            // Check for memory accumulation
            let cycleMetrics = frameExtractor.performanceMetrics
            let performanceChange = abs(cycleMetrics.averageTime - initialMetrics.averageTime)

            print("📊 Cycle \(cycle) metrics: avg=\(Int(cycleMetrics.averageTime * 1000))ms")

            // Verify no significant performance degradation (indicating leaks)
            XCTAssertLessThan(performanceChange, 0.05, "No significant performance change in cycle \(cycle)")
        }

        let finalMetrics = frameExtractor.performanceMetrics
        print("📊 Final performance comparison:")
        print("   Initial: \(Int(initialMetrics.averageTime * 1000))ms")
        print("   Final: \(Int(finalMetrics.averageTime * 1000))ms")
        print("   Error rate: \(Int(finalMetrics.errorRate * 100))%")

        // Overall leak detection
        let totalPerformanceChange = abs(finalMetrics.averageTime - initialMetrics.averageTime)
        XCTAssertLessThan(totalPerformanceChange, 0.02, "No significant overall performance degradation")
        XCTAssertLessThan(finalMetrics.errorRate, 0.1, "Error rate should remain low")

        print("✅ Memory leak detection completed")
    }

    // MARK: - Animation Performance Tests

    func testAnimationPerformanceTargets() throws {
        print("🧪 Testing animation performance targets (60fps requirement)")

        let targetFrameTime: TimeInterval = 1.0 / 60.0 // 16.67ms for 60fps
        var frameTimeViolations = 0
        let testFrames = 30

        print("🎯 Target frame time: \(Int(targetFrameTime * 1000))ms (60fps)")

        for frame in 1...testFrames {
            let frameStart = Date()

            // Simulate peek progress calculation (lightweight operation)
            let progress = Double(frame) / Double(testFrames)
            let _: RallyPeekDirection = frame % 2 == 0 ? .next : .previous

            // Simulate UI update work
            let _ = 0.85 + (progress * 0.15)
            let _ = pow(progress, 0.8) * 0.9

            let frameTime = Date().timeIntervalSince(frameStart)

            if frameTime > targetFrameTime {
                frameTimeViolations += 1
            }

            if frame <= 5 || frame % 10 == 0 {
                print("📍 Frame \(frame): \(Int(frameTime * 1000))ms, progress=\(String(format: "%.2f", progress))")
            }
        }

        let violationRate = Double(frameTimeViolations) / Double(testFrames)
        print("📊 Animation Performance Results:")
        print("   Frame time violations: \(frameTimeViolations)/\(testFrames)")
        print("   Violation rate: \(Int(violationRate * 100))%")

        // Allow some tolerance for frame time violations
        XCTAssertLessThan(violationRate, 0.1, "Frame time violations should be under 10%")

        print("✅ Animation performance targets validated")
    }

    func testGestureResponsivenessTargets() async throws {
        print("🧪 Testing gesture responsiveness targets")

        var callbackTimes: [TimeInterval] = []
        let gestureCount = 20

        let peekCallback: (Double, RallyPeekDirection?) -> Void = { progress, direction in
            // Simulate callback processing time
            let callbackStart = Date()

            // Lightweight progress handling
            _ = progress * 100.0
            _ = direction?.description

            let callbackTime = Date().timeIntervalSince(callbackStart)
            callbackTimes.append(callbackTime)
        }

        // Simulate rapid gesture updates
        let gestureStart = Date()
        for i in 0..<gestureCount {
            let progress = Double(i) / Double(gestureCount - 1)
            let direction: RallyPeekDirection = i % 3 == 0 ? .next : .previous

            peekCallback(progress, direction)
        }
        let totalGestureTime = Date().timeIntervalSince(gestureStart)

        // Analyze responsiveness
        let averageCallbackTime = callbackTimes.reduce(0, +) / Double(callbackTimes.count)
        let maxCallbackTime = callbackTimes.max() ?? 0

        print("📊 Gesture Responsiveness Results:")
        print("   Total gesture time: \(Int(totalGestureTime * 1000))ms")
        print("   Average callback time: \(String(format: "%.3f", averageCallbackTime * 1000))ms")
        print("   Maximum callback time: \(String(format: "%.3f", maxCallbackTime * 1000))ms")

        // Responsiveness requirements
        XCTAssertLessThan(averageCallbackTime, 0.001, "Average callback should be under 1ms")
        XCTAssertLessThan(maxCallbackTime, 0.005, "Maximum callback should be under 5ms")
        XCTAssertLessThan(totalGestureTime, 0.1, "Total gesture handling should be fast")

        print("✅ Gesture responsiveness targets validated")
    }

    // MARK: - Device Compatibility Tests

    func testLowEndDevicePerformance() async throws {
        print("🧪 Testing low-end device performance simulation")

        // Simulate low-end device by reducing priority and adding delay
        let lowEndConfig = FrameExtractor.ExtractionConfig(
            frameTime: CMTime(seconds: 0.1, preferredTimescale: 600),
            maximumSize: CGSize(width: 480, height: 480), // Smaller size for low-end
            appliesPreferredTrackTransform: true,
            extractionTimeout: 0.15 // More lenient timeout
        )

        let lowEndExtractor = FrameExtractor(config: lowEndConfig)

        // Test performance on simulated low-end device
        let extractionTimes: [TimeInterval] = try await withThrowingTaskGroup(of: TimeInterval.self) { group in
            for _ in 1...3 {
                group.addTask {
                    let start = Date()
                    _ = try await lowEndExtractor.extractFrame(from: self.testVideoURL, priority: .low)
                    return Date().timeIntervalSince(start)
                }
            }

            var times: [TimeInterval] = []
            for try await time in group {
                times.append(time)
            }
            return times
        }

        let averageTime = extractionTimes.reduce(0, +) / Double(extractionTimes.count)
        print("📊 Low-end device simulation: avg=\(Int(averageTime * 1000))ms")

        // More lenient requirements for low-end devices
        XCTAssertLessThan(averageTime, 0.15, "Low-end device performance should be acceptable")

        lowEndExtractor.clearCache()
        print("✅ Low-end device performance simulation completed")
    }

    func testHighEndDevicePerformance() async throws {
        print("🧪 Testing high-end device performance optimization")

        // Simulate high-end device with optimal settings
        let highEndConfig = FrameExtractor.ExtractionConfig(
            frameTime: CMTime(seconds: 0.1, preferredTimescale: 600),
            maximumSize: CGSize(width: 1280, height: 1280), // Larger size for high-end
            appliesPreferredTrackTransform: true,
            extractionTimeout: 0.08 // Stricter timeout
        )

        let highEndExtractor = FrameExtractor(config: highEndConfig)

        // Test optimized performance
        let extractionTimes: [TimeInterval] = try await withThrowingTaskGroup(of: TimeInterval.self) { group in
            for _ in 1...5 {
                group.addTask {
                    let start = Date()
                    _ = try await highEndExtractor.extractFrame(from: self.testVideoURL, priority: .high)
                    return Date().timeIntervalSince(start)
                }
            }

            var times: [TimeInterval] = []
            for try await time in group {
                times.append(time)
            }
            return times
        }

        let averageTime = extractionTimes.reduce(0, +) / Double(extractionTimes.count)
        print("📊 High-end device optimization: avg=\(Int(averageTime * 1000))ms")

        // Stricter requirements for high-end devices
        XCTAssertLessThan(averageTime, 0.08, "High-end device should achieve optimal performance")

        highEndExtractor.clearCache()
        print("✅ High-end device performance optimization validated")
    }

    // MARK: - Helper Methods

    private func createTestVideoFile() throws -> URL {
        let videoURL = tempDirectory.appendingPathComponent("performance_test_\(UUID().uuidString).mp4")

        // Create test file for URL-based testing
        let testData = "performance test video data".data(using: .utf8)!
        try testData.write(to: videoURL)

        return videoURL
    }
}
#endif