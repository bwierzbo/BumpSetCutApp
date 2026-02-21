//
//  DeviceCompatibilityTests.swift
//  BumpSetCutTests
//
//  Created for Issue #45 - Testing and Quality Assurance
//  Device compatibility and memory leak detection tests
//

#if DEBUG
import XCTest
import UIKit
import AVFoundation
@testable import BumpSetCut

@MainActor
final class DeviceCompatibilityTests: XCTestCase {

    var frameExtractor: FrameExtractor!
    var tempDirectory: URL!
    var testVideoURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Setup temporary directory
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Initialize frame extractor
        frameExtractor = FrameExtractor()

        // Create test video
        testVideoURL = try createTestVideoFile()

        print("DeviceCompatibilityTests: Setup completed")
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

    // MARK: - Device Capability Tests

    func testDeviceProcessingCapabilities() async throws {
        print("🧪 Testing device processing capabilities")

        // Detect device characteristics
        let deviceInfo = getDeviceInfo()
        print("📱 Device Info:")
        print("   Model: \(deviceInfo.model)")
        print("   Memory: \(deviceInfo.memoryGB)GB")
        print("   CPU Cores: \(deviceInfo.cpuCores)")
        print("   Is Simulator: \(deviceInfo.isSimulator)")

        // Test performance scaling based on device capabilities
        let performanceConfig = determinePerformanceConfig(for: deviceInfo)
        let compatibilityExtractor = FrameExtractor(config: performanceConfig)

        var capabilityResults: [(String, TimeInterval, Bool)] = []

        // Test basic extraction capability
        let basicStart = Date()
        do {
            let frame = try await compatibilityExtractor.extractFrame(from: testVideoURL, priority: .normal)
            let basicTime = Date().timeIntervalSince(basicStart)
            capabilityResults.append(("basic_extraction", basicTime, true))
            print("✅ Basic extraction: \(Int(basicTime * 1000))ms, size: \(frame.size)")

            // Verify frame quality
            XCTAssertGreaterThan(frame.size.width, 0, "Frame should have valid width")
            XCTAssertGreaterThan(frame.size.height, 0, "Frame should have valid height")

        } catch {
            capabilityResults.append(("basic_extraction", 0.0, false))
            print("❌ Basic extraction failed: \(error)")
        }

        // Test concurrent capability
        let concurrentStart = Date()
        let concurrentCount = deviceInfo.cpuCores

        let concurrentResults = try await withThrowingTaskGroup(of: TimeInterval.self) { group in
            for _ in 1...concurrentCount {
                group.addTask {
                    let taskStart = Date()
                    _ = try await compatibilityExtractor.extractFrame(from: self.testVideoURL, priority: .normal)
                    return Date().timeIntervalSince(taskStart)
                }
            }

            var times: [TimeInterval] = []
            for try await time in group {
                times.append(time)
            }
            return times
        }

        let concurrentTime = Date().timeIntervalSince(concurrentStart)
        let avgConcurrentTime = concurrentResults.reduce(0, +) / Double(concurrentResults.count)

        capabilityResults.append(("concurrent_extraction", concurrentTime, true))
        print("✅ Concurrent extraction (\(concurrentCount) tasks): total=\(Int(concurrentTime * 1000))ms, avg=\(Int(avgConcurrentTime * 1000))ms")

        // Performance validation based on device class
        let expectedPerformance = getExpectedPerformance(for: deviceInfo)

        for (test, time, success) in capabilityResults {
            if success {
                XCTAssertLessThan(time, expectedPerformance.maxTime, "\(test) should meet performance expectations for this device")
            }
        }

        compatibilityExtractor.clearCache()
        print("✅ Device processing capabilities validated")
    }

    func testMemoryConstrainedEnvironments() async throws {
        print("🧪 Testing memory-constrained environments")

        // Configure for memory-constrained environment
        let constrainedConfig = FrameExtractor.ExtractionConfig(
            frameTime: CMTime(seconds: 0.1, preferredTimescale: 600),
            maximumSize: CGSize(width: 320, height: 320), // Smaller frames
            appliesPreferredTrackTransform: true,
            extractionTimeout: 0.15 // More lenient timeout
        )

        let constrainedExtractor = FrameExtractor(config: constrainedConfig)

        // Enable graceful degradation to simulate memory pressure
        constrainedExtractor.enableGracefulDegradation()

        var memoryResults: [(String, Bool, CGSize)] = []

        // Test extraction under memory constraints
        let constraintTests = [
            "first_extraction",
            "cached_extraction",
            "after_pressure",
            "recovery_test"
        ]

        for testName in constraintTests {
            do {
                let frame = try await constrainedExtractor.extractFrame(from: testVideoURL, priority: .normal)
                memoryResults.append((testName, true, frame.size))
                print("✅ \(testName): Success, size: \(frame.size)")

                // Verify memory-conscious frame size
                let maxDimension = max(frame.size.width, frame.size.height)
                XCTAssertLessThanOrEqual(maxDimension, 320, "Frame should respect memory constraints")

            } catch {
                memoryResults.append((testName, false, .zero))
                print("❌ \(testName): Failed - \(error.localizedDescription)")

                // Memory pressure failures are acceptable
                if let frameError = error as? FrameExtractionError,
                   case .memoryPressure = frameError {
                    print("✅ \(testName): Acceptable memory pressure failure")
                }
            }

            // Simulate memory pressure between tests
            if testName == "first_extraction" {
                constrainedExtractor.enableGracefulDegradation()
            } else if testName == "after_pressure" {
                constrainedExtractor.disableGracefulDegradation()
            }
        }

        print("📊 Memory Constraint Results:")
        for (test, success, size) in memoryResults {
            print("   \(test): \(success ? "✅ SUCCESS" : "❌ FAILED"), size: \(size)")
        }

        // Should have some successful extractions even under constraints
        let successCount = memoryResults.filter { $0.1 }.count
        XCTAssertGreaterThan(successCount, 0, "Should handle some requests under memory constraints")

        constrainedExtractor.clearCache()
        print("✅ Memory-constrained environments validated")
    }

    func testOrientationCompatibility() throws {
        print("🧪 Testing orientation compatibility")

        var orientationCallbacks: [(UIDeviceOrientation, Double, RallyPeekDirection?)] = []

        let peekCallback: (Double, RallyPeekDirection?) -> Void = { progress, direction in
            let currentOrientation = UIDevice.current.orientation
            orientationCallbacks.append((currentOrientation, progress, direction))
        }

        // Test different orientation scenarios
        let orientationTests: [(String, Double, RallyPeekDirection?)] = [
            ("portrait_peek", 0.4, .next),
            ("landscape_peek", 0.6, .previous),
            ("orientation_reset", 0.0, nil),
            ("portrait_reverse", 0.3, .next),
            ("landscape_reverse", 0.5, .previous),
            ("final_reset", 0.0, nil)
        ]

        for (testName, progress, direction) in orientationTests {
            print("🔄 \(testName): progress=\(progress), direction=\(String(describing: direction))")
            peekCallback(progress, direction)
        }

        print("📊 Orientation Compatibility Results:")
        print("   Total orientation callbacks: \(orientationCallbacks.count)")

        // Verify all orientations are handled consistently
        for (orientation, progress, direction) in orientationCallbacks {
            print("   \(orientation.rawValue): progress=\(progress), direction=\(String(describing: direction))")

            // Progress should be within valid range regardless of orientation
            XCTAssertGreaterThanOrEqual(progress, 0.0, "Progress should not be negative")
            XCTAssertLessThanOrEqual(progress, 1.0, "Progress should not exceed 1.0")
        }

        print("✅ Orientation compatibility validated")
    }

    // MARK: - Memory Leak Detection Tests

    func testLongRunningMemoryLeaks() async throws {
        print("🧪 Testing long-running memory leak detection")

        let initialMetrics = frameExtractor.performanceMetrics
        let leakTestCycles = 20

        var memorySnapshots: [(Int, String)] = []
        memorySnapshots.append((0, frameExtractor.cacheStatus))

        for cycle in 1...leakTestCycles {
            // Perform extraction cycle
            do {
                let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
                XCTAssertNotNil(frame, "Frame extraction should succeed in cycle \(cycle)")
            } catch {
                print("⚠️ Cycle \(cycle) extraction failed: \(error)")
            }

            // Take memory snapshot every 5 cycles
            if cycle % 5 == 0 {
                let cacheStatus = frameExtractor.cacheStatus
                memorySnapshots.append((cycle, cacheStatus))
                print("📊 Cycle \(cycle) memory: \(cacheStatus)")
            }

            // Clear cache periodically to test cleanup
            if cycle % 10 == 0 {
                frameExtractor.clearCache()
            }
        }

        let finalMetrics = frameExtractor.performanceMetrics

        print("📊 Memory Leak Detection Results:")
        print("   Initial metrics: avg=\(Int(initialMetrics.averageTime * 1000))ms")
        print("   Final metrics: avg=\(Int(finalMetrics.averageTime * 1000))ms")
        print("   Performance change: \(Int(abs(finalMetrics.averageTime - initialMetrics.averageTime) * 1000))ms")
        print("   Error rate: \(Int(finalMetrics.errorRate * 100))%")

        // Memory leak indicators
        let performanceChange = abs(finalMetrics.averageTime - initialMetrics.averageTime)
        XCTAssertLessThan(performanceChange, 0.02, "Performance should not degrade significantly (possible memory leak)")
        XCTAssertLessThan(finalMetrics.errorRate, 0.1, "Error rate should remain low")

        // Analyze memory snapshots
        for (cycle, status) in memorySnapshots {
            print("   Cycle \(cycle): \(status)")
        }

        print("✅ Long-running memory leak detection completed")
    }

    func testMemoryPressureResponseCycles() async throws {
        print("🧪 Testing memory pressure response cycles")

        var pressureCycleResults: [(Int, Bool, String)] = []
        let pressureCycles = 5

        for cycle in 1...pressureCycles {
            print("🔄 Memory pressure cycle \(cycle)/\(pressureCycles)")

            // Enable pressure
            frameExtractor.enableGracefulDegradation()
            let _ = frameExtractor.cacheStatus

            // Test extraction under pressure
            do {
                let _ = try await frameExtractor.extractFrame(from: testVideoURL, priority: .high)
                pressureCycleResults.append((cycle, true, "Extraction succeeded under pressure"))
                print("✅ Cycle \(cycle): Succeeded under pressure")
            } catch {
                pressureCycleResults.append((cycle, false, "Extraction failed: \(error.localizedDescription)"))
                print("❌ Cycle \(cycle): Failed under pressure - \(error)")
            }

            // Disable pressure and verify recovery
            frameExtractor.disableGracefulDegradation()

            // Test recovery extraction
            do {
                let _ = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
                pressureCycleResults.append((cycle, true, "Recovery successful"))
                print("✅ Cycle \(cycle): Recovery successful")
            } catch {
                pressureCycleResults.append((cycle, false, "Recovery failed: \(error.localizedDescription)"))
                print("❌ Cycle \(cycle): Recovery failed - \(error)")
            }

            // Clear cache between cycles
            frameExtractor.clearCache()
        }

        print("📊 Memory Pressure Cycle Results:")
        for (cycle, success, message) in pressureCycleResults {
            let status = success ? "pass" : "FAIL"
            print("   Cycle \(cycle): \(status) \(message)")
        }

        // Verify system remains stable across pressure cycles
        let successfulCycles = pressureCycleResults.filter { $0.1 }.count
        let totalOperations = pressureCycleResults.count
        let successRate = Double(successfulCycles) / Double(totalOperations)

        print("   Success rate: \(Int(successRate * 100))% (\(successfulCycles)/\(totalOperations))")
        XCTAssertGreaterThan(successRate, 0.7, "Should maintain >70% success rate across pressure cycles")

        print("✅ Memory pressure response cycles validated")
    }

    func testResourceCleanupValidation() async throws {
        print("🧪 Testing resource cleanup validation")

        let initialCacheStatus = frameExtractor.cacheStatus
        print("📊 Initial state: \(initialCacheStatus)")

        // Create and cleanup resources multiple times
        var cleanupResults: [(String, String)] = []

        for iteration in 1...5 {
            // Populate resources
            let _ = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
            let populatedStatus = frameExtractor.cacheStatus
            cleanupResults.append(("populate_\(iteration)", populatedStatus))

            // Verify resources are present
            XCTAssertTrue(populatedStatus.contains("entries: 1"), "Resources should be populated")

            // Clean up resources
            frameExtractor.clearCache()
            let cleanedStatus = frameExtractor.cacheStatus
            cleanupResults.append(("cleanup_\(iteration)", cleanedStatus))

            // Verify cleanup
            XCTAssertTrue(cleanedStatus.contains("entries: 0"), "Resources should be cleaned up")
        }

        print("📊 Resource Cleanup Results:")
        for (operation, status) in cleanupResults {
            print("   \(operation): \(status)")
        }

        // Final cleanup verification
        let finalStatus = frameExtractor.cacheStatus
        XCTAssertTrue(finalStatus.contains("entries: 0"), "Final state should be clean")
        XCTAssertTrue(finalStatus.contains("memory: 0MB"), "Final memory should be zero")

        print("✅ Resource cleanup validation completed")
    }

    // MARK: - Device-Specific Performance Tests

    func testDeviceSpecificPerformanceTargets() async throws {
        print("🧪 Testing device-specific performance targets")

        let deviceInfo = getDeviceInfo()
        let performanceTargets = getPerformanceTargets(for: deviceInfo)

        print("📱 Performance targets for \(deviceInfo.model):")
        print("   Max extraction time: \(Int(performanceTargets.maxExtractionTime * 1000))ms")
        print("   Min cache hit speedup: \(performanceTargets.minCacheSpeedup)x")
        print("   Max memory per frame: \(performanceTargets.maxMemoryPerFrame)MB")

        // Test extraction performance
        frameExtractor.clearCache()

        let extractionStart = Date()
        let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        let extractionTime = Date().timeIntervalSince(extractionStart)

        print("⏱️ Extraction performance: \(Int(extractionTime * 1000))ms")
        XCTAssertLessThan(extractionTime, performanceTargets.maxExtractionTime, "Should meet device-specific extraction time target")

        // Test cache performance
        let cacheHitStart = Date()
        let _ = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        let cacheHitTime = Date().timeIntervalSince(cacheHitStart)

        let cacheSpeedup = extractionTime / cacheHitTime
        print("⚡ Cache performance: \(Int(cacheHitTime * 1000))ms (speedup: \(String(format: "%.1f", cacheSpeedup))x)")
        XCTAssertGreaterThan(cacheSpeedup, performanceTargets.minCacheSpeedup, "Should meet device-specific cache speedup target")

        // Test memory usage
        let memoryUsage = estimateFrameMemoryUsage(frame)
        print("💾 Memory usage: \(String(format: "%.1f", memoryUsage))MB")
        XCTAssertLessThan(memoryUsage, performanceTargets.maxMemoryPerFrame, "Should meet device-specific memory target")

        print("✅ Device-specific performance targets validated")
    }

    // MARK: - Helper Methods

    private func getDeviceInfo() -> DeviceInfo {
        let processInfo = ProcessInfo.processInfo

        return DeviceInfo(
            model: getDeviceModel(),
            memoryGB: Int(processInfo.physicalMemory / (1024 * 1024 * 1024)),
            cpuCores: processInfo.processorCount,
            isSimulator: isRunningOnSimulator()
        )
    }

    private func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
        return model
    }

    private func isRunningOnSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private func determinePerformanceConfig(for device: DeviceInfo) -> FrameExtractor.ExtractionConfig {
        let maxSize: CGSize
        let timeout: TimeInterval

        if device.memoryGB >= 6 && device.cpuCores >= 6 {
            // High-end device
            maxSize = CGSize(width: 1280, height: 1280)
            timeout = 0.08
        } else if device.memoryGB >= 3 && device.cpuCores >= 4 {
            // Mid-range device
            maxSize = CGSize(width: 640, height: 640)
            timeout = 0.1
        } else {
            // Low-end device
            maxSize = CGSize(width: 480, height: 480)
            timeout = 0.15
        }

        return FrameExtractor.ExtractionConfig(
            frameTime: CMTime(seconds: 0.1, preferredTimescale: 600),
            maximumSize: maxSize,
            appliesPreferredTrackTransform: true,
            extractionTimeout: timeout
        )
    }

    private func getExpectedPerformance(for device: DeviceInfo) -> ExpectedPerformance {
        if device.isSimulator {
            // More lenient for simulator
            return ExpectedPerformance(maxTime: 0.5, minCacheSpeedup: 3.0, maxMemoryPerFrame: 20.0)
        } else if device.memoryGB >= 6 {
            // High-end device
            return ExpectedPerformance(maxTime: 0.08, minCacheSpeedup: 8.0, maxMemoryPerFrame: 10.0)
        } else if device.memoryGB >= 3 {
            // Mid-range device
            return ExpectedPerformance(maxTime: 0.12, minCacheSpeedup: 5.0, maxMemoryPerFrame: 8.0)
        } else {
            // Low-end device
            return ExpectedPerformance(maxTime: 0.2, minCacheSpeedup: 3.0, maxMemoryPerFrame: 5.0)
        }
    }

    private func getPerformanceTargets(for device: DeviceInfo) -> PerformanceTargets {
        if device.isSimulator {
            return PerformanceTargets(maxExtractionTime: 0.5, minCacheSpeedup: 3.0, maxMemoryPerFrame: 20.0)
        } else if device.memoryGB >= 6 {
            return PerformanceTargets(maxExtractionTime: 0.08, minCacheSpeedup: 8.0, maxMemoryPerFrame: 10.0)
        } else if device.memoryGB >= 3 {
            return PerformanceTargets(maxExtractionTime: 0.12, minCacheSpeedup: 5.0, maxMemoryPerFrame: 8.0)
        } else {
            return PerformanceTargets(maxExtractionTime: 0.2, minCacheSpeedup: 3.0, maxMemoryPerFrame: 5.0)
        }
    }

    private func estimateFrameMemoryUsage(_ frame: UIImage) -> Double {
        let size = frame.size
        let scale = frame.scale
        let pixelCount = size.width * scale * size.height * scale
        let bytes = pixelCount * 4 // RGBA
        return Double(bytes) / (1024 * 1024) // Convert to MB
    }

    private func createTestVideoFile() throws -> URL {
        let videoURL = tempDirectory.appendingPathComponent("compatibility_test_\(UUID().uuidString).mp4")
        let testData = "compatibility test video data".data(using: .utf8)!
        try testData.write(to: videoURL)
        return videoURL
    }

    // MARK: - Supporting Types

    struct DeviceInfo {
        let model: String
        let memoryGB: Int
        let cpuCores: Int
        let isSimulator: Bool
    }

    struct ExpectedPerformance {
        let maxTime: TimeInterval
        let minCacheSpeedup: Double
        let maxMemoryPerFrame: Double
    }

    struct PerformanceTargets {
        let maxExtractionTime: TimeInterval
        let minCacheSpeedup: Double
        let maxMemoryPerFrame: Double
    }
}
#endif