//
//  LabelingSyncCutsTests.swift
//  RallyLabTests
//
//  Cut ranges travel with the rally times (D-030): a row from before the
//  column decodes with no cuts, a row with them carries them, and the sync's
//  "same" rule tells a change of cuts alone apart — so it is pushed or
//  pulled like a change of rallies. A row an older phone build wrote (no
//  `cuts` at all) never erases the cuts marked here.
//

import XCTest
@testable import RallyLab

final class LabelingSyncCutsTests: XCTestCase {
    private let id = UUID()

    private func times(_ rallies: [(Double, Double)], complete: Bool = false, cuts: [CutRange]? = nil) -> LabelRallyTimes {
        LabelRallyTimes(videoId: id, rallies: rallies.map { LabelRally(start: $0.0, end: $0.1) }, complete: complete, updatedAt: nil, cuts: cuts)
    }

    func testARowFromBeforeTheColumnDecodesWithNoCutsAndOneWithThemCarriesThem() throws {
        let old = try JSONDecoder().decode(LabelRallyTimes.self, from: Data("""
        {"videoId":"\(id.uuidString)","rallies":[{"start":1,"end":2}],"complete":false}
        """.utf8))
        XCTAssertNil(old.cuts); XCTAssertEqual(old.cutRanges, [])
        let new = try JSONDecoder().decode(LabelRallyTimes.self, from: Data("""
        {"videoId":"\(id.uuidString)","rallies":[],"complete":true,"cuts":[{"start":141.6,"end":157},{"start":0,"end":12.4}]}
        """.utf8))
        XCTAssertEqual(new.cuts, [CutRange(start: 141.6, end: 157), CutRange(start: 0, end: 12.4)])
        XCTAssertEqual(new.cutRanges, [CutRange(start: 0, end: 12.4), CutRange(start: 141.6, end: 157)])
        // Encoded only when set: a build that never knew cuts sends no key, and the server keeps its value.
        let encoded = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        XCTAssertFalse(encoded.contains("cuts"))
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(new), as: UTF8.self).contains("\"cuts\""))
    }

    @MainActor
    func testSameTellsAChangeOfCutsAlone() {
        let a = times([(10, 20)], cuts: [CutRange(start: 30, end: 40)])
        XCTAssertTrue(LabelingSync.same(a, times([(10, 20.01)], cuts: [CutRange(start: 30.01, end: 40)])), "within a frame")
        XCTAssertFalse(LabelingSync.same(a, times([(10, 20)])), "no cuts on one side")
        XCTAssertFalse(LabelingSync.same(a, times([(10, 20)], cuts: [CutRange(start: 30, end: 45)])))
        XCTAssertFalse(LabelingSync.same(a, times([(10, 20)], cuts: [CutRange(start: 30, end: 40), CutRange(start: 50, end: 60)])))
        XCTAssertTrue(LabelingSync.same(times([(10, 20)]), times([(10, 20)], cuts: [])), "nil and empty are the same: no cuts")
    }

    // MARK: - An older build never erases the Mac's cuts

    /// A phone build from before cuts rewrites a row's rallies and sends no `cuts` (the server keeps its value;
    /// migration 051). Pulled to the Mac — newer than the Mac's file — such a row updates the rallies and the
    /// declaration and leaves the cuts alone; the Mac's next push says what the cuts are.
    @MainActor
    func testARowWithoutCutsFromAnOlderBuildNeverErasesTheMacsCuts() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lsc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("empty"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let suite = "RallyLabTests.LabelingSyncCuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // A project with one recording, its cuts marked here, and its rally-marks file older than the server's row.
        let root = base.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("footage"), withIntermediateDirectories: true)
        let footage = root.appendingPathComponent("footage/video_01.mp4")
        try Data("A: video_01 footage".utf8).write(to: footage)
        let store = DatasetStore(root: root)
        try store.prepare()
        var session = VideoSession(name: "video_01", sourcePath: footage.path, split: "train", addedAt: Date(), frames: [])
        session.cuts = [CutRange(start: 10, end: 20)]
        try store.save(session)
        let card = SourceRegistryTests.clip("card_0", number: 1, videos: [SourceRegistryTests.video("video_01", fingerprint: ProjectsModel.readFileFingerprint(atPath: footage.path))])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: "A", createdAt: Date(), framesPerRally: 2, clips: [card])).write(to: root.appendingPathComponent("project.json"))
        let labels = RallyMarkModel.labelsURL(for: footage)
        try JSONEncoder().encode([RallyMarkRecord(startTime: 1, endTime: 4, kind: nil, contacts: nil)]).write(to: labels, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: labels.path)

        let sampler = SamplerModel(defaults: defaults, root: base.appendingPathComponent("empty"))
        let projects = ProjectsModel(sampler: sampler, defaults: defaults)
        let server = FakeLabeling()
        let sync = LabelingSync(projects: projects, client: server, pendingDirectory: base.appendingPathComponent("pending"))
        projects.open(root)
        let row = LabelVideo(id: UUID(), project: "A", sessionName: "video_01", title: "", surface: .beach, camera: .endlineGround, lighting: "",
                             split: "train", clipPath: nil, duration: 0, ralliesFound: [], status: .rallylab, updatedAt: Date())
        server.videos = [row]
        // The older build's row: the rallies rewritten, the pass finished, no `cuts` key at all — newer than the Mac's file.
        server.times[row.id] = LabelRallyTimes(videoId: row.id, rallies: [LabelRally(start: 30, end: 35), LabelRally(start: 40, end: 44)],
                                               complete: true, updatedAt: Date(), cuts: nil)
        let firstRound = await sync.sync(videos: false)
        XCTAssertTrue(firstRound)
        let pulled = projects.session(named: "video_01")
        XCTAssertEqual(pulled?.cuts, [CutRange(start: 10, end: 20)], "the row said nothing about cuts: the Mac's stay")
        XCTAssertEqual(pulled?.ralliesMarked, true)
        XCTAssertEqual(RallyMarkModel.load(labels).map(\.start), [30, 40])
        XCTAssertTrue(server.savedTimes.isEmpty, "nothing pushed: the server's row was the newer")
        // Edited here afterwards: the push carries the cuts, so the server's row says what they are.
        try JSONEncoder().encode([RallyMarkRecord(startTime: 30, endTime: 36, kind: nil, contacts: nil)]).write(to: labels, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: labels.path)
        let secondRound = await sync.sync(videos: false)
        XCTAssertTrue(secondRound)
        XCTAssertEqual(server.savedTimes.last?.cuts, [CutRange(start: 10, end: 20)])
        XCTAssertEqual(server.savedTimes.last?.rallies.map(\.end), [36])
    }
}
