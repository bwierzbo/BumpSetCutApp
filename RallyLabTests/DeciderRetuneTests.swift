//
//  DeciderRetuneTests.swift
//  RallyLabTests
//
//  The retune's rules: every marked rally lands in one class, the objective
//  reads as written, the grid is every combination in a fixed order, recording
//  groups join by card / uploader / identity, and a plan that would evaluate
//  on a group it chose with — or on a withheld recording — is refused.
//

import XCTest
@testable import RallyLab

final class DeciderRetuneTests: XCTestCase {

    private func iv(_ s: Double, _ e: Double) -> Interval { Interval(start: s, end: e) }

    func testEveryRallyLandsInOneClass() {
        // Six rallies; clips: one preserved, one clipped (half of it), one clip merging rallies 3 and 4,
        // rally 5 split in two, rally 6 missed, plus a false clip and a clip that only grazes rally 1's tail.
        let truth = [iv(10, 20), iv(30, 40), iv(50, 60), iv(62, 72), iv(80, 90), iv(100, 110)]
        let clips = [iv(9, 21), iv(35, 40), iv(49, 73), iv(80, 84), iv(86, 90), iv(120, 125)]
        let a = DeciderRetune.account(clips: clips, raw: [iv(11, 19)], truth: truth, preservedShare: 0.95)
        XCTAssertEqual(a.rallies, 6)
        XCTAssertEqual(a.preserved, 1)
        XCTAssertEqual(a.clipped, 1)
        XCTAssertEqual(a.merged, 2, "both rallies under the merging clip")
        XCTAssertEqual(a.split, 1)
        XCTAssertEqual(a.partial, 0)
        XCTAssertEqual(a.missed, 1)
        XCTAssertEqual(a.preserved + a.clipped + a.merged + a.split + a.partial + a.missed, a.rallies, "one class each")
        XCTAssertEqual(a.clips, 6)
        XCTAssertEqual(a.falseClips, 1)
        XCTAssertEqual(a.rallyTime, 60)
        XCTAssertEqual(a.covered, 43, accuracy: 1e-9, "10 + 5 + 10 + 10 + 8")
        XCTAssertEqual(a.deadTime, 11, accuracy: 1e-9, "2 + 0 + 4 + 0 + 0 + 5")
        // Boundary errors are over the scorer's one-to-one matches (IoU ≥ 0.3), whatever class the rally landed in:
        // rallies 1 and 2, one of the two merged rallies (the clip matches one), and one half of the split rally.
        XCTAssertEqual(a.startErrors.count, 4)
        XCTAssertEqual(a.startErrors[0], -1); XCTAssertEqual(a.endErrors[0], 1)
        XCTAssertEqual(a.rawStartErrors, [1])
        XCTAssertEqual(a.rawEndErrors, [-1])
        // Partial: a clip touches a rally but matches nothing and merges nothing.
        let b = DeciderRetune.account(clips: [iv(19, 23)], raw: [], truth: [iv(10, 20)], preservedShare: 0.95)
        XCTAssertEqual(b.partial, 1)
        XCTAssertEqual(b.falseClips, 0)
    }

    func testObjectiveReadsAsWritten() {
        var a = DeciderRetune.Account()
        a.rallies = 10; a.preserved = 7; a.merged = 2; a.falseClips = 4; a.rallyTime = 100; a.deadTime = 20
        let o = DeciderRetune.Plan.Objective(mergedRallyCost: 0.5, falseClipCost: 0.25, deadTimeCost: 0.25)
        XCTAssertEqual(a.objective(o), (7 - 1 - 1) / 10.0 - 0.25 * 0.2, accuracy: 1e-12)
        XCTAssertEqual(DeciderRetune.Account().objective(o), 0, "no rallies: nothing to score")
        let sum = a + a
        XCTAssertEqual(sum.rallies, 20); XCTAssertEqual(sum.deadTime, 40)
        XCTAssertEqual(DeciderRetune.Account.median([3, 1, 2]), 2)
        XCTAssertEqual(DeciderRetune.Account.median([4, 1, 2, 3]), 2.5)
        XCTAssertNil(DeciderRetune.Account.median([]))
    }

    func testGridIsEveryCombinationInOrderAndAppliesToTheConfig() {
        let grid = DeciderRetune.Plan.Grid(preroll: [0.5, 2.0], postroll: nil, minGapToMerge: [0, 1.35], minSegmentLength: nil, endTimeout: nil, startBuffer: nil, skyBallTimeout: nil)
        let cs = DeciderRetune.candidates(grid)
        XCTAssertEqual(cs.count, 4)
        XCTAssertEqual(cs.map(\.label), ["minGapToMerge=0 preroll=0.5", "minGapToMerge=1.35 preroll=0.5", "minGapToMerge=0 preroll=2", "minGapToMerge=1.35 preroll=2"])
        let c = cs[1].apply(to: ProcessorConfig())
        XCTAssertEqual(c.preroll, 0.5); XCTAssertEqual(c.minGapToMerge, 1.35)
        XCTAssertEqual(c.postroll, ProcessorConfig().postroll, "knobs not in the grid stay as committed")
        XCTAssertEqual(DeciderRetune.candidates(DeciderRetune.Plan.Grid(preroll: nil, postroll: nil, minGapToMerge: nil, minSegmentLength: nil, endTimeout: nil, startBuffer: nil, skyBallTimeout: nil)).count, 1, "an empty grid is the committed settings alone")
    }

    private func video(_ name: String, clip: String? = nil, uploader: String? = nil, group: String? = nil, source: String? = nil) -> ManifestVideo {
        ManifestVideo(video: name, clipId: clip, surface: nil, camera: nil, lighting: nil, orientation: nil, uploader: uploader, originKind: nil,
                      fingerprint: nil, sourceId: source.map { .confirmed($0) } ?? .unknown, sessionId: .unknown, venueId: .unknown,
                      datasetSplit: "train", split: .train, unreservedSplit: nil, reservedAs: nil, aliasGroup: group,
                      ralliesMarked: true, frames: 0, reviewedFrames: 0, addedAt: Date(timeIntervalSince1970: 0), exposure: [])
    }

    func testRecordingGroupsJoinByCardUploaderAndIdentity() {
        let groups = DeciderRetune.groups([
            video("bch_a", clip: "bch_a", uploader: "Blake"), video("bch_a_v2", clip: "bch_a", uploader: "Blake"),
            video("grs_b", uploader: "Grace"), video("grs_c", uploader: "Grace"), video("grs_d", uploader: " Grace "),
            video("ind_e", source: "youtube:x"), video("ind_f", source: "youtube:x"),
            video("ind_g", group: "ind_g"), video("ind_h", group: "ind_g"),
            video("ind_i"),
        ])
        XCTAssertEqual(groups["bch_a_v2"], "bch_a")
        XCTAssertEqual(Set([groups["grs_b"], groups["grs_c"], groups["grs_d"]]).count, 1, "one uploader, whitespace trimmed")
        XCTAssertEqual(groups["ind_f"], "ind_e")
        XCTAssertEqual(groups["ind_h"], "ind_g")
        XCTAssertEqual(groups["ind_i"], "ind_i")
        XCTAssertEqual(Set(groups.values).count, 5)
    }

    func testAPlanIsRefusedWhenPoolsShareAGroupOrNameAWithheldRecording() {
        let groups = ["bch_a": "bch_a", "bch_a_v2": "bch_a", "grs_b": "grs_b", "ind_c": "ind_c"]
        let grid = DeciderRetune.Plan.Grid(preroll: [1], postroll: nil, minGapToMerge: nil, minSegmentLength: nil, endTimeout: nil, startBuffer: nil, skyBallTimeout: nil)
        let objective = DeciderRetune.Plan.Objective(mergedRallyCost: 0.5, falseClipCost: 0.25, deadTimeCost: 0.25)
        func plan(tune: [String], eval: [String]) -> DeciderRetune.Plan {
            DeciderRetune.Plan(id: "EXP-test", baselineModel: "l1", candidateModel: "l2", tune: tune, eval: eval, grid: grid,
                               objective: objective, preservedShare: 0.95, minRallySec: 1.1653)
        }
        XCTAssertNil(DeciderRetune.planRefusal(plan(tune: ["bch_a", "bch_a_v2"], eval: ["grs_b", "ind_c"]), reserved: [], withheld: [], groups: groups))
        XCTAssertTrue(DeciderRetune.planRefusal(plan(tune: ["bch_a"], eval: ["bch_a_v2", "grs_b"]), reserved: [], withheld: [], groups: groups)!.contains("both pools"))
        XCTAssertTrue(DeciderRetune.planRefusal(plan(tune: ["bch_a"], eval: ["grs_b"]), reserved: [], withheld: ["grs_b"], groups: groups)!.contains("withheld"))
        XCTAssertTrue(DeciderRetune.planRefusal(plan(tune: ["bch_a"], eval: ["grs_b"]), reserved: ["bch_a"], withheld: ["bch_a"], groups: groups)!.contains("final_test"))
        XCTAssertTrue(DeciderRetune.planRefusal(plan(tune: ["bch_a", "grs_b"], eval: ["grs_b"]), reserved: [], withheld: [], groups: groups)!.contains("twice"))
        XCTAssertTrue(DeciderRetune.planRefusal(plan(tune: [], eval: ["grs_b"]), reserved: [], withheld: [], groups: groups)!.contains("both a tune"))
    }

    func testPlanRoundTrips() throws {
        let json = """
        {"id":"EXP-20261031-l2-decider-retune","baselineModel":"l1","candidateModel":"l2","tune":["a"],"eval":["b"],
         "grid":{"preroll":[0.5,1.0],"postroll":[0.5],"minGapToMerge":[0,0.5]},
         "objective":{"mergedRallyCost":0.5,"falseClipCost":0.25,"deadTimeCost":0.25},"preservedShare":0.95,"minRallySec":1.1653}
        """
        let plan = try JSONDecoder().decode(DeciderRetune.Plan.self, from: Data(json.utf8))
        XCTAssertEqual(DeciderRetune.candidates(plan.grid).count, 4)
        XCTAssertNil(plan.grid.endTimeout)
    }
}
