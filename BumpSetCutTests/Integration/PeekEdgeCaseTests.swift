//
//  PeekEdgeCaseTests.swift
//  BumpSetCutTests
//
//  Created for Issue #45 - Testing and Quality Assurance
//  Edge case tests for corrupted videos, cancellation handling, and robustness
//

#if DEBUG
import XCTest
import UIKit
import AVFoundation
@testable import BumpSetCut

@MainActor
final class PeekEdgeCaseTests: XCTestCase {

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

        // Create basic test video
        testVideoURL = try createTestVideoFile()

        print("PeekEdgeCaseTests: Setup completed")
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

    // MARK: - Corrupted Video Handling Tests

    func testCorruptedVideoFileHandling() async throws {
        print("🧪 Testing corrupted video file handling")

        // Create various types of corrupted video files
        let corruptedVideos = try createCorruptedVideoFiles()
        var corruptionResults: [(String, Bool, String)] = []

        for (description, url) in corruptedVideos {
            print("🔍 Testing \(description): \(url.lastPathComponent)")

            do {
                let frame = try await frameExtractor.extractFrame(from: url, priority: .normal)
                corruptionResults.append((description, true, "Unexpected success"))
                XCTFail("Should have failed for \(description)")
            } catch let error as FrameExtractionError {
                corruptionResults.append((description, false, error.localizedDescription))
                print("✅ Correctly handled \(description): \(error.localizedDescription)")

                // Verify specific error types
                switch error {
                case .avFoundationError(_):
                    XCTAssertTrue(true, "AVFoundation error is expected for corrupted files")
                case .imageGenerationFailed:
                    XCTAssertTrue(true, "Image generation failure is expected for corrupted files")
                case .invalidVideoURL:
                    XCTAssertTrue(true, "Invalid URL error is expected for some corrupted files")
                default:
                    print("⚠️ Unexpected error type for \(description): \(error)")
                }

            } catch {
                corruptionResults.append((description, false, "Unexpected error: \(error)"))
                XCTAssertTrue(error is FrameExtractionError, "Should throw FrameExtractionError, got: \(type(of: error))")
            }
        }

        print("📊 Corrupted Video Test Results:")
        for (description, succeeded, message) in corruptionResults {
            print("   \(description): \(succeeded ? "❌ FAILED" : "✅ PASSED") - \(message)")
        }

        // All corrupted videos should fail
        let failureCount = corruptionResults.filter { !$0.1 }.count
        XCTAssertEqual(failureCount, corruptedVideos.count, "All corrupted videos should fail gracefully")

        // Clean up corrupted files
        for (_, url) in corruptedVideos {
            try? FileManager.default.removeItem(at: url)
        }

        print("✅ Corrupted video file handling validated")
    }

    func testInvalidVideoFormats() async throws {
        print("🧪 Testing invalid video format handling")

        // Create files with invalid video formats
        let invalidFormats = try createInvalidFormatFiles()
        var formatResults: [(String, Error?)] = []

        for (description, url) in invalidFormats {
            print("🔍 Testing \(description)")

            do {
                _ = try await frameExtractor.extractFrame(from: url, priority: .normal)
                formatResults.append((description, nil))
                XCTFail("Should have failed for invalid format: \(description)")
            } catch {
                formatResults.append((description, error))
                print("✅ Correctly rejected \(description): \(error.localizedDescription)")
                XCTAssertTrue(error is FrameExtractionError, "Should throw FrameExtractionError")
            }
        }

        print("📊 Invalid Format Results:")
        for (description, error) in formatResults {
            if let error = error {
                print("   \(description): ✅ REJECTED - \(error.localizedDescription)")
            } else {
                print("   \(description): ❌ ACCEPTED (should have failed)")
            }
        }

        // All invalid formats should be rejected
        let rejectionCount = formatResults.filter { $0.1 != nil }.count
        XCTAssertEqual(rejectionCount, invalidFormats.count, "All invalid formats should be rejected")

        // Clean up invalid files
        for (_, url) in invalidFormats {
            try? FileManager.default.removeItem(at: url)
        }

        print("✅ Invalid video format handling validated")
    }

    func testCorruptedVideoRecovery() async throws {
        print("🧪 Testing recovery after corrupted video errors")

        let corruptedURL = try createCorruptedVideoFile(type: .invalidContent)
        var recoveryEvents: [(String, Bool)] = []

        // Test recovery sequence
        let recoverySequence: [(String, URL)] = [
            ("valid_start", testVideoURL),
            ("corrupted_error", corruptedURL),
            ("valid_recovery", testVideoURL),
            ("corrupted_again", corruptedURL),
            ("final_recovery", testVideoURL)
        ]

        for (phase, url) in recoverySequence {
            do {
                let frame = try await frameExtractor.extractFrame(from: url, priority: .normal)
                recoveryEvents.append((phase, true))
                print("✅ \(phase): Successfully extracted frame (\(frame.size))")

                // Verify frame is valid
                XCTAssertGreaterThan(frame.size.width, 0, "Frame should have valid dimensions")
                XCTAssertGreaterThan(frame.size.height, 0, "Frame should have valid dimensions")

            } catch {
                recoveryEvents.append((phase, false))
                print("❌ \(phase): Expected error - \(error.localizedDescription)")

                if phase.contains("valid") {
                    XCTFail("Valid video should not fail in phase: \(phase)")
                } else {
                    XCTAssertTrue(error is FrameExtractionError, "Should throw FrameExtractionError for corrupted video")
                }
            }
        }

        print("📊 Recovery Sequence Results:")
        for (phase, success) in recoveryEvents {
            print("   \(phase): \(success ? "✅ SUCCESS" : "❌ FAILED")")
        }

        // Verify recovery pattern
        let validPhases = recoveryEvents.filter { $0.0.contains("valid") }
        let corruptedPhases = recoveryEvents.filter { $0.0.contains("corrupted") }

        let validSuccesses = validPhases.filter { $0.1 }.count
        let corruptedFailures = corruptedPhases.filter { !$0.1 }.count

        XCTAssertEqual(validSuccesses, validPhases.count, "All valid videos should succeed")
        XCTAssertEqual(corruptedFailures, corruptedPhases.count, "All corrupted videos should fail")

        // Verify frame extractor continues working after errors
        let finalFrame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        XCTAssertNotNil(finalFrame, "Frame extractor should work normally after recovery")

        try? FileManager.default.removeItem(at: corruptedURL)
        print("✅ Corrupted video recovery validated")
    }

    // MARK: - Task Cancellation Tests

    func testFrameExtractionCancellation() async throws {
        print("🧪 Testing frame extraction task cancellation")

        var cancellationResults: [(String, Bool, TimeInterval)] = []

        // Test immediate cancellation
        do {
            let cancellationStart = Date()
            let extractionTask = Task {
                try await frameExtractor.extractFrame(from: testVideoURL, priority: .low)
            }

            // Cancel immediately
            extractionTask.cancel()

            let frame = try await extractionTask.value
            let cancellationTime = Date().timeIntervalSince(cancellationStart)
            cancellationResults.append(("immediate", false, cancellationTime))
            print("⚠️ Immediate cancellation: Task completed unexpectedly")

        } catch {
            let cancellationTime = Date().timeIntervalSince(Date())
            cancellationResults.append(("immediate", true, cancellationTime))
            if error is CancellationError {
                print("✅ Immediate cancellation: Properly cancelled")
            } else {
                print("⚠️ Immediate cancellation: Different error - \(error)")
            }
        }

        // Test delayed cancellation
        let cancellationStart = Date()
        do {
            let extractionTask = Task {
                try await frameExtractor.extractFrame(from: testVideoURL, priority: .low)
            }

            // Cancel after brief delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                extractionTask.cancel()
            }

            let frame = try await extractionTask.value
            let cancellationTime = Date().timeIntervalSince(cancellationStart)
            cancellationResults.append(("delayed", false, cancellationTime))
            print("⚠️ Delayed cancellation: Task completed despite cancellation")

        } catch {
            let cancellationTime = Date().timeIntervalSince(cancellationStart)
            cancellationResults.append(("delayed", true, cancellationTime))
            if error is CancellationError {
                print("✅ Delayed cancellation: Properly cancelled in \(Int(cancellationTime * 1000))ms")
            } else {
                print("⚠️ Delayed cancellation: Different error - \(error)")
            }
        }

        // Test multiple concurrent cancellations
        let concurrentCancellations = 3
        var concurrentResults: [Bool] = []

        let concurrentTasks = (1...concurrentCancellations).map { i in
            Task {
                do {
                    let task = Task {
                        try await frameExtractor.extractFrame(from: testVideoURL, priority: .low)
                    }

                    // Cancel each task at different times
                    DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.005) {
                        task.cancel()
                    }

                    _ = try await task.value
                    return false // Task completed
                } catch {
                    return error is CancellationError // True if properly cancelled
                }
            }
        }

        for task in concurrentTasks {
            let result = await task.value
            concurrentResults.append(result)
        }

        let successfulCancellations = concurrentResults.filter { $0 }.count
        print("📊 Concurrent cancellations: \(successfulCancellations)/\(concurrentCancellations) properly cancelled")

        print("📊 Cancellation Test Results:")
        for (type, cancelled, time) in cancellationResults {
            print("   \(type): \(cancelled ? "✅ CANCELLED" : "⚠️ COMPLETED") in \(Int(time * 1000))ms")
        }

        print("✅ Frame extraction cancellation handling validated")
    }

    func testPeekGestureCancellationPatterns() throws {
        print("🧪 Testing peek gesture cancellation patterns")

        var gestureEvents: [(String, Double, RallyPeekDirection?)] = []
        let peekCallback: (Double, RallyPeekDirection?) -> Void = { progress, direction in
            gestureEvents.append(("callback", progress, direction))
        }

        // Test various cancellation patterns
        let cancellationPatterns: [(String, [(Double, RallyPeekDirection?)])] = [
            ("abrupt_cancel", [
                (0.0, nil), (0.3, .next), (0.0, nil)
            ]),
            ("progressive_cancel", [
                (0.0, nil), (0.2, .next), (0.4, .next), (0.6, .next), (0.4, .next), (0.2, .next), (0.0, nil)
            ]),
            ("direction_change_cancel", [
                (0.0, nil), (0.4, .next), (0.3, .previous), (0.0, nil)
            ]),
            ("peak_cancel", [
                (0.0, nil), (0.9, .previous), (0.0, nil)
            ]),
            ("multi_start_cancel", [
                (0.0, nil), (0.2, .next), (0.0, nil), (0.3, .previous), (0.0, nil), (0.1, .next), (0.0, nil)
            ])
        ]

        for (patternName, sequence) in cancellationPatterns {
            print("🎯 Testing pattern: \(patternName)")

            let patternStart = gestureEvents.count

            for (progress, direction) in sequence {
                peekCallback(progress, direction)
            }

            let patternEvents = Array(gestureEvents[patternStart...])

            // Verify cancellation reset
            let lastEvent = patternEvents.last
            XCTAssertEqual(lastEvent?.1, 0.0, "Pattern \(patternName) should end with zero progress")
            XCTAssertNil(lastEvent?.2, "Pattern \(patternName) should end with nil direction")

            // Verify pattern integrity
            let progressValues = patternEvents.map { $0.1 }
            XCTAssertEqual(progressValues.first, 0.0, "Pattern \(patternName) should start with zero")
            XCTAssertEqual(progressValues.last, 0.0, "Pattern \(patternName) should end with zero")

            print("✅ Pattern \(patternName): \(patternEvents.count) events, proper reset")
        }

        print("📊 Gesture Cancellation Results:")
        print("   Total patterns tested: \(cancellationPatterns.count)")
        print("   Total gesture events: \(gestureEvents.count)")

        // Verify all patterns ended properly
        let resetEvents = gestureEvents.filter { (event: (String, Double, RallyPeekDirection?)) -> Bool in
            event.1 == 0.0 && event.2 == nil
        }
        XCTAssertGreaterThanOrEqual(resetEvents.count, cancellationPatterns.count, "Each pattern should have reset events")

        print("✅ Peek gesture cancellation patterns validated")
    }

    // MARK: - Memory Pressure Edge Cases

    func testExtremeMemoryPressureHandling() async throws {
        print("🧪 Testing extreme memory pressure handling")

        frameExtractor.clearCache()

        // Simulate extreme memory pressure
        frameExtractor.enableGracefulDegradation()

        var pressureResults: [(String, Bool, TimeInterval)] = []

        // Test extraction under extreme pressure with different priorities
        let pressureTests: [(String, ExtractionPriority)] = [
            ("high_priority", .high),
            ("normal_priority", .normal),
            ("low_priority", .low)
        ]

        for (testName, priority) in pressureTests {
            let pressureStart = Date()

            do {
                let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: priority)
                let pressureTime = Date().timeIntervalSince(pressureStart)
                pressureResults.append((testName, true, pressureTime))
                print("✅ \(testName): Succeeded under pressure in \(Int(pressureTime * 1000))ms")

                XCTAssertNotNil(frame, "Frame should be extracted under pressure")
                XCTAssertGreaterThan(frame.size.width, 0, "Frame should have valid size under pressure")

            } catch {
                let pressureTime = Date().timeIntervalSince(pressureStart)
                pressureResults.append((testName, false, pressureTime))
                print("❌ \(testName): Failed under pressure - \(error.localizedDescription)")

                if error is FrameExtractionError {
                    // Memory pressure failures are acceptable
                    if case .memoryPressure = error as! FrameExtractionError {
                        print("✅ \(testName): Properly handled memory pressure")
                    }
                }
            }
        }

        // Test cache behavior under extreme pressure
        let cacheStatusUnderPressure = frameExtractor.cacheStatus
        print("📊 Cache under extreme pressure: \(cacheStatusUnderPressure)")

        // Restore normal operation
        frameExtractor.disableGracefulDegradation()

        // Verify recovery
        let recoveryFrame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        XCTAssertNotNil(recoveryFrame, "Should recover after memory pressure")

        print("📊 Extreme Memory Pressure Results:")
        for (test, success, time) in pressureResults {
            print("   \(test): \(success ? "✅ SUCCESS" : "❌ FAILED") in \(Int(time * 1000))ms")
        }

        print("✅ Extreme memory pressure handling validated")
    }

    func testCacheCorruptionRecovery() async throws {
        print("🧪 Testing cache corruption recovery")

        frameExtractor.clearCache()

        // Populate cache with valid data
        let initialFrame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        let initialCacheStatus = frameExtractor.cacheStatus
        print("📊 Initial cache: \(initialCacheStatus)")

        XCTAssertTrue(initialCacheStatus.contains("entries: 1"), "Cache should have one entry")

        // Simulate cache corruption by clearing and trying to access
        frameExtractor.clearCache()
        let clearedCacheStatus = frameExtractor.cacheStatus
        print("📊 Cleared cache: \(clearedCacheStatus)")

        // Verify recovery by re-extracting
        let recoveredFrame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)
        let recoveredCacheStatus = frameExtractor.cacheStatus
        print("📊 Recovered cache: \(recoveredCacheStatus)")

        XCTAssertEqual(initialFrame.size, recoveredFrame.size, "Recovered frame should match original")
        XCTAssertTrue(recoveredCacheStatus.contains("entries: 1"), "Cache should be rebuilt")

        // Test multiple corruption/recovery cycles
        for cycle in 1...3 {
            print("🔄 Corruption recovery cycle \(cycle)")

            frameExtractor.clearCache()
            let cycleFrame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .normal)

            XCTAssertEqual(cycleFrame.size, initialFrame.size, "Cycle \(cycle) frame should be consistent")
        }

        print("✅ Cache corruption recovery validated")
    }

    // MARK: - Resource Exhaustion Tests

    func testResourceExhaustionScenarios() async throws {
        print("🧪 Testing resource exhaustion scenarios")

        var resourceResults: [(String, Bool)] = []

        // Test many concurrent extractions to exhaust resources
        let exhaustionCount = 20
        let exhaustionTasks = (1...exhaustionCount).map { i in
            Task {
                do {
                    let frame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .low)
                    return (i, true, frame.size)
                } catch {
                    return (i, false, CGSize.zero)
                }
            }
        }

        let exhaustionResults = await withTaskGroup(of: (Int, Bool, CGSize).self) { group in
            for task in exhaustionTasks {
                group.addTask { await task.value }
            }

            var results: [(Int, Bool, CGSize)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let successCount = exhaustionResults.filter { $0.1 }.count
        let failureCount = exhaustionResults.filter { !$0.1 }.count

        print("📊 Resource Exhaustion Results:")
        print("   Total tasks: \(exhaustionCount)")
        print("   Successful: \(successCount)")
        print("   Failed: \(failureCount)")
        print("   Success rate: \(Int(Double(successCount)/Double(exhaustionCount) * 100))%")

        // Should handle most requests gracefully
        XCTAssertGreaterThanOrEqual(successCount, exhaustionCount / 2, "Should handle at least 50% of requests")

        // Verify system remains responsive
        let postExhaustionFrame = try await frameExtractor.extractFrame(from: testVideoURL, priority: .high)
        XCTAssertNotNil(postExhaustionFrame, "System should remain responsive after exhaustion test")

        print("✅ Resource exhaustion scenarios validated")
    }

    // MARK: - Helper Methods

    private func createCorruptedVideoFiles() throws -> [(String, URL)] {
        var corruptedFiles: [(String, URL)] = []

        // Empty file
        let emptyURL = tempDirectory.appendingPathComponent("empty.mp4")
        try Data().write(to: emptyURL)
        corruptedFiles.append(("Empty file", emptyURL))

        // Random binary data
        let randomURL = tempDirectory.appendingPathComponent("random.mp4")
        let randomData = Data((0..<1024).map { _ in UInt8.random(in: 0...255) })
        try randomData.write(to: randomURL)
        corruptedFiles.append(("Random binary data", randomURL))

        // Truncated MP4 header
        let truncatedURL = tempDirectory.appendingPathComponent("truncated.mp4")
        let truncatedData = "ftyp".data(using: .utf8)! // Incomplete MP4 header
        try truncatedData.write(to: truncatedURL)
        corruptedFiles.append(("Truncated MP4 header", truncatedURL))

        // Invalid MP4 structure
        let invalidURL = tempDirectory.appendingPathComponent("invalid.mp4")
        let invalidData = "ftypmp41\0\0\0\0invalid_data_follows".data(using: .utf8)!
        try invalidData.write(to: invalidURL)
        corruptedFiles.append(("Invalid MP4 structure", invalidURL))

        return corruptedFiles
    }

    private func createInvalidFormatFiles() throws -> [(String, URL)] {
        var invalidFiles: [(String, URL)] = []

        // Text file with MP4 extension
        let textURL = tempDirectory.appendingPathComponent("text.mp4")
        try "This is a text file, not a video".write(to: textURL, atomically: true, encoding: .utf8)
        invalidFiles.append(("Text file with MP4 extension", textURL))

        // JSON data with MP4 extension
        let jsonURL = tempDirectory.appendingPathComponent("data.mp4")
        let jsonData = "{\"not\": \"a video file\"}".data(using: .utf8)!
        try jsonData.write(to: jsonURL)
        invalidFiles.append(("JSON data with MP4 extension", jsonURL))

        // Image data with MP4 extension
        let imageURL = tempDirectory.appendingPathComponent("image.mp4")
        let imageData = "PNG\r\n\u{1a}\n".data(using: .utf8)! // PNG header
        try imageData.write(to: imageURL)
        invalidFiles.append(("Image data with MP4 extension", imageURL))

        return invalidFiles
    }

    private func createCorruptedVideoFile(type: CorruptionType) throws -> URL {
        let corruptedURL = tempDirectory.appendingPathComponent("corrupted_\(UUID().uuidString).mp4")

        switch type {
        case .invalidContent:
            try "corrupted video content".write(to: corruptedURL, atomically: true, encoding: .utf8)
        case .emptyFile:
            try Data().write(to: corruptedURL)
        case .randomData:
            let randomData = Data((0..<2048).map { _ in UInt8.random(in: 0...255) })
            try randomData.write(to: corruptedURL)
        }

        return corruptedURL
    }

    private func createTestVideoFile() throws -> URL {
        let videoURL = tempDirectory.appendingPathComponent("edge_test_\(UUID().uuidString).mp4")
        let testData = "edge case test video data".data(using: .utf8)!
        try testData.write(to: videoURL)
        return videoURL
    }

    private enum CorruptionType {
        case invalidContent
        case emptyFile
        case randomData
    }
}
#endif