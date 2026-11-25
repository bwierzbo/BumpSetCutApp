//
//  CourtNetCalibrationTests.swift
//  BumpSetCutTests
//
//  court_net_calibration_v1: only a person's Confirm makes a geometry confirmed; a
//  proposal never does and never replaces one; court and net stand apart; a camera change
//  splits the recording; a file made for another video or frame is stale.
//

import XCTest
@testable import BumpSetCut

final class CourtNetCalibrationTests: XCTestCase {
    private typealias F = CalibrationFixtures
    private let manual = CourtNetCalibrationV1.manual

    private func file() -> CourtNetCalibrationFile { .new(for: F.binding) }

    private func confirmed(court: Bool = true, net: Bool = true) throws -> CourtNetCalibrationFile {
        var f = file()
        if court {
            try f.saveDraft(F.court, of: \.court, segment: 0, startedFrom: manual, baseline: nil)
            try f.confirm(\.court, segment: 0, by: "ben", tool: "test", now: F.day)
        }
        if net {
            try f.saveDraft(F.net, of: \.net, segment: 0, startedFrom: manual, baseline: nil)
            try f.confirm(\.net, segment: 0, by: "ben", tool: "test", now: F.day)
        }
        return f
    }

    private func proposal(_ kind: CalibrationProposal<CourtLayout>.Kind, _ method: String, _ geometry: CourtLayout) -> CalibrationProposal<CourtLayout> {
        CalibrationProposal(method: method, kind: kind, geometry: geometry, confidence: 0.5, uncertainty: [], createdAt: F.day)
    }

    // MARK: A new file

    func testANewFileIsOneStableSegmentWithNothingPlaced() {
        let f = file()
        XCTAssertEqual(f.problems, [])
        XCTAssertEqual(f.segments.count, 1)
        XCTAssertEqual(f.segments[0].validToSec, 120)
        XCTAssertEqual(f.status(for: F.binding), .notCalibrated)
        XCTAssertNil(f.confirmed(\.court, at: 10))
        XCTAssertNil(f.confirmed(\.net, at: 10))
        XCTAssertNil(f.segments[0].court.startingPoint.geometry)
        XCTAssertEqual(f.segments[0].court.startingPoint.startedFrom, manual)
    }

    // MARK: Draft and confirm, with no proposal anywhere

    func testADraftIsNotAConfirmation() throws {
        var f = file()
        try f.saveDraft(F.court, of: \.court, segment: 0, startedFrom: manual, baseline: nil)
        XCTAssertEqual(f.status(for: F.binding), .draft)
        XCTAssertNil(f.confirmed(\.court, at: 10))
    }

    func testAnUnusableDraftIsSavedButCannotBeConfirmed() throws {
        var f = file()
        var half = F.court
        half.nearLeft = half.nearRight
        half.farLeft = F.point(0, 0, .unknown)
        try f.saveDraft(half, of: \.court, segment: 0, startedFrom: manual, baseline: nil)
        let before = f
        XCTAssertThrowsError(try f.confirm(\.court, segment: 0, by: "ben", tool: "test", now: F.day)) {
            guard case CourtNetCalibrationError.unusableGeometry = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(f, before)
    }

    func testConfirmingWithNothingPlacedIsRefused() {
        var f = file()
        XCTAssertThrowsError(try f.confirm(\.net, segment: 0, by: "ben", tool: "test", now: F.day)) {
            XCTAssertEqual($0 as? CourtNetCalibrationError, .nothingToConfirm)
        }
    }

    func testCourtAndNetAreConfirmedApart() throws {
        let courtOnly = try confirmed(net: false)
        XCTAssertEqual(courtOnly.status(for: F.binding), .courtConfirmed)
        XCTAssertNotNil(courtOnly.confirmed(\.court, at: 10))
        XCTAssertNil(courtOnly.confirmed(\.net, at: 10))
        XCTAssertEqual(try confirmed(court: false).status(for: F.binding), .netConfirmed)
        let both = try confirmed()
        XCTAssertEqual(both.status(for: F.binding), .bothConfirmed)
        XCTAssertEqual(both.confirmed(\.net, at: 119.9)?.geometry, F.net)
        XCTAssertNil(both.confirmed(\.net, at: 120))
        XCTAssertEqual(both.problems, [])
    }

    func testAManualConfirmationSaysSo() throws {
        let c = try XCTUnwrap(try confirmed().segments[0].court.confirmation)
        XCTAssertEqual(c.startedFrom, manual)
        XCTAssertNil(c.baseline)
        XCTAssertEqual(c.adjustedPoints, CourtLayout.pointNames)
        XCTAssertEqual(c.confirmedBy, "ben")
        XCTAssertEqual(c.tool, "test")
        XCTAssertEqual(c.confirmedAt, F.day)
        XCTAssertNil(try confirmed().segments[0].court.draft)
    }

    func testConfirmationTimesAreWholeSeconds() throws {
        var f = file()
        try f.saveDraft(F.net, of: \.net, segment: 0, startedFrom: manual, baseline: nil)
        try f.confirm(\.net, segment: 0, by: "ben", tool: "test", now: F.day.addingTimeInterval(0.75))
        XCTAssertEqual(f.segments[0].net.confirmation?.confirmedAt, F.day)
    }

    // MARK: Proposals

    func testAProposalIsNeverAConfirmationAndNeverReplacesOne() throws {
        var f = try confirmed()
        let before = f.segments[0].court.confirmation
        var other = F.court
        other.netLeft = F.point(0.30, 0.45)
        try f.add(proposal(.detection, "court_lines_v1", other), to: \.court, segment: 0)
        XCTAssertEqual(f.segments[0].court.confirmation, before)
        XCTAssertNil(f.segments[0].court.draft)
        XCTAssertEqual(f.confirmed(\.court, at: 5)?.geometry, F.court)
        // The editor still opens on the person's confirmation, not the newer proposal.
        XCTAssertEqual(f.segments[0].court.startingPoint.startedFrom, CourtNetCalibrationV1.confirmation)

        var fresh = file()
        try fresh.add(proposal(.detection, "court_lines_v1", other), to: \.court, segment: 0)
        XCTAssertEqual(fresh.status(for: F.binding), .notCalibrated)
        XCTAssertNil(fresh.confirmed(\.court, at: 5))
    }

    func testTheEditorOpensOnADetectionBeforeAnEstimate() throws {
        var estimate = F.court
        estimate.farLeft = F.point(0.35, 0.62, .estimated)
        var f = file()
        try f.add(proposal(.detection, "court_lines_v1", F.court), to: \.court, segment: 0)
        try f.add(proposal(.estimate, "net_guided_v1", estimate), to: \.court, segment: 0)
        XCTAssertEqual(f.segments[0].court.startingPoint.startedFrom, "court_lines_v1")
        var onlyEstimate = file()
        try onlyEstimate.add(proposal(.estimate, "net_guided_v1", estimate), to: \.court, segment: 0)
        XCTAssertEqual(onlyEstimate.segments[0].court.startingPoint.geometry, estimate)
    }

    func testAConfirmationFromAProposalKeepsWhatWasProposedAndWhatMoved() throws {
        var f = file()
        try f.add(proposal(.detection, "court_lines_v1", F.court), to: \.court, segment: 0)
        let start = f.segments[0].court.startingPoint
        let adjusted = F.court.moving(.farRight, to: 0.70, 0.63)
        try f.saveDraft(adjusted, of: \.court, segment: 0, startedFrom: start.startedFrom, baseline: start.baseline)
        try f.confirm(\.court, segment: 0, by: "ben", tool: "test", now: F.day)
        let c = try XCTUnwrap(f.segments[0].court.confirmation)
        XCTAssertEqual(c.startedFrom, "court_lines_v1")
        XCTAssertEqual(c.baseline, F.court)
        XCTAssertEqual(c.geometry, adjusted)
        XCTAssertEqual(c.adjustedPoints, ["farRight"])
        XCTAssertEqual(f.segments[0].court.proposals.count, 1)
    }

    // MARK: Editing a confirmation

    func testEditingAConfirmationKeepsItInForceUntilTheNextConfirmThenInHistory() throws {
        var f = try confirmed()
        let first = try XCTUnwrap(f.segments[0].net.confirmation)
        let start = f.segments[0].net.startingPoint
        XCTAssertEqual(start.startedFrom, CourtNetCalibrationV1.confirmation)
        let moved = F.net.moving(corner: 0, to: CGPoint(x: 0.22, y: 0.62))
        try f.saveDraft(moved, of: \.net, segment: 0, startedFrom: start.startedFrom, baseline: start.baseline)
        XCTAssertEqual(f.confirmed(\.net, at: 1)?.geometry, F.net)
        XCTAssertEqual(f.status(for: F.binding), .bothConfirmed)

        try f.confirm(\.net, segment: 0, by: "ben", tool: "test", now: F.day.addingTimeInterval(60))
        XCTAssertEqual(f.confirmed(\.net, at: 1)?.geometry, moved)
        XCTAssertEqual(f.segments[0].net.confirmation?.adjustedPoints, ["topLeft"])
        XCTAssertEqual(f.segments[0].net.history, [first])
    }

    func testDiscardingADraftLeavesTheConfirmation() throws {
        var f = try confirmed()
        try f.saveDraft(F.net.offset(dx: 0.01, dy: 0), of: \.net, segment: 0, startedFrom: CourtNetCalibrationV1.confirmation, baseline: F.net)
        try f.discardDraft(of: \.net, segment: 0)
        XCTAssertNil(f.segments[0].net.draft)
        XCTAssertNil(f.segments[0].net.draftBaseline)
        XCTAssertEqual(f.confirmed(\.net, at: 1)?.geometry, F.net)
    }

    // MARK: The net's shape

    func testANetIsFourFreeCornersNotARectangle() {
        XCTAssertEqual(F.net.problems, [])
        XCTAssertNotEqual(F.net.topLeft.y, F.net.topRight.y)
    }

    func testCrossedTinyAndOutOfFrameNetsAreRefused() {
        let crossed = NetQuad(topLeft: F.net.topRight, topRight: F.net.topLeft, bottomRight: F.net.bottomRight, bottomLeft: F.net.bottomLeft)
        XCTAssertEqual(crossed.problems, ["the net's corners cross, fold or lie on one line"])
        let tiny = NetQuad(rect: CGRect(x: 0.5, y: 0.5, width: 0.006, height: 0.006))
        XCTAssertEqual(tiny.problems, ["the net is too small to use"])
        var outside = F.net
        outside.topRight = .init(x: 1.2, y: 0.61)
        XCTAssertEqual(outside.problems, ["the net's topRight corner is outside the frame"])
    }

    // MARK: Camera changes

    func testACameraChangeSplitsTheSegmentAndReuseIsOnlyADraft() throws {
        var f = try confirmed()
        XCTAssertTrue(f.split(at: 40, reuse: true))
        XCTAssertEqual(f.problems, [])
        XCTAssertEqual(f.segments.map(\.id), [0, 1])
        XCTAssertEqual(f.segments[0].validToSec, 40)
        XCTAssertEqual(f.segments[1].validFromSec, 40)
        XCTAssertEqual(f.segments[1].validToSec, 120)
        XCTAssertEqual(f.confirmed(\.court, at: 39)?.geometry, F.court)
        XCTAssertNil(f.confirmed(\.court, at: 40))
        XCTAssertNil(f.confirmed(\.net, at: 100))
        XCTAssertEqual(f.segments[1].court.draft, F.court)
        XCTAssertEqual(f.segments[1].court.draftStartedFrom, "segment 0")
        XCTAssertEqual(f.segments[1].net.draftBaseline, F.net)
        XCTAssertTrue(f.segments[1].court.history.isEmpty)
        // One view confirmed, the next waiting: a person has to look.
        XCTAssertEqual(f.status(for: F.binding), .needsReview)

        try f.confirm(\.court, segment: 1, by: "ben", tool: "test", now: F.day)
        XCTAssertEqual(f.segments[1].court.confirmation?.startedFrom, "segment 0")
        XCTAssertEqual(f.segments[1].court.confirmation?.adjustedPoints, [])
    }

    func testReuseTakesTheMarksAsTheyStandTheDraftBeforeTheConfirmation() throws {
        var f = try confirmed()
        let edited = F.court.moving(.farRight, to: 0.70, 0.63)
        try f.saveDraft(edited, of: \.court, segment: 0, startedFrom: CourtNetCalibrationV1.confirmation, baseline: F.court)
        XCTAssertTrue(f.split(at: 40, reuse: true))
        // The new view starts from what the person was looking at; the net, untouched, from its confirmation.
        XCTAssertEqual(f.segments[1].court.draft, edited)
        XCTAssertEqual(f.segments[1].court.draftBaseline, edited)
        XCTAssertEqual(f.segments[1].net.draft, F.net)
        // The first view keeps its confirmation in force and its own draft.
        XCTAssertEqual(f.confirmed(\.court, at: 10)?.geometry, F.court)
        XCTAssertEqual(f.segments[0].court.draft, edited)
        XCTAssertNil(f.confirmed(\.court, at: 50))
    }

    func testASplitWithoutReuseStartsEmpty() throws {
        var f = try confirmed()
        XCTAssertTrue(f.split(at: 40, reuse: false))
        XCTAssertEqual(f.segments[1], CalibrationSegment(id: 1, validFromSec: 40, validToSec: 120, view: .stable))
    }

    func testASplitAtASegmentsEdgeDoesNothing() throws {
        var f = try confirmed()
        let before = f
        XCTAssertFalse(f.split(at: 0.01, reuse: true))
        XCTAssertFalse(f.split(at: 119.99, reuse: true))
        XCTAssertFalse(f.split(at: 500, reuse: true))
        XCTAssertEqual(f, before)
    }

    func testAViewThatIsNotStableHoldsNoConfirmation() throws {
        var f = try confirmed()
        XCTAssertTrue(f.split(at: 40, reuse: false))
        try f.setView(.unsuitable, segment: 0, note: "panning", at: F.day)
        XCTAssertNil(f.confirmed(\.court, at: 10))
        XCTAssertNil(f.segments[0].net.confirmation)
        XCTAssertEqual(f.segments[0].court.history.count, 1)
        XCTAssertEqual(f.segments[0].note, "panning")
        XCTAssertEqual(f.problems, [])
        XCTAssertEqual(f.status(for: F.binding), .notCalibrated)

        try f.saveDraft(F.net, of: \.net, segment: 0, startedFrom: manual, baseline: nil)
        XCTAssertThrowsError(try f.confirm(\.net, segment: 0, by: "ben", tool: "test", now: F.day)) {
            XCTAssertEqual($0 as? CourtNetCalibrationError, .notStableView)
        }
        try f.setView(.unknown, segment: 1, note: nil, at: F.day)
        XCTAssertEqual(f.status(for: F.binding), .unsuitable)
        try f.setView(.stable, segment: 0, note: nil, at: F.day)
        XCTAssertNoThrow(try f.confirm(\.net, segment: 0, by: "ben", tool: "test", now: F.day))
    }

    // MARK: Staleness and validation

    func testAFileForAnotherVideoFrameOrLengthIsStale() throws {
        let f = try confirmed()
        XCTAssertNil(f.staleReason(for: F.binding))
        var b = F.binding
        b.sourceFingerprint = "file:def"
        XCTAssertEqual(f.staleReason(for: b), "the video file changed")
        XCTAssertEqual(f.status(for: b), .needsReview)
        b = F.binding; b.recordingId = "other"
        XCTAssertEqual(f.staleReason(for: b), "made for another recording")
        // The same file read as portrait: the upright frame is another frame.
        b = F.binding; (b.frameWidth, b.frameHeight, b.orientation) = (1080, 1920, 6)
        XCTAssertEqual(f.staleReason(for: b), "the frame changed (1920×1080 o1 → 1080×1920 o6)")
        b = F.binding; b.durationSec = 119
        XCTAssertEqual(f.staleReason(for: b), "the video's length changed")
        b = F.binding; b.durationSec = 120.01
        XCTAssertNil(f.staleReason(for: b))
        var old = f
        old.schemaVersion = "court_net_calibration_v0"
        XCTAssertNotNil(old.staleReason(for: F.binding))
    }

    func testAPortraitRecordingCalibratesLikeALandscapeOne() throws {
        var b = F.binding
        (b.frameWidth, b.frameHeight, b.orientation) = (1080, 1920, 6)
        var f = CourtNetCalibrationFile.new(for: b)
        try f.saveDraft(F.court, of: \.court, segment: 0, startedFrom: manual, baseline: nil)
        try f.confirm(\.court, segment: 0, by: "ben", tool: "test", now: F.day)
        XCTAssertEqual(f.status(for: b), .courtConfirmed)
        XCTAssertEqual(f.status(for: F.binding), .needsReview)
    }

    func testMalformedFilesAreNamed() throws {
        var f = try confirmed()
        f.segments[0].validToSec = 100
        XCTAssertEqual(f.problems, ["segments end at 100.0 s, the recording at 120.0 s"])

        f = try confirmed()
        XCTAssertTrue(f.split(at: 40, reuse: false))
        f.segments[1].validFromSec = 30
        XCTAssertFalse(f.problems.isEmpty)
        f.segments[1].validFromSec = 40
        f.segments[1].id = 0
        XCTAssertEqual(f.problems, ["segment ids repeat"])

        f = try confirmed()
        f.segments[0].view = .unsuitable
        XCTAssertEqual(f.problems, ["segment 0 holds a confirmation but is not a stable view"])

        f = try confirmed()
        f.segments[0].net.confirmation?.geometry.topRight = .init(x: 1.4, y: 0.6)
        XCTAssertEqual(f.problems, ["segment 0 net: the net's topRight corner is outside the frame"])
        XCTAssertNil(f.confirmed(\.net, at: 1))

        f = file()
        f.recordingId = "../escape"
        f.frameWidth = 0
        f.segments = []
        XCTAssertEqual(f.problems, ["the recording id can't name a file", "frame 0×1080", "no segments"])
    }

    func testACoordinateThatIsNotANumberIsMalformedEvenInADraft() throws {
        var f = file()
        var net = F.net
        net.topLeft.y = .infinity
        try f.saveDraft(net, of: \.net, segment: 0, startedFrom: manual, baseline: nil)
        XCTAssertEqual(f.problems, ["segment 0 holds a value that is not a number"])
        XCTAssertEqual(f.status(for: F.binding), .needsReview)
        try f.discardDraft(of: \.net, segment: 0)
        XCTAssertEqual(f.problems, [])
    }

    func testOnlyNamesMakeRecordingIds() {
        for id in ["5D1F0C0E-0000-4000-8000-000000000001", "video_01", "a.b"] { XCTAssertTrue(CourtNetCalibrationFile.isSafeId(id), id) }
        for id in ["", ".hidden", "a/b", "..", "a b", "é"] { XCTAssertFalse(CourtNetCalibrationFile.isSafeId(id), id) }
    }
}
