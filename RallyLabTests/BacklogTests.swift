//
//  BacklogTests.swift
//  RallyLabTests
//
//  The labeling backlog (migration 053; owner, 2026-11-06): a recording set
//  aside leaves the marking and tracking queues on both devices until put
//  back, the work queue blocks its tasks, the row carries why and when, and
//  an older row or session without the columns still decodes.
//

import XCTest
@testable import RallyLab

@MainActor
final class BacklogTests: XCTestCase {
    private func plan(_ name: String, surface: String = "Beach") -> PlanVideo {
        PlanVideo(name: name, surface: surface, split: "train", available: true, rallies: 0, labeledFrames: 0, checkedFrames: 0, openRallies: 1, ralliesMarked: false)
    }
    private func video(_ name: String, found: Int = 3, marked: Int = 0, backlog: Bool = false, rally: LabelRally? = nil) -> LabelQueue.Video {
        LabelQueue.Video(plan: plan(name), nextRally: rally, found: found, marked: marked, complete: false, backlog: backlog)
    }

    func testASetAsideRecordingIsNoJobOfEitherKindUntilPutBack() {
        let rally = LabelRally(start: 10, end: 20)
        let videos = [video("a", found: 9, rally: rally), video("b", found: 5, marked: 2, backlog: true, rally: rally), video("c", found: 1)]
        let jobs = LabelQueue.jobs(videos, round: TrainingPlan.rounds.first)
        XCTAssertFalse(jobs.contains { $0.video == "b" }, "set aside: neither marking nor tracking offers it")
        XCTAssertEqual(LabelQueue.markingJobs(videos).map(\.video), ["a", "c"], "the started one would have led, but it is set aside")
        XCTAssertTrue(jobs.contains(.track("a", rally)), "the others still track: \(jobs)")
        // Put back: it leads again (started ones first).
        let back = [videos[0], video("b", found: 5, marked: 2, rally: rally), videos[2]]
        XCTAssertEqual(LabelQueue.markingJobs(back).map(\.video).first, "b")
    }

    func testASetAsideRecordingIsNoCandidateForThePlanEither() {
        // Every preferred candidate set aside: the plan's slots go to the others instead of standing empty.
        let rally = LabelRally(start: 10, end: 20)
        let aside = (0..<8).map { video("aside\($0)", found: 20, backlog: true, rally: rally) }
        let others = (0..<3).map { video("other\($0)", found: 1, rally: rally) }
        let jobs = LabelQueue.jobs(aside + others, round: TrainingPlan.rounds.first)
        XCTAssertFalse(jobs.contains { $0.video.hasPrefix("aside") })
        XCTAssertTrue(others.allSatisfy { o in jobs.contains(.track(o.plan.name, rally)) }, "\(jobs)")
        XCTAssertFalse(aside[0].plan.unavailable.available); XCTAssertEqual(aside[0].plan.unavailable.name, "aside0")
    }

    func testAPublishedRowNeverCarriesTheBacklog() throws {
        var row = LabelVideo(id: UUID(), project: "P", sessionName: "v", title: "", surface: .beach, camera: .endlineGround, lighting: "",
                             split: "train", clipPath: nil, duration: 0, ralliesFound: [], status: .rallylab, updatedAt: nil)
        row.backlogReason = "poor footage"; row.backlogAt = Date(); row.backlogBy = UUID()
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase
        let json = String(decoding: try e.encode(row), as: UTF8.self)
        XCTAssertFalse(json.contains("backlog"), "only setBacklog writes the backlog: \(json)")
        XCTAssertTrue(json.contains("\"session_name\":\"v\""))
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertFalse(try d.decode(LabelVideo.self, from: try e.encode(row)).isBacklogged)
    }

    func testThePatchSetsAsideOrPutsBackWithExplicitNulls() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let by = UUID(uuidString: "139A3DC5-DB9A-400C-A00E-7C7102F8E62C")!
        XCTAssertEqual(String(decoding: LabelingClient.backlogPayload(reason: "poor footage", by: by, at: at), as: UTF8.self),
                       #"{"backlog_reason":"poor footage","backlog_at":"2027-01-15T08:00:00Z","backlog_by":"139a3dc5-db9a-400c-a00e-7c7102f8e62c","updated_at":"2027-01-15T08:00:00Z"}"#)
        XCTAssertEqual(String(decoding: LabelingClient.backlogPayload(reason: nil, by: by, at: at), as: UTF8.self),
                       #"{"backlog_reason":null,"backlog_at":null,"backlog_by":null,"updated_at":"2027-01-15T08:00:00Z"}"#)
        XCTAssertEqual(String(decoding: LabelingClient.backlogPayload(reason: "a \"quoted\" reason", by: nil, at: at), as: UTF8.self),
                       #"{"backlog_reason":"a \"quoted\" reason","backlog_at":"2027-01-15T08:00:00Z","backlog_by":null,"updated_at":"2027-01-15T08:00:00Z"}"#)
    }

    func testARowOrASessionWithoutTheColumnsStillDecodesAsNotSetAside() throws {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        let old = Data(#"{"id":"80e9f985-aaf2-486b-b874-ead468e38c22","title":"t","surface":"Beach","camera":"endline_raised","lighting":"","split":"train","duration":20,"rallies_found":[],"status":"rallylab"}"#.utf8)
        let row = try d.decode(LabelVideo.self, from: old)
        XCTAssertFalse(row.isBacklogged); XCTAssertNil(row.backlogReason)
        let set = Data(#"{"id":"80e9f985-aaf2-486b-b874-ead468e38c22","title":"t","surface":"Beach","camera":"endline_raised","lighting":"","split":"train","duration":20,"rallies_found":[],"status":"rallylab","backlog_reason":"wrong camera","backlog_at":"2026-11-06T20:00:00Z","backlog_by":null}"#.utf8)
        let aside = try d.decode(LabelVideo.self, from: set)
        XCTAssertTrue(aside.isBacklogged); XCTAssertEqual(aside.backlogReason, "wrong camera")
        // The Mac's session file from before the columns.
        var session = VideoSession(name: "v", sourcePath: "/x/v.mp4", split: "train", addedAt: Date(), frames: [])
        let roundTrip = try JSONDecoder().decode(VideoSession.self, from: try JSONEncoder().encode(session))
        XCTAssertNil(roundTrip.backlogAt)
        session.backlogReason = "poor footage"; session.backlogAt = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(try JSONDecoder().decode(VideoSession.self, from: try JSONEncoder().encode(session)).backlogReason, "poor footage")
        // (The phone's outbox, which carries a set-aside until it is sent, is an iOS-only store: covered by its
        // build and by the shared row and queue rules above.)
    }

    func testTheWorkQueueBlocksASetAsideRecordingsTasks() {
        let now = Date()
        var s = VideoSession(name: "v", sourcePath: "/x/v.mp4", split: "train", addedAt: now, frames: [])
        s.backlogReason = "poor footage"; s.backlogAt = now
        let inputs = WorkQueueReconciler.Inputs(sessions: [s], withheld: [], events: [:], net: nil, netProblem: nil, identityKeys: [:],
                                                policy: WorkQueue.Policy(), now: now, admission: [:], admissionReason: [:])
        let v = WorkQueueReconciler.verdicts(inputs)
        XCTAssertEqual(v[.rallyBoundaries]?["v"]?.state, .blocked)
        XCTAssertEqual(v[.ballTracks]?["v"]?.state, .blocked)
        XCTAssertTrue(v[.rallyBoundaries]?["v"]?.reason?.contains("poor footage") ?? false)
        s.backlogReason = nil; s.backlogAt = nil
        let back = WorkQueueReconciler.verdicts(WorkQueueReconciler.Inputs(sessions: [s], withheld: [], events: [:], net: nil, netProblem: nil, identityKeys: [:],
                                                                           policy: WorkQueue.Policy(), now: now, admission: [:], admissionReason: [:]))
        XCTAssertNotEqual(back[.ballTracks]?["v"]?.state, .blocked, "put back: judged from its records again")
    }
}
