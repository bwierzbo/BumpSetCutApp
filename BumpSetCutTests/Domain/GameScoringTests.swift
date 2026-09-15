//
//  GameScoringTests.swift
//  BumpSetCutTests
//
//  Game scoring: score engine progression (points, unscored rallies, set
//  breaks), sidecar coding + persistence, and the timeline-edit index remap.
//

import XCTest
import CoreMedia
@testable import BumpSetCut

@MainActor
final class GameScoringTests: XCTestCase {

    var tempDirectory: URL!
    var metadataStore: MetadataStore!
    var videoId: UUID!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameScoringTests_\(UUID().uuidString)")
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

    // MARK: - Score Engine

    func testStatesShowScoreBeforeEachRally() {
        var scoring = GameScoring()
        scoring.pointWinners = [0: .teamA, 1: .teamA, 2: .teamB]

        let states = GameScoreEngine.states(for: scoring, rallyCount: 4)

        XCTAssertEqual(states.count, 4)
        XCTAssertEqual(states[0], GameScoreState(scoreA: 0, scoreB: 0, setsA: 0, setsB: 0))
        XCTAssertEqual(states[1], GameScoreState(scoreA: 1, scoreB: 0, setsA: 0, setsB: 0))
        XCTAssertEqual(states[2], GameScoreState(scoreA: 2, scoreB: 0, setsA: 0, setsB: 0))
        XCTAssertEqual(states[3], GameScoreState(scoreA: 2, scoreB: 1, setsA: 0, setsB: 0))
    }

    func testUnscoredRalliesCarryScoreForward() {
        var scoring = GameScoring()
        scoring.pointWinners = [0: .teamB, 3: .teamB]  // rallies 1 & 2 unscored

        let states = GameScoreEngine.states(for: scoring, rallyCount: 5)

        XCTAssertEqual(states[1].scoreB, 1)
        XCTAssertEqual(states[2].scoreB, 1)
        XCTAssertEqual(states[3].scoreB, 1)
        XCTAssertEqual(states[4].scoreB, 2)
    }

    func testSetBreakAwardsLeaderAndResetsPoints() {
        var scoring = GameScoring()
        scoring.pointWinners = [0: .teamA, 1: .teamA, 2: .teamB, 3: .teamB]
        scoring.setBreaks = [2]  // rally 2 starts set 2, with A leading 2–0

        let states = GameScoreEngine.states(for: scoring, rallyCount: 4)

        XCTAssertEqual(states[2], GameScoreState(scoreA: 0, scoreB: 0, setsA: 1, setsB: 0))
        XCTAssertEqual(states[3], GameScoreState(scoreA: 0, scoreB: 1, setsA: 1, setsB: 0))

        let final = GameScoreEngine.finalState(for: scoring, rallyCount: 4)
        XCTAssertEqual(final, GameScoreState(scoreA: 0, scoreB: 2, setsA: 1, setsB: 0))
    }

    func testTiedSetBreakAwardsNoSet() {
        var scoring = GameScoring()
        scoring.pointWinners = [0: .teamA, 1: .teamB]
        scoring.setBreaks = [2]  // 1–1 at the break

        let states = GameScoreEngine.states(for: scoring, rallyCount: 3)
        XCTAssertEqual(states[2], GameScoreState(scoreA: 0, scoreB: 0, setsA: 0, setsB: 0))
    }

    func testSetBreakAtIndexZeroIsIgnored() {
        var scoring = GameScoring()
        scoring.pointWinners = [0: .teamA]
        scoring.setBreaks = [0]

        let states = GameScoreEngine.states(for: scoring, rallyCount: 2)
        XCTAssertEqual(states[0], GameScoreState())
        XCTAssertEqual(states[1].scoreA, 1)
        XCTAssertEqual(states[1].setsA, 0)
    }

    // MARK: - Coding & Persistence

    func testGameScoringRoundTrip() throws {
        let scoring = GameScoring(
            teamA: GameTeam(name: "Sharks", colorHex: "#EF4444"),
            teamB: GameTeam(name: "Jets", colorHex: "#3B82F6"),
            pointWinners: [0: .teamA, 5: .teamB],
            setBreaks: [3]
        )
        let data = try JSONEncoder().encode(scoring)
        let decoded = try JSONDecoder().decode(GameScoring.self, from: data)
        XCTAssertEqual(decoded, scoring)
    }

    func testLegacyDecodeDefaultsOptionalFields() throws {
        let json = "{\"teamA\":{\"name\":\"A\",\"colorHex\":\"#FFFFFF\"},\"teamB\":{\"name\":\"B\",\"colorHex\":\"#000000\"}}"
        let decoded = try JSONDecoder().decode(GameScoring.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(decoded.pointWinners.isEmpty)
        XCTAssertTrue(decoded.setBreaks.isEmpty)
    }

    func testMetadataStorePersistence() throws {
        XCTAssertNil(metadataStore.loadGameScoring(for: videoId), "No sidecar yet → nil (drives setup)")

        let scoring = GameScoring(pointWinners: [1: .teamB], setBreaks: [4])
        try metadataStore.saveGameScoring(scoring, for: videoId)

        let loaded = metadataStore.loadGameScoring(for: videoId)
        XCTAssertEqual(loaded, scoring)
    }

    // MARK: - Timeline Remap

    /// Deleting a rally on the timeline shifts later indices down; point
    /// winners and set breaks must follow their rallies.
    func testTimelineSaveRemapsGameScoring() async throws {
        let videoURL = tempDirectory.appendingPathComponent("scoring_remap.mp4")
        try TestVideoFactory.writeVideo(to: videoURL, duration: 8.0, size: CGSize(width: 160, height: 120), fps: 5)

        let segments = [
            makeSegment(start: 1.0, end: 2.0),
            makeSegment(start: 3.0, end: 4.0),
            makeSegment(start: 5.0, end: 6.0)
        ]
        try metadataStore.saveMetadata(makeMetadata(segments: segments))
        try metadataStore.saveGameScoring(
            GameScoring(pointWinners: [0: .teamA, 2: .teamB], setBreaks: [2]),
            for: videoId
        )

        let viewModel = RallyTimelineViewModel(videoURL: videoURL, videoId: videoId, metadataStore: metadataStore)
        await viewModel.load()
        XCTAssertTrue(viewModel.isLoaded)

        // Delete the middle rally: index 2 becomes index 1.
        viewModel.selectedSegmentID = viewModel.segments[1].id
        viewModel.deleteSelected()
        try viewModel.save()

        let remapped = metadataStore.loadGameScoring(for: videoId)
        XCTAssertEqual(remapped?.pointWinners, [0: .teamA, 1: .teamB])
        XCTAssertEqual(remapped?.setBreaks, [1])
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
