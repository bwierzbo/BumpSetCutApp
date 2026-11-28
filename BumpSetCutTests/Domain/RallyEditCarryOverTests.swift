//
//  RallyEditCarryOverTests.swift
//  BumpSetCutTests
//
//  A video's edits follow its rallies when the rallies are decided again
//  (D-044): by time, one to one, and never onto a rally that is mostly
//  something else.
//

import XCTest
import CoreMedia
@testable import BumpSetCut

@MainActor
final class RallyEditCarryOverTests: XCTestCase {

    private var tempDirectory: URL!
    private var metadataStore: MetadataStore!
    private var videoId: UUID!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RallyEditCarryOverTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = tempDirectory
        metadataStore = MetadataStore()
        videoId = UUID()
    }

    override func tearDownWithError() throws {
        StorageManager.storageDirectoryOverride = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    // MARK: - Which rally is which

    func testTheSameRalliesKeepTheirPlaces() {
        let rallies = [segment(10, 20), segment(30, 42), segment(50, 55)]
        XCTAssertEqual(RallyEditCarryOver.pairs(from: rallies, to: rallies.map { segment($0.startTime, $0.endTime) }),
                       [0: 0, 1: 1, 2: 2])
    }

    func testARallyThatIsGoneShiftsTheOnesAfterIt() {
        let old = [segment(10, 20), segment(30, 42), segment(50, 55)]
        let new = [segment(10.2, 19.5), segment(50, 56)]
        XCTAssertEqual(RallyEditCarryOver.pairs(from: old, to: new), [0: 0, 2: 1])
    }

    func testANewRallyShiftsTheOnesAfterIt() {
        let old = [segment(10, 20), segment(50, 55)]
        let new = [segment(10, 20), segment(30, 42), segment(50, 55)]
        XCTAssertEqual(RallyEditCarryOver.pairs(from: old, to: new), [0: 0, 1: 2])
    }

    func testARallySplitInTwoGoesToThePartThatIsAtLeastHalfOfIt() {
        let old = [segment(10, 20)]
        XCTAssertEqual(RallyEditCarryOver.pairs(from: old, to: [segment(10, 14), segment(14.5, 20)]), [0: 1])
        // Three parts, none of them half of it: it is not any of them.
        XCTAssertEqual(RallyEditCarryOver.pairs(from: old, to: [segment(10, 13), segment(13.5, 16.5), segment(17, 20)]), [:])
    }

    func testTwoRalliesJoinedIntoOneGiveItToTheOneThatIsAtLeastHalfOfIt() {
        let new = [segment(0, 10)]
        XCTAssertEqual(RallyEditCarryOver.pairs(from: [segment(0, 6), segment(6.5, 10)], to: new), [0: 0])
        // Equal halves: the earlier one, and only one of them.
        XCTAssertEqual(RallyEditCarryOver.pairs(from: [segment(0, 5), segment(5, 10)], to: new), [0: 0])
    }

    func testAShortRallyInsideALongOneIsNotThatRally() {
        XCTAssertEqual(RallyEditCarryOver.pairs(from: [segment(10, 12)], to: [segment(0, 60)]), [:])
        XCTAssertEqual(RallyEditCarryOver.pairs(from: [segment(0, 60)], to: [segment(10, 12)]), [:])
    }

    func testRalliesThatOnlyTouchAreNotTheSame() {
        XCTAssertEqual(RallyEditCarryOver.pairs(from: [segment(10, 20)], to: [segment(20, 30)]), [:])
    }

    // MARK: - What follows

    func testEveryKindOfEditFollowsItsRallyAndTheRestIsLeftBehind() {
        let old = [segment(10, 20), segment(30, 42), segment(50, 55), segment(60, 70)]
        let new = [segment(10, 20), segment(50, 55), segment(60, 70)]
        let edits = RallyEdits(
            trims: [1: RallyTrimAdjustment(before: 1, after: 1), 2: RallyTrimAdjustment(before: 0, after: 0, rotation: 90, zoom: 2, panX: 0.1, panY: -0.2)],
            selections: RallyReviewSelections(saved: [0, 3], removed: [1], favorited: [2, 3],
                                              favoriteCollections: [2: "Best digs", 1: "Gone"], posted: [3]),
            scoring: GameScoring(pointWinners: [0: .teamA, 1: .teamB, 3: .teamB], setBreaks: [])
        )

        let outcome = RallyEditCarryOver.carry(edits, from: old, to: new)

        XCTAssertEqual(outcome.oldToNew, [0: 0, 2: 1, 3: 2])
        XCTAssertEqual(outcome.leftBehind, [1])
        XCTAssertEqual(Set(outcome.edits.trims.keys), [1])
        XCTAssertEqual(outcome.edits.trims[1]?.rotation, 90)
        XCTAssertEqual(outcome.edits.trims[1]?.zoom, 2)
        XCTAssertEqual(outcome.edits.trims[1]?.panX, 0.1)
        XCTAssertEqual(outcome.edits.trims[1]?.panY, -0.2)
        XCTAssertEqual(outcome.edits.selections.saved, [0, 2])
        XCTAssertEqual(outcome.edits.selections.removed, [])
        XCTAssertEqual(outcome.edits.selections.favorited, [1, 2])
        XCTAssertEqual(outcome.edits.selections.favoriteCollections, [1: "Best digs"])
        XCTAssertEqual(outcome.edits.selections.posted, [2])
        XCTAssertEqual(outcome.edits.scoring?.pointWinners, [0: .teamA, 2: .teamB])
        XCTAssertEqual(outcome.edits.scoring?.teamA, edits.scoring?.teamA)
    }

    func testAnUneditedRallyThatIsGoneIsNotReported() {
        let outcome = RallyEditCarryOver.carry(
            RallyEdits(trims: [:], selections: RallyReviewSelections(favorited: [0]), scoring: nil),
            from: [segment(10, 20), segment(30, 42)], to: [segment(10, 20)])
        XCTAssertEqual(outcome.leftBehind, [])
        XCTAssertNil(outcome.edits.scoring)
    }

    /// The person moved the start a second earlier (to 9 s) and left the end
    /// alone. The new rally starts at 11 and ends half a second later: it
    /// still plays from 9, and to the new end.
    func testATrimmedEdgeStaysAtItsTimeAndAnUntouchedEdgeFollowsTheNewRally() throws {
        let outcome = RallyEditCarryOver.carry(
            RallyEdits(trims: [0: RallyTrimAdjustment(before: 1, after: 0, rotation: 5)],
                       selections: RallyReviewSelections(), scoring: nil),
            from: [segment(10, 20)], to: [segment(11, 20.5)])
        let trim = try XCTUnwrap(outcome.edits.trims[0])
        XCTAssertEqual(trim.before, 2, accuracy: 1e-9)
        XCTAssertEqual(trim.after, 0)
        XCTAssertEqual(trim.rotation, 5)
    }

    func testATrimIntoTheRallyStaysAtItsTimeToo() throws {
        // Ended 1.5 s early (at 18.5); the new rally ends at 19.
        let outcome = RallyEditCarryOver.carry(
            RallyEdits(trims: [0: RallyTrimAdjustment(before: 0, after: -1.5)],
                       selections: RallyReviewSelections(), scoring: nil),
            from: [segment(10, 20)], to: [segment(10.4, 19)])
        let trim = try XCTUnwrap(outcome.edits.trims[0])
        XCTAssertEqual(trim.before, 0)
        XCTAssertEqual(trim.after, -0.5, accuracy: 1e-9)
        XCTAssertEqual(outcome.trimTimesDropped, [])
    }

    /// Trimmed to play 19–20 s only; the new rally is 10–15 s (half of the
    /// old one, so it is that rally). Keeping the start at 19 would end
    /// before it began: the times are given up and said so, the framing kept.
    func testATrimThatWouldLeaveNothingToPlayGivesUpItsTimesAndIsReported() throws {
        let outcome = RallyEditCarryOver.carry(
            RallyEdits(trims: [0: RallyTrimAdjustment(before: -9, after: 0, rotation: 90, zoom: 1.5)],
                       selections: RallyReviewSelections(favorited: [0]), scoring: nil),
            from: [segment(10, 20)], to: [segment(10, 15)])
        let trim = try XCTUnwrap(outcome.edits.trims[0])
        XCTAssertEqual(trim.before, 0)
        XCTAssertEqual(trim.after, 0)
        XCTAssertEqual(trim.rotation, 90)
        XCTAssertEqual(trim.zoom, 1.5)
        XCTAssertEqual(outcome.trimTimesDropped, [0])
        XCTAssertEqual(outcome.leftBehind, [])
        XCTAssertEqual(outcome.edits.selections.favorited, [0])
    }

    /// Both edges trimmed and both kept at their times: start 12, end 14,
    /// inside the new rally — and a start exactly at the end is nothing to play.
    func testBothTrimmedEdgesKeepTheirTimesUnlessTheyMeet() throws {
        let kept = RallyEditCarryOver.carry(
            RallyEdits(trims: [0: RallyTrimAdjustment(before: -2, after: -6)], selections: RallyReviewSelections(), scoring: nil),
            from: [segment(10, 20)], to: [segment(11, 17)])
        XCTAssertEqual(try XCTUnwrap(kept.edits.trims[0]).before, -1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(kept.edits.trims[0]).after, -3, accuracy: 1e-9)
        XCTAssertEqual(kept.trimTimesDropped, [])

        let met = RallyEditCarryOver.carry(
            RallyEdits(trims: [0: RallyTrimAdjustment(before: -5, after: 0)], selections: RallyReviewSelections(), scoring: nil),
            from: [segment(10, 20)], to: [segment(10, 15)])
        XCTAssertEqual(met.trimTimesDropped, [0])
    }

    func testASetStartGoesToTheFirstRallyNotBeforeItThoughItsOwnRallyIsGone() {
        let old = [segment(10, 20), segment(30, 42), segment(50, 55), segment(60, 70)]
        // The rally that started the second set (30–42) is gone.
        let new = [segment(10, 20), segment(50, 55), segment(60, 70)]
        let outcome = RallyEditCarryOver.carry(
            RallyEdits(trims: [:], selections: RallyReviewSelections(),
                       scoring: GameScoring(pointWinners: [:], setBreaks: [1])),
            from: old, to: new)
        XCTAssertEqual(outcome.edits.scoring?.setBreaks, [1])
        XCTAssertEqual(outcome.leftBehind, [], "a set start is not an edit of a rally")
    }

    func testASetStartWithNothingBeforeItOrNothingAfterItIsDropped() {
        let scoring = GameScoring(pointWinners: [:], setBreaks: [1, 2, 9])
        let old = [segment(10, 20), segment(30, 42), segment(50, 55)]
        // Nothing before 30 any more: the rally at 30 is first, which starts a set anyway.
        XCTAssertEqual(RallyEditCarryOver.carry(RallyEdits(trims: [:], selections: RallyReviewSelections(), scoring: scoring),
                                                from: old, to: [segment(30, 42), segment(50, 55)]).edits.scoring?.setBreaks, [1])
        // Nothing from 50 on: that set has no rally. Position 9 never existed.
        XCTAssertEqual(RallyEditCarryOver.carry(RallyEdits(trims: [:], selections: RallyReviewSelections(), scoring: scoring),
                                                from: old, to: [segment(10, 20), segment(30, 42)]).edits.scoring?.setBreaks, [1])
    }

    // MARK: - On disk

    func testInstallingPutsTheNewRalliesAndTheMovedEditsInPlace() throws {
        let old = [segment(10, 20), segment(30, 42), segment(50, 55)]
        try metadataStore.saveMetadata(metadata(old))
        try metadataStore.saveTrimAdjustments([2: RallyTrimAdjustment(before: 0.5, after: 0)], for: videoId)
        try metadataStore.saveReviewSelections(RallyReviewSelections(removed: [1], favorited: [2]), for: videoId)
        try metadataStore.saveGameScoring(GameScoring(pointWinners: [0: .teamA, 2: .teamB], setBreaks: [2]), for: videoId)

        let new = [segment(10, 20.5), segment(50, 55)]
        let outcome = try RallyEditCarryOver.install(metadata(new), metadataStore: metadataStore, mediaStore: nil)

        XCTAssertEqual(outcome.leftBehind, [1])
        XCTAssertEqual(outcome.trimTimesDropped, [])
        XCTAssertEqual(try metadataStore.loadMetadata(for: videoId).rallySegments.map(\.id), new.map(\.id))
        XCTAssertEqual(metadataStore.loadTrimAdjustments(for: videoId)[1]?.before, 0.5)
        XCTAssertEqual(Set(metadataStore.loadTrimAdjustments(for: videoId).keys), [1])
        XCTAssertEqual(metadataStore.loadReviewSelections(for: videoId).favorited, [1])
        XCTAssertEqual(metadataStore.loadReviewSelections(for: videoId).removed, [])
        XCTAssertEqual(metadataStore.loadGameScoring(for: videoId)?.pointWinners, [0: .teamA, 1: .teamB])
        XCTAssertEqual(metadataStore.loadGameScoring(for: videoId)?.setBreaks, [1])
        let names = try FileManager.default.contentsOfDirectory(atPath: metadataStore.metadataDirectory.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".staged") || $0.hasSuffix(".txn") })
    }

    func testInstallingWithNoGameLeavesNoGame() throws {
        try metadataStore.saveMetadata(metadata([segment(10, 20)]))
        XCTAssertEqual(try RallyEditCarryOver.install(metadata([segment(10, 21)]), metadataStore: metadataStore, mediaStore: nil).leftBehind, [])
        XCTAssertNil(metadataStore.loadGameScoring(for: videoId))
        XCTAssertTrue(metadataStore.loadTrimAdjustments(for: videoId).isEmpty)
    }

    func testInstallingOverAVideoWithNoSavedRalliesThrowsAndWritesNothing() throws {
        XCTAssertThrowsError(try RallyEditCarryOver.install(metadata([segment(10, 20)]), metadataStore: metadataStore, mediaStore: nil))
        XCTAssertFalse(metadataStore.metadataExists(for: videoId))
    }

    // MARK: - Fixtures

    private func segment(_ start: Double, _ end: Double) -> RallySegment {
        RallySegment(
            startTime: CMTime(seconds: start, preferredTimescale: 600),
            endTime: CMTime(seconds: end, preferredTimescale: 600),
            confidence: 0.9, quality: 0.9, detectionCount: 10, averageTrajectoryLength: 5.0
        )
    }

    private func metadata(_ segments: [RallySegment]) -> ProcessingMetadata {
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
