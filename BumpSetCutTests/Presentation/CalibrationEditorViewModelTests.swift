//
//  CalibrationEditorViewModelTests.swift
//  BumpSetCutTests
//
//  The Court & Net editor against a real video file and a real store, with no model and
//  no proposal anywhere: place, save, confirm, reopen, edit, split at a camera change,
//  and a calibration on file for another video.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class CalibrationEditorViewModelTests: XCTestCase {
    private var dir: URL!
    private var video: URL!
    private var store: CourtNetCalibrationStore!
    private let videoId = UUID()

    private let courtTaps: [(Double, Double)] = [(0.10, 0.10), (0.90, 0.10), (0.25, 0.45), (0.75, 0.45), (0.33, 0.62), (0.67, 0.62)]
    private let netTaps: [(Double, Double)] = [(0.24, 0.60), (0.76, 0.61), (0.76, 0.50), (0.24, 0.49)]

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CalibrationEditorViewModelTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        video = try TestVideoFactory.writeVideo(to: dir.appendingPathComponent("clip.mp4"), duration: 4, size: CGSize(width: 320, height: 180))
        store = CourtNetCalibrationStore(directory: dir.appendingPathComponent("sidecars"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func open() async -> CalibrationEditorViewModel {
        let model = CalibrationEditorViewModel(videoId: videoId, url: video, store: store, reviewer: "tester")
        await model.load()
        return model
    }

    private func place(_ taps: [(Double, Double)], in model: CalibrationEditorViewModel) {
        for (x, y) in taps { model.tap(x: x, y: y, on: nil) }
    }

    private func onFile() throws -> CourtNetCalibrationFile { try XCTUnwrap(try store.load(videoId.uuidString)) }

    func testAVideoWithNothingOnFileOpensEmptyAndBoundToTheFile() async throws {
        let model = await open()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.status, .notCalibrated)
        XCTAssertFalse(model.shapes.hasCourtPoints)
        XCTAssertEqual(model.video?.binding.frameWidth, 320)
        XCTAssertEqual(model.video?.binding.frameHeight, 180)
        XCTAssertEqual(model.video?.binding.sourceFingerprint, FileFingerprint.read(atPath: video.path))
        XCTAssertEqual(model.durationSec, 4, accuracy: 0.1)
        XCTAssertNil(try store.load(videoId.uuidString), "opening writes nothing")
    }

    func testCourtAndNetArePlacedSavedAndConfirmedByHandAndReopen() async throws {
        let model = await open()
        place(courtTaps, in: model)
        XCTAssertEqual(model.selected, .court(.farRight))
        XCTAssertEqual(model.partState(.court), .placing)
        XCTAssertTrue(model.hasUnsavedChanges)

        model.saveDraft()
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(try onFile().segments[0].court.draft, CalibrationFixtures.court)
        XCTAssertEqual(model.status, .draft)

        model.confirm()
        XCTAssertEqual(model.status, .courtConfirmed)
        XCTAssertEqual(model.partState(.court), .confirmed)
        let court = try XCTUnwrap(try onFile().segments[0].court.confirmation)
        XCTAssertEqual(court.geometry, CalibrationFixtures.court)
        XCTAssertEqual(court.startedFrom, CourtNetCalibrationV1.manual)
        XCTAssertNil(court.baseline)
        XCTAssertEqual(court.confirmedBy, "tester")
        XCTAssertTrue(court.tool.hasPrefix("bumpsetcut_ios"))

        model.target = .net
        place(netTaps, in: model)
        model.confirm()
        XCTAssertEqual(model.status, .bothConfirmed)
        XCTAssertEqual(try onFile().segments[0].net.confirmation?.geometry, CalibrationFixtures.net)

        let reopened = await open()
        XCTAssertEqual(reopened.status, .bothConfirmed)
        XCTAssertEqual(reopened.shapes.court, CalibrationFixtures.court)
        XCTAssertEqual(reopened.shapes.netQuad, CalibrationFixtures.net)
        XCTAssertEqual(reopened.partState(.net), .confirmed)
        XCTAssertFalse(reopened.hasUnsavedChanges)
    }

    func testEditingAConfirmationLeavesItInForceUntilConfirmedAgain() async throws {
        let model = await open()
        place(courtTaps, in: model)
        model.confirm()
        let start = model.shapes
        model.drag(.handle(.court(.farRight)), from: start, dx: 0.03, dy: 0.01)
        XCTAssertEqual(model.partState(.court), .editedSinceConfirmed)
        model.saveDraft()
        XCTAssertEqual(try onFile().confirmed(\.court, at: 1)?.geometry, CalibrationFixtures.court)
        XCTAssertEqual(model.status, .courtConfirmed)

        model.confirm()
        let segment = try onFile().segments[0]
        XCTAssertEqual(segment.court.confirmation?.geometry.farRight.x ?? 0, 0.70, accuracy: 1e-9)
        XCTAssertEqual(segment.court.confirmation?.startedFrom, CourtNetCalibrationV1.confirmation)
        XCTAssertEqual(segment.court.confirmation?.adjustedPoints, ["farRight"])
        XCTAssertEqual(segment.court.history.map(\.geometry), [CalibrationFixtures.court])
        XCTAssertEqual(model.partState(.court), .confirmed)

        // Confirming again with nothing changed adds nothing.
        model.confirm()
        XCTAssertEqual(try onFile().segments[0].court.history.count, 1)
    }

    func testAnUnusableCourtIsNotConfirmedAndSaysWhy() async throws {
        let model = await open()
        place([(0.5, 0.5), (0.5, 0.5), (0.5, 0.5)], in: model)
        model.confirm()
        XCTAssertEqual(model.status, .draft)
        XCTAssertNil(try onFile().segments[0].court.confirmation)
        XCTAssertNotNil(model.notice)
    }

    func testANetWithFewerThanFourCornersIsKeptInTheEditorNotOnFile() async throws {
        let model = await open()
        model.target = .net
        place(Array(netTaps.prefix(3)), in: model)
        model.confirm()
        XCTAssertNil(try store.load(videoId.uuidString))
        model.saveDraft()
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertNil(try onFile().segments[0].net.draft)
        XCTAssertEqual(model.shapes.net.compactMap { $0 }.count, 3)
        place([netTaps[3]], in: model)
        model.saveDraft()
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(try onFile().segments[0].net.draft, CalibrationFixtures.net)
    }

    func testTappingAPointSelectsItAndASelectedUnplacedPointIsPlacedNext() async {
        let model = await open()
        place(Array(courtTaps.prefix(2)), in: model)
        model.tap(x: 0, y: 0, on: .court(.nearLeft))
        XCTAssertEqual(model.selected, .court(.nearLeft))
        XCTAssertEqual(model.shapes.court.nearLeft.x, 0.10)
        model.selected = .court(.farRight)
        model.tap(x: 0.67, y: 0.62, on: nil)
        XCTAssertEqual(model.shapes.court.farRight.x, 0.67)
        XCTAssertEqual(model.shapes.court.netLeft.status, .unknown)
        model.removeSelected()
        XCTAssertEqual(model.shapes.court.farRight.status, .unknown)
        model.target = .net
        XCTAssertNil(model.selected)
    }

    func testStartingOverClearsTheDraftAndKeepsTheConfirmation() async throws {
        let model = await open()
        place(courtTaps, in: model)
        model.confirm()
        model.drag(.shape, from: model.shapes, dx: 0.01, dy: 0)
        model.saveDraft()
        XCTAssertNotNil(try onFile().segments[0].court.draft)
        model.startOver()
        XCTAssertFalse(model.shapes.hasCourtPoints)
        let segment = try onFile().segments[0]
        XCTAssertNil(segment.court.draft)
        XCTAssertEqual(segment.court.confirmation?.geometry, CalibrationFixtures.court)
        model.confirm()
        XCTAssertEqual(try onFile().segments[0].court.history.count, 0, "nothing placed, nothing confirmed")
    }

    func testACameraChangeSplitsHereAndTheNewViewStartsAsADraft() async throws {
        let model = await open()
        place(courtTaps, in: model)
        model.confirm()
        model.seek(to: 2)
        model.cameraChangedHere(reuse: true)
        let file = try onFile()
        XCTAssertEqual(file.segments.count, 2)
        XCTAssertEqual(file.segments[1].validFromSec, 2, accuracy: 1e-6)
        XCTAssertEqual(model.segmentNumber, 2)
        XCTAssertEqual(model.shapes.court, CalibrationFixtures.court)
        XCTAssertEqual(model.partState(.court), .placing)
        XCTAssertEqual(model.status, .needsReview)
        XCTAssertNil(file.confirmed(\.court, at: 3))
        XCTAssertNotNil(file.confirmed(\.court, at: 1))

        model.confirm()
        XCTAssertEqual(try onFile().segments[1].court.confirmation?.startedFrom, "segment 0")
        XCTAssertEqual(model.status, .courtConfirmed)

        model.seek(to: 0.5)
        XCTAssertEqual(model.segmentNumber, 1)
        model.seek(to: 0.01)
        model.cameraChangedHere(reuse: false)
        XCTAssertEqual(try onFile().segments.count, 2, "too close to the start to split")
    }

    func testAViewThatIsNotStableTakesNoMarks() async throws {
        let model = await open()
        place(courtTaps, in: model)
        model.confirm()
        model.setView(.unsuitable)
        XCTAssertFalse(model.isStableView)
        XCTAssertEqual(model.status, .unsuitable)
        XCTAssertNil(try onFile().confirmed(\.court, at: 1))
        XCTAssertEqual(try onFile().segments[0].court.history.count, 1)
        let before = model.shapes
        model.tap(x: 0.2, y: 0.2, on: nil)
        model.drag(.shape, from: before, dx: 0.1, dy: 0.1)
        XCTAssertEqual(model.shapes, before)
        model.setView(.stable)
        XCTAssertTrue(model.isStableView)
    }

    func testMarksOfAViewCalledStableAgainCanBeConfirmedWithoutMovingThem() async throws {
        let model = await open()
        place(courtTaps, in: model)
        model.confirm()
        model.target = .net
        place(netTaps, in: model)
        model.confirm()
        model.setView(.unsuitable)
        XCTAssertNil(try onFile().confirmed(\.court, at: 1))

        model.setView(.stable)
        // What was on screen is the view's draft again — not a confirmation.
        var segment = try onFile().segments[0]
        XCTAssertEqual(segment.court.draft, CalibrationFixtures.court)
        XCTAssertEqual(segment.net.draft, CalibrationFixtures.net)
        XCTAssertNil(segment.court.confirmation)
        XCTAssertEqual(model.status, .draft)
        XCTAssertEqual(model.partState(.net), .placing)

        model.confirm()
        model.target = .court
        model.confirm()
        segment = try onFile().segments[0]
        XCTAssertEqual(model.status, .bothConfirmed)
        XCTAssertEqual(segment.court.confirmation?.geometry, CalibrationFixtures.court)
        XCTAssertEqual(segment.court.confirmation?.startedFrom, CourtNetCalibrationV1.confirmation)
        XCTAssertEqual(segment.court.confirmation?.adjustedPoints, [])
        XCTAssertEqual(segment.net.confirmation?.geometry, CalibrationFixtures.net)
        XCTAssertEqual(segment.court.history.count, 1)
        XCTAssertEqual(segment.net.history.count, 1)
    }

    func testTheCourtTypeIsSavedWithTheCalibration() async throws {
        let model = await open()
        model.setSetup(surface: .beach, format: .twos)
        XCTAssertEqual(try onFile().setup?.spec, .beach)
        XCTAssertEqual(model.setup.format, .twos)
    }

    func testMarksSavedForAnotherVersionOfTheVideoAreNotUsed() async throws {
        let first = await open()
        place(courtTaps, in: first)
        first.confirm()
        // The video under this id is replaced by another file.
        try TestVideoFactory.writeVideo(to: video, duration: 4, size: CGSize(width: 320, height: 180), fps: 24)

        let model = await open()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.staleReason, "the video file changed")
        XCTAssertEqual(model.status, .needsReview)
        XCTAssertFalse(model.shapes.hasCourtPoints)

        model.startFromStaleFile()
        XCTAssertEqual(model.shapes.court, CalibrationFixtures.court)
        XCTAssertEqual(model.partState(.court), .placing)
        model.confirm()
        XCTAssertNil(model.staleReason)
        XCTAssertEqual(model.status, .courtConfirmed)
        XCTAssertEqual(try onFile().segments[0].court.confirmation?.startedFrom, "earlier calibration")
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(names.filter { $0.contains("_calibration.superseded-") }.count, 1)
    }

    func testAnUnreadableCalibrationStopsTheEditor() async throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: store.url(videoId.uuidString))
        let model = await open()
        guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
        model.tap(x: 0.5, y: 0.5, on: nil)
        model.saveDraft()
        XCTAssertEqual(try Data(contentsOf: store.url(videoId.uuidString)), Data("nope".utf8))
    }

    func testAFileThatIsNotAVideoStopsTheEditor() async throws {
        let notVideo = dir.appendingPathComponent("notes.mp4")
        try Data("not a video".utf8).write(to: notVideo)
        let model = CalibrationEditorViewModel(videoId: videoId, url: notVideo, store: store, reviewer: "tester")
        await model.load()
        guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
    }

    func testTheStatusLineReadsTheSameFile() async throws {
        let none = await store.status(videoId: videoId, url: video)
        XCTAssertEqual(none, .notCalibrated)
        let model = await open()
        place(courtTaps, in: model)
        model.confirm()
        let confirmed = await store.status(videoId: videoId, url: video)
        XCTAssertEqual(confirmed, .courtConfirmed)
        try TestVideoFactory.writeVideo(to: video, duration: 4, size: CGSize(width: 320, height: 180), fps: 24)
        let stale = await store.status(videoId: videoId, url: video)
        XCTAssertEqual(stale, .needsReview)
    }
}
