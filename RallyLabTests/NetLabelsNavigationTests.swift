//
//  NetLabelsNavigationTests.swift
//  RallyLabTests
//
//  Opening a recording in the Net labels tab from another tab (the Queue's
//  "Open in Net labels"). Codex on #134 (d6a41b7): the recording was selected
//  before SwiftUI switched tabs, and the tab's activation reload cleared the
//  selection. The request is now kept on the model until the tab is active and
//  has reloaded the project it names; it is dropped when the project changes
//  meanwhile; and it is applied through the ordinary selection, so a withheld
//  or skipped recording is named and never opened, one not in the project is
//  reported, and one whose file can't be read shows nothing.
//

import XCTest
@testable import RallyLab

@MainActor
final class NetLabelsNavigationTests: XCTestCase {
    /// Footage that answers from memory: readable unless named, 100 s long, one blank frame, no model.
    final class Footage: NetLabelFootage, @unchecked Sendable {
        let lock = NSLock()
        var unreadable: Set<String> = []
        private(set) var durationCalls: [String] = []
        func isReadable(_ url: URL) async -> Bool { lock.withLock { !unreadable.contains(url.lastPathComponent) } }
        func rallyMarks(for url: URL) async -> [(start: Double, end: Double)] { [] }
        func duration(of url: URL) async -> Double { lock.withLock { durationCalls.append(url.lastPathComponent) }; return 100 }
        func frame(of url: URL, at time: Double) async throws -> CGImage { try NetLabelsTests.ScriptedFootage.image() }
        var modelAvailable: Bool { false }
        func proposal(on frame: CGImage) -> (rect: CGRect, confidence: Float)? { nil }
    }

    struct Video {
        var id: String
        var split = "train"
        var camera = "Tripod / corner"
        var identified = true
    }

    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
    }

    /// A project folder the tab can list: project.json with one clip per video, and a split
    /// manifest of it (hash of project.json as written; no validation.json).
    private func project(named name: String, videos: [Video]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nlnav-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        roots.append(dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clips = videos.map { v in
            PlannedClip(id: v.id, number: 1, environment: "indoor", camera: v.camera, lighting: "bright", orientation: "land", ball: "", notes: "", split: "train",
                        videos: [ClipSource(kind: .file, origin: "/footage/\(v.id).mov", start: 0, length: 60, license: "permission: test", title: v.id, uploader: "test",
                                            clipFile: dir.appendingPathComponent("\(v.id).mp4").path, fetchedAt: now, videoId: nil, frames: nil,
                                            fingerprint: nil, sourceId: nil, sessionId: nil, venueId: nil)])
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: name, createdAt: now, framesPerRally: 4, clips: clips)).write(to: dir.appendingPathComponent("project.json"))
        // A session over each recording: without one its cut ranges are unknown and the tab skips it (no_session).
        let store = DatasetStore(root: dir)
        try store.prepare()
        for v in videos { try store.save(VideoSession(name: v.id, sourcePath: dir.appendingPathComponent("\(v.id).mp4").path, split: "train", addedAt: now, frames: [])) }
        let rows = videos.map { v in
            """
            {"video":"\(v.id)","sourceId":{"origin":"unknown"},"sessionId":{"origin":"unknown"},"venueId":{"origin":"unknown"},
             "datasetSplit":"train","split":"\(v.split)",\(v.identified ? "\"fingerprint\":\"fp-\(v.id)\"," : "")
             "ralliesMarked":true,"frames":1,"reviewedFrames":1,"addedAt":"2026-10-30T00:00:00Z","exposure":[]}
            """
        }
        let hash = try XCTUnwrap(DatasetSplitManifest.sha256(of: dir.appendingPathComponent("project.json")))
        let manifest = """
        {"schemaVersion":1,"project":"\(name)","createdAt":"2026-10-30T00:00:00Z","generator":"test",
         "hashes":{"projectJson":"\(hash)"},"splitDefinitions":{},"videos":[\(rows.joined(separator: ","))]}
        """
        try Data(manifest.utf8).write(to: NetInventory.manifestURL(in: dir))
        return dir
    }

    /// What ProjectsModel would answer for the project at `dir`.
    private func open(_ dir: URL) throws -> (project: Project, dir: URL) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try decoder.decode(Project.self, from: Data(contentsOf: dir.appendingPathComponent("project.json"))), dir.standardizedFileURL)
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// The Queue's open while the tab is off screen: nothing is selected until the tab is
    /// active and has reloaded; the request survives a reload of the same project meanwhile.
    func testARequestIsAppliedAfterTheActivationReloadAndSurvivesAReloadBeforeIt() async throws {
        let a = try project(named: "A", videos: [Video(id: "c_ok"), Video(id: "d_next")])
        let current = try open(a)
        let footage = Footage()
        let model = NetLabelsModel(project: { current }, footage: footage, prefetchAhead: 0)
        XCTAssertEqual(model.items.map(\.video), ["c_ok", "d_next"])
        XCTAssertFalse(model.isActive)

        model.open("d_next", in: a)
        XCTAssertNil(model.selected, "selected before the activation reload: the reload would have cleared it")
        XCTAssertEqual(model.pending, .init(video: "d_next", root: a.standardizedFileURL))
        // The project is read again while the tab is still off screen (ContentView does this when the
        // project folder changes): the request is kept.
        model.reload()
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.pending?.video, "d_next")
        XCTAssertTrue(footage.durationCalls.isEmpty, "nothing opened while the tab is off screen")

        // SwiftUI switches tabs: the activation reload lists the project again, then applies the request.
        model.activate(true)
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.selected, "d_next")
        XCTAssertNil(model.pending)
        await settle()
        XCTAssertEqual(footage.durationCalls, ["d_next.mp4"])
        XCTAssertNotNil(model.frame)
        XCTAssertEqual(model.selectedItem?.video, "d_next")

        // Off screen and on again with nothing pending: the ordinary reload, nothing selected.
        model.activate(false)
        model.activate(true)
        XCTAssertNil(model.selected)
        XCTAssertNil(model.pending)
    }

    /// The list's skips are as of its last reload. A recording withheld since — listed in validation.json while
    /// the tab stays on screen — is shown no model: no proposal, no ledger row. An ordinary one still is.
    func testNoProposalIsMadeForARecordingWithheldSinceTheListWasRead() async throws {
        let a = try project(named: "A", videos: [Video(id: "c_ok"), Video(id: "d_next")])
        let current = try open(a)
        let footage = NetLabelsTests.ScriptedFootage()
        let model = NetLabelsModel(project: { current }, footage: footage, prefetchAhead: 0)
        model.activate(true)
        XCTAssertNil(model.items.first { $0.video == "c_ok" }?.skip, "the fixture: listed as an ordinary recording")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try #"{"tune":[],"holdout":["c_ok"],"finalTest":[]}"#.write(to: PipelineTuner.ValidationSet.file(in: a), atomically: true, encoding: .utf8)

        model.select("c_ok")
        await settle()
        XCTAssertEqual(footage.proposalCalls, 0, "the model did not run")
        XCTAssertTrue(model.status.contains("c_ok is withheld"), model.status)
        XCTAssertNil(model.proposal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExposureLog.url(in: a).path), "and nothing was recorded")

        model.select("d_next")
        await settle()
        XCTAssertEqual(footage.proposalCalls, 1, "an ordinary recording still gets its proposal")
        XCTAssertEqual(try ExposureLog.readStrict(in: a).map { "\($0.video) \($0.kind.rawValue)" }, ["d_next net_proposal"])
    }

    /// The tab already on screen: the request is applied at once, without a reload.
    func testARequestWhileTheTabIsActiveIsAppliedAtOnce() async throws {
        let a = try project(named: "A", videos: [Video(id: "c_ok"), Video(id: "d_next")])
        let current = try open(a)
        let footage = Footage()
        let model = NetLabelsModel(project: { current }, footage: footage, prefetchAhead: 0)
        model.activate(true)
        model.select("c_ok")
        await settle()
        XCTAssertEqual(footage.durationCalls, ["c_ok.mp4"])

        model.open("d_next", in: a)
        XCTAssertEqual(model.selected, "d_next")
        XCTAssertNil(model.pending)
        await settle()
        XCTAssertEqual(footage.durationCalls, ["c_ok.mp4", "d_next.mp4"])
        XCTAssertNotNil(model.frame)

        // Blocked (the manifest is no longer of project.json as it is): the request is dropped and the
        // block's message stands; nothing is selected.
        try Data("changed".utf8).write(to: a.appendingPathComponent("project.json"))
        let changed = try? open(a)
        XCTAssertNil(changed, "the fixture's project.json is no longer a project")
        try FileManager.default.removeItem(at: a.appendingPathComponent("project.json"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var project = current.project
        project.name = "A renamed"
        try encoder.encode(project).write(to: a.appendingPathComponent("project.json"))
        let renamed = try open(a)
        let blocked = NetLabelsModel(project: { renamed }, footage: footage, prefetchAhead: 0)
        blocked.activate(true)
        XCTAssertNotNil(blocked.blocked)
        blocked.open("c_ok", in: a)
        XCTAssertNil(blocked.pending)
        XCTAssertNil(blocked.selected)
        XCTAssertNotNil(blocked.blocked)
        XCTAssertEqual(blocked.status, blocked.blocked)
    }

    /// The project changes while the request waits: the request named the old project and is dropped,
    /// even when the new project has a recording of the same name. A request for a project that is not
    /// the open one is dropped the same way.
    func testTheRequestIsDroppedWhenTheProjectChangesBeforeTheTabActivates() async throws {
        let a = try project(named: "A", videos: [Video(id: "c_ok")])
        let b = try project(named: "B", videos: [Video(id: "c_ok"), Video(id: "x_other")])
        var current = try open(a)
        let footage = Footage()
        let model = NetLabelsModel(project: { current }, footage: footage, prefetchAhead: 0)

        model.open("c_ok", in: a)
        XCTAssertEqual(model.pending?.root, a.standardizedFileURL)
        // Another project is opened; ContentView reloads this tab for it.
        current = try open(b)
        model.reload()
        XCTAssertNil(model.pending, "a request for A is not a request for B's recording of the same name")
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.status.contains("not opened"), model.status)
        XCTAssertEqual(model.items.map(\.video), ["c_ok", "x_other"])
        model.activate(true)
        XCTAssertNil(model.selected)
        await settle()
        XCTAssertTrue(footage.durationCalls.isEmpty)

        // A stale request — made for A while B is open — is dropped by the activation reload.
        model.activate(false)
        model.open("c_ok", in: a)
        model.activate(true)
        XCTAssertNil(model.pending)
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.status.contains("not opened"), model.status)

        // No project open at all: nothing to apply it to.
        model.activate(false)
        model.open("c_ok", in: nil)
        XCTAssertNil(model.pending)
        model.open("c_ok", in: b)
        let none = NetLabelsModel(project: { nil }, footage: footage, prefetchAhead: 0)
        none.open("c_ok", in: b)
        none.activate(true)
        XCTAssertNil(none.pending)
        XCTAssertNil(none.selected)
        XCTAssertEqual(none.status, "Open a project.")
    }

    /// Applied through the ordinary selection: a withheld or unidentified recording is named and never
    /// opened (no read of its file), one the project doesn't have is reported, and one whose file can't
    /// be read here shows nothing.
    func testWithheldAndUnavailableRecordingsStayInaccessible() async throws {
        let a = try project(named: "A", videos: [Video(id: "c_ok"), Video(id: "e_withheld", split: "lineage_holdout"),
                                                 Video(id: "g_nofp", identified: false), Video(id: "h_hand", camera: "Handheld / corner")])
        let current = try open(a)
        let footage = Footage()
        let model = NetLabelsModel(project: { current }, footage: footage, prefetchAhead: 0)

        model.open("e_withheld", in: a)
        model.activate(true)
        await settle()
        XCTAssertEqual(model.selected, "e_withheld")
        XCTAssertEqual(model.selectedItem?.skip, .withheld)
        XCTAssertTrue(model.status.contains("skipped (withheld)"), model.status)
        XCTAssertNil(model.frame)
        XCTAssertFalse(model.canConfirm)
        XCTAssertTrue(footage.durationCalls.isEmpty, "a withheld recording's file was read")

        for (video, skip) in [("g_nofp", NetLabels.Skip.unidentified), ("h_hand", .handheld)] {
            model.open(video, in: a)
            await settle()
            XCTAssertEqual(model.selected, video)
            XCTAssertEqual(model.selectedItem?.skip, skip)
            XCTAssertNil(model.frame)
            XCTAssertFalse(model.canConfirm)
        }
        XCTAssertTrue(footage.durationCalls.isEmpty, "a skipped recording's file was read")

        model.open("zzz_not_here", in: a)
        await settle()
        XCTAssertNil(model.pending)
        XCTAssertNotEqual(model.selected, "zzz_not_here")
        XCTAssertTrue(model.status.contains("isn't a recording of"), model.status)
        XCTAssertTrue(footage.durationCalls.isEmpty)

        footage.unreadable = ["c_ok.mp4"]
        model.open("c_ok", in: a)
        await settle()
        XCTAssertEqual(model.selected, "c_ok")
        XCTAssertNil(model.frame)
        XCTAssertFalse(model.canConfirm)
        XCTAssertTrue(model.status.contains("isn't readable"), model.status)
        XCTAssertTrue(footage.durationCalls.isEmpty, "an unreadable file was read past the check")
    }
}
