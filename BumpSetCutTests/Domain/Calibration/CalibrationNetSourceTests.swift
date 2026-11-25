//
//  CalibrationNetSourceTests.swift
//  BumpSetCutTests
//
//  The app's net for a run: a person's confirmed net for that file, one view for the whole
//  video — or no net, with the reason.
//

import AVFoundation
import XCTest
@testable import BumpSetCut

final class CalibrationNetSourceTests: XCTestCase {
    private typealias F = CalibrationFixtures

    private func file(confirmNet: Bool = true, binding: CourtNetCalibrationFile.Binding = F.binding) throws -> CourtNetCalibrationFile {
        var f = CourtNetCalibrationFile.new(for: binding)
        try f.saveDraft(F.net, of: \.net, segment: 0, startedFrom: CourtNetCalibrationV1.manual, baseline: nil)
        if confirmNet { try f.confirm(\.net, segment: 0, by: "tester", tool: "test", now: F.day) }
        return f
    }

    private func why(_ lookup: CourtNetCalibrationStore.Lookup, _ config: ProcessorConfig = ProcessorConfig()) -> CalibrationNetSource.Unavailable? {
        if case .failure(let why) = CalibrationNetSource.usableNet(from: lookup, config: config) { return why }
        return nil
    }

    private func reason(_ lookup: CourtNetCalibrationStore.Lookup, _ config: ProcessorConfig = ProcessorConfig()) -> String? {
        why(lookup, config)?.reason
    }

    func testAConfirmedNetGivesTheBoxRoundItsFourCorners() throws {
        let net = try CalibrationNetSource.usableNet(from: .usable(try file()), config: ProcessorConfig()).get()
        // The quad tilts (its top-right is higher than its top-left): the box holds all of it.
        XCTAssertEqual(net.box.minX, 0.24, accuracy: 1e-9)
        XCTAssertEqual(net.box.maxX, 0.76, accuracy: 1e-9)
        XCTAssertEqual(net.box.minY, 0.49, accuracy: 1e-9)
        XCTAssertEqual(net.box.maxY, 0.61, accuracy: 1e-9)
        XCTAssertEqual(net.confidence, 1)
    }

    func testACourtAloneOrADraftNetIsNoNet() throws {
        XCTAssertEqual(reason(.usable(try file(confirmNet: false))), "the net is not confirmed")
        var courtOnly = CourtNetCalibrationFile.new(for: F.binding)
        try courtOnly.saveDraft(F.court, of: \.court, segment: 0, startedFrom: CourtNetCalibrationV1.manual, baseline: nil)
        try courtOnly.confirm(\.court, segment: 0, by: "tester", tool: "test", now: F.day)
        XCTAssertEqual(reason(.usable(courtOnly)), "the net is not confirmed")
    }

    func testNoCalibrationAStaleOneAndAnUnreadableOneAreNoNet() throws {
        XCTAssertEqual(reason(.none), "no court and net calibration")
        XCTAssertEqual(reason(.stale(try file(), reason: "the video file changed")), "the calibration is for another version of the video (the video file changed)")
        XCTAssertEqual(reason(.unreadable("bad json")), "the calibration can't be read (bad json)")
    }

    func testMoreThanOneCameraViewOrAViewThatIsNotStableIsNoNet() throws {
        var split = try file()
        XCTAssertTrue(split.split(at: 40, reuse: true))
        XCTAssertEqual(reason(.usable(split)), "the camera view changes during the video")
        var unstable = try file()
        try unstable.setView(.unsuitable, segment: 0, note: nil, at: F.day)
        XCTAssertEqual(reason(.usable(unstable)), "the video is not marked as a stable court view")
    }

    func testEveryViewsNetConfirmedStillLeavesASplitVideoWithoutANetForTheRules() throws {
        // What the status line calls "net confirmed" is not what the rules can use: they take one net for a run.
        var split = try file()
        XCTAssertTrue(split.split(at: 40, reuse: true))
        try split.confirm(\.net, segment: 1, by: "tester", tool: "test", now: F.day)
        XCTAssertEqual(split.status(for: F.binding), .netConfirmed)
        XCTAssertEqual(why(.usable(split)), .severalViews)
        XCTAssertEqual(why(.usable(try file())), nil)
        XCTAssertEqual(why(.none), .noCalibration)
        XCTAssertEqual(why(.usable(try file(confirmNet: false))), .netNotConfirmed)
    }

    func testAnUprightCalibrationIsNotUsedByARunThatReadsRotatedFramesAsStored() throws {
        var portrait = F.binding
        (portrait.frameWidth, portrait.frameHeight, portrait.orientation) = (1080, 1920, 6)
        var stored = ProcessorConfig()
        stored.applyVideoRotation = false
        XCTAssertEqual(reason(.usable(try file(binding: portrait)), stored), "the run reads frames as stored and the calibration is in the upright frame")
        XCTAssertNil(reason(.usable(try file(binding: portrait))))
        // A video stored upright is the same frame either way.
        XCTAssertNil(reason(.usable(try file()), stored))
    }

    func testTheSourceReadsTheStoreForTheVideoItIsGiven() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CalibrationNetSourceTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try TestVideoFactory.writeVideo(to: dir.appendingPathComponent("clip.mp4"), duration: 2, size: CGSize(width: 320, height: 180))
        let id = UUID()
        let store = CourtNetCalibrationStore(directory: dir.appendingPathComponent("sidecars"))
        let source = CalibrationNetSource(store: store, videoId: id)
        let asset = AVURLAsset(url: url)
        let none = await source.netGeometry(forVideoAt: url, asset: asset, durationSec: 2, config: ProcessorConfig())
        XCTAssertEqual(none.unavailableReason, "no court and net calibration")

        let video = try await CalibrationVideo.load(recordingId: id.uuidString, url: url)
        try store.save(try file(binding: video.binding))
        let confirmed = await source.netGeometry(forVideoAt: url, asset: asset, durationSec: 2, config: ProcessorConfig())
        XCTAssertEqual(confirmed.origin, NetGeometry.personConfirmed)

        // The file under the id is replaced: the confirmed net is for another video.
        try TestVideoFactory.writeVideo(to: url, duration: 2, size: CGSize(width: 320, height: 180), fps: 24)
        let stale = await source.netGeometry(forVideoAt: url, asset: AVURLAsset(url: url), durationSec: 2, config: ProcessorConfig())
        XCTAssertEqual(stale.unavailableReason, "the calibration is for another version of the video (the video file changed)")
    }
}
