//
//  NetAIProposalsTests.swift
//  RallyLabTests
//
//  The AI-assisted net-corner pilot: which recordings it may take, that only
//  their frames are read, that the ledger row lands before a frame may be
//  shown and is refused for a withheld or changed one, that an import needs
//  that row and never touches a person's label, and that the tab offers a
//  proposal without running the old model, saves it only on Confirm with its
//  source, and drops it for good on Reject.
//

import CoreGraphics
import XCTest
@testable import RallyLab

extension NetLabelsTests {

    private static let aiCorners = NetQuad(topLeft: .init(x: 0.12, y: 0.62), topRight: .init(x: 0.9, y: 0.58),
                                           bottomRight: .init(x: 0.88, y: 0.41), bottomLeft: .init(x: 0.14, y: 0.44))

    private static func aiProposal(_ outcome: NetAIProposal.Outcome = .proposed, fingerprint: String = "fp-a", time: Double = 42,
                                   width: Int = 64, height: Int = 36) -> NetAIProposal {
        NetAIProposal(outcome: outcome, corners: outcome == .proposed ? aiCorners : nil, confidence: outcome == .proposed ? .uncertain : nil,
                      uncertainty: outcome == .proposed ? "right post behind a player" : "net out of frame",
                      time: time, frameWidth: width, frameHeight: height, imageSHA256: "sha", fingerprint: fingerprint,
                      model: "claude-test", run: "run-1", exposureRecordedAt: Date(timeIntervalSince1970: 1_800_000_000),
                      importedAt: Date(timeIntervalSince1970: 1_800_000_100))
    }

    private static func candidate(_ v: String, surface: String, group: String? = nil, camera: String = "Tripod / corner",
                                  fp: String? = "fp", file: String? = "fp") -> NetAIPilot.Candidate {
        NetAIPilot.Candidate(video: v, clip: v, camera: camera, surface: surface, aliasGroup: group,
                             url: URL(fileURLWithPath: "/nowhere/\(v).mp4"), fingerprint: fp, fileFingerprint: file)
    }

    // MARK: - Choosing and extracting

    func testPilotTakesEligibleRecordingsOnePerAliasGroupRoundRobinOverSurfaces() {
        let all = [
            Self.candidate("bch_a", surface: "beach", group: "bch_a"),
            Self.candidate("bch_a_v2", surface: "beach", group: "bch_a"),          // same net as bch_a
            Self.candidate("bch_b", surface: "beach"),
            Self.candidate("bch_c", surface: "beach"),
            Self.candidate("grs_a", surface: "grass"),
            Self.candidate("grs_held", surface: "grass"),                          // withheld
            Self.candidate("grs_hand", surface: "grass", camera: "Handheld / corner"),
            Self.candidate("ind_a", surface: "indoor", fp: nil, file: nil),        // unidentified
            Self.candidate("ind_b", surface: "indoor", file: "other"),             // the file is not the manifest's
            Self.candidate("ind_c", surface: "indoor"),
            Self.candidate("ind_lab", surface: "indoor"),                          // labeled
            Self.candidate("ind_box", surface: "indoor"),                          // box-only: still the person's
            Self.candidate("ind_ai", surface: "indoor"),                           // proposed already
        ]
        let chosen = NetAIPilot.choose(all, labels: ["ind_lab": Self.label(), "ind_box": Self.label(boxOnly: true)],
                                       proposals: ["ind_ai": Self.aiProposal()], withheld: ["grs_held"], count: 4)
        XCTAssertEqual(chosen.map(\.video), ["bch_a", "grs_a", "ind_c", "bch_b"])
        let every = NetAIPilot.choose(all, labels: ["ind_lab": Self.label(), "ind_box": Self.label(boxOnly: true)],
                                      proposals: ["ind_ai": Self.aiProposal()], withheld: ["grs_held"], count: .max)
        XCTAssertEqual(Set(every.map(\.video)), ["bch_a", "bch_b", "bch_c", "grs_a", "ind_c"])
    }

    func testPilotFramesReadOnlyTheChosenByTheTabsRuleWithTheirHashes() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        let out = dir.appendingPathComponent("pilot")
        let m = try await NetAIPilot.writeFrames([Self.candidate("bch_a", surface: "beach", fp: "fp-a")], footage: footage, project: "P",
                                                 run: "run-1", model: "claude-test", withheldCount: 21, eligibleCount: 9, to: out)
        XCTAssertEqual(footage.frameCalls.map(\.0), ["bch_a.mp4"])
        XCTAssertEqual(footage.frameCalls.map(\.1), [50], "the tab's rule: no marks → the middle")
        XCTAssertEqual(footage.proposalCalls, 0, "no model runs while extracting")
        let f = try XCTUnwrap(m.frames.first)
        XCTAssertEqual(f.fingerprint, "fp-a"); XCTAssertEqual(f.width, 64); XCTAssertEqual(f.height, 36)
        XCTAssertEqual(DatasetSplitManifest.sha256(of: out.appendingPathComponent(f.image)), f.imageSHA256)
        let back = try NetAIPilot.readManifest(in: out)   // dates are whole seconds on file
        XCTAssertEqual(back.frames, m.frames); XCTAssertEqual(back.run, m.run); XCTAssertEqual(back.model, m.model)
        XCTAssertEqual(back.createdAt.timeIntervalSince1970, m.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExposureLog.url(in: dir).path), "extracting writes no ledger row")
        do {
            _ = try await NetAIPilot.writeFrames([], footage: footage, project: "P", run: "r", model: "m", withheldCount: 0, eligibleCount: 0, to: out)
            XCTFail("an existing folder is never written into")
        } catch {}
    }

    /// A pilot folder with one frame, in a project folder of the test's own.
    private func pilot(_ dir: URL) async throws -> (NetAIPilot.Manifest, URL) {
        let out = dir.appendingPathComponent("pilot")
        let m = try await NetAIPilot.writeFrames([Self.candidate("bch_a", surface: "beach", fp: "fp-a")], footage: ScriptedFootage(), project: "P",
                                                 run: "run-1", model: "claude-test", withheldCount: 0, eligibleCount: 1, to: out)
        return (m, out)
    }

    func testExposureLandsBeforeAFrameMayBeShownAndIsRefusedForWithheldOrChangedFrames() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (m, out) = try await pilot(dir)
        let ok = NetInventory(withheld: [], fingerprint: ["bch_a": "fp-a"])
        // Withheld since — by the manifest's closure or by the files' — refused, no row.
        let cases: [(NetInventory, Set<String>)] = [(NetInventory(withheld: ["bch_a"], fingerprint: ["bch_a": "fp-a"]), []), (ok, ["bch_a"])]
        for (inv, files) in cases {
            XCTAssertThrowsError(try NetAIPilot.recordExposure("bch_a", manifest: m, dir: out, projectDir: dir, inventory: inv, fileWithheld: files)) {
                XCTAssertEqual($0 as? NetAIPilot.PilotError, .withheld("bch_a"))
            }
        }
        XCTAssertThrowsError(try NetAIPilot.recordExposure("bch_a", manifest: m, dir: out, projectDir: dir,
                                                           inventory: NetInventory(withheld: [], fingerprint: ["bch_a": "fp-b"]), fileWithheld: []))
        XCTAssertThrowsError(try NetAIPilot.recordExposure("bch_z", manifest: m, dir: out, projectDir: dir, inventory: ok, fileWithheld: []))
        XCTAssertEqual(try ExposureLog.readStrict(in: dir), [])

        let r = try NetAIPilot.recordExposure("bch_a", manifest: m, dir: out, projectDir: dir, inventory: ok, fileWithheld: [])
        let rows = try ExposureLog.readStrict(in: dir)
        XCTAssertEqual(rows.map(\.video), ["bch_a"])
        XCTAssertEqual(rows.first?.kind, .netProposal)
        XCTAssertEqual(rows.first?.ref, "run-1")
        XCTAssertTrue(rows.first?.note?.contains(m.frames[0].imageSHA256) == true)
        XCTAssertTrue(rows.first?.note?.contains("claude-test") == true)
        XCTAssertEqual(r.imageSHA256, m.frames[0].imageSHA256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: NetAIPilot.receiptURL("bch_a", in: out).path))

        // The image changed after it was written: refused.
        try Data("not the frame".utf8).write(to: out.appendingPathComponent(m.frames[0].image))
        XCTAssertThrowsError(try NetAIPilot.recordExposure("bch_a", manifest: m, dir: out, projectDir: dir, inventory: ok, fileWithheld: [])) {
            XCTAssertEqual($0 as? NetAIPilot.PilotError, .imageChanged("bch_a"))
        }
    }

    func testAnImportNeedsTheExposureOnRecordAndNeverTouchesALabel() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (m, out) = try await pilot(dir)
        let inv = NetInventory(withheld: [], fingerprint: ["bch_a": "fp-a"])
        let good = NetAIPilot.Submission(video: "bch_a", outcome: .proposed, corners: Self.aiCorners, confidence: .confident, uncertainty: nil)
        func run(_ subs: [NetAIPilot.Submission], labels: [String: NetLabel] = [:], existing: [String: NetAIProposal] = [:]) throws -> [String: NetAIProposal] {
            try NetAIPilot.importSubmissions(subs, manifest: m, dir: out, inventory: inv, fileWithheld: [], ledger: try ExposureLog.readStrict(in: dir),
                                             labels: labels, existing: existing, now: Date(timeIntervalSince1970: 1_800_000_500))
        }
        XCTAssertThrowsError(try run([good])) { XCTAssertEqual($0 as? NetAIPilot.PilotError, .noExposure("bch_a")) }
        let receipt = try NetAIPilot.recordExposure("bch_a", manifest: m, dir: out, projectDir: dir, inventory: inv, fileWithheld: [])

        XCTAssertThrowsError(try run([good], labels: ["bch_a": Self.label(boxOnly: true)])) { XCTAssertEqual($0 as? NetAIPilot.PilotError, .labeled("bch_a")) }
        XCTAssertThrowsError(try run([good, good])) { XCTAssertEqual($0 as? NetAIPilot.PilotError, .duplicate("bch_a")) }
        XCTAssertThrowsError(try run([good], existing: ["bch_a": Self.aiProposal()].mapValues { var p = $0; p.run = "run-0"; return p }))
        // Upside down (the tape below the mesh), outside the frame, without a confidence; a manual-review answer with corners.
        let flipped = NetQuad(topLeft: Self.aiCorners.bottomLeft, topRight: Self.aiCorners.bottomRight, bottomRight: Self.aiCorners.topRight, bottomLeft: Self.aiCorners.topLeft)
        for bad in [NetAIPilot.Submission(video: "bch_a", outcome: .proposed, corners: flipped, confidence: .confident, uncertainty: nil),
                    NetAIPilot.Submission(video: "bch_a", outcome: .proposed, corners: Self.aiCorners, confidence: nil, uncertainty: nil),
                    NetAIPilot.Submission(video: "bch_a", outcome: .needsManualReview, corners: Self.aiCorners, confidence: nil, uncertainty: "x"),
                    NetAIPilot.Submission(video: "bch_a", outcome: .needsManualReview, corners: nil, confidence: nil, uncertainty: nil)] {
            XCTAssertThrowsError(try run([bad])) { XCTAssertEqual($0 as? NetAIPilot.PilotError, .badCorners("bch_a")) }
        }
        var outside = Self.aiCorners; outside.topRight.x = 1.2
        XCTAssertThrowsError(try run([NetAIPilot.Submission(video: "bch_a", outcome: .proposed, corners: outside, confidence: .confident, uncertainty: nil)]))

        let merged = try run([good])
        let p = try XCTUnwrap(merged["bch_a"])
        XCTAssertEqual(p.corners, Self.aiCorners)
        XCTAssertEqual(p.time, m.frames[0].time); XCTAssertEqual(p.frameWidth, 64)
        XCTAssertEqual(p.imageSHA256, m.frames[0].imageSHA256); XCTAssertEqual(p.fingerprint, "fp-a")
        XCTAssertEqual(p.model, "claude-test"); XCTAssertEqual(p.run, "run-1")
        XCTAssertEqual(p.exposureRecordedAt.timeIntervalSince1970, receipt.recordedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(p.rejectedAt)
        let store = NetAIProposalStore(projectDir: dir)
        try store.save(merged)
        XCTAssertEqual(try store.load(), merged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: NetLabelStore(projectDir: dir).url.path), "net-labels.json is never written")
        try Data("{oops".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load(), "an unreadable proposals file is an error, never empty")
    }

    // MARK: - The tab

    @MainActor
    func testTheTabShowsTheAIProposalOnItsFrameWithoutTheOldModelAndSavesItOnlyOnConfirm() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        let store = NetLabelStore(projectDir: dir)
        var recorded: [String] = []
        let ai = Self.aiProposal()
        let model = NetLabelsModel(items: [try item("c_ok", in: dir), try item("d_next", in: dir)], labels: [:], store: store, footage: footage,
                                   aiProposals: ["c_ok": ai]) { v, _ in recorded.append(v) }
        XCTAssertEqual(model.offeredAI(try XCTUnwrap(model.items.first)), ai)
        model.select("c_ok")
        await settle()
        XCTAssertEqual(model.frameTime, 42, "the frame the model saw")
        XCTAssertEqual(model.quad, Self.aiCorners)
        XCTAssertEqual(model.shownAI, ai)
        XCTAssertTrue(model.proposed); XCTAssertFalse(model.adjusted)
        XCTAssertEqual(footage.proposalCalls, 0, "the old model doesn't run on a recording with a vision proposal")
        XCTAssertTrue(recorded.isEmpty, "its use is the vision model's row, already on file")
        XCTAssertTrue(model.status.contains("not a label until you confirm"), model.status)
        XCTAssertEqual(try store.load(), [:], "nothing is a label before Confirm")

        // The person moves the right tape end, then confirms: a label that says where it started.
        let moved = Self.aiCorners.moving(corner: 1, to: CGPoint(x: 0.91, y: 0.6))
        model.setQuad(moved)
        model.useProposal()
        XCTAssertEqual(model.quad, Self.aiCorners, "back to the proposal")
        model.setQuad(moved)
        XCTAssertTrue(model.confirm())
        let saved = try XCTUnwrap(try store.load()["c_ok"])
        XCTAssertEqual(saved.corners, moved)
        XCTAssertEqual(saved.time, 42)
        XCTAssertTrue(saved.proposed); XCTAssertTrue(saved.adjusted)
        XCTAssertEqual(saved.proposalSource, "claude-test · run-1")
        XCTAssertEqual(saved.fingerprint, "fp-a")
        XCTAssertNil(model.offeredAI(try XCTUnwrap(model.items.first)), "labeled: no longer offered")

        // The next one has no vision proposal: the old model's, as before, and its source says so.
        await settle()
        XCTAssertEqual(model.selected, "d_next")
        XCTAssertEqual(footage.proposalCalls, 1)
        XCTAssertEqual(recorded, ["d_next"])
        XCTAssertTrue(model.confirm())
        XCTAssertEqual(try store.load()["d_next"]?.proposalSource, NetLabels.oldModelSource)
    }

    @MainActor
    func testRejectingAnAIProposalMarksItOnFileAndFallsBackToTheOldModel() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        let aiStore = NetAIProposalStore(projectDir: dir)
        try aiStore.save(["c_ok": Self.aiProposal()])
        var recorded: [String] = []
        let model = NetLabelsModel(items: [try item("c_ok", in: dir)], labels: [:], store: NetLabelStore(projectDir: dir), footage: footage,
                                   aiProposals: try aiStore.load(), aiStore: aiStore) { v, _ in recorded.append(v) }
        model.select("c_ok")
        await settle()
        XCTAssertNotNil(model.shownAI)
        model.rejectAIProposal()
        XCTAssertNil(model.shownAI)
        XCTAssertNotNil(try aiStore.load()["c_ok"]?.rejectedAt, "kept on file, marked rejected")
        XCTAssertEqual(recorded, ["c_ok"]); XCTAssertEqual(footage.proposalCalls, 1, "the ordinary path: the old model's box, its row first")
        XCTAssertEqual(model.quad, NetQuad(rect: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1)))
        XCTAssertTrue(model.status.contains("rejected"), model.status)
        model.select("c_ok")
        await settle()
        XCTAssertNil(model.shownAI, "a rejected proposal is not offered again")
        XCTAssertEqual(model.frameTime, 50)
    }

    @MainActor
    func testNoAIProposalOnASkippedLabeledBoxOnlyOrOtherRecordingOrAnotherFrame() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let footage = ScriptedFootage()
        var recorded: [String] = []
        let model = NetLabelsModel(items: [try item("a_withheld", skip: .withheld, in: dir), try item("b_boxonly", in: dir), try item("c_labeled", in: dir),
                                           try item("d_otherfile", fingerprint: "fp-new", in: dir), try item("e_size", in: dir), try item("f_manual", in: dir)],
                                   labels: ["b_boxonly": Self.label(time: 7, boxOnly: true), "c_labeled": Self.label(time: 3)],
                                   store: NetLabelStore(projectDir: dir), footage: footage,
                                   aiProposals: ["a_withheld": Self.aiProposal(), "b_boxonly": Self.aiProposal(), "c_labeled": Self.aiProposal(),
                                                 "d_otherfile": Self.aiProposal(fingerprint: "fp-old"), "e_size": Self.aiProposal(width: 1920, height: 1080),
                                                 "f_manual": Self.aiProposal(.needsManualReview)]) { v, _ in recorded.append(v) }
        for v in ["a_withheld", "b_boxonly", "c_labeled", "d_otherfile"] {
            XCTAssertNil(model.offeredAI(try XCTUnwrap(model.items.first { $0.video == v })), v)
        }
        model.select("a_withheld")
        await settle()
        XCTAssertTrue(footage.frameCalls.isEmpty, "a withheld recording is never opened, proposal or not")
        model.select("b_boxonly")
        await settle()
        XCTAssertEqual(model.quad, NetQuad(rect: Self.box.rect), "the person's box-only label seeds the corners, not the proposal")
        XCTAssertEqual(model.frameTime, 7)
        // A proposal made on a frame of another size is not this frame's: the old model's box instead.
        model.select("e_size")
        await settle()
        XCTAssertNil(model.shownAI)
        XCTAssertTrue(model.status.contains("another frame"), model.status)
        XCTAssertEqual(model.quad, NetQuad(rect: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1)))
        // The model couldn't place the net: it says why, and the ordinary path follows.
        model.select("f_manual")
        await settle()
        XCTAssertNil(model.shownAI)
        XCTAssertTrue(model.status.contains("could not place the net"), model.status)
        XCTAssertTrue(model.status.contains("net out of frame"), model.status)
        XCTAssertEqual(recorded, ["e_size", "f_manual"])
    }
}
