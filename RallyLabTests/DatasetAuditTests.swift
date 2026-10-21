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
}
