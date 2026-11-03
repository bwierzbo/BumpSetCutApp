//
//  TrackNavigationTests.swift
//  RallyLabTests
//
//  Opening a recording in the Track tab's ball-track editor from another tab
//  (the Queue's "Open in Track"). Codex on #134 (29905d9): the Queue opened the
//  recording in the tracker only, so a Track tab left in "rally times" mode
//  still showed the rally marker, and its appearance restored the tab's own
//  saved recording into it. The request now lives on the tracker model and is
//  resolved against the open project's trackable recordings when the tab takes
//  it; the tab then switches to ball tracks and remembers the recording. The
//  resolution is the part a test can run without the app's sampler.
//

import XCTest
@testable import RallyLab

final class TrackNavigationTests: XCTestCase {
    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracknav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func session(_ name: String, in root: URL) -> VideoSession {
        VideoSession(name: name, sourcePath: root.appendingPathComponent("\(name).mp4").path, split: "train", addedAt: now, frames: [])
    }

    private func request(_ video: String, in root: URL) -> TrackLabelModel.Request {
        .init(video: video, root: root.standardizedFileURL)
    }

    func testARequestForATrackableRecordingOfTheOpenProjectOpens() {
        let a = dir.appendingPathComponent("A", isDirectory: true)
        let trackable = [session("c_ok", in: a), session("d_next", in: a)]
        XCTAssertEqual(TrackLabelModel.resolve(request("d_next", in: a), root: a, trackable: trackable), .open("d_next"))
        // The request carries ProjectsModel's standardised project folder; the sampler holds the folder as it
        // was opened (no trailing slash, not standardised). Both name the same project.
        let raw = URL(fileURLWithPath: a.path)
        XCTAssertEqual(TrackLabelModel.resolve(request("c_ok", in: a), root: raw, trackable: trackable), .open("c_ok"))
        XCTAssertEqual(TrackLabelModel.resolve(request("c_ok", in: raw), root: a, trackable: trackable), .open("c_ok"))
    }

    /// The project changed while the request waited, or the request was made for another project:
    /// dropped and said so, even when the open project has a recording of the same name.
    func testARequestForAnotherProjectIsDropped() {
        let a = dir.appendingPathComponent("A", isDirectory: true), b = dir.appendingPathComponent("B", isDirectory: true)
        let resolution = TrackLabelModel.resolve(request("c_ok", in: a), root: b, trackable: [session("c_ok", in: b)])
        guard case .dropped(let why) = resolution else { return XCTFail("\(resolution)") }
        XCTAssertTrue(why.contains("asked for in A, not B"), why)
        XCTAssertTrue(why.hasSuffix("not opened."), why)
    }

    /// Not a recording of the project, or one whose video is not on this Mac (the tab lists only
    /// those): dropped and said so.
    func testARecordingThatCannotBeTrackedHereIsDropped() {
        let a = dir.appendingPathComponent("A", isDirectory: true)
        for video in ["zzz_not_here", "e_offline"] {
            let resolution = TrackLabelModel.resolve(request(video, in: a), root: a, trackable: [session("c_ok", in: a)])
            guard case .dropped(let why) = resolution else { return XCTFail("\(resolution)") }
            XCTAssertTrue(why.contains(video) && why.contains("not opened"), why)
        }
    }
}
