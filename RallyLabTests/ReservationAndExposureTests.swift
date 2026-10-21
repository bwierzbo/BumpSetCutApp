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

    func testAliasesOfAReservedRecordingAreReservedToo() throws {
        let F = DatasetSplitManifestTests.self
        // Two sessions, one file (same fingerprint); a third shares a confirmed venue; a fourth is unrelated.
        let project = Project(name: "T", createdAt: F.day, framesPerRally: 40, clips: [
            F.clip("bch_a", split: "val", videos: [F.source("bch_a", fingerprint: "youtube:SAME", venueId: "venue-1")]),
            F.clip("bch_copy", split: "train", videos: [F.source("bch_copy", fingerprint: "youtube:SAME")]),
            F.clip("bch_same_venue", split: "train", videos: [F.source("bch_same_venue", fingerprint: "youtube:OTHER", venueId: "venue-1")]),
            F.clip("grs_other", split: "train", videos: [F.source("grs_other", fingerprint: "youtube:X")]),
        ])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(project).write(to: root.appendingPathComponent("project.json"))
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["bch_a"]}"#)
        XCTAssertEqual(try ReservedVideos.reservedNames(in: root), ["bch_a", "bch_copy", "bch_same_venue"])
        XCTAssertEqual(try PipelineTuner.ValidationSet.finalTestNames(in: root), ["bch_a", "bch_copy", "bch_same_venue"],
                       "every package/score/tune/pre-track filter sees the aliases")
    }

    func testLegacySourceWithoutStoredFingerprintStillAliases() throws {
        let F = DatasetSplitManifestTests.self
        // The reserved video is an older record: no stored fingerprint, only its origin link.
        var legacy = F.source("bch_old", fingerprint: nil); legacy.origin = "https://youtu.be/SAME"
        let copy = F.source("bch_copy", fingerprint: "youtube:SAME")
        let project = Project(name: "T", createdAt: F.day, framesPerRally: 40, clips: [
            F.clip("bch_old", split: "val", videos: [legacy]),
            F.clip("bch_copy", split: "train", videos: [copy]),
        ])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(project).write(to: root.appendingPathComponent("project.json"))
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["bch_old"]}"#)
        XCTAssertEqual(try ReservedVideos.reservedNames(in: root), ["bch_old", "bch_copy"])
    }

    func testReservationClosureFollowsIdentityChains() throws {
        let F = DatasetSplitManifestTests.self
        // A ~file~ B ~venue~ C ~session~ D; E unrelated. Reserving A must reserve B, C and D.
        let sources: [String: ClipSource] = [
            "A": F.source("A", fingerprint: "youtube:AB"),
            "B": F.source("B", fingerprint: "youtube:AB", venueId: "venue-1"),
            "C": F.source("C", fingerprint: "youtube:C", sessionId: "sess-cd", venueId: "venue-1"),
            "D": F.source("D", fingerprint: "youtube:D", sessionId: "sess-cd"),
            "E": F.source("E", fingerprint: "youtube:E"),
        ]
        XCTAssertEqual(ReservedVideos.closure(of: ["A"], over: sources), ["A", "B", "C", "D"])
        XCTAssertEqual(ReservedVideos.closure(of: ["E"], over: sources), ["E"])
    }

    func testCandidatesAreProtectedLikeFinalTestButKeptApartInTheManifest() throws {
        let F = DatasetSplitManifestTests.self
        let project = Project(name: "T", createdAt: F.day, framesPerRally: 40, clips: [
            F.clip("bch_a", split: "val", videos: [F.source("bch_a", fingerprint: "youtube:A")]),
            F.clip("bch_c", split: "val", videos: [F.source("bch_c", fingerprint: "youtube:C")]),
            F.clip("bch_c_copy", split: "train", videos: [F.source("bch_c_copy", fingerprint: "youtube:C")]),
        ])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(project).write(to: root.appendingPathComponent("project.json"))
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["bch_a"],"finalTestCandidates":["bch_c"]}"#)
        XCTAssertEqual(try PipelineTuner.ValidationSet.finalTestNames(in: root), ["bch_a", "bch_c", "bch_c_copy"], "candidates and their aliases are protected everywhere")
        let set = try XCTUnwrap(try PipelineTuner.ValidationSet.loadStrict(from: root))
        let (finalTest, lineage, candidates) = ReservedVideos.expanded(set, sources: ReservedVideos.sources(in: root))
        XCTAssertEqual(finalTest, ["bch_a"])
        XCTAssertEqual(lineage, [])
        XCTAssertEqual(candidates, ["bch_c", "bch_c_copy"], "a candidate's alias is a candidate, not final test")
    }

    func testLineageHoldoutIsReservedWithItsAliasesAndOutranksCandidates() throws {
        let F = DatasetSplitManifestTests.self
        let project = Project(name: "T", createdAt: F.day, framesPerRally: 40, clips: [
            F.clip("bch_l", split: "val", videos: [F.source("bch_l", fingerprint: "file:L", sessionId: "2026-10-03", venueId: "beach-x")]),
            F.clip("bch_n", split: "train", videos: [F.source("bch_n", fingerprint: "file:N", sessionId: "2026-10-03", venueId: "beach-x")]),
            F.clip("bch_c", split: "val", videos: [F.source("bch_c", fingerprint: "file:C")]),
            F.clip("bch_t", split: "train", videos: [F.source("bch_t", fingerprint: "file:T")]),
        ])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(project).write(to: root.appendingPathComponent("project.json"))
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":[],"finalTestCandidates":["bch_c","bch_l"],"lineageHoldout":["bch_l"]}"#)
        XCTAssertEqual(try PipelineTuner.ValidationSet.finalTestNames(in: root), ["bch_c", "bch_l", "bch_n"],
                       "the lineage holdout and its same-session alias are protected everywhere packages, scoring, tuning and pre-tracking look")
        let set = try XCTUnwrap(try PipelineTuner.ValidationSet.loadStrict(from: root))
        let (finalTest, lineage, candidates) = ReservedVideos.expanded(set, sources: ReservedVideos.sources(in: root))
        XCTAssertEqual(finalTest, [])
        XCTAssertEqual(lineage, ["bch_l", "bch_n"], "an alias of a lineage-holdout video is lineage holdout")
        XCTAssertEqual(candidates, ["bch_c"], "a name listed in both is lineage holdout, not a candidate")
    }

    func testOlderValidationFilesWithoutLineageHoldoutStillDecode() throws {
        try writeValidation(#"{"tune":["a"],"holdout":["b"],"finalTest":[],"finalTestCandidates":["c"]}"#)
        let set = try XCTUnwrap(try PipelineTuner.ValidationSet.loadStrict(from: root))
        XCTAssertEqual(set.lineageHoldout, [])
        XCTAssertEqual(set.reservedAsListed, ["c"])
    }

    func testPreLoggingUsesAreDiscoveredFromMachineTracksAndEvidenceCache() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("pipeline_tuning/evidence"), withIntermediateDirectories: true)
        // A session whose only trace of use is a machine track written by a pre-tracking model.
        let session = #"{"name":"grs_x","sourcePath":"/f/grs_x.mov","split":"val","addedAt":"2026-10-17T07:11:52Z","frames":[],"tracks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":1.0,"end":5.0,"points":[],"done":true,"isRally":true,"machine":true,"updatedAt":"2026-10-18T05:39:44Z","candidates":[]}]}"#
        try session.write(to: root.appendingPathComponent("sessions/grs_x.json"), atomically: true, encoding: .utf8)
        // Cached detection passes from a tuner round; one session name itself contains "__".
        try "x".write(to: root.appendingPathComponent("pipeline_tuning/evidence/bch_y__02c961372a94.evidence"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("pipeline_tuning/evidence/ind_a__b__1d7253e72acc.evidence"), atomically: true, encoding: .utf8)
        let found = try DatasetSplitManifest.discoverExposure(in: root)
        XCTAssertEqual(found["grs_x"]?.map(\.kind), [.preTracking])
        XCTAssertEqual(found["grs_x"]?.first?.date, "2026-10-18")
        XCTAssertEqual(found["bch_y"]?.map(\.kind), [.rallyScoring])
        XCTAssertEqual(found["ind_a__b"]?.map(\.kind), [.rallyScoring], "split at the last separator")
        XCTAssertNil(found["ind_a"])
    }

    func testYouTubeSourceIdPlanIsDeterministicAndConservative() throws {
        let F = DatasetSplitManifestTests.self
        var good = F.source("v_good", fingerprint: "youtube:abc123DEF45"); good.origin = "https://www.youtube.com/watch?v=abc123DEF45"
        var shorts = F.source("v_shorts", fingerprint: "youtube:zzz999ZZZ99"); shorts.origin = "https://youtube.com/shorts/zzz999ZZZ99?si=x"
        var mismatch = F.source("v_mismatch", fingerprint: "youtube:OTHER"); mismatch.origin = "https://youtu.be/abc123DEF45"
        var vimeo = F.source("v_vimeo", fingerprint: nil); vimeo.origin = "https://vimeo.com/12345"
        var done = F.source("v_done", fingerprint: "youtube:abc123DEF45", sourceId: "youtube:abc123DEF45"); done.origin = "https://youtu.be/abc123DEF45"
        var conflict = F.source("v_conflict", fingerprint: "youtube:abc123DEF45", sourceId: "src-manual"); conflict.origin = "https://youtu.be/abc123DEF45"
        var local = F.source("v_local", fingerprint: "file:aa"); local.kind = .file; local.origin = "/Users/x/own.mov"
        var nofp = F.source("v_nofp", fingerprint: nil); nofp.origin = "https://youtu.be/abc123DEF45"
        let all = ["v_good": good, "v_shorts": shorts, "v_mismatch": mismatch, "v_vimeo": vimeo, "v_done": done, "v_conflict": conflict, "v_local": local, "v_nofp": nofp]
        let plan = YouTubeSourceIDs.plan(sources: all)
        XCTAssertEqual(plan.proposals.map(\.video), ["v_good", "v_shorts"])
        XCTAssertEqual(plan.proposals.map(\.sourceId), ["youtube:abc123DEF45", "youtube:zzz999ZZZ99"])
        XCTAssertEqual(plan.alreadyConfirmed, ["v_done"])
        XCTAssertEqual(Set(plan.ambiguous.map(\.video)), ["v_mismatch", "v_vimeo", "v_conflict", "v_nofp"], "a link alone never confirms: a stored fingerprint must agree")
        XCTAssertEqual(plan, YouTubeSourceIDs.plan(sources: all), "deterministic")
    }

    func testUnlistableArtefactDirectoryFailsDiscovery() throws {
        // A file where pipeline_tuning/evidence should be: it exists but cannot be listed.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("pipeline_tuning/evidence"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DatasetSplitManifest.discoverExposure(in: root)) { error in
            guard case DatasetSplitManifest.DiscoveryError.unreadable = error else { return XCTFail("\(error)") }
        }
    }

    func testMalformedSessionFileFailsDiscovery() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try "{broken".write(to: root.appendingPathComponent("sessions/grs_bad.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DatasetSplitManifest.discoverExposure(in: root)) { error in
            guard case DatasetStore.LoadError.malformed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(DatasetStore(root: root).loadSessions().count, 0, "the lenient loader still skips it for the UI")
    }

    func testLoggedExposureBlocksFinalTestReservation() throws {
        try ExposureLog.record(videos: ["bch_a_v3"], kind: .trainingPackage, ref: "P1", note: nil, in: root)
        var inputs = DatasetSplitManifestTests.inputs(validation: PipelineTuner.ValidationSet(tune: [], holdout: [], finalTest: ["bch_a_v3"]))
        inputs.discovered = try DatasetSplitManifest.discoverExposure(in: root)
        XCTAssertThrowsError(try DatasetSplitManifest.build(inputs))
    }
}
