//
//  ReservationAndExposureTests.swift
//  RallyLabTests
//
//  The final-test reservation must fail closed, and exposure must be
//  recorded from every artefact kind and from the append-only log.
//

import XCTest
@testable import RallyLab

final class ReservationAndExposureTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeValidation(_ text: String) throws {
        try text.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
    }

    // MARK: - Reservations fail closed

    func testMissingValidationFileMeansNoReservations() throws {
        XCTAssertEqual(try PipelineTuner.ValidationSet.finalTestNames(in: root), [])
        XCTAssertNil(try PipelineTuner.ValidationSet.loadStrict(from: root))
    }

    func testLegacyValidationFileWithoutFinalTestMeansNoReservations() throws {
        try writeValidation(#"{"tune":["a"],"holdout":["b"]}"#)
        XCTAssertEqual(try PipelineTuner.ValidationSet.finalTestNames(in: root), [])
    }

    func testFinalTestNamesAreReturned() throws {
        try writeValidation(#"{"tune":["a"],"holdout":["b"],"finalTest":["z","y"]}"#)
        XCTAssertEqual(try PipelineTuner.ValidationSet.finalTestNames(in: root), ["y", "z"])
    }

    func testUnreadableValidationFileThrowsInsteadOfEmptying() throws {
        try writeValidation(#"{"tune":["a"],"holdout":["b"],"finalTest":["z"]"#)   // truncated
        XCTAssertThrowsError(try PipelineTuner.ValidationSet.finalTestNames(in: root)) { error in
            XCTAssertTrue(error is PipelineTuner.ValidationSet.ReservationError)
        }
        XCTAssertThrowsError(try PipelineTuner.ValidationSet.loadStrict(from: root))
        // The lenient loader used by older code paths still returns nil; nothing must treat that as "none".
        XCTAssertNil(PipelineTuner.ValidationSet.load(from: root))
    }

    // MARK: - Exposure discovery

    func testExposureIsFoundInScoresWindowsManifestCsvLogAndSeed() throws {
        let fm = FileManager.default
        // scores/<export>/scores.json
        let scores = root.appendingPathComponent("scores/Export-A")
        try fm.createDirectory(at: scores, withIntermediateDirectories: true)
        try #"{"clips":{"v_scored":{"f1":[0.9]}}}"#.write(to: scores.appendingPathComponent("scores.json"), atomically: true, encoding: .utf8)
        // exports/<multi-frame folder>/windows.jsonl
        let mf = root.appendingPathComponent("exports/Pkg-MF")
        try fm.createDirectory(at: mf, withIntermediateDirectories: true)
        try "{\"clip\":\"v_mf\",\"split\":\"train\"}\n{\"clip\":\"v_mf\",\"split\":\"train\"}\n".write(to: mf.appendingPathComponent("windows.jsonl"), atomically: true, encoding: .utf8)
        // exports/<yolo folder>/manifest.csv
        let yolo = root.appendingPathComponent("exports/Pkg-YOLO")
        try fm.createDirectory(at: yolo, withIntermediateDirectories: true)
        try "image,clip,split,source,time,boxes\na.jpg,v_yolo,val,rally:0,1.000,1\nb.jpg,v_yolo,val,rally:0,2.000,0\n".write(to: yolo.appendingPathComponent("manifest.csv"), atomically: true, encoding: .utf8)
        // exposure-log.json via the API, and a hand-written seed
        try ExposureLog.record(videos: ["v_logged"], kind: .pipelineTune, ref: "report-1.md", note: nil, in: root)
        try fm.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try #"[{"video":"v_seed","kind":"training_package","ref":"Old.zip","date":"2026-10-17","note":"from zip"}]"#
            .write(to: ExposureLog.seedURL(in: root), atomically: true, encoding: .utf8)

        let found = try DatasetSplitManifest.discoverExposure(in: root)
        XCTAssertEqual(found["v_scored"]?.map(\.kind), [.testSetScoring])
        XCTAssertEqual(found["v_scored"]?.first?.ref, "Export-A")
        XCTAssertEqual(found["v_mf"]?.map(\.kind), [.trainingPackage])
        XCTAssertEqual(found["v_yolo"]?.map(\.kind), [.trainingPackage])
        XCTAssertEqual(found["v_yolo"]?.first?.note, "manifest.csv split=val")
        XCTAssertEqual(found["v_logged"]?.map(\.kind), [.pipelineTune])
        XCTAssertEqual(found["v_seed"]?.first?.ref, "Old.zip")
    }

    func testExposureLogAppendsWithoutDuplicates() throws {
        try ExposureLog.record(videos: ["a", "b"], kind: .trainingPackage, ref: "P1", note: nil, in: root)
        try ExposureLog.record(videos: ["b", "c"], kind: .trainingPackage, ref: "P1", note: nil, in: root)
        try ExposureLog.record(videos: ["a"], kind: .testSetScoring, ref: "S1", note: nil, in: root)
        let rows = ExposureLog.read(in: root)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.filter { $0.video == "b" }.count, 1)
        XCTAssertEqual(Set(rows.filter { $0.video == "a" }.map(\.kind)), [.trainingPackage, .testSetScoring])
    }

    func testUnreadableExposureLogIsNeverOverwrittenAndFailsDiscovery() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        let log = ExposureLog.url(in: root)
        try "[{\"video\":\"old\",\"kind\":\"training_package\",\"ref\":\"P0\"".write(to: log, atomically: true, encoding: .utf8)   // truncated
        let before = try String(contentsOf: log, encoding: .utf8)
        try ExposureLog.record(videos: ["new"], kind: .testSetScoring, ref: "S1", note: nil, in: root)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), before, "a damaged log is left untouched")
        let parked = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("manifests").path)
            .filter { $0.hasPrefix("exposure-log.unmerged-") }
        XCTAssertEqual(parked.count, 1, "the new use is parked beside it")
        XCTAssertThrowsError(try ExposureLog.readStrict(in: root))
        XCTAssertThrowsError(try DatasetSplitManifest.discoverExposure(in: root), "history unknown → the manifest must not be built")
    }

    func testParkedSidecarsAreDiscoveredAndFoldedBackOnceTheLogIsRepaired() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        let log = ExposureLog.url(in: root)
        try "{broken".write(to: log, atomically: true, encoding: .utf8)
        try ExposureLog.record(videos: ["parked"], kind: .rallyScoring, ref: "R1", note: nil, in: root)
        XCTAssertEqual(ExposureLog.sidecarURLs(in: root).count, 1)
        // Repair the log: discovery must now see the parked use, and the next record folds it in.
        try "[]".write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(try DatasetSplitManifest.discoverExposure(in: root)["parked"]?.map(\.kind), [.rallyScoring])
        try ExposureLog.record(videos: ["later"], kind: .testSetScoring, ref: "S1", note: nil, in: root)
        XCTAssertEqual(ExposureLog.sidecarURLs(in: root).count, 0, "sidecar merged and removed")
        XCTAssertEqual(Set(try ExposureLog.readStrict(in: root).map(\.video)), ["parked", "later"])
    }

    func testUnreadablePreviousManifestIsRefusedNotOverwritten() throws {
        let file = root.appendingPathComponent("manifest.json")
        try "{\"schemaVersion\":1,".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DatasetSplitManifest.readStrict(from: file))
        XCTAssertNil(try DatasetSplitManifest.readStrict(from: root.appendingPathComponent("absent.json")), "absence is not an error")
    }

    func testParkedSidecarsNeverCollideWithinOneSecond() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try "{broken".write(to: ExposureLog.url(in: root), atomically: true, encoding: .utf8)
        let now = Date()
        try ExposureLog.record(videos: ["a"], kind: .pipelineTune, ref: "report-1.md", note: nil, in: root, now: now)
        try ExposureLog.record(videos: ["b"], kind: .pipelineHoldout, ref: "report-1.md", note: nil, in: root, now: now)
        XCTAssertEqual(ExposureLog.sidecarURLs(in: root).count, 2, "same-second records get their own sidecars")
        try "[]".write(to: ExposureLog.url(in: root), atomically: true, encoding: .utf8)
        XCTAssertEqual(Set(try ExposureLog.readStrict(in: root).map(\.video)), ["a", "b"])
    }

    func testRenameCarriesLogHistoryToTheNewName() throws {
        try ExposureLog.record(videos: ["old_name"], kind: .trainingPackage, ref: "P1", note: nil, in: root)
        try ExposureLog.record(videos: ["old_name"], kind: .testSetScoring, ref: "S1", note: nil, in: root)
        try ExposureLog.rename("old_name", to: "new_name", in: root)
        let rows = try ExposureLog.readStrict(in: root)
        XCTAssertEqual(Set(rows.filter { $0.video == "new_name" }.map(\.kind)), [.trainingPackage, .testSetScoring])
        XCTAssertEqual(rows.filter { $0.video == "old_name" }.count, 2, "old rows stay for older manifests")
        XCTAssertTrue(rows.first { $0.video == "new_name" }!.note!.contains("carried from old_name"))
    }

    func testRenameCarriesSeedHistoryToo() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try #"[{"video":"old_name","kind":"training_package","ref":"Old.zip","date":"2026-10-17","note":"from zip"}]"#
            .write(to: ExposureLog.seedURL(in: root), atomically: true, encoding: .utf8)
        try ExposureLog.rename("old_name", to: "new_name", in: root)
        XCTAssertEqual(try DatasetSplitManifest.discoverExposure(in: root)["new_name"]?.map(\.ref), ["Old.zip"])
    }

    func testPreviousManifestExposureFollowsTheFingerprintAcrossARename() throws {
        // bch_a_v3 was scored under that name; it is then moved and becomes ind_moved with the same fingerprint.
        let before = try DatasetSplitManifest.build(DatasetSplitManifestTests.inputs(discovered: [
            "bch_a_v3": [ExposureRecord(kind: .testSetScoring, ref: "S1", date: nil, note: nil)],
        ]))
        let F = DatasetSplitManifestTests.self
        var inputs = F.inputs(previous: before)
        inputs.project?.clips[0].videos.removeAll { $0.videoId == "bch_a_v3" }
        inputs.project?.clips.append(F.clip("ind_moved", environment: "Indoor", split: "val",
                                            videos: [F.source("ind_moved", fingerprint: "youtube:A3")]))
        inputs.sessions = inputs.sessions.filter { $0.name != "bch_a_v3" } + [F.session("ind_moved", split: "val")]
        let after = try DatasetSplitManifest.build(inputs)
        let moved = after.videos.first { $0.video == "ind_moved" }!
        XCTAssertEqual(moved.exposure.map(\.kind), [.testSetScoring], "history followed the fingerprint")
        // And it can therefore not be reserved.
        inputs.validation = PipelineTuner.ValidationSet(tune: [], holdout: [], finalTest: ["ind_moved"])
        XCTAssertThrowsError(try DatasetSplitManifest.build(inputs))
    }

    func testRecordThrowsWhenTheLogCannotBeWritten() throws {
        // A file where the manifests/ folder should be: nothing under it can be created.
        try "x".write(to: root.appendingPathComponent("manifests"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ExposureLog.record(videos: ["a"], kind: .rallyScoring, ref: "R", note: nil, in: root)) { error in
            guard case ExposureLog.LogError.notWritten = error else { return XCTFail("\(error)") }
        }
    }

    func testRenameThrowsWhenHistoryIsUnreadable() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try "{broken".write(to: ExposureLog.url(in: root), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ExposureLog.rename("old", to: "new", in: root))
    }

    func testReservedVideoIsRecognisedByPathNameAndContent() throws {
        let fm = FileManager.default
        let footage = root.appendingPathComponent("footage"); try fm.createDirectory(at: footage, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let video = footage.appendingPathComponent("grs_extra_self_06.mp4")
        try Data((0..<5000).map { UInt8($0 % 251) }).write(to: video)
        let print = try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: video.path))
        // Session + project card for it; reserved in validation.json.
        let session = DatasetSplitManifestTests.session("grs_extra_self_06", split: "val")
        var s = session; s = VideoSession(name: s.name, sourcePath: video.path, split: s.split, addedAt: s.addedAt, frames: [])
        try DatasetStore(root: root).save(s)
        let clip = DatasetSplitManifestTests.clip("grs_extra_self_06", environment: "Grass", split: "val",
                                                  videos: [DatasetSplitManifestTests.source(nil, fingerprint: print)])
        var source = clip.videos[0]; source.clipFile = video.path
        let project = Project(name: "T", createdAt: DatasetSplitManifestTests.day, framesPerRally: 40,
                              clips: [DatasetSplitManifestTests.clip("grs_extra_self_06", environment: "Grass", split: "val", videos: [source])])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(project).write(to: root.appendingPathComponent("project.json"))
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["grs_extra_self_06"]}"#)

        XCTAssertEqual(try ReservedVideos.match(video, root: root), .init(session: "grs_extra_self_06", reserved: true), "by path")
        let renamed = root.appendingPathComponent("somewhere else.mp4"); try fm.copyItem(at: video, to: renamed)
        XCTAssertEqual(try ReservedVideos.match(renamed, root: root), .init(session: "grs_extra_self_06", reserved: true), "a copy under another name, by content")
        let other = root.appendingPathComponent("other.mp4"); try Data([1, 2, 3]).write(to: other)
        XCTAssertNil(try ReservedVideos.match(other, root: root), "a file that is not a project video")
    }

    func testLoggedExposureBlocksFinalTestReservation() throws {
        try ExposureLog.record(videos: ["bch_a_v3"], kind: .trainingPackage, ref: "P1", note: nil, in: root)
        var inputs = DatasetSplitManifestTests.inputs(validation: PipelineTuner.ValidationSet(tune: [], holdout: [], finalTest: ["bch_a_v3"]))
        inputs.discovered = try DatasetSplitManifest.discoverExposure(in: root)
        XCTAssertThrowsError(try DatasetSplitManifest.build(inputs))
    }
}
