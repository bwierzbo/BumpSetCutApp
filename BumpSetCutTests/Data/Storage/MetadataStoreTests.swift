//
//  MetadataStoreTests.swift
//  BumpSetCutTests
//
//  Created for Metadata Video Processing - Task 002
//

import XCTest
import CoreMedia
@testable import BumpSetCut
import Foundation

@MainActor
final class MetadataStoreTests: XCTestCase {

    // MARK: - Test Properties

    var metadataStore: MetadataStore!
    var tempDirectory: URL!
    var testVideoId: UUID!

    // MARK: - Setup and Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Create a temporary directory for testing
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataStoreTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        print("MetadataStoreTests: Created temp directory: \(tempDirectory.path)")

        // Point storage at the isolated temp dir so MetadataStore reads/writes there
        // instead of the shared on-disk library (the seam this comment always wanted).
        StorageManager.storageDirectoryOverride = tempDirectory
        metadataStore = MetadataStore()
        testVideoId = UUID()

        print("MetadataStoreTests: Setup complete for test video ID: \(testVideoId!)")
    }

    override func tearDownWithError() throws {
        StorageManager.storageDirectoryOverride = nil
        // Clean up temp directory
        if let tempDirectory = tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
            print("MetadataStoreTests: Cleaned up temp directory")
        }

        metadataStore = nil
        testVideoId = nil
        tempDirectory = nil

        try super.tearDownWithError()
    }

    // MARK: - Test Data Creation

    private func createTestMetadata(videoId: UUID? = nil) -> ProcessingMetadata {
        let id = videoId ?? testVideoId!

        // Create test ProcessorConfig
        let config = ProcessorConfig()

        // Create test rally segments
        let rallySegment = RallySegment(
            startTime: CMTime(seconds: 10.0, preferredTimescale: 600),
            endTime: CMTime(seconds: 15.0, preferredTimescale: 600),
            confidence: 0.95,
            quality: 0.88,
            detectionCount: 150,
            averageTrajectoryLength: 25.0
        )

        // Create test processing stats
        let stats = ProcessingStats(
            totalFrames: 1800,
            processedFrames: 1750,
            detectionFrames: 800,
            trackingFrames: 600,
            rallyFrames: 150,
            physicsValidFrames: 120,
            totalDetections: 2500,
            validTrajectories: 45,
            averageDetectionsPerFrame: 1.4,
            averageConfidence: 0.82,
            processingDuration: 45.2,
            framesPerSecond: 30.0
        )

        // Create test quality metrics
        let confidenceDistribution = ConfidenceDistribution(high: 300, medium: 150, low: 50)
        let qualityBreakdown = QualityBreakdown(
            velocityConsistency: 0.85,
            accelerationPattern: 0.78,
            smoothnessScore: 0.82,
            verticalMotionScore: 0.90,
            overallCoherence: 0.84
        )

        let quality = QualityMetrics(
            overallQuality: 0.85,
            averageRSquared: 0.88,
            trajectoryConsistency: 0.82,
            physicsValidationRate: 0.80,
            movementClassificationAccuracy: 0.75,
            confidenceDistribution: confidenceDistribution,
            qualityBreakdown: qualityBreakdown
        )

        // Create test performance data
        let performance = PerformanceData(
            processingStartTime: Date().addingTimeInterval(-60),
            processingEndTime: Date(),
            averageFPS: 28.5,
            peakMemoryUsageMB: 1200.0,
            averageMemoryUsageMB: 800.0,
            cpuUsagePercent: 65.0,
            processingOverheadPercent: 8.5,
            detectionLatencyMs: 15.2
        )

        return ProcessingMetadata(
            videoId: id,
            processingConfig: config,
            rallySegments: [rallySegment],
            processingStats: stats,
            qualityMetrics: quality,
            performanceMetrics: performance
        )
    }

    // MARK: - Basic CRUD Tests

    @MainActor
    func testSaveAndLoadMetadata() throws {
        let testMetadata = createTestMetadata()

        // Test save
        XCTAssertNoThrow(try metadataStore.saveMetadata(testMetadata), "Save should succeed")

        // Test exists
        XCTAssertTrue(metadataStore.metadataExists(for: testVideoId), "Metadata should exist after save")

        // Test load
        let loadedMetadata = try metadataStore.loadMetadata(for: testVideoId)

        // Verify loaded data matches saved data
        XCTAssertEqual(loadedMetadata.id, testMetadata.id, "Metadata ID should match")
        XCTAssertEqual(loadedMetadata.videoId, testMetadata.videoId, "Video ID should match")
        XCTAssertEqual(loadedMetadata.processingVersion, testMetadata.processingVersion, "Processing version should match")
        XCTAssertEqual(loadedMetadata.rallySegments.count, testMetadata.rallySegments.count, "Rally segment count should match")
        XCTAssertEqual(loadedMetadata.processingStats.totalFrames, testMetadata.processingStats.totalFrames, "Processing stats should match")

        print("testSaveAndLoadMetadata: ✅ Basic save/load functionality verified")
    }

    @MainActor
    func testDeleteMetadata() throws {
        let testMetadata = createTestMetadata()

        // Save metadata first
        try metadataStore.saveMetadata(testMetadata)
        XCTAssertTrue(metadataStore.metadataExists(for: testVideoId), "Metadata should exist after save")

        // Delete metadata
        XCTAssertNoThrow(try metadataStore.deleteMetadata(for: testVideoId), "Delete should succeed")

        // Verify deletion
        XCTAssertFalse(metadataStore.metadataExists(for: testVideoId), "Metadata should not exist after delete")

        // Verify load fails after deletion
        XCTAssertThrowsError(try metadataStore.loadMetadata(for: testVideoId)) { error in
            XCTAssertTrue(error is MetadataStoreError, "Should throw MetadataStoreError")
            if case MetadataStoreError.metadataNotFound = error {
                // Expected error type
            } else {
                XCTFail("Should throw metadataNotFound error")
            }
        }

        print("testDeleteMetadata: ✅ Delete functionality verified")
    }

    @MainActor
    func testMetadataNotFound() throws {
        let nonExistentId = UUID()

        // Test exists for non-existent metadata
        XCTAssertFalse(metadataStore.metadataExists(for: nonExistentId), "Non-existent metadata should not exist")

        // Test load for non-existent metadata
        XCTAssertThrowsError(try metadataStore.loadMetadata(for: nonExistentId)) { error in
            XCTAssertTrue(error is MetadataStoreError, "Should throw MetadataStoreError")
            if case MetadataStoreError.metadataNotFound(let videoId) = error {
                XCTAssertEqual(videoId, nonExistentId, "Error should include correct video ID")
            } else {
                XCTFail("Should throw metadataNotFound error")
            }
        }

        // Test delete for non-existent metadata
        XCTAssertThrowsError(try metadataStore.deleteMetadata(for: nonExistentId)) { error in
            XCTAssertTrue(error is MetadataStoreError, "Should throw MetadataStoreError")
            if case MetadataStoreError.metadataNotFound = error {
                // Expected error type
            } else {
                XCTFail("Should throw metadataNotFound error")
            }
        }

        print("testMetadataNotFound: ✅ Error handling for non-existent metadata verified")
    }

    // MARK: - Atomic Operations Tests

    @MainActor
    func testAtomicWrite() throws {
        let testMetadata = createTestMetadata()

        // Save initial metadata
        try metadataStore.saveMetadata(testMetadata)

        // Create updated metadata
        // We can't modify the let properties, so we'll create a new one with a different processing date
        let updatedTestMetadata = ProcessingMetadata(
            videoId: testMetadata.videoId,
            processingConfig: ProcessorConfig(),
            rallySegments: testMetadata.rallySegments + [RallySegment(
                startTime: CMTimeMakeWithSeconds(20.0, preferredTimescale: 600),
                endTime: CMTimeMakeWithSeconds(25.0, preferredTimescale: 600),
                confidence: 0.90,
                quality: 0.85,
                detectionCount: 120,
                averageTrajectoryLength: 22.0
            )],
            processingStats: testMetadata.processingStats,
            qualityMetrics: testMetadata.qualityMetrics,
            performanceMetrics: testMetadata.performanceMetrics
        )

        // Save updated metadata (should create backup and perform atomic write)
        XCTAssertNoThrow(try metadataStore.saveMetadata(updatedTestMetadata), "Atomic update should succeed")

        // Verify updated data
        let loadedMetadata = try metadataStore.loadMetadata(for: testVideoId)
        XCTAssertEqual(loadedMetadata.rallySegments.count, 2, "Should have updated rally segments")

        print("testAtomicWrite: ✅ Atomic write operations verified")
    }

    @MainActor
    func testBackupCreation() throws {
        let testMetadata = createTestMetadata()

        // Save initial metadata
        try metadataStore.saveMetadata(testMetadata)

        // Get file info before update
        let metadataURL = metadataStore.metadataDirectory.appendingPathComponent("\(testVideoId!.uuidString).json")
        let _ = try FileManager.default.attributesOfItem(atPath: metadataURL.path)[.size] as! Int64

        // Create and save updated metadata (this should create a backup)
        let updatedTestMetadata = ProcessingMetadata(
            videoId: testMetadata.videoId,
            processingConfig: ProcessorConfig(),
            rallySegments: testMetadata.rallySegments,
            processingStats: testMetadata.processingStats,
            qualityMetrics: testMetadata.qualityMetrics,
            performanceMetrics: testMetadata.performanceMetrics
        )

        try metadataStore.saveMetadata(updatedTestMetadata)

        // The replaced version is kept as the backup (the fallback for a
        // corrupt or missing main file).
        let backupURL = metadataStore.metadataDirectory.appendingPathComponent("\(testVideoId!.uuidString).json.backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path), "Previous version should be kept as the backup")
    }

    // MARK: - Query Operations Tests

    @MainActor
    func testGetAllMetadataVideoIds() throws {
        // Initially should be empty
        let initialIds = metadataStore.getAllMetadataVideoIds()
        XCTAssertTrue(initialIds.isEmpty, "Should start with no metadata")

        // Add multiple metadata files
        let videoId1 = UUID()
        let videoId2 = UUID()
        let videoId3 = UUID()

        try metadataStore.saveMetadata(createTestMetadata(videoId: videoId1))
        try metadataStore.saveMetadata(createTestMetadata(videoId: videoId2))
        try metadataStore.saveMetadata(createTestMetadata(videoId: videoId3))

        // Get all IDs
        let allIds = Set(metadataStore.getAllMetadataVideoIds())
        let expectedIds = Set([videoId1, videoId2, videoId3])

        XCTAssertEqual(allIds, expectedIds, "Should return all saved video IDs")

        print("testGetAllMetadataVideoIds: ✅ Query operations verified")
    }

    @MainActor
    func testGetMetadataFileSize() throws {
        let testMetadata = createTestMetadata()

        // Should return nil for non-existent metadata
        XCTAssertNil(metadataStore.getMetadataFileSize(for: testVideoId), "Should return nil for non-existent metadata")

        // Save metadata and check size
        try metadataStore.saveMetadata(testMetadata)
        let fileSize = metadataStore.getMetadataFileSize(for: testVideoId)

        XCTAssertNotNil(fileSize, "Should return file size for existing metadata")
        XCTAssertGreaterThan(fileSize!, 0, "File size should be greater than 0")

        print("testGetMetadataFileSize: ✅ File size queries verified")
    }

    // MARK: - Error Handling Tests

    @MainActor
    func testVideoIdMismatchValidation() throws {
        let testMetadata = createTestMetadata()

        // Save metadata
        try metadataStore.saveMetadata(testMetadata)

        // Manually modify the JSON file to have a different video ID
        let metadataURL = metadataStore.metadataDirectory.appendingPathComponent("\(testVideoId!.uuidString).json")
        let jsonData = try Data(contentsOf: metadataURL)

        var json = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]
        json["videoId"] = UUID().uuidString  // Change to different UUID

        let modifiedData = try JSONSerialization.data(withJSONObject: json)
        try modifiedData.write(to: metadataURL)

        // Loading should fail with corruption error
        XCTAssertThrowsError(try metadataStore.loadMetadata(for: testVideoId)) { error in
            XCTAssertTrue(error is MetadataStoreError, "Should throw MetadataStoreError")
            if case MetadataStoreError.corruptedMetadata(_, let reason) = error {
                XCTAssertTrue(reason.contains("Video ID mismatch"), "Should indicate video ID mismatch")
            } else {
                XCTFail("Should throw corruptedMetadata error with video ID mismatch")
            }
        }

        print("testVideoIdMismatchValidation: ✅ Video ID validation verified")
    }

    @MainActor
    func testEmptyFileHandling() throws {
        let testMetadata = createTestMetadata()

        // Save metadata
        try metadataStore.saveMetadata(testMetadata)

        // Create empty file
        let metadataURL = metadataStore.metadataDirectory.appendingPathComponent("\(testVideoId!.uuidString).json")
        try Data().write(to: metadataURL)

        // Loading should fail with corruption error
        XCTAssertThrowsError(try metadataStore.loadMetadata(for: testVideoId)) { error in
            XCTAssertTrue(error is MetadataStoreError, "Should throw MetadataStoreError")
            if case MetadataStoreError.corruptedMetadata(_, let reason) = error {
                XCTAssertTrue(reason.contains("File is empty"), "Should indicate empty file")
            } else {
                XCTFail("Should throw corruptedMetadata error for empty file")
            }
        }

        print("testEmptyFileHandling: ✅ Empty file handling verified")
    }

    // MARK: - Maintenance Operations Tests

    @MainActor
    func testSweepOrphanedSidecarsRemovesEveryKindForUnknownVideos() throws {
        let keep = UUID()
        let orphan = UUID()
        for videoId in [keep, orphan] {
            try metadataStore.saveMetadata(createTestMetadata(videoId: videoId))
            try metadataStore.saveMetadata(createTestMetadata(videoId: videoId)) // leaves a .backup
            try metadataStore.saveTrimAdjustments([0: RallyTrimAdjustment(before: 1, after: 0)], for: videoId)
            try metadataStore.saveReviewSelections(RallyReviewSelections(), for: videoId)
            try metadataStore.saveGameScoring(GameScoring(), for: videoId)
            try metadataStore.saveFrameEvidence([], for: videoId)
            try Data("{}".utf8).write(to: metadataStore.processingCheckpointFileURL(for: videoId))
        }

        let removed = metadataStore.sweepOrphanedSidecars(keeping: [keep])

        XCTAssertEqual(removed, 7, "metadata, backup, trims, selections, scoring, evidence, checkpoint")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: metadataStore.metadataDirectory.path)
        XCTAssertFalse(remaining.contains { $0.hasPrefix(orphan.uuidString) })
        XCTAssertEqual(remaining.filter { $0.hasPrefix(keep.uuidString) }.count, 7)
    }

    @MainActor
    func testDeleteAllSidecarsIncludesScoringAndCheckpoint() throws {
        try metadataStore.saveMetadata(createTestMetadata())
        try metadataStore.saveGameScoring(GameScoring(), for: testVideoId)
        try Data("{}".utf8).write(to: metadataStore.processingCheckpointFileURL(for: testVideoId))

        metadataStore.deleteAllSidecars(for: testVideoId)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: metadataStore.metadataDirectory.path)
        XCTAssertTrue(remaining.filter { $0.hasPrefix(testVideoId.uuidString) }.isEmpty)
    }

    @MainActor
    func testReprocessKeepsRallyMetadataButDropsIndexKeyedSidecars() throws {
        try metadataStore.saveMetadata(createTestMetadata())
        try metadataStore.saveTrimAdjustments([0: RallyTrimAdjustment(before: 1, after: 0)], for: testVideoId)
        try metadataStore.saveGameScoring(GameScoring(), for: testVideoId)

        metadataStore.deleteSidecarsForReprocess(videoId: testVideoId)

        XCTAssertNoThrow(try metadataStore.loadMetadata(for: testVideoId),
                         "The processor reads the old metadata to carry manual rallies through")
        XCTAssertTrue(metadataStore.loadTrimAdjustments(for: testVideoId).isEmpty)
        XCTAssertNil(metadataStore.loadGameScoring(for: testVideoId))
    }

    // MARK: - Backup Fallback & Quarantine

    @MainActor
    func testLoadFallsBackToBackupWhenMainFileIsCorrupt() throws {
        let original = createTestMetadata()
        try metadataStore.saveMetadata(original)
        try metadataStore.saveMetadata(original) // first version becomes the backup

        let mainURL = metadataStore.metadataDirectory.appendingPathComponent("\(testVideoId!.uuidString).json")
        try Data("not json".utf8).write(to: mainURL)

        let loaded = try metadataStore.loadMetadata(for: testVideoId)
        XCTAssertEqual(loaded.rallySegments.count, original.rallySegments.count)
        let names = try FileManager.default.contentsOfDirectory(atPath: metadataStore.metadataDirectory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("\(testVideoId!.uuidString).json.corrupt-") },
                      "The corrupt main file is quarantined, not overwritten")
        XCTAssertNoThrow(try metadataStore.loadMetadata(for: testVideoId), "Backup is reinstated as the main file")
    }

    @MainActor
    func testLoadFallsBackToBackupWhenMainFileIsMissing() throws {
        try metadataStore.saveMetadata(createTestMetadata())
        try metadataStore.saveMetadata(createTestMetadata())
        let mainURL = metadataStore.metadataDirectory.appendingPathComponent("\(testVideoId!.uuidString).json")
        try FileManager.default.removeItem(at: mainURL)

        XCTAssertNoThrow(try metadataStore.loadMetadata(for: testVideoId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mainURL.path))
    }

    @MainActor
    func testCorruptSidecarIsQuarantinedNotOverwritten() throws {
        let trimsURL = metadataStore.metadataDirectory.appendingPathComponent("\(testVideoId!.uuidString)_trims.json")
        try FileManager.default.createDirectory(at: metadataStore.metadataDirectory, withIntermediateDirectories: true)
        let corrupt = Data("{ truncated".utf8)
        try corrupt.write(to: trimsURL)

        XCTAssertTrue(metadataStore.loadTrimAdjustments(for: testVideoId).isEmpty)
        try metadataStore.saveTrimAdjustments([0: RallyTrimAdjustment(before: 2, after: 0)], for: testVideoId)

        let names = try FileManager.default.contentsOfDirectory(atPath: metadataStore.metadataDirectory.path)
        guard let quarantined = names.first(where: { $0.hasPrefix("\(testVideoId!.uuidString)_trims.json.corrupt-") }) else {
            return XCTFail("Corrupt sidecar should be moved aside")
        }
        let preserved = try Data(contentsOf: metadataStore.metadataDirectory.appendingPathComponent(quarantined))
        XCTAssertEqual(preserved, corrupt, "The unreadable bytes survive for recovery")
        XCTAssertEqual(metadataStore.loadTrimAdjustments(for: testVideoId)[0]?.before, 2)
    }

    @MainActor
    func testMissingSidecarIsNotQuarantined() throws {
        XCTAssertTrue(metadataStore.loadTrimAdjustments(for: testVideoId).isEmpty)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: metadataStore.metadataDirectory.path)) ?? []
        XCTAssertTrue(names.isEmpty)
    }

    // MARK: - Timeline transaction

    @MainActor
    func testSaveTimelineEditWritesAllFilesAndLeavesNoTemps() throws {
        let metadata = createTestMetadata()
        try metadataStore.saveMetadata(metadata)

        try metadataStore.saveTimelineEdit(
            metadata: metadata.withRallySegments(Array(metadata.rallySegments.prefix(1))),
            trims: [0: RallyTrimAdjustment(before: 1, after: 1)],
            selections: RallyReviewSelections(saved: [0], removed: [], favorited: [], favoriteCollections: [:], posted: []),
            scoring: GameScoring()
        )

        XCTAssertEqual(try metadataStore.loadMetadata(for: testVideoId).rallySegments.count, 1)
        XCTAssertEqual(metadataStore.loadTrimAdjustments(for: testVideoId)[0]?.before, 1)
        XCTAssertEqual(metadataStore.loadReviewSelections(for: testVideoId).saved, [0])
        XCTAssertNotNil(metadataStore.loadGameScoring(for: testVideoId))
        let names = try FileManager.default.contentsOfDirectory(atPath: metadataStore.metadataDirectory.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".staged") || $0.hasSuffix(".txn") })
    }

    // MARK: - Concurrency Tests

    @MainActor
    func testConcurrentOperations() async throws {
        let videoIds = (0..<5).map { _ in UUID() }

        // Test concurrent saves
        try await withThrowingTaskGroup(of: Void.self) { group in
            for videoId in videoIds {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    try await Task { @MainActor in
                        try self.metadataStore.saveMetadata(self.createTestMetadata(videoId: videoId))
                    }.value
                }
            }

            for try await _ in group {
                // Wait for all saves to complete
            }
        }

        // Verify all saves succeeded
        for videoId in videoIds {
            XCTAssertTrue(metadataStore.metadataExists(for: videoId), "Concurrent save should succeed for \(videoId)")
        }

        // Test concurrent loads
        let loadResults = try await withThrowingTaskGroup(of: ProcessingMetadata.self, returning: [ProcessingMetadata].self) { group in
            for videoId in videoIds {
                group.addTask { [weak self] in
                    guard let self = self else { throw NSError(domain: "TestError", code: 1) }
                    return try await Task { @MainActor in
                        try self.metadataStore.loadMetadata(for: videoId)
                    }.value
                }
            }

            var results: [ProcessingMetadata] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(loadResults.count, videoIds.count, "All concurrent loads should succeed")

        print("testConcurrentOperations: ✅ Concurrent operations verified")
    }
}
