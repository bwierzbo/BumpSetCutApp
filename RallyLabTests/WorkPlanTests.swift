//
//  WorkPlanTests.swift
//  RallyLabTests
//
//  The work plan (owner, 2026-11-26): what each recording still needs before it can teach the rally classifier,
//  and the order to mark them in — a new camera group before more of a covered one, short clips after the longer
//  ones, withheld recordings last — the same on the Mac and the phone; and the facts the Mac publishes for it.
//

import XCTest
@testable import RallyLab

@MainActor
final class WorkPlanTests: XCTestCase {
    private func video(_ name: String, surface: String = "Beach", found: Int = 0, marked: Int = 0, complete: Bool = false, backlog: Bool = false,
                       access: LabelAccess = .open, group: String? = nil, seconds: Double? = 300, available: Bool = true) -> LabelQueue.Video {
        LabelQueue.Video(plan: PlanVideo(name: name, surface: surface, split: "train", available: available, rallies: 0, labeledFrames: 0, checkedFrames: 0,
                                         openRallies: 0, ralliesMarked: complete),
                         nextRally: nil, found: found, marked: marked, complete: complete, backlog: backlog, access: access, group: group, seconds: seconds)
    }

    private func order(_ videos: [LabelQueue.Video]) -> [String] { LabelQueue.markingJobs(videos).map(\.video) }

    // MARK: - The marking order

    func testWithoutGroupsTheOrderIsAsBeforeSurfacesInTurnMostFoundFirst() {
        let videos = [video("b1", found: 1), video("b2", found: 5), video("g1", surface: "Grass", found: 2), video("i1", surface: "Indoor"),
                      video("b0", complete: true)]
        // Beach already has one marked: the others lead, by name; then in turn.
        XCTAssertEqual(order(videos), ["g1", "i1", "b2", "b1"])
    }

    func testANewCameraGroupLeadsAnotherRecordingOfACoveredOne() {
        let videos = [video("a_v2", found: 9, group: "a"), video("a", complete: true, group: "a"),
                      video("b", found: 1, group: "b"), video("b_v2", found: 5, group: "b"), video("c", found: 0, group: "c")]
        // b's group opens with its most-found recording, then c's; only then the siblings, most found first.
        XCTAssertEqual(order(videos), ["b_v2", "c", "a_v2", "b"])
        // A group begun (a recording started) is covered too: the started one leads as ever, its sibling waits.
        let begun = [video("d", marked: 2, group: "d"), video("d_v2", found: 9, group: "d"), video("e", group: "e")]
        XCTAssertEqual(order(begun), ["d", "e", "d_v2"])
    }

    func testNewGroupsAreTakenFromEverySurfaceBeforeAnySibling() {
        let videos = [video("g_done", surface: "Grass", complete: true, group: "g"), video("g_v2", surface: "Grass", group: "g"),
                      video("b1", group: "b1"), video("b2", group: "b2")]
        // Grass has only a sibling left: it waits until Beach's new groups are through, though Beach has more marked by then.
        XCTAssertEqual(order(videos), ["b1", "b2", "g_v2"])
    }

    func testShortClipsFollowTheLongerOnesAndWithheldRecordingsComeLast() {
        let videos = [video("held", found: 9, access: .byHandOnly(.withheld)), video("clip", found: 9, seconds: 8), video("long", seconds: 300),
                      video("unknownLength", seconds: nil), video("unknownList", access: .byHandOnly(.unknown))]
        XCTAssertEqual(order(videos), ["long", "unknownLength", "clip", "held", "unknownList"])
        // A withheld recording marked through does not cover its group for the ones that can train.
        let group = [video("w", complete: true, access: .byHandOnly(.withheld), group: "x"), video("x_v2", group: "x"), video("y", found: 5, group: "y"),
                     video("y_done", complete: true, group: "y")]
        XCTAssertEqual(order(group), ["x_v2", "y"])
        // An ordinary labeler is offered none of the closed ones.
        XCTAssertEqual(order([video("closed", access: .closed(.withheld)), video("open")]), ["open"])
    }

    func testFootageThatCantBePlayedHereIsNoJobButIsInThePlan() {
        let videos = [video("away", available: false), video("here")]
        XCTAssertEqual(order(videos), ["here"])
        XCTAssertEqual(LabelQueue.markingOrder(videos, playableOnly: false).map(\.plan.name), ["away", "here"])
        let plan = WorkPlan.plan(videos.map { WorkPlan.Recording(video: $0, type: nil, audit: nil) })
        XCTAssertEqual(plan.items(.mark).map(\.name), ["away", "here"])
        XCTAssertEqual(plan.items(.mark).map(\.playable), [false, true])
    }

    // MARK: - The steps

    func testEachRecordingIsAtTheFirstStepItStillNeeds() {
        func step(complete: Bool = true, type: String? = WorkPlan.continuous, audit: WorkPlan.Audit? = .clean, access: LabelAccess = .open) -> WorkPlan.Step {
            WorkPlan.step(of: WorkPlan.Recording(video: video("v", complete: complete, access: access), type: type, audit: audit))
        }
        XCTAssertEqual(step(complete: false), .mark)
        XCTAssertEqual(step(type: nil), .type)
        XCTAssertEqual(step(audit: .notDrawn), .draw)
        XCTAssertEqual(step(audit: .open), .audit)
        XCTAssertEqual(step(audit: .findings), .fix)
        XCTAssertEqual(step(audit: .clean), .done)
        XCTAssertEqual(step(type: "edited", audit: .open), .done, "not continuous: its rallies count, its unmarked time is not audited")
        XCTAssertEqual(step(type: "submitted", audit: .notDrawn), .done, "a choice on its way to the Mac is not owed again")
        XCTAssertEqual(step(audit: nil), .done, "the audit is not known here: nothing is asked for")
        XCTAssertEqual(step(audit: .open, access: .byHandOnly(.withheld)), .done, "a withheld recording is never audited")
        XCTAssertEqual(step(complete: false, access: .byHandOnly(.withheld)), .mark)
        XCTAssertEqual(step(type: nil, access: .byHandOnly(.withheld)), .type)
    }

    func testThePlanCountsWhatCanTrainBySurfaceAndGroup() {
        func r(_ v: LabelQueue.Video, _ type: String? = nil, _ audit: WorkPlan.Audit? = .notDrawn) -> WorkPlan.Recording { WorkPlan.Recording(video: v, type: type, audit: audit) }
        let plan = WorkPlan.plan([
            r(video("i1", surface: "Indoor", complete: true, group: "i1"), WorkPlan.continuous, .clean),
            r(video("i1_v2", surface: "Indoor", complete: true, group: "i1"), "edited"),
            r(video("i2", surface: "Indoor", complete: true, group: "i2"), WorkPlan.continuous, .open),
            r(video("i3", surface: "Indoor", group: "i3", seconds: 120)),
            r(video("i3_v2", surface: "Indoor", group: "i3", seconds: 60)),
            r(video("b1", complete: true, group: "b1")),
            r(video("b2", complete: true, group: "b2"), WorkPlan.continuous, .findings),
            r(video("b3", complete: true, group: "b3"), WorkPlan.continuous, .notDrawn),
            r(video("held", access: .byHandOnly(.withheld), group: "h")),
            r(video("aside", backlog: true, group: "z")),
        ])
        XCTAssertEqual(plan.surfaces.map(\.surface), ["Indoor", "Beach"])
        let indoor = plan.surfaces[0], beach = plan.surfaces[1]
        XCTAssertEqual([indoor.recordings, indoor.marked, indoor.continuous, indoor.clean], [5, 3, 2, 1])
        XCTAssertEqual([indoor.groups, indoor.groupsMarked, indoor.groupsClean], [3, 2, 1])
        XCTAssertEqual([beach.recordings, beach.marked, beach.continuous, beach.clean], [3, 3, 2, 0], "the withheld and the set-aside one are not counted")
        XCTAssertEqual([beach.groups, beach.groupsMarked, beach.groupsClean], [3, 3, 0])
        XCTAssertEqual(plan.total.groups, 6); XCTAssertEqual(plan.backlog, 1); XCTAssertTrue(plan.auditKnown)

        XCTAssertEqual(plan.items(.mark).map(\.name), ["i3", "i3_v2"])
        XCTAssertEqual(plan.items(.mark).map(\.newGroup), [true, false], "one recording opens a group; its sibling does not")
        XCTAssertEqual(plan.newGroups, 1); XCTAssertEqual(plan.markingSeconds, 180)
        XCTAssertEqual(plan.items(.mark, held: true).map(\.name), ["held"])
        XCTAssertFalse(plan.items(.mark, held: true)[0].newGroup)
        XCTAssertEqual(plan.items(.type).map(\.name), ["b1"])
        XCTAssertEqual(plan.items(.audit).map(\.name), ["i2"])
        XCTAssertEqual(plan.items(.fix).map(\.name), ["b2"])
        XCTAssertEqual(plan.items(.draw).map(\.name), ["b3"])
        XCTAssertEqual(Set(plan.items(.done).map(\.name)), ["i1", "i1_v2"])
        XCTAssertFalse(plan.items.contains { $0.name == "aside" })

        // No facts from the Mac yet: nothing is known of the audits, and each recording is its own group.
        let bare = WorkPlan.plan([WorkPlan.Recording(video: video("a", complete: true), type: WorkPlan.continuous, audit: nil),
                                  WorkPlan.Recording(video: video("a_v2"), type: nil, audit: nil)])
        XCTAssertFalse(bare.auditKnown)
        XCTAssertEqual(bare.total.groups, 2); XCTAssertEqual(bare.items(.mark).map(\.newGroup), [true])
    }

    // MARK: - What the Mac publishes

    /// The labeling client rewrites every JSON key between camel and snake case: recording names must come through
    /// as they are, and a row from a Mac build before the work plan (no `work`) still decodes.
    func testThePublishedFactsSurviveTheClientsKeyConversionAndAnOlderRowDecodes() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.dateEncodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase; decoder.dateDecodingStrategy = .iso8601
        let work = WorkPlan.Published(recordings: [.init(name: "bch_extra_self_01", group: "bch_extra_self_01", audit: .notDrawn),
                                                   .init(name: "ind_ele_dim_land_self_02_v3", group: "ind_ele_dim_land_self_02", audit: nil)],
                                      publishedAt: "2026-11-26T18:00:00Z")
        let data = try encoder.encode(LabelProjectState(project: "P", plan: [], scores: [:], updatedAt: nil, work: work))
        let back = try decoder.decode(LabelProjectState.self, from: data)
        XCTAssertEqual(back.work, work)
        XCTAssertEqual(back.work?.byName["ind_ele_dim_land_self_02_v3"]?.group, "ind_ele_dim_land_self_02")
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"audit\":\"not_drawn\""), json)

        let older = try decoder.decode(LabelProjectState.self, from: Data(#"{"project":"P","plan":[],"scores":{}}"#.utf8))
        XCTAssertNil(older.work)
        let bare = try XCTUnwrap(String(data: try encoder.encode(older), encoding: .utf8))
        XCTAssertFalse(bare.contains("work"), "a row without the facts leaves the column out, so the upsert keeps what the server has")
    }

    func testADrawnRecordingsAuditIsReadFromItsStatus() {
        func status(contaminated: Bool, partial: Bool, moved: Int = 0, setAside: String? = nil) -> CoverageAudit.RecordingStatus {
            var tally = CoverageAudit.Tally(total: 4, state: CoverageAudit.RecordingState(contaminated: contaminated, partial: partial))
            tally.movedIntervals = moved
            var s = CoverageAudit.RecordingStatus(recordingId: "v", surface: nil, tally: tally)
            s.setAside = setAside
            return s
        }
        XCTAssertEqual(WorkPlanFacts.audit(of: status(contaminated: false, partial: false)), .clean)
        XCTAssertEqual(WorkPlanFacts.audit(of: status(contaminated: false, partial: true)), .open)
        XCTAssertEqual(WorkPlanFacts.audit(of: status(contaminated: true, partial: true)), .findings)
        XCTAssertEqual(WorkPlanFacts.audit(of: status(contaminated: true, partial: false, moved: 1)), .notDrawn, "its marks changed since the draw: the findings are taken as dealt with")
        XCTAssertNil(WorkPlanFacts.audit(of: status(contaminated: false, partial: true, setAside: "typed edited")))
    }

    func testTheFactsAreReadFromTheProjectsFilesAndARecordingTheyDoNotNameIsItsOwnGroup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workplan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().date(from: "2026-11-26T18:00:00Z")!
        let store = FootageProperties.Store(root: root)
        try store.save(FootageProperties.File(video: "a", recordingType: .continuous, recordingTypeBy: "bw", recordingTypeAt: EventReview.stamp(now), updatedAt: EventReview.stamp(now)))
        try store.save(FootageProperties.File(video: "b", recordingType: .unknown, updatedAt: EventReview.stamp(now)))   // nobody has said
        let facts = WorkPlanFacts.read(root: root, recordings: ["b", "a"], now: now)
        XCTAssertEqual(facts.types, ["a": "continuous"])
        XCTAssertEqual(facts.published.recordings.map(\.name), ["a", "b"])
        XCTAssertEqual(facts.published.recordings.map(\.group), ["a", "b"], "no manifest: each its own group")
        XCTAssertEqual(facts.published.recordings.map(\.audit), [.notDrawn, .notDrawn], "no draws: nothing is drawn")
        XCTAssertEqual(facts.published.publishedAt, EventReview.stamp(now))
    }
}
