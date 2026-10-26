//
//  CommitGateTests.swift
//  RallyLabTests
//
//  The phone's commit gate (Labeler/Shared/FrameIdentity.swift): a boundary commit
//  on a copy is allowed only when the recording is reviewable there, the Mac has
//  published the original's frame identity, the copy is downloaded, and the copy's
//  own frame times reproduce that digest. Everything else is playback only.
//

import XCTest
@testable import RallyLab

final class CommitGateTests: XCTestCase {
    private let times: [Double] = (0..<90).map { Double($0) / 30 }
    private var digest: String { FrameIdentity.digest(of: times) }

    func testOnlyAVerifiedCopyOfAReviewableRecordingMayCommit() {
        XCTAssertEqual(CommitGate.decide(reviewable: true, publishedDigest: digest, copyFrames: .success(times)).verdict, .allowed)
        XCTAssertTrue(CommitGate.decide(reviewable: true, publishedDigest: digest, copyFrames: .success(times)).allowed)
    }

    func testWithheldWinsOverEverything() {
        XCTAssertEqual(CommitGate.decide(reviewable: false, publishedDigest: digest, copyFrames: .success(times)).verdict, .withheld)
        XCTAssertEqual(CommitGate.decide(reviewable: false, publishedDigest: nil, copyFrames: nil).verdict, .withheld)
    }

    func testNoPublishedIdentityMeansPlaybackOnly() {
        XCTAssertEqual(CommitGate.decide(reviewable: true, publishedDigest: nil, copyFrames: .success(times)).verdict, .noDigestPublished)
        XCTAssertEqual(CommitGate.decide(reviewable: true, publishedDigest: "", copyFrames: .success(times)).verdict, .noDigestPublished)
    }

    func testAStreamedCopyIsPlaybackOnly() {
        let g = CommitGate.decide(reviewable: true, publishedDigest: digest, copyFrames: nil)
        XCTAssertEqual(g.verdict, .copyNotDownloaded)
        XCTAssertFalse(g.allowed)
    }

    func testACopyWhoseFramesDifferIsRefusedNamingTheCount() {
        // One frame dropped, or one frame's time rounded: not the original's frames.
        let dropped = Array(times.dropLast())
        guard case .framesDiffer(let n, let original) = CommitGate.decide(reviewable: true, publishedDigest: digest, copyFrames: .success(dropped)).verdict else { return XCTFail("frames differ") }
        XCTAssertEqual(n, 89); XCTAssertEqual(original, digest)
        var rounded = times; rounded[10] = 0.33
        XCTAssertFalse(CommitGate.decide(reviewable: true, publishedDigest: digest, copyFrames: .success(rounded)).allowed, "no silent rounding")
        XCTAssertTrue(CommitGate.decide(reviewable: true, publishedDigest: digest, copyFrames: .success(rounded)).reason.contains("commits refused"))
    }

    func testUnreadableFramesAreRefusedWithTheReason() {
        struct Boom: LocalizedError { var errorDescription: String? { "no video track" } }
        let g = CommitGate.decide(reviewable: true, publishedDigest: digest, copyFrames: .failure(Boom()))
        XCTAssertEqual(g.verdict, .framesUnreadable("no video track"))
        XCTAssertTrue(g.reason.contains("no video track"))
    }
}
