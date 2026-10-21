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

    func testFixtureLeaksAcrossCards() throws {
        let a = try audit(F.inputs())
        // grs_c is an auto card with videos on both sides of train → hard card split;
        // bch_a is pinned val but spans tune + legacy_holdout + dev_val → reserved touched → hard too.
        XCTAssertTrue(a.hasHardLeak)
        let cards = a.findings.filter { $0.code == "CARD-SPLIT" && $0.severity == .hard }.map { $0.videos.first ?? "" }
        XCTAssertEqual(Set(cards), ["bch_a", "grs_c"])
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

    func testProvenanceQualityIsReported() throws {
        let a = try audit(F.inputs())
        let source = a.findings.first { $0.code == "PROVENANCE-SOURCE" }
        XCTAssertEqual(source?.severity, .info)
        XCTAssertFalse(source!.videos.contains("bch_b"), "confirmed sourceId is not flagged")
        XCTAssertTrue(source!.videos.contains("bch_a"))
        XCTAssertNotNil(a.findings.first { $0.code == "PROVENANCE-VENUE" })
    }

    func testMarkdownNamesTheVerdict() throws {
        let a = try audit(F.inputs())
        let md = a.markdown(manifest: try DatasetSplitManifest.build(F.inputs()))
        XCTAssertTrue(md.contains("HARD LEAK"))
        XCTAssertTrue(md.contains("CARD-SPLIT"))
    }
}
