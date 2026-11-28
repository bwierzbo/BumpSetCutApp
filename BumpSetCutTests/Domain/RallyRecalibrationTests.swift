//
//  RallyRecalibrationTests.swift
//  BumpSetCutTests
//
//  Recalibrate (D-044): a processed video's rallies are decided again from its saved balls under the camera
//  position and net it has now. The old rallies' edits start over; favourite clips stay as files of their own;
//  and when there is no answer (no saved balls, no rallies) nothing at all changes.
//

import AVFoundation
import XCTest
@testable import BumpSetCut

@MainActor
final class RallyRecalibrationTests: XCTestCase {
    private var dir: URL!
    private var store: MediaStore!
    private var video: VideoMetadata!
    private var metadataStore: MetadataStore { store.metadataStore }

    private let netOverTheBall = NetGeometry.confirmed(DetectedNet(box: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.08), confidence: 1))
    private let netFarAside = NetGeometry.confirmed(DetectedNet(box: CGRect(x: 0.85, y: 0.4, width: 0.1, height: 0.08), confidence: 1))

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RallyRecalibrationTests_\(UUID().uuidString)", isDirectory: true)
        let saved = dir.appendingPathComponent(LibraryType.saved.rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        StorageManager.storageDirectoryOverride = dir
        store = MediaStore(baseDirectory: dir)
        let file = try TestVideoFactory.writeVideo(to: saved.appendingPathComponent("game.mp4"), duration: 14, size: CGSize(width: 160, height: 90))
        XCTAssertTrue(store.addVideo(at: file, toFolder: LibraryType.saved.rootPath))
        video = try XCTUnwrap(store.getAllVideos().first { $0.fileName == "game.mp4" })
    }

    override func tearDown() async throws {
        StorageManager.storageDirectoryOverride = nil
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    /// The video as a run with no net left it: one rally, its saved balls, and optionally everything a person
    /// can do to a rally, with a favourite clip copied from it into the library.
    @discardableResult
    private func processed(config: ProcessorConfig = ProcessorConfig(), edited: Bool = false) async throws -> ProcessingMetadata {
        let log = BallDetectionLog.writtenArcs(of: video.originalURL)
        XCTAssertTrue(log.write(to: metadataStore.ballDetectionsFileURL(for: video.id)))
        let processor = VideoProcessor()
        processor.config = config
        processor.netSource = FixedNetSource(.unavailable(reason: "none marked"))
        let metadata = try await processor.decideRalliesAgain(from: log, forVideoAt: video.originalURL, videoId: video.id)
        store.markVideoAsProcessed(videoId: video.id, metadataFileSize: 1)
        guard edited else { return metadata }

        try metadataStore.saveTrimAdjustments([0: RallyTrimAdjustment(before: 1, after: -0.5, rotation: 90)], for: video.id)
        try metadataStore.saveReviewSelections(RallyReviewSelections(saved: [0], favorited: [0], favoriteCollections: [0: "Best"], posted: [0]), for: video.id)
        try metadataStore.saveGameScoring(GameScoring(pointWinners: [0: .teamA]), for: video.id)
        let favorites = dir.appendingPathComponent(LibraryType.favorites.rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: favorites, withIntermediateDirectories: true)
        let clip = try TestVideoFactory.writeVideo(to: favorites.appendingPathComponent("clip.mp4"), duration: 1)
        XCTAssertTrue(store.addVideo(at: clip, toFolder: LibraryType.favorites.rootPath, sourceVideoId: video.id, sourceRallyIndex: 0))
        return metadata
    }

    private var favoriteClip: VideoMetadata? { store.getAllVideos(in: .favorites).first { $0.sourceVideoId == video.id } }

    private func spans(_ metadata: ProcessingMetadata) -> [String] {
        metadata.rallySegments.map { String(format: "%.3f…%.3f", $0.startTime, $0.endTime) }
    }

    private func recalibrate(net: NetGeometry) async throws -> ProcessingMetadata {
        try await RallyRecalibration.run(videoId: video.id, videoURL: video.originalURL, mediaStore: store, netSource: FixedNetSource(net))
    }

    // MARK: - The answer

    func testTheRalliesAreDecidedAgainUnderTheNetAndSavedInPlaceOfTheOldOnes() async throws {
        let before = try await processed()
        XCTAssertEqual(before.spatialChecks?.underNetRejection, .noNetGeometry)
        XCTAssertTrue(RallyRecalibration.isAvailable(for: video.id, in: metadataStore))
        let balls = try Data(contentsOf: metadataStore.ballDetectionsFileURL(for: video.id))

        let after = try await recalibrate(net: netOverTheBall)

        XCTAssertEqual(after.spatialChecks?.underNetRejection, .ran)
        XCTAssertFalse(after.rallySegments.isEmpty)
        let saved = try metadataStore.loadMetadata(for: video.id)
        XCTAssertEqual(saved.rallySegments.map(\.id), after.rallySegments.map(\.id))
        XCTAssertEqual(saved.spatialChecks?.underNetRejection, .ran)
        XCTAssertEqual(try Data(contentsOf: metadataStore.ballDetectionsFileURL(for: video.id)), balls, "the saved balls stay, for the next time")
        XCTAssertEqual(store.getAllVideos().first { $0.id == video.id }?.hasMetadata, true)
    }

    func testTheCameraPositionTheVideoHasNowIsTheOneDecidedUnder() async throws {
        try await processed()
        let corner = CameraSetup(position: CameraZone.corner.presetPosition, height: .raised)
        store.setCameraSetup(corner, forVideoId: video.id)

        let after = try await recalibrate(net: netOverTheBall)

        XCTAssertEqual(after.cameraSetup, corner)
        XCTAssertEqual(try metadataStore.loadMetadata(for: video.id).cameraSetup, corner)
    }

    func testAPersonsOwnRallyIsKept() async throws {
        let before = try await processed()
        let own = RallySegment(id: UUID(), startTimeSeconds: 11, endTimeSeconds: 12.5, confidence: 1, quality: 1, detectionCount: 0,
                               averageTrajectoryLength: 0, ballSizeTrend: nil, serveBallX: nil, isManual: true)
        try metadataStore.saveMetadata(before.withRallySegments(before.rallySegments + [own]))

        let after = try await recalibrate(net: netOverTheBall)

        XCTAssertTrue(after.rallySegments.contains { $0.id == own.id }, "\(spans(after))")
        XCTAssertGreaterThan(after.rallySegments.count, 1)
    }

    func testAVideoRetriedWithHigherSensitivityIsDecidedAgainWithIt() async throws {
        let sensitive = ProcessorConfig.highSensitivity
        let before = try await processed(config: sensitive)
        XCTAssertEqual(RallyRecalibration.settings(of: before).detectionConfidence, sensitive.detectionConfidence)
        XCTAssertEqual(RallyRecalibration.settings(of: before).minSegmentLength, sensitive.minSegmentLength)

        let after = try await recalibrate(net: netOverTheBall)
        XCTAssertEqual(after.processingConfig.parabolaMinR2, sensitive.parabolaMinR2)
        XCTAssertEqual(after.processingConfig.minSegmentLength, sensitive.minSegmentLength)
    }

    func testAnOrdinaryRunIsDecidedAgainWithTheOrdinarySettings() async throws {
        let before = try await processed()
        XCTAssertEqual(RallyRecalibration.settings(of: before).detectionConfidence, ProcessorConfig().detectionConfidence)
        XCTAssertEqual(RallyRecalibration.settings(of: before).parabolaMinR2, ProcessorConfig().parabolaMinR2)
    }

    // MARK: - The edits

    func testTheOldRalliesEditsStartOverAndTheFavoriteClipStaysAsItsOwnFile() async throws {
        try await processed(edited: true)
        let clipFile = try XCTUnwrap(favoriteClip).originalURL

        _ = try await recalibrate(net: netOverTheBall)

        XCTAssertTrue(metadataStore.loadTrimAdjustments(for: video.id).isEmpty)
        XCTAssertTrue(metadataStore.loadReviewSelections(for: video.id).isEmpty)
        XCTAssertTrue(metadataStore.loadReviewSelections(for: video.id).posted.isEmpty)
        XCTAssertNil(metadataStore.loadGameScoring(for: video.id))
        let clip = try XCTUnwrap(favoriteClip, "the clip is still in the library, still known to be from this video")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipFile.path))
        XCTAssertNil(clip.sourceRallyIndex, "it no longer says which rally: that place in the list is another rally's now")
    }

    // MARK: - No answer, nothing changed

    private func assertNothingChanged(since before: ProcessingMetadata, _ why: String) throws {
        XCTAssertEqual(try metadataStore.loadMetadata(for: video.id).rallySegments.map(\.id), before.rallySegments.map(\.id), why)
        XCTAssertEqual(metadataStore.loadTrimAdjustments(for: video.id)[0]?.rotation, 90, why)
        XCTAssertEqual(metadataStore.loadReviewSelections(for: video.id).favorited, [0], why)
        XCTAssertEqual(metadataStore.loadReviewSelections(for: video.id).favoriteCollections, [0: "Best"], why)
        XCTAssertEqual(metadataStore.loadGameScoring(for: video.id)?.pointWinners, [0: .teamA], why)
        XCTAssertEqual(favoriteClip?.sourceRallyIndex, 0, why)
    }

    func testANetThatLeavesNoRalliesChangesNothing() async throws {
        let before = try await processed(edited: true)
        do {
            _ = try await recalibrate(net: netFarAside)
            XCTFail("balls off the court made a rally")
        } catch ProcessingError.noRalliesDetected {}
        try assertNothingChanged(since: before, "no rallies")
    }

    func testAVideoWithNoSavedBallsIsRefusedAndNothingChanges() async throws {
        let before = try await processed(edited: true)
        try FileManager.default.removeItem(at: metadataStore.ballDetectionsFileURL(for: video.id))
        XCTAssertFalse(RallyRecalibration.isAvailable(for: video.id, in: metadataStore))
        do {
            _ = try await recalibrate(net: netOverTheBall)
            XCTFail("decided with no saved balls")
        } catch RallyRecalibration.Failure.noSavedBalls {}
        try assertNothingChanged(since: before, "no saved balls")
    }

    func testSavedBallsOfAnotherFileAreRefusedAndNothingChanges() async throws {
        let before = try await processed(edited: true)
        let other = try TestVideoFactory.writeVideo(to: dir.appendingPathComponent("other.mp4"), duration: 13, size: CGSize(width: 160, height: 90))
        XCTAssertTrue(BallDetectionLog.writtenArcs(of: other).write(to: metadataStore.ballDetectionsFileURL(for: video.id)))
        do {
            _ = try await recalibrate(net: netOverTheBall)
            XCTFail("decided from another file's balls")
        } catch ProcessingError.savedDetectionsNotOfThisVideo {}
        try assertNothingChanged(since: before, "another file's balls")
    }

    // MARK: - After Free Up Space

    /// Free Up Space leaves the metadata with the shorter file's duration and takes the saved balls with the
    /// footage. Such a video is neither reprocessed nor recalibrated, and nothing of it is dropped by the try.
    func testAVideoCutToItsRalliesIsNeitherReprocessedNorRecalibrated() async throws {
        let before = try await processed(edited: true)
        XCTAssertFalse(store.isCutToRallies(videoId: video.id))
        try metadataStore.stageMetadata(before.withRallySegments(before.rallySegments, sourceDurationSec: 9), evidence: nil)
        try metadataStore.commitStagedSidecars(for: video.id)
        XCTAssertTrue(store.isCutToRallies(videoId: video.id))

        XCTAssertThrowsError(try store.prepareForReprocess(videoId: video.id)) { error in
            guard case MediaStore.ReprocessRefusal.cutToRallies = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("Free Up Space"))
        }
        try assertNothingChanged(since: before, "a refused reprocess")

        XCTAssertFalse(RallyRecalibration.isAvailable(for: video.id, in: metadataStore))
        do {
            _ = try await recalibrate(net: netOverTheBall)
            XCTFail("recalibrated a video cut to its rallies")
        } catch RallyRecalibration.Failure.noSavedBalls {}
        try assertNothingChanged(since: before, "a refused recalibration")
    }

    func testATimelineEditKeepsAVideoKnownAsCutToItsRallies() async throws {
        let before = try await processed()
        try metadataStore.saveMetadata(before.withRallySegments(before.rallySegments, sourceDurationSec: 9))
        let cut = try metadataStore.loadMetadata(for: video.id)
        try metadataStore.saveMetadata(cut.withRallySegments(Array(cut.rallySegments.prefix(1))))
        XCTAssertTrue(store.isCutToRallies(videoId: video.id))
    }

    // MARK: - A reprocess

    func testAReprocessAlsoLeavesTheFavoriteClipWithoutAPlaceInTheList() async throws {
        try await processed(edited: true)
        try store.prepareForReprocess(videoId: video.id)
        XCTAssertNotNil(favoriteClip)
        XCTAssertNil(favoriteClip?.sourceRallyIndex)
        XCTAssertTrue(metadataStore.loadReviewSelections(for: video.id).isEmpty)
        XCTAssertFalse(RallyRecalibration.isAvailable(for: video.id, in: metadataStore), "a reprocess finds the balls afresh")
    }
}
