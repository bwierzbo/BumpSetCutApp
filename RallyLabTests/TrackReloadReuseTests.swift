//
//  TrackReloadReuseTests.swift
//  RallyLabTests
//
//  The phone's full reload used to ask for every tracked rally in one request — the heaviest read there is, which
//  ran into the server's statement limit and held up everything else (a download link could not be signed while
//  three of them ran). It now asks which rallies changed (`trackStamps`) and takes in full only those it does not
//  already hold as the server has them. This is the rule that decides which.
//

import XCTest
@testable import RallyLab

final class TrackReloadReuseTests: XCTestCase {
    private let video = UUID()
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func track(_ id: UUID = UUID(), updatedAt: Date?, deleted: Bool = false) -> LabelTrack {
        LabelTrack(id: id, videoId: video, start: 1, end: 2, points: .init([]), done: true, deleted: deleted,
                   updatedAt: updatedAt, reviewed: nil, unsure: nil, machine: nil, isRally: nil)
    }

    private func stamp(_ t: LabelTrack, updatedAt: Date?, deleted: Bool? = nil, video: UUID? = nil) -> LabelingClient.TrackStamp {
        LabelingClient.TrackStamp(id: t.id, videoId: video ?? t.videoId, deleted: deleted ?? t.deleted, updatedAt: updatedAt)
    }

    func testARallyHeldAsTheServerHasItIsKeptAndNotFetched() {
        let held = track(updatedAt: at)
        // The server's time comes back through JSON: equal to the millisecond, not to the bit.
        let plan = LabelingClient.reuse([held], for: [stamp(held, updatedAt: at.addingTimeInterval(0.0004))])
        XCTAssertEqual(plan.kept, [held])
        XCTAssertEqual(plan.fetch, [])
    }

    func testARallyChangedOnTheServerOrNewThereIsFetched() {
        let changed = track(updatedAt: at), unknown = track(updatedAt: at)
        let plan = LabelingClient.reuse([changed], for: [stamp(changed, updatedAt: at.addingTimeInterval(5)), stamp(unknown, updatedAt: at)])
        XCTAssertEqual(plan.kept, [])
        XCTAssertEqual(plan.fetch, [changed.id, unknown.id])
    }

    func testARallyTheServerNoLongerListsIsDropped() {
        let gone = track(updatedAt: at), stays = track(updatedAt: at)
        let plan = LabelingClient.reuse([gone, stays], for: [stamp(stays, updatedAt: at)])
        XCTAssertEqual(plan.kept, [stays])
        XCTAssertEqual(plan.fetch, [])
    }

    func testARallyEditedHereSinceItWasLoadedIsFetchedAgain() {
        // A local edit clears the time (LabelerModel.apply, setIsRally): the row is no longer the server's.
        let edited = track(updatedAt: nil)
        XCTAssertEqual(LabelingClient.reuse([edited], for: [stamp(edited, updatedAt: at)]).fetch, [edited.id])
        // And a stamp without a time proves nothing either.
        let held = track(updatedAt: at)
        XCTAssertEqual(LabelingClient.reuse([held], for: [stamp(held, updatedAt: nil)]).fetch, [held.id])
    }

    func testADeletionOrAMoveToAnotherRecordingIsFetched() {
        let deletedThere = track(updatedAt: at), moved = track(updatedAt: at)
        let plan = LabelingClient.reuse([deletedThere, moved],
                                        for: [stamp(deletedThere, updatedAt: at, deleted: true), stamp(moved, updatedAt: at, video: UUID())])
        XCTAssertEqual(plan.kept, [])
        XCTAssertEqual(plan.fetch, [deletedThere.id, moved.id])
    }
}
