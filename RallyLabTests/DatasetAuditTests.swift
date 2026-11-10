//
//  DatasetAuditTests.swift
//  RallyLabTests
//

import XCTest
@testable import RallyLab

final class DatasetAuditTests: XCTestCase {

    private typealias F = DatasetSplitManifestTests

    private func audit(_ inputs: DatasetSplitManifest.Inputs) throws -> DatasetAudit {
        DatasetAudit.run(manifest: try DatasetSplitManifest.build(inputs), now: F.day)
    }

    private func codes(_ a: DatasetAudit, _ severity: DatasetAudit.Severity) -> [String] {
        a.findings.filter { $0.severity == severity }.map(\.code)
    }

    func testCardOverlapIsSoftNeverHard() throws {
        let a = try audit(F.inputs())
        // grs_c is an auto card with videos on both sides of train, bch_a spans tune + legacy_holdout
        // + dev_val: a card is not confirmed identity (D-009), so both are soft and nothing is hard.
        XCTAssertFalse(a.hasHardLeak)
        let cards = a.findings.filter { $0.code == "CARD-SPLIT" }
        XCTAssertEqual(Set(cards.map { $0.videos.first ?? "" }), ["bch_a", "grs_c"])
        XCTAssertTrue(cards.allSatisfy { $0.severity == .soft })
        XCTAssertTrue(codes(a, .soft).contains("CARD-AUTO"))
    }

    func testCutRangesAreReportedAndAnUnreadableOneIsHard() throws {
        var inputs = F.inputs()
        inputs.sessions = inputs.sessions.map { s in
            var s = s
            if s.name == "bch_b" { s.cuts = [CutRange(start: 141.6, end: 157.0)] }
            if s.name == "grs_c" { s.cuts = [CutRange(start: 0, end: 12.4), CutRange(start: 20, end: 25)] }
            return s
        }
        let a = try audit(inputs)
        let info = try XCTUnwrap(a.findings.first { $0.code == "CUT-RANGES" })
        XCTAssertEqual(info.severity, .info)
        XCTAssertEqual(info.videos, ["bch_b", "grs_c"])
        XCTAssertTrue(info.message.contains("32.8 s"), info.message)
        XCTAssertFalse(codes(a, .hard).contains("CUT-RANGE-INVALID"))

        inputs.sessions = inputs.sessions.map { s in
            var s = s
            if s.name == "bch_b" { s.cuts = [CutRange(start: 30, end: 28)] }
            return s
        }
        let bad = try audit(inputs)
        let hard = try XCTUnwrap(bad.findings.first { $0.code == "CUT-RANGE-INVALID" })
        XCTAssertEqual(hard.severity, .hard)
        XCTAssertEqual(hard.videos, ["bch_b"])
        XCTAssertTrue(bad.hasHardLeak)
        XCTAssertEqual(try XCTUnwrap(bad.findings.first { $0.code == "CUT-RANGES" }).videos, ["bch_b", "grs_c"], "still listed, so the owner sees it")
    }

    func testCleanDatasetHasNoHardFindings() throws {
        // Pin grs_c to train and keep bch_a's three videos together in dev_val.
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: [], holdout: []))
        inputs.sessions = inputs.sessions.map { s in
            s.name.hasPrefix("grs_c") ? F.session(s.name, split: "train") : s
        }
        inputs.project?.clips[2].split = "train"
        let a = try audit(inputs)
        XCTAssertFalse(a.hasHardLeak, codes(a, .hard).joined(separator: ","))
        XCTAssertFalse(codes(a, .soft).contains("CARD-AUTO"))
    }

    func testSharedFingerprintAcrossTrainAndValIsHard() throws {
        let extra = F.clip("ind_dup", environment: "Indoor", split: "train",
                           videos: [F.source("ind_dup", uploader: "Z", fingerprint: "youtube:A1")]) // same file as bch_a (tune)
        let a = try audit(F.inputs(extraClips: [extra], extraSessions: [F.session("ind_dup", split: "train")]))
        let fp = a.findings.first { $0.code == "FP-SHARED" }
        XCTAssertEqual(fp?.severity, .hard)
        XCTAssertEqual(fp?.videos, ["bch_a", "ind_dup"])
    }

    func testConfirmedVenueAcrossSplitsIsHardButUploaderIsOnlySoft() throws {
        let v1 = F.clip("ind_v1", environment: "Indoor", split: "train",
                        videos: [F.source("ind_v1", uploader: "Gym", fingerprint: "y:1", venueId: "venue-gym")])
        let v2 = F.clip("ind_v2", environment: "Indoor", split: "val",
                        videos: [F.source("ind_v2", uploader: "Gym", fingerprint: "y:2", venueId: "venue-gym")])
        let a = try audit(F.inputs(extraClips: [v1, v2], extraSessions: [F.session("ind_v1", split: "train"), F.session("ind_v2", split: "val")]))
        XCTAssertEqual(a.findings.first { $0.code == "VENUE-SHARED" }?.severity, .hard)
        XCTAssertEqual(a.findings.first { $0.code == "UPLOADER-SPLIT" && $0.videos == ["ind_v1", "ind_v2"] }?.severity, .soft)
    }

    func testProvenIdentityAcrossDevValAndTuneIsHard() throws {
        // Same file in tune (bch_a) and dev_val (ind_dup): proven relationship, two evaluation splits → hard.
        let extra = F.clip("ind_dup", environment: "Indoor", split: "val",
                           videos: [F.source("ind_dup", uploader: "Z", fingerprint: "youtube:A1")])
        let a = try audit(F.inputs(validation: PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: []),
                                   extraClips: [extra], extraSessions: [F.session("ind_dup", split: "val")]))
        let fp = a.findings.first { $0.code == "FP-SHARED" }
        XCTAssertEqual(fp?.severity, .hard)
        XCTAssertTrue(a.hasHardLeak)
    }

    func testDevValVersusTuneOnOneCardIsSoftNotHard() throws {
        // bch_a card: bch_a tune, bch_a_v3 dev_val, and no holdout → soft.
        let a = try audit(F.inputs(validation: PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: [])))
        let card = a.findings.first { $0.code == "CARD-SPLIT" && $0.videos.contains("bch_a") }
        XCTAssertEqual(card?.severity, .soft)
    }

    func testFinalTestCandidatesAreReported() throws {
        // A fresh video on its own card and uploader, never exposed.
        let fresh = F.clip("grs_new", environment: "Grass", split: "val",
                           videos: [F.source("grs_new", uploader: "NewChannel", fingerprint: "y:new")])
        let a = try audit(F.inputs(extraClips: [fresh], extraSessions: [F.session("grs_new", split: "val")]))
        let candidates = a.findings.first { $0.code == "FINAL-TEST-CANDIDATE" }
        XCTAssertNotNil(candidates)
        XCTAssertTrue(candidates!.videos.contains("grs_new"))
        XCTAssertFalse(candidates!.videos.contains("grs_c_v2"), "shares card and uploader with a train video")
        XCTAssertTrue(a.findings.first { $0.code == "FINAL-TEST-CANDIDATE-OVERLAP" }!.videos.contains("grs_c_v2"))
    }

    func testCandidateWithAnAliasInTheTrainingDatasetIsBlocked() throws {
        // bch_a_v3 is a listed candidate; ind_dup is the same file and its frames are in images/train.
        // The reservation overlay relabels ind_dup as a candidate alias, but its data is still training data.
        let extra = F.clip("ind_dup", environment: "Indoor", split: "train",
                           videos: [F.source("ind_dup", uploader: "Z", fingerprint: "youtube:A3")])
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: [], holdout: [], finalTestCandidates: ["bch_a_v3", "ind_dup"]),
                              extraClips: [extra], extraSessions: [F.session("ind_dup", split: "train")])
        inputs.discovered = [:]
        let a = try audit(inputs)
        let listed = a.findings.first { $0.code.hasPrefix("CANDIDATE") && $0.videos == ["bch_a_v3"] }
        XCTAssertEqual(listed?.code, "CANDIDATE-BLOCKED")
        XCTAssertTrue(listed!.message.contains("alias ind_dup's frames sit in the training dataset"), listed!.message)
        let alias = a.findings.first { $0.code.hasPrefix("CANDIDATE") && $0.videos == ["ind_dup"] }
        XCTAssertEqual(alias?.code, "CANDIDATE-BLOCKED")
        XCTAssertTrue(alias!.message.contains("images/train"), alias!.message)
    }

    func testCandidateInheritsATuneAliasExposureAndRole() throws {
        // bch_a is tune (searched on). ind_dup is the same file and is listed as a candidate:
        // the overlay makes bch_a a candidate alias, but it was tune and its exposure counts.
        let extra = F.clip("ind_dup", environment: "Indoor", split: "val",
                           videos: [F.source("ind_dup", uploader: "Z", fingerprint: "youtube:A1")])
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: [], finalTestCandidates: ["ind_dup"]),
                              extraClips: [extra], extraSessions: [F.session("ind_dup", split: "val")])
        inputs.discovered = [:]
        let m = try DatasetSplitManifest.build(inputs)
        let alias = m.videos.first { $0.video == "bch_a" }!
        XCTAssertEqual(alias.split, .finalTestCandidate); XCTAssertEqual(alias.reservedAs, "alias"); XCTAssertEqual(alias.unreservedSplit, .tune)
        XCTAssertEqual(m.videos.first { $0.video == "ind_dup" }!.reservedAs, "listed")
        let a = DatasetAudit.run(manifest: m, now: F.day)
        let listed = a.findings.first { $0.code.hasPrefix("CANDIDATE") && $0.videos == ["ind_dup"] }!
        XCTAssertEqual(listed.code, "CANDIDATE-BLOCKED")
        XCTAssertTrue(listed.message.contains("alias bch_a was tune"), listed.message)
        XCTAssertTrue(listed.message.contains("via aliases: pipeline_tuning_tune"), listed.message)
    }

    func testCandidateNeedsConfirmedProvenanceForEveryAlias() throws {
        // Listed candidate A has confirmed venue + session; its alias B (same confirmed venue) has no session.
        let a = F.clip("grs_a", environment: "Grass", split: "val", videos: [F.source("grs_a", uploader: "Me", fingerprint: "y:a", sessionId: "s1", venueId: "v1")])
        let b = F.clip("grs_b", environment: "Grass", split: "val", videos: [F.source("grs_b", uploader: "Me", fingerprint: "y:b", venueId: "v1")])
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: [], holdout: [], finalTestCandidates: ["grs_a"]),
                              extraClips: [a, b], extraSessions: [F.session("grs_a", split: "val"), F.session("grs_b", split: "val")])
        inputs.discovered = [:]
        let audit = try audit(inputs)
        let listed = audit.findings.first { $0.code.hasPrefix("CANDIDATE") && $0.videos == ["grs_a"] }!
        XCTAssertEqual(listed.code, "CANDIDATE-BLOCKED")
        XCTAssertTrue(listed.message.contains("sessionId unconfirmed (alias grs_b)"), listed.message)
        XCTAssertFalse(listed.message.contains("venueId unconfirmed"), "both venues are confirmed")
    }

    func testSessionlessProjectVideoBridgesCandidateToTrainingVideo() throws {
        // A (listed candidate, file AB) ~ B (project video with NO session, file AB, venue v1) ~ C (train session, venue v1).
        let a = F.clip("grs_p", environment: "Grass", split: "val", videos: [F.source("grs_p", uploader: "Me", fingerprint: "y:AB", sessionId: "s1", venueId: "v-a")])
        let b = F.clip("grs_q", environment: "Grass", split: "train", videos: [F.source("grs_q", uploader: "Me", fingerprint: "y:AB", venueId: "v1")])
        let c = F.clip("grs_r", environment: "Grass", split: "train", videos: [F.source("grs_r", uploader: "You", fingerprint: "y:C", sessionId: "s3", venueId: "v1")])
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: [], holdout: [], finalTestCandidates: ["grs_p"]),
                              extraClips: [a, b, c], extraSessions: [F.session("grs_p", split: "val"), F.session("grs_r", split: "train")])   // no session for grs_q
        inputs.discovered = ["grs_r": [ExposureRecord(kind: .trainingPackage, ref: "P1", date: nil, note: nil)]]
        let m = try DatasetSplitManifest.build(inputs)
        XCTAssertNil(m.videos.first { $0.video == "grs_q" }, "no session → not in the manifest")
        XCTAssertEqual(m.videos.first { $0.video == "grs_p" }?.aliasGroup, m.videos.first { $0.video == "grs_r" }?.aliasGroup, "grouped through the sessionless bridge")
        XCTAssertEqual(m.videos.first { $0.video == "grs_r" }?.split, .finalTestCandidate, "C is reserved with A through B")
        let audit = DatasetAudit.run(manifest: m, now: F.day)
        let listed = audit.findings.first { $0.code.hasPrefix("CANDIDATE") && $0.videos == ["grs_p"] }!
        XCTAssertEqual(listed.code, "CANDIDATE-BLOCKED")
        XCTAssertTrue(listed.message.contains("alias grs_r's frames sit in the training dataset"), listed.message)
        XCTAssertTrue(listed.message.contains("via aliases: training_package"), listed.message)
    }

    func testExposureOfASessionlessAliasIsInheritedByTheCandidate() throws {
        // A (listed candidate, confirmed s/v) shares a confirmed venue with B, whose session was removed
        // from the dataset but whose training_package record is still on the ledger.
        let a = F.clip("grs_s", environment: "Grass", split: "val", videos: [F.source("grs_s", uploader: "Me", fingerprint: "y:S", sessionId: "s-s", venueId: "v-shared")])
        let b = F.clip("grs_t", environment: "Grass", split: "train", videos: [F.source("grs_t", uploader: "Me", fingerprint: "y:T", sessionId: "s-t", venueId: "v-shared")])
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: [], holdout: [], finalTestCandidates: ["grs_s"]),
                              extraClips: [a, b], extraSessions: [F.session("grs_s", split: "val")])   // grs_t has no session
        inputs.discovered = ["grs_t": [ExposureRecord(kind: .trainingPackage, ref: "P1", date: "2026-10-17", note: nil)]]
        let m = try DatasetSplitManifest.build(inputs)
        let row = m.videos.first { $0.video == "grs_s" }!
        XCTAssertEqual(row.exposure.map(\.kind), [.trainingPackage], "inherited from the sessionless alias")
        XCTAssertTrue(row.exposure.first!.note!.contains("via sessionless alias grs_t"))
        let listed = DatasetAudit.run(manifest: m, now: F.day).findings.first { $0.code.hasPrefix("CANDIDATE") && $0.videos == ["grs_s"] }!
        XCTAssertEqual(listed.code, "CANDIDATE-BLOCKED")
        XCTAssertTrue(listed.message.contains("prior exposure (training_package"), listed.message)
    }

    func testProvenanceQualityIsReported() throws {
        let a = try audit(F.inputs())
        let source = a.findings.first { $0.code == "PROVENANCE-SOURCE" }
        XCTAssertEqual(source?.severity, .info)
        XCTAssertFalse(source!.videos.contains("bch_b"), "confirmed sourceId is not flagged")
        XCTAssertTrue(source!.videos.contains("bch_a"))
        XCTAssertNotNil(a.findings.first { $0.code == "PROVENANCE-VENUE" })
    }

    func testMarkdownNamesTheVerdict() throws {
        let extra = F.clip("ind_dup", environment: "Indoor", split: "train",
                           videos: [F.source("ind_dup", uploader: "Z", fingerprint: "youtube:A1")])
        let a = try audit(F.inputs(extraClips: [extra], extraSessions: [F.session("ind_dup", split: "train")]))
        let md = a.markdown(manifest: try DatasetSplitManifest.build(F.inputs()))
        XCTAssertTrue(md.contains("HARD LEAK"))
        XCTAssertTrue(md.contains("FP-SHARED"))
        XCTAssertFalse(try audit(F.inputs()).markdown(manifest: try DatasetSplitManifest.build(F.inputs())).contains("HARD LEAK"))
    }
}

// MARK: - Model-lineage holdout (D-017)

extension DatasetAuditTests {
    func testLineageHoldoutKeepsItsGroupInOneSplitAndIsReportedAsExposed() throws {
        // A historically exposed dev_val recording and its same-outing training neighbour, listed as lineage holdout.
        let clips = [
            F.clip("bch_l", split: "val", videos: [F.source("bch_l", uploader: "", fingerprint: "file:L", sessionId: "2026-10-03", venueId: "beach-x")]),
            F.clip("bch_n", split: "train", videos: [F.source("bch_n", uploader: "", fingerprint: "file:N", sessionId: "2026-10-03", venueId: "beach-x")]),
        ]
        let sessions = [F.session("bch_l", split: "val"), F.session("bch_n", split: "train", marked: true)]
        let validation = PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_a_v2"], lineageHoldout: ["bch_l"])
        let inputs = F.inputs(validation: validation,
                              discovered: ["bch_l": [ExposureRecord(kind: .preTracking, ref: "session tracks (machine)", date: "2026-10-18", note: nil)],
                                           "bch_n": [ExposureRecord(kind: .trainingPackage, ref: "pkg-1", date: "2026-10-16", note: nil)]],
                              extraClips: clips, extraSessions: sessions)
        let manifest = try DatasetSplitManifest.build(inputs)
        let l = manifest.videos.first { $0.video == "bch_l" }!, n = manifest.videos.first { $0.video == "bch_n" }!
        XCTAssertEqual(l.split, .lineageHoldout); XCTAssertEqual(l.reservedAs, "listed")
        XCTAssertEqual(n.split, .lineageHoldout); XCTAssertEqual(n.reservedAs, "alias"); XCTAssertEqual(n.unreservedSplit, .train)
        let a = DatasetAudit.run(manifest: manifest, now: F.day)
        XCTAssertEqual(codes(a, .hard), [], "a confirmed session shared inside one reserved split is not a leak")
        let infos = a.findings.filter { $0.code == "LINEAGE-HOLDOUT" }
        XCTAssertEqual(Set(infos.flatMap(\.videos)), ["bch_l", "bch_n"])
        XCTAssertTrue(infos.first { $0.videos == ["bch_n"] }!.message.contains("images/train"), "reviewed frames of the moved neighbour are named")
        XCTAssertTrue(infos.first { $0.videos == ["bch_l"] }!.message.contains("pre_tracking"))
        let summary = a.findings.first { $0.code == "LINEAGE-HOLDOUT-SUMMARY" }
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.message.contains("2 lineage-holdout"))
        XCTAssertTrue(a.findings.contains { $0.code == "LINEAGE-UNKNOWN-RELATIONS" }, "train/dev recordings without venue or session are reported as unknown, not cleared")
        XCTAssertFalse(a.findings.contains { $0.code.hasPrefix("CANDIDATE") }, "lineage holdout members are not judged as final-test candidates")
    }

    func testLineageHoldoutIsNotASourceOfFinalTestCandidates() throws {
        let clips = [F.clip("grs_l", environment: "Grass", split: "val", videos: [F.source("grs_l", uploader: "", fingerprint: "file:GL", sessionId: "2026-09-06", venueId: "grass-x")])]
        let inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_a_v2"], lineageHoldout: ["grs_l"]),
                              extraClips: clips, extraSessions: [F.session("grs_l", split: "val")])
        let a = try audit(inputs)
        XCTAssertFalse(a.findings.contains { $0.code == "FINAL-TEST-CANDIDATE" && $0.videos.contains("grs_l") },
                       "even with no recorded exposure, a lineage-holdout recording is never offered as a final-test candidate")
    }

    // MARK: - The same file under two cards (D-036)

    /// The case found on 2026-11-09: a train card registered with a file's fingerprint, and a
    /// lineage-holdout card (registered with its original's fingerprint) whose video is that file.
    private func copiedHoldout(confirmed: Bool) -> DatasetSplitManifest.Inputs {
        let clips = [
            F.clip("grs_t", environment: "Grass", split: "train",
                   videos: [F.source("grs_t", uploader: "", fingerprint: "file:CUT", sourceId: confirmed ? "IMG_1" : nil)]),
            F.clip("grs_h", environment: "Grass", split: nil,
                   videos: [F.source("grs_h", uploader: "", fingerprint: "file:ORIGINAL", sourceId: confirmed ? "IMG_1" : nil)]),
        ]
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_a_v2"], lineageHoldout: ["grs_h"]),
                              discovered: ["grs_t": [ExposureRecord(kind: .trainingPackage, ref: "pkg-L2", date: "2026-10-25", note: nil),
                                                     ExposureRecord(kind: .trainingPackage, ref: "pkg-L1", date: "2026-10-17", note: nil)],
                                           "grs_h": [ExposureRecord(kind: .preTracking, ref: "session tracks (machine)", date: "2026-10-17", note: nil)]],
                              extraClips: clips, extraSessions: [F.session("grs_t", split: "train"), F.session("grs_h", split: "val")])
        // The holdout's video is the file the train card was registered with; the train card's own file has since been re-encoded.
        inputs.content = { ["grs_h": .read("file:CUT"), "grs_t": .read("file:REENCODED")][$0.name] ?? .absent }
        return inputs
    }

    func testAHoldoutFileRegisteredUnderATrainCardIsHardByContent() throws {
        let manifest = try DatasetSplitManifest.build(copiedHoldout(confirmed: false))
        let t = manifest.videos.first { $0.video == "grs_t" }!, h = manifest.videos.first { $0.video == "grs_h" }!
        XCTAssertEqual(t.split, .train, "nothing the cards say joins them")
        XCTAssertEqual([h.contentFingerprint, h.contentState], ["file:CUT", "read"])
        XCTAssertEqual([t.fingerprint, t.contentFingerprint], ["file:CUT", "file:REENCODED"], "a stored fingerprint is not the file read today")
        let a = DatasetAudit.run(manifest: manifest, now: F.day)
        let shared = try XCTUnwrap(a.findings.first { $0.code == "CONTENT-SHARED" })
        XCTAssertEqual(shared.severity, .hard)
        XCTAssertEqual(shared.videos, ["grs_h", "grs_t"])
        XCTAssertTrue(shared.message.contains("lineage_holdout + train"), shared.message)
        XCTAssertTrue(a.hasHardLeak)
        XCTAssertFalse(codes(a, .hard).contains("FP-SHARED"), "the two cards were registered with different fingerprints")
    }

    func testOnceTheSharedRecordingIsConfirmedTheCopyIsWithheldAndItsTrainingHistoryIsSaid() throws {
        let manifest = try DatasetSplitManifest.build(copiedHoldout(confirmed: true))
        let t = manifest.videos.first { $0.video == "grs_t" }!
        XCTAssertEqual(t.split, .lineageHoldout); XCTAssertEqual(t.reservedAs, "alias"); XCTAssertEqual(t.unreservedSplit, .train)
        XCTAssertEqual(Set(t.exposure.filter { $0.kind == .trainingPackage }.map(\.ref)), ["pkg-L1", "pkg-L2"], "its history is kept")
        let a = DatasetAudit.run(manifest: manifest, now: F.day)
        XCTAssertEqual(codes(a, .hard), [], "one split now: no boundary is crossed")
        let trained = a.findings.filter { $0.code == "LINEAGE-HOLDOUT-TRAINED" }
        XCTAssertEqual(trained.map(\.severity), [.soft, .soft])
        let listed = try XCTUnwrap(trained.first { $0.videos.first == "grs_h" })
        XCTAssertEqual(listed.videos, ["grs_h", "grs_t"], "the listed holdout is in the packages under the copy's name")
        XCTAssertTrue(listed.message.contains("pkg-L1, pkg-L2") && listed.message.contains("as grs_t"), listed.message)
        XCTAssertEqual(try XCTUnwrap(trained.first { $0.videos == ["grs_t"] }).message.contains("pkg-L1, pkg-L2"), true)
        for name in ["grs_h", "grs_t"] {
            let note = try XCTUnwrap(a.findings.first { $0.code == "LINEAGE-HOLDOUT" && $0.videos == [name] })
            XCTAssertTrue(note.message.contains("trained from none of those packages"), note.message)
            XCTAssertFalse(note.message.contains("after the D-017 cut-over"), "the cut-over date does not clear it")
        }
    }

    func testAVenueMateInAPackageDoesNotMarkAnotherRecordingAsTrained() throws {
        // bch_n shares a confirmed session with the listed bch_l: withheld with it, but another recording.
        let clips = [F.clip("bch_l", videos: [F.source("bch_l", uploader: "", fingerprint: "file:L", sessionId: "day-1")]),
                     F.clip("bch_n", split: "train", videos: [F.source("bch_n", uploader: "", fingerprint: "file:N", sessionId: "day-1")])]
        let inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_a_v2"], lineageHoldout: ["bch_l"]),
                              discovered: ["bch_n": [ExposureRecord(kind: .trainingPackage, ref: "pkg-1", date: "2026-10-16", note: nil)]],
                              extraClips: clips, extraSessions: [F.session("bch_l", split: "val"), F.session("bch_n", split: "train")])
        let trained = try audit(inputs).findings.filter { $0.code == "LINEAGE-HOLDOUT-TRAINED" }
        XCTAssertEqual(trained.map(\.videos), [["bch_n"]], "the neighbour is in a package; the listed recording is not")
    }

    func testAHoldoutIsInAPackageThroughAChainOfRecordingIdentities() throws {
        // grs_h (listed) and grs_m share a confirmed sourceId; grs_m's video is the file grs_p's card was
        // registered with; only grs_p is in a package, and nothing joins grs_p to grs_h directly.
        let clips = [F.clip("grs_h", environment: "Grass", videos: [F.source("grs_h", uploader: "", fingerprint: "file:H", sourceId: "IMG_9")]),
                     F.clip("grs_m", environment: "Grass", split: "train", videos: [F.source("grs_m", uploader: "", fingerprint: "file:M", sourceId: "IMG_9")]),
                     F.clip("grs_p", environment: "Grass", split: "train", videos: [F.source("grs_p", uploader: "", fingerprint: "file:CUT")])]
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_a_v2"], lineageHoldout: ["grs_h"]),
                              discovered: ["grs_p": [ExposureRecord(kind: .trainingPackage, ref: "pkg-L2", date: "2026-10-25", note: nil)]],
                              extraClips: clips, extraSessions: [F.session("grs_h", split: "val"), F.session("grs_m", split: "train"), F.session("grs_p", split: "train")])
        inputs.content = { ["grs_m": .read("file:CUT")][$0.name] ?? .absent }
        let a = try audit(inputs)
        let trained = a.findings.filter { $0.code == "LINEAGE-HOLDOUT-TRAINED" }
        XCTAssertEqual(Set(trained.map(\.videos)), [["grs_h", "grs_p"], ["grs_m", "grs_p"]],
                       "the listed holdout is in pkg-L2 two steps away: a sourceId to grs_m, then grs_m's file to grs_p")
        let note = try XCTUnwrap(a.findings.first { $0.code == "LINEAGE-HOLDOUT" && $0.videos == ["grs_h"] })
        XCTAssertFalse(note.message.contains("after the D-017 cut-over"), note.message)
        XCTAssertEqual(a.findings.first { $0.code == "CONTENT-SHARED" }?.videos, ["grs_m", "grs_p"], "and grs_p, still train, is a hard leak")
    }

    func testAPackageRowInheritedFromASessionlessVenueMateIsNotTheHoldoutsOwn() throws {
        // grs_h (listed) shares only a confirmed venue with grs_t, whose session was removed from the
        // dataset and whose package row is still on the ledger. The row reaches grs_h's history, marked
        // as its group's; grs_h itself is in no package.
        func run(mate: ClipSource) throws -> (row: ManifestVideo, audit: DatasetAudit) {
            let clips = [F.clip("grs_h", environment: "Grass", videos: [F.source("grs_h", uploader: "", fingerprint: "file:H", sourceId: "IMG_9", venueId: "v-shared")]),
                         F.clip("grs_t", environment: "Grass", split: "train", videos: [mate])]
            let inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_a_v2"], lineageHoldout: ["grs_h"]),
                                  discovered: ["grs_t": [ExposureRecord(kind: .trainingPackage, ref: "pkg-L2", date: "2026-10-25", note: nil)]],
                                  extraClips: clips, extraSessions: [F.session("grs_h", split: "val")])   // grs_t has no session
            let m = try DatasetSplitManifest.build(inputs)
            return (try XCTUnwrap(m.videos.first { $0.video == "grs_h" }), DatasetAudit.run(manifest: m, now: F.day))
        }
        let venueOnly = try run(mate: F.source("grs_t", uploader: "", fingerprint: "file:T", venueId: "v-shared"))
        XCTAssertEqual(venueOnly.row.exposure.map(\.inherited), ["group"])
        XCTAssertFalse(venueOnly.audit.findings.contains { $0.code == "LINEAGE-HOLDOUT-TRAINED" }, "a venue mate's package is not this recording's")
        let note = try XCTUnwrap(venueOnly.audit.findings.first { $0.code == "LINEAGE-HOLDOUT" && $0.videos == ["grs_h"] })
        XCTAssertTrue(note.message.contains("historical exposure: training_package"), "the group's history is still shown: \(note.message)")

        // The same mate under the holdout's confirmed sourceId is the holdout's recording: its package counts.
        let sameRecording = try run(mate: F.source("grs_t", uploader: "", fingerprint: "file:T", sourceId: "IMG_9"))
        XCTAssertEqual(sameRecording.row.exposure.map(\.inherited), ["recording"])
        XCTAssertEqual(sameRecording.audit.findings.filter { $0.code == "LINEAGE-HOLDOUT-TRAINED" }.map(\.videos), [["grs_h"]])
    }

    func testAGroupRowStaysTheGroupsWhenTheVideoThatCarriedItLosesItsSession() throws {
        // grs_h (listed) and grs_b are one recording (a confirmed sourceId). grs_x, with no session, shares
        // only their venue and is in a package. First build: both take grs_x's row as their group's. Then
        // grs_b's session is removed: its rows reach grs_h through the previous manifest, as the same
        // recording's — and the package row among them is still only the group's.
        let clips = [F.clip("grs_h", environment: "Grass", videos: [F.source("grs_h", uploader: "", fingerprint: "file:H", sourceId: "IMG_9", venueId: "v-shared")]),
                     F.clip("grs_b", environment: "Grass", split: "train", videos: [F.source("grs_b", uploader: "", fingerprint: "file:B", sourceId: "IMG_9", venueId: "v-shared")]),
                     F.clip("grs_x", environment: "Grass", split: "train", videos: [F.source("grs_x", uploader: "", fingerprint: "file:X", venueId: "v-shared")])]
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_a_v2"], lineageHoldout: ["grs_h"]),
                              discovered: ["grs_x": [ExposureRecord(kind: .trainingPackage, ref: "pkg-L2", date: "2026-10-25", note: nil)]],
                              extraClips: clips, extraSessions: [F.session("grs_h", split: "val"), F.session("grs_b", split: "train")])
        let first = try DatasetSplitManifest.build(inputs)
        XCTAssertEqual(first.videos.first { $0.video == "grs_b" }?.exposure.map(\.inherited), ["group"])
        XCTAssertFalse(DatasetAudit.run(manifest: first, now: F.day).findings.contains { $0.code == "LINEAGE-HOLDOUT-TRAINED" })

        inputs.previous = first
        inputs.sessions.removeAll { $0.name == "grs_b" }
        let second = try DatasetSplitManifest.build(inputs)
        let row = try XCTUnwrap(second.videos.first { $0.video == "grs_h" })
        XCTAssertFalse(row.exposure.isEmpty)
        XCTAssertEqual(Set(row.exposure.map(\.inherited)), ["group"], "the row came through grs_b, and is still grs_x's group's")
        XCTAssertFalse(DatasetAudit.run(manifest: second, now: F.day).findings.contains { $0.code == "LINEAGE-HOLDOUT-TRAINED" },
                       "neither grs_h nor grs_b was ever packaged")
    }

    func testAnUnmarkedInheritedRowFromAnOlderManifestIsReplacedNotDoubled() throws {
        let clips = [F.clip("grs_h", environment: "Grass", videos: [F.source("grs_h", uploader: "", fingerprint: "file:H", venueId: "v-shared")]),
                     F.clip("grs_t", environment: "Grass", split: "train", videos: [F.source("grs_t", uploader: "", fingerprint: "file:T", venueId: "v-shared")])]
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_a_v2"], lineageHoldout: ["grs_h"]),
                              discovered: ["grs_t": [ExposureRecord(kind: .trainingPackage, ref: "pkg-L2", date: "2026-10-25", note: nil)]],
                              extraClips: clips, extraSessions: [F.session("grs_h", split: "val")])
        var older = try DatasetSplitManifest.build(inputs)
        let at = try XCTUnwrap(older.videos.firstIndex { $0.video == "grs_h" })
        older.videos[at].exposure = older.videos[at].exposure.map { var r = $0; r.inherited = nil; return r }
        inputs.previous = older
        let row = try XCTUnwrap(try DatasetSplitManifest.build(inputs).videos.first { $0.video == "grs_h" })
        XCTAssertEqual(row.exposure.map(\.inherited), ["group"], "one row, now saying how it was inherited")
    }

    func testOneFileUnderTwoCardsOfOneSplitIsSoftAndTwoCardsWithOneStoredFingerprintStayFPShared() throws {
        let clips = [F.clip("ind_x", environment: "Indoor", split: "train", videos: [F.source("ind_x", uploader: "", fingerprint: "file:X")]),
                     F.clip("ind_y", environment: "Indoor", split: "train", videos: [F.source("ind_y", uploader: "", fingerprint: "file:Y")]),
                     F.clip("ind_dup", environment: "Indoor", split: "train", videos: [F.source("ind_dup", uploader: "Z", fingerprint: "youtube:A1")])]
        var inputs = F.inputs(extraClips: clips, extraSessions: [F.session("ind_x", split: "train"), F.session("ind_y", split: "train"), F.session("ind_dup", split: "train")])
        inputs.content = { ["ind_x": .read("file:X"), "ind_y": .read("file:X")][$0.name] ?? .absent }
        let a = try audit(inputs)
        let dup = try XCTUnwrap(a.findings.first { $0.code == "CONTENT-DUPLICATE" })
        XCTAssertEqual(dup.severity, .soft); XCTAssertEqual(dup.videos, ["ind_x", "ind_y"])
        XCTAssertFalse(a.findings.contains { $0.code == "CONTENT-SHARED" })
        XCTAssertEqual(a.findings.filter { $0.code == "FP-SHARED" }.map(\.videos), [["bch_a", "ind_dup"]], "a shared stored fingerprint is reported once, as before")
    }

    func testAVideoThatCouldNotBeComparedIsCountedNeverCleared() throws {
        var inputs = F.inputs()
        inputs.content = { ["bch_b": .unreadable, "grs_c": .read("file:C")][$0.name] ?? .absent }
        let manifest = try DatasetSplitManifest.build(inputs)
        XCTAssertEqual(manifest.videos.first { $0.video == "bch_b" }!.contentState, "unreadable")
        XCTAssertNil(manifest.videos.first { $0.video == "bch_b" }!.contentFingerprint)
        let a = DatasetAudit.run(manifest: manifest, now: F.day)
        let unreadable = try XCTUnwrap(a.findings.first { $0.code == "CONTENT-UNREADABLE" })
        XCTAssertEqual(unreadable.severity, .soft); XCTAssertEqual(unreadable.videos, ["bch_b"])
        let absent = try XCTUnwrap(a.findings.first { $0.code == "CONTENT-ABSENT" })
        XCTAssertEqual(absent.severity, .info); XCTAssertEqual(absent.videos, ["bch_a", "bch_a_v2", "bch_a_v3", "grs_c_v2"])
    }

    func testAManifestFromBeforeContentFingerprintsStillDecodesAndClaimsNothing() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(try DatasetSplitManifest.build(F.inputs()))) as? [String: Any])
        object["videos"] = (object["videos"] as? [[String: Any]])?.map { row in row.filter { $0.key != "contentFingerprint" && $0.key != "contentState" } }
        let old = try decoder.decode(DatasetSplitManifest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(old.videos.allSatisfy { $0.contentState == nil && $0.contentFingerprint == nil })
        let a = DatasetAudit.run(manifest: old, now: F.day)
        XCTAssertFalse(a.findings.contains { $0.code.hasPrefix("CONTENT-") }, "nothing was compared, so nothing is said either way")
    }
}
