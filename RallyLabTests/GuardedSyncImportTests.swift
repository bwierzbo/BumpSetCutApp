//
//  GuardedSyncImportTests.swift
//  RallyLabTests
//
//  A guarded run's sync round (importsPhoneUploads: false) never pulls a phone upload into the project, however
//  visible it is; an ordinary round does. Fixtures: a temporary project of its own, a fake server, a defaults suite
//  of its own — no network, no session, nothing of the person's.
//

import XCTest
@testable import RallyLab

@MainActor
final class GuardedSyncImportTests: XCTestCase {
    private var base: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var projects: ProjectsModel!
    private var server: FakeLabeling!
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T16:00:00Z")!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("gsi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("empty"), withIntermediateDirectories: true)
        suite = "rallylab.test.GuardedSyncImport.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        projects = ProjectsModel(sampler: SamplerModel(defaults: defaults, root: base.appendingPathComponent("empty")), defaults: defaults, restoreLastProject: false)
        server = FakeLabeling()
        // A test project with one beach card, so the upload below has a card to land on.
        let root = base.appendingPathComponent("Accept-import", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("footage"), withIntermediateDirectories: true)
        try DatasetStore(root: root).prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let card = SourceRegistryTests.clip("card_0", number: 1, videos: [])
        try encoder.encode(Project(name: "Accept-import", createdAt: now, framesPerRally: 2, clips: [card])).write(to: root.appendingPathComponent("project.json"))
        projects.open(root)
        XCTAssertNotNil(projects.opening)
        // Someone's upload, waiting on the server: not this project's, not synthetic.
        server.videos.append(LabelVideo(id: UUID(), project: nil, sessionName: nil, title: "Real phone footage", surface: .beach, camera: .endlineGround,
                                        lighting: "", split: "train", clipPath: "phone/real.mp4", duration: 30, ralliesFound: [], status: .uploaded, updatedAt: now))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    func testAGuardedRoundLeavesAPendingUploadWhereItIs() async {
        let sync = LabelingSync(projects: projects, client: server, pendingDirectory: base.appendingPathComponent("pending"), importsPhoneUploads: false)
        _ = await sync.sync(videos: true)
        XCTAssertFalse(server.calls.contains("download"), "nothing of the upload is fetched")
        XCTAssertTrue(server.downloads.isEmpty)
        let row = server.videos.first { $0.clipPath == "phone/real.mp4" }
        XCTAssertEqual(row?.status, .uploaded, "the row is untouched")
        XCTAssertNil(row?.project)
        XCTAssertFalse(server.savedVideos.contains { $0.clipPath == "phone/real.mp4" }, "never saved under the test project")
        XCTAssertTrue(sync.status.contains("phone uploads not pulled in (guarded run)"), sync.status)
    }

    func testAnOrdinaryRoundStillPullsTheUploadIn() async {
        struct Stop: Error {}
        // The fake refuses the download: the attempt is the evidence, and nothing is cut or sampled in a test.
        server.failures["download"] = Stop()
        let sync = LabelingSync(projects: projects, client: server, pendingDirectory: base.appendingPathComponent("pending"))
        _ = await sync.sync(videos: true)
        XCTAssertTrue(server.calls.contains("download"), "the unguarded round went for the upload")
    }
}
