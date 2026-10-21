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
