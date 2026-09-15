//
//  FavoriteCollectionsTests.swift
//  BumpSetCutTests
//
//  Favorite collections: RallyReviewSelections codability, RallyActionManager
//  collection bookkeeping (set/clear/undo/deselect), and the timeline editor's
//  index remap of the collections sidecar.
//

import XCTest
import CoreMedia
@testable import BumpSetCut

@MainActor
final class FavoriteCollectionsTests: XCTestCase {

    var tempDirectory: URL!
    var metadataStore: MetadataStore!
    var videoId: UUID!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoriteCollectionsTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = tempDirectory
        metadataStore = MetadataStore()
        videoId = UUID()
    }

    override func tearDownWithError() throws {
        StorageManager.storageDirectoryOverride = nil
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
        metadataStore = nil
        videoId = nil
        try super.tearDownWithError()
    }

    // MARK: - RallyReviewSelections coding

    func testReviewSelectionsRoundTripWithCollections() throws {
        let original = RallyReviewSelections(
            saved: [0, 1, 3],
            removed: [2],
            favorited: [1, 3],
            favoriteCollections: [1: "Weekend Highlights", 3: "Big Blocks"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RallyReviewSelections.self, from: data)

        XCTAssertEqual(decoded.saved, original.saved)
        XCTAssertEqual(decoded.removed, original.removed)
        XCTAssertEqual(decoded.favorited, original.favorited)
        XCTAssertEqual(decoded.favoriteCollections, original.favoriteCollections)
    }

    func testReviewSelectionsLegacyDecodeDefaultsCollections() throws {
        // Sidecar written before favorited/favoriteCollections existed.
        let legacyJSON = #"{"saved":[0,2],"removed":[1]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RallyReviewSelections.self, from: legacyJSON)

        XCTAssertEqual(decoded.saved, [0, 2])
        XCTAssertEqual(decoded.removed, [1])
        XCTAssertTrue(decoded.favorited.isEmpty)
        XCTAssertTrue(decoded.favoriteCollections.isEmpty)
    }

    // MARK: - RallyActionManager

    private func makeLoadedManager() -> RallyActionManager {
        let manager = RallyActionManager()
        manager.loadSavedSelections(videoId: videoId, metadataStore: metadataStore)
        return manager
    }

    func testSetFavoriteCollectionPersistsImmediately() {
        let manager = makeLoadedManager()
        _ = manager.registerAction(.favorite, rallyIndex: 2, direction: .up)
        manager.setFavoriteCollection("Beach Trip", for: 2)

        XCTAssertEqual(manager.favoriteCollections[2], "Beach Trip")
        // Persisted without waiting for player dismiss.
        let reloaded = metadataStore.loadReviewSelections(for: videoId)
        XCTAssertEqual(reloaded.favoriteCollections[2], "Beach Trip")

        manager.setFavoriteCollection(nil, for: 2)
        XCTAssertNil(manager.favoriteCollections[2])
        XCTAssertNil(metadataStore.loadReviewSelections(for: videoId).favoriteCollections[2])
    }

    func testRemoveActionClearsCollection() {
        let manager = makeLoadedManager()
        _ = manager.registerAction(.favorite, rallyIndex: 1, direction: .up)
        manager.setFavoriteCollection("Blocks", for: 1)

        _ = manager.registerAction(.remove, rallyIndex: 1, direction: .left)

        XCTAssertFalse(manager.favoritedRallies.contains(1))
        XCTAssertNil(manager.favoriteCollections[1])
        XCTAssertNil(metadataStore.loadReviewSelections(for: videoId).favoriteCollections[1])
    }

    func testUndoRestoresPreviousCollection() {
        let manager = makeLoadedManager()
        _ = manager.registerAction(.favorite, rallyIndex: 0, direction: .up)
        manager.setFavoriteCollection("Aces", for: 0)

        // Removing snapshots previousCollection; undo must bring it back.
        _ = manager.registerAction(.remove, rallyIndex: 0, direction: .left)
        XCTAssertNil(manager.favoriteCollections[0])

        _ = manager.undoLast()
        XCTAssertTrue(manager.favoritedRallies.contains(0))
        XCTAssertEqual(manager.favoriteCollections[0], "Aces")
        XCTAssertEqual(metadataStore.loadReviewSelections(for: videoId).favoriteCollections[0], "Aces")
    }

    func testUndoFavoriteClearsCollectionChosenAfterIt() {
        let manager = makeLoadedManager()
        _ = manager.registerAction(.favorite, rallyIndex: 4, direction: .up)
        manager.setFavoriteCollection("Digs", for: 4)

        // Undoing the favorite itself: before it there was no collection.
        _ = manager.undoLast()
        XCTAssertFalse(manager.favoritedRallies.contains(4))
        XCTAssertNil(manager.favoriteCollections[4])
    }

    func testDeselectAllClearsCollections() {
        let manager = makeLoadedManager()
        _ = manager.registerAction(.favorite, rallyIndex: 0, direction: .up)
        manager.setFavoriteCollection("A", for: 0)
        _ = manager.registerAction(.favorite, rallyIndex: 1, direction: .up)
        manager.setFavoriteCollection("B", for: 1)

        manager.deselectAll()

        XCTAssertTrue(manager.favoriteCollections.isEmpty)
        XCTAssertTrue(metadataStore.loadReviewSelections(for: videoId).favoriteCollections.isEmpty)
    }

    func testLoadSavedSelectionsRestoresCollections() throws {
        let selections = RallyReviewSelections(
            saved: [0, 1], removed: [], favorited: [1], favoriteCollections: [1: "Finals"]
        )
        try metadataStore.saveReviewSelections(selections, for: videoId)

        let manager = makeLoadedManager()
        XCTAssertEqual(manager.favoriteCollections, [1: "Finals"])
    }

    // MARK: - Timeline remap

    /// Deleting a segment on the timeline shifts later indices down; the
    /// collections sidecar must follow its rallies to their new indices.
    func testTimelineSaveRemapsFavoriteCollections() async throws {
        let videoURL = tempDirectory.appendingPathComponent("timeline_remap.mp4")
        try TestVideoFactory.writeVideo(to: videoURL, duration: 8.0, size: CGSize(width: 160, height: 120), fps: 5)

        let segments = [
            makeSegment(start: 1.0, end: 2.0),
            makeSegment(start: 3.0, end: 4.0),
            makeSegment(start: 5.0, end: 6.0)
        ]
        try metadataStore.saveMetadata(makeMetadata(segments: segments))
        try metadataStore.saveReviewSelections(
            RallyReviewSelections(
                saved: [0, 1, 2], removed: [], favorited: [0, 2],
                favoriteCollections: [0: "Keep", 2: "Shifted"]
            ),
            for: videoId
        )

        let viewModel = RallyTimelineViewModel(videoURL: videoURL, videoId: videoId, metadataStore: metadataStore)
        await viewModel.load()
        XCTAssertTrue(viewModel.isLoaded)
        XCTAssertEqual(viewModel.segments.count, 3)

        // Delete the middle segment: index 2 becomes index 1.
        viewModel.selectedSegmentID = viewModel.segments[1].id
        viewModel.deleteSelected()
        try viewModel.save()

        let remapped = metadataStore.loadReviewSelections(for: videoId)
        XCTAssertEqual(remapped.favoriteCollections, [0: "Keep", 1: "Shifted"])
        XCTAssertEqual(remapped.favorited, [0, 1])
        XCTAssertEqual(remapped.saved, [0, 1])
    }

    // MARK: - Fixture helpers

    private func makeSegment(start: Double, end: Double) -> RallySegment {
        RallySegment(
            startTime: CMTime(seconds: start, preferredTimescale: 600),
            endTime: CMTime(seconds: end, preferredTimescale: 600),
            confidence: 0.9,
            quality: 0.9,
            detectionCount: 10,
            averageTrajectoryLength: 5.0
        )
    }

    private func makeMetadata(segments: [RallySegment]) -> ProcessingMetadata {
        ProcessingMetadata(
            videoId: videoId,
            processingConfig: ProcessorConfig(),
            rallySegments: segments,
            processingStats: ProcessingStats(
                totalFrames: 40, processedFrames: 40, detectionFrames: 20,
                trackingFrames: 10, rallyFrames: 10, physicsValidFrames: 8,
                totalDetections: 50, validTrajectories: 3,
                averageDetectionsPerFrame: 1.2, averageConfidence: 0.8,
                processingDuration: 1.0, framesPerSecond: 5.0
            ),
            qualityMetrics: QualityMetrics(
                overallQuality: 0.8, averageRSquared: 0.8, trajectoryConsistency: 0.8,
                physicsValidationRate: 0.8, movementClassificationAccuracy: 0.8,
                confidenceDistribution: ConfidenceDistribution(high: 10, medium: 5, low: 2),
                qualityBreakdown: QualityBreakdown(
                    velocityConsistency: 0.8, accelerationPattern: 0.8,
                    smoothnessScore: 0.8, verticalMotionScore: 0.8, overallCoherence: 0.8
                )
            ),
            performanceMetrics: PerformanceData(
                processingStartTime: Date().addingTimeInterval(-10),
                processingEndTime: Date(),
                averageFPS: 5.0, peakMemoryUsageMB: 100, averageMemoryUsageMB: 80,
                cpuUsagePercent: 10, processingOverheadPercent: 1, detectionLatencyMs: 5
            )
        )
    }
}
