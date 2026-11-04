//
//  RecordingTypeClaimsTests.swift
//  RallyLabTests
//
//  The shared rules of a footage-type claim (D-033): what the phone shows
//  for a recording (the newest choice and its state, a refusal or a
//  replacement never dropped), what the Mac decides on a submitted claim
//  from the project as it is (what is wrong with the claim is declined,
//  what is wrong on the Mac is deferred, a newer Mac decision wins, the
//  claim already on file is acknowledged without a second write), and the
//  row surviving the labeling client's snake-case strategy.
//

import XCTest
@testable import RallyLab

final class RecordingTypeClaimsTests: XCTestCase {
    private let video = UUID()
    private let t0 = ISO8601DateFormatter().date(from: "2026-11-04T10:00:00Z")!

    private func claim(_ kind: String = "continuous", revision: Int = 1, status: RecordingTypeClaim.Status = .submitted, reason: String? = nil,
                       fingerprint: String = "file:abc", at: Date? = nil, video: UUID? = nil, id: UUID = UUID()) -> RecordingTypeClaim {
        RecordingTypeClaim(id: id, videoId: video ?? self.video, project: "A", sessionName: "video_01", sourceFingerprint: fingerprint, recordingType: kind,
                           revision: revision, status: status, reason: reason, submittedBy: UUID(), submittedAt: at ?? t0, settledBy: nil, settledAt: nil, updatedAt: nil)
    }

    // MARK: - What the phone shows

    func testThePhoneShowsTheNewestChoiceAndItsState() {
        let pending = RecordingTypeClaims.Pending(id: UUID(), videoId: video, sourceFingerprint: "file:abc", kind: .edited, madeAt: t0.addingTimeInterval(60))
        let rows = [claim(revision: 1, status: .superseded, reason: "replaced by a newer choice"), claim("edited", revision: 2, status: .accepted)]
        XCTAssertEqual(RecordingTypeClaims.display(video: video, pending: [:], rows: []), .none)
        // The server's newest revision, whatever its state.
        XCTAssertEqual(RecordingTypeClaims.display(video: video, pending: [:], rows: rows), .accepted(rows[1]))
        let rejected = claim("unknown", revision: 3, status: .rejected, reason: "the recording's file changed since this was sent — confirm again")
        XCTAssertEqual(RecordingTypeClaims.display(video: video, pending: [:], rows: rows + [rejected]), .rejected(rejected, reason: rejected.reason!))
        XCTAssertEqual(RecordingTypeClaims.display(video: video, pending: [:], rows: [rows[0]]), .superseded(rows[0]))
        let waiting = claim(revision: 4)
        XCTAssertEqual(RecordingTypeClaims.display(video: video, pending: [:], rows: rows + [waiting]), .submitted(waiting))
        // A choice still on the phone is newer than anything the server has from it.
        XCTAssertEqual(RecordingTypeClaims.display(video: video, pending: [pending.id: pending], rows: rows + [waiting]), .pending(pending))
        // Another recording's rows are not this one's.
        XCTAssertEqual(RecordingTypeClaims.display(video: UUID(), pending: [pending.id: pending], rows: rows), .none)
        // The words: a sent choice is never "accepted"; a refusal names the reason; a pending one that couldn't be sent says so.
        XCTAssertEqual(RecordingTypeClaims.Display.submitted(waiting).statusText(), "Continuous recording: sent — waiting for the Mac to confirm.")
        XCTAssertEqual(RecordingTypeClaims.Display.pending(pending).statusText(), "Edited recording: saved on this phone, sends when online.")
        XCTAssertEqual(RecordingTypeClaims.Display.pending(pending).statusText(problem: "withheld: video_01 is not open to labeling"),
                       "Edited recording: couldn't be sent — withheld: video_01 is not open to labeling. Choose again to try afresh.")
        XCTAssertEqual(RecordingTypeClaims.Display.rejected(rejected, reason: rejected.reason!).statusText(),
                       "Unknown: not accepted — the recording's file changed since this was sent — confirm again. You can choose again.")
        XCTAssertTrue(RecordingTypeClaims.Display.accepted(rows[1]).statusText().hasPrefix("Edited recording: accepted on the Mac"))
        XCTAssertTrue(RecordingTypeClaims.Display.submitted(waiting).isOpen); XCTAssertFalse(RecordingTypeClaims.Display.accepted(rows[1]).isOpen)
    }

    // MARK: - What the Mac decides

    func testTheMacDeclinesWhatIsWrongWithTheClaimBeforeAnythingIsWritten() {
        let c = claim()
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: "file:abc", withheld: true, record: .none), .reject("this recording is withheld from labeling on the Mac"))
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: nil, withheld: false, record: .none), .reject("the recording has no file identity on the Mac"))
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: "file:new", withheld: false, record: .none),
                       .reject("the recording's file changed since this was sent — confirm again"))
        XCTAssertEqual(RecordingTypeClaims.decide(claim: claim("replay"), cardFingerprint: "file:abc", withheld: false, record: .none),
                       .reject("the choice \"replay\" is not one this Mac knows"))
        // Withheld wins over everything else; a stale fingerprint over the record's state.
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: nil, withheld: true, record: .unreadable("x")), .reject("this recording is withheld from labeling on the Mac"))
    }

    func testTheMacDefersWhatIsWrongOnTheMacAndAcceptsTheRest() {
        let c = claim()
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: "file:abc", withheld: false, record: .unreadable("not json")),
                       .defer("the recording's footage record can't be read on the Mac: not json"))
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: "file:abc", withheld: false, record: .none), .accept)
        // A record older than the claim: the claim is the newer human decision.
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: "file:abc", withheld: false,
                                                  record: .record(type: "edited", by: "BW", at: "2026-11-04T09:00:00Z")), .accept)
        // An explicit "unknown" is a decision too, newer than the record: accepted.
        XCTAssertEqual(RecordingTypeClaims.decide(claim: claim("unknown"), cardFingerprint: "file:abc", withheld: false,
                                                  record: .record(type: "continuous", by: "BW", at: "2026-11-04T09:00:00Z")), .accept)
        // A record with no time (an older writer) does not outrank the claim.
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: "file:abc", withheld: false, record: .record(type: "edited", by: nil, at: nil)), .accept)
    }

    func testANewerDecisionOnTheMacWinsAndTheClaimAlreadyOnFileIsAcknowledgedWithoutASecondWrite() {
        let c = claim()
        // Confirmed on the Mac after the claim was sent: the claim is stale — declined, the Mac's type named.
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: "file:abc", withheld: false,
                                                  record: .record(type: "edited", by: "BW", at: "2026-11-04T10:00:01Z")),
                       .reject("confirmed on the Mac as edited recording after this was sent — confirm again if that is wrong"))
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: "file:abc", withheld: false,
                                                  record: .record(type: "unknown", by: "BW", at: "2026-11-04T10:00:00.500Z")),
                       .reject("confirmed on the Mac as unknown after this was sent — confirm again if that is wrong"), "fractional seconds read too")
        // The record carries this very claim (its acknowledgement was lost): acknowledged, nothing written again.
        let by = RecordingTypeClaims.attribution(of: c)
        XCTAssertTrue(by.hasSuffix("claim \(c.id.uuidString.lowercased())")); XCTAssertTrue(by.hasPrefix("labeler "))
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: "file:abc", withheld: false,
                                                  record: .record(type: "continuous", by: by, at: "2026-11-04T10:00:00Z")), .alreadyApplied)
        // The same claim id but another type on file (someone changed it on the Mac since): the Mac's later decision wins.
        XCTAssertEqual(RecordingTypeClaims.decide(claim: c, cardFingerprint: "file:abc", withheld: false,
                                                  record: .record(type: "edited", by: "BW", at: "2026-11-04T11:00:00Z")),
                       .reject("confirmed on the Mac as edited recording after this was sent — confirm again if that is wrong"))
        // Another claim's attribution is not this one's.
        XCTAssertFalse(RecordingTypeClaims.isAttributed(RecordingTypeClaims.attribution(of: claim()), to: c))
    }

    // MARK: - The row and the server's words

    func testARowDecodesFromTheServersKeysAndRefusalsAreRecognised() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let id = UUID(), v = UUID(), who = UUID()
        let body = Data("""
        {"id":"\(id.uuidString)","video_id":"\(v.uuidString)","project":"Scratch","session_name":"bch_a","source_fingerprint":"file:abc",
         "recording_type":"edited","revision":2,"status":"rejected","reason":"the recording's file changed since this was sent — confirm again",
         "submitted_by":"\(who.uuidString)","submitted_at":"2026-11-04T10:00:00Z","settled_by":null,"settled_at":"2026-11-04T10:05:00Z","updated_at":"2026-11-04T10:05:00Z"}
        """.utf8)
        let row = try decoder.decode(RecordingTypeClaim.self, from: body)
        XCTAssertEqual(row.id, id); XCTAssertEqual(row.videoId, v); XCTAssertEqual(row.kind, .edited); XCTAssertEqual(row.status, .rejected)
        XCTAssertEqual(row.submittedBy, who); XCTAssertNil(row.settledBy); XCTAssertEqual(row.settledAt, t0.addingTimeInterval(300))
        // A type this build does not know still decodes (kept as text, shown as such).
        let odd = try decoder.decode(RecordingTypeClaim.self, from: Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\"edited\"", with: "\"montage\"").utf8))
        XCTAssertNil(odd.kind); XCTAssertEqual(odd.recordingType, "montage")
        XCTAssertTrue(RecordingTypeClaims.isRefusal("withheld: bch_a is not open to labeling"))
        XCTAssertTrue(RecordingTypeClaims.isRefusal("identity: the claim is about footage file:x, but bch_a is file:abc"))
        XCTAssertTrue(RecordingTypeClaims.isRefusal("recording_type_claim_submit: claim id … is already used for another claim"))
        XCTAssertFalse(RecordingTypeClaims.isRefusal("conflict: claim … is already accepted"))
        XCTAssertFalse(RecordingTypeClaims.isRefusal("The network connection was lost."))
        XCTAssertEqual(RecordingTypeClaims.parse("2026-11-04T10:00:00Z"), t0); XCTAssertEqual(RecordingTypeClaims.parse("2026-11-04T10:00:00.250Z"), t0.addingTimeInterval(0.25))
    }

    /// An older build's rows and a newer server: the videos row without the published type decodes as before, and
    /// a row with it carries it; a build that never knew the columns encodes neither (nil keys are left out), so its
    /// upserts leave the server's values as they are.
    func testTheVideosRowReadsWithAndWithoutThePublishedType() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let id = UUID()
        let old = Data("""
        {"id":"\(id.uuidString)","project":"Scratch","session_name":"a","title":"","surface":"Beach","camera":"endline_ground","lighting":"",
         "split":"train","clip_path":null,"duration":300,"rallies_found":[],"status":"rallylab","updated_at":null,"source_fingerprint":"file:abc"}
        """.utf8)
        let row = try decoder.decode(LabelVideo.self, from: old)
        XCTAssertNil(row.recordingType); XCTAssertNil(row.recordingTypeAt); XCTAssertEqual(row.sourceFingerprint, "file:abc")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        XCTAssertFalse(String(decoding: try encoder.encode(row), as: UTF8.self).contains("recording_type"), "nothing sent for the columns when unset")
        let published = try decoder.decode(LabelVideo.self, from: Data(String(decoding: old, as: UTF8.self)
            .replacingOccurrences(of: "\"source_fingerprint\":\"file:abc\"", with: "\"source_fingerprint\":\"file:abc\",\"recording_type\":\"edited\",\"recording_type_at\":\"2026-11-04T10:00:00Z\"").utf8))
        XCTAssertEqual(published.recordingType, "edited"); XCTAssertEqual(published.recordingTypeAt, t0)
    }
}
