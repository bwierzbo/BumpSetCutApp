//
//  NetExclusionsTests.swift
//  RallyLabTests
//
//  The owner's side-view exclusions: bound to the file they were decided on,
//  skipped like a handheld recording in the tab, refused by the export even
//  when labeled, never offered a proposal or chosen for one, and the store
//  failing closed and keeping what was written since the tab loaded.
//

import CoreGraphics
import XCTest
@testable import RallyLab

extension NetLabelsTests {

    private static func exclusion(_ fingerprint: String = "fp-a") -> NetExclusion {
        NetExclusion(reason: .sideView, fingerprint: fingerprint, decidedAt: Date(timeIntervalSince1970: 1_800_000_000), decidedBy: "owner, test")
    }

    func testAnExclusionIsASideViewSkipOnlyForItsOwnFile() {
        XCTAssertEqual(NetLabels.skip(video: "a", camera: "Tripod", withheld: [], fingerprint: "f", excluded: ["a"]), .sideView)
        XCTAssertEqual(NetLabels.skip(video: "a", camera: "Tripod", withheld: ["a"], fingerprint: "f", excluded: ["a"]), .withheld, "withheld wins")
        XCTAssertNil(NetLabels.skip(video: "a", camera: "Tripod", withheld: [], fingerprint: "f", excluded: []))
        let fps: [String: String] = ["a": "fp-a", "b": "fp-new"]
        XCTAssertEqual(NetExclusionStore.excluded(["a": Self.exclusion("fp-a"), "b": Self.exclusion("fp-old"), "c": Self.exclusion()]) { fps[$0] }, ["a"],
                       "another file under the same id, or an id no longer there, is not excluded")
    }

    func testTheExportRefusesAnExcludedRecordingEvenWhenLabeled() {
        func src(_ v: String, fp: String = "fp-a") -> NetDatasetExport.Source {
            NetDatasetExport.Source(video: v, clip: v, camera: "Tripod / corner", url: URL(fileURLWithPath: "/nowhere/\(v).mp4"), fingerprint: fp)
        }
        let labels = ["a_side": Self.label(), "b_ok": Self.label(), "c_refiled": Self.label(fingerprint: "fp-new")]
        let plan = NetDatasetExport.plan(labels: labels, sources: [src("a_side"), src("b_ok"), src("c_refiled", fp: "fp-new")], withheld: [],
                                         exclusions: ["a_side": Self.exclusion(), "c_refiled": Self.exclusion("fp-old")])
        XCTAssertEqual(plan.export.map(\.video), ["b_ok", "c_refiled"])
        XCTAssertEqual(plan.skipped, [NetDatasetExport.Skipped(video: "a_side", reason: "side_view")])
    }

    func testAnExcludedRecordingIsNeverChosenForAProposal() {
        let c = NetAIPilot.Candidate(video: "a", clip: "a", camera: "Tripod", surface: "beach", aliasGroup: nil,
                                     url: URL(fileURLWithPath: "/nowhere/a.mp4"), fingerprint: "fp", fileFingerprint: "fp")
        XCTAssertEqual(NetAIPilot.choose([c], labels: [:], proposals: [:], withheld: [], count: 10).count, 1)
        XCTAssertTrue(NetAIPilot.choose([c], labels: [:], proposals: [:], withheld: [], count: 10, excluded: ["a"]).isEmpty)
    }

    func testTheExclusionStoreRoundTripsAndFailsClosed() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NetExclusionStore(projectDir: dir)
        XCTAssertEqual(try store.load(), [:])
        try store.save(["a": Self.exclusion()])
        XCTAssertEqual(try store.load(), ["a": Self.exclusion()])
        XCTAssertTrue(try String(contentsOf: store.url, encoding: .utf8).contains("\"side_view\""))
        try Data("{nope".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }

    @MainActor
    func testTheOwnerExcludesASideViewInTheTabAndCanTakeItBack() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        let exclusionStore = NetExclusionStore(projectDir: dir)
        let ai = NetAIProposal(outcome: .needsManualReview, corners: nil, confidence: nil, uncertainty: "side view: camera at the near post",
                               time: 50, frameWidth: 64, frameHeight: 36, imageSHA256: "sha", fingerprint: "fp-a", model: "claude-test",
                               run: "run-1", exposureRecordedAt: Date(timeIntervalSince1970: 1_800_000_000), importedAt: Date(timeIntervalSince1970: 1_800_000_100))
        var recorded: [String] = []
        let model = NetLabelsModel(items: [try item("c_side", in: dir), try item("d_next", in: dir), try item("e_before", in: dir)],
                                   labels: [:], store: NetLabelStore(projectDir: dir), footage: footage,
                                   aiProposals: ["c_side": ai], exclusions: ["e_before": Self.exclusion()], exclusionStore: exclusionStore) { v, _ in recorded.append(v) }
        XCTAssertEqual(model.items.first { $0.video == "e_before" }?.skip, .sideView, "an exclusion on file is a skip when the tab loads")
        model.select("c_side")
        await settle()
        XCTAssertNotNil(model.frame)
        // Something else wrote an exclusion after the tab loaded: it must survive this one.
        try exclusionStore.save(["z_later": Self.exclusion("fp-z")])
        model.excludeSideView()
        let onFile = try exclusionStore.load()
        XCTAssertEqual(onFile["c_side"]?.reason, .sideView)
        XCTAssertEqual(onFile["c_side"]?.fingerprint, "fp-a")
        XCTAssertNotNil(onFile["z_later"], "an exclusion written since the tab loaded is kept")
        let side = try XCTUnwrap(model.items.first { $0.video == "c_side" })
        XCTAssertEqual(side.skip, .sideView)
        XCTAssertNil(model.offeredAI(side), "no proposal on an excluded recording")
        XCTAssertNil(model.frame); XCTAssertNil(model.quad); XCTAssertFalse(model.canConfirm)
        XCTAssertFalse(model.confirm())
        XCTAssertTrue(model.status.contains("excluded as a side view"), model.status)
        let reads = footage.frameCalls.count
        model.select("c_side")
        await settle()
        XCTAssertEqual(footage.frameCalls.count, reads, "an excluded recording isn't read again")
        XCTAssertEqual(model.toLabelCount, 1, "only d_next is still to label")

        model.includeAgain()
        await settle()
        XCTAssertNil(try exclusionStore.load()["c_side"])
        XCTAssertNotNil(try exclusionStore.load()["z_later"])
        XCTAssertNil(model.items.first { $0.video == "c_side" }?.skip)
        XCTAssertNotNil(model.frame, "back to label: its frame is shown again")
        XCTAssertEqual(model.toLabelCount, 2)
    }
}
