//
//  RallyEventsSyncTests.swift
//  RallyLabTests
//
//  The cross-device sync decisions for Stage 1 records, made the same way on the Mac
//  and the phone (RallyEventsSync): what one side does given its record, its shadow
//  of the last sync and the server's row; the schema's keys surviving the labeling
//  client's snake-case strategies; the server's refusals recognised.
//

import XCTest
@testable import RallyLab

final class RallyEventsSyncTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-26T20:00:00Z")!

    private func file(_ video: String = "v", revision: Int = 0, rallies: Int = 0, digest: String? = nil) -> EventReview.File {
        var f = EventReview.File(video: video, sourceFingerprint: "file:abc", frameRate: 30, durationSec: 10, tool: "t", frameTimesDigest: digest, revision: revision)
        EventReview.Mutation.markReviewed(from: 0, to: 10, in: &f, at: now, annotator: "BW")
        for i in 0..<rallies {
            let r = EventReview.Rally(rallyId: UUID(), kind: .rally, contact: .init(earliest: Double(i), latest: Double(i)), dead: .init(earliest: Double(i) + 0.5, latest: Double(i) + 0.5),
                                      annotator: "BW", reviewedAt: EventReview.stamp(now))
            EventReview.Mutation.upsert(r, in: &f)
        }
        return f
    }

    private func row(_ record: EventReview.File, revision: Int) -> LabelRallyEvents {
        var r = record; r.revision = revision
        return LabelRallyEvents(videoId: UUID(), project: "Scratch", sessionName: record.video, annotationVersion: EventReview.annotationVersion,
                                record: r, revision: revision, updatedBy: nil, updatedAt: now)
    }

    func testDecisionsCoverEveryCombination() {
        XCTAssertEqual(RallyEventsSync.decide(local: nil, shadow: nil, server: nil), .upToDate)
        // New here, nothing on the server: push as new.
        XCTAssertEqual(RallyEventsSync.decide(local: file(), shadow: nil, server: nil), .push(expected: 0))
        // On the server only: take it.
        XCTAssertEqual(RallyEventsSync.decide(local: nil, shadow: nil, server: row(file(), revision: 3)), .pull)
        // Synced at 3, unchanged on both sides.
        let synced = file(revision: 3, rallies: 1)
        XCTAssertEqual(RallyEventsSync.decide(local: synced, shadow: synced, server: row(synced, revision: 3)), .upToDate)
        // I changed it, the server did not: push at 3.
        let mine = file(revision: 3, rallies: 2)
        XCTAssertEqual(RallyEventsSync.decide(local: mine, shadow: synced, server: row(synced, revision: 3)), .push(expected: 3))
        // The server moved to 4, I did not touch mine: pull.
        XCTAssertEqual(RallyEventsSync.decide(local: synced, shadow: synced, server: row(file(revision: 4, rallies: 2), revision: 4)), .pull)
        // Both changed: conflict, with both revisions named.
        XCTAssertEqual(RallyEventsSync.decide(local: mine, shadow: synced, server: row(file(revision: 4, rallies: 3), revision: 4)), .conflict(local: 3, server: 4))
        // No shadow (an older install): a local record at revision 0 beside a server row counts as changed here.
        XCTAssertEqual(RallyEventsSync.decide(local: file(rallies: 1), shadow: nil, server: row(file(), revision: 1)), .conflict(local: 0, server: 1))
        // No shadow, same content and revision: nothing to do; same revision, different content: push.
        XCTAssertEqual(RallyEventsSync.decide(local: synced, shadow: nil, server: row(synced, revision: 3)), .upToDate)
        XCTAssertEqual(RallyEventsSync.decide(local: mine, shadow: nil, server: row(synced, revision: 3)), .push(expected: 3))
        // A local record that lost its revision bookkeeping but matches the shadow is not a local change: the server's
        // copy (same content, right revision) is taken, which repairs the bookkeeping.
        var bookkeeping = synced; bookkeeping.revision = 0
        XCTAssertEqual(RallyEventsSync.decide(local: bookkeeping, shadow: synced, server: row(synced, revision: 3)), .pull)
    }

    func testRecordKeysSurviveTheClientsKeyStrategies() throws {
        // The row is read by the client's decoder (snake_case → camelCase): the record inside keeps its own keys.
        let f = file(revision: 2, rallies: 1, digest: "abc")
        let rowJSON = """
        {"video_id":"6D2F7E3C-0D4A-4B2E-9B4E-2E7E3E6C0D4A","project":"Scratch","session_name":"v","annotation_version":"rally_event_truth_v1",
         "record":\(String(decoding: try RallyEventsSync.encodeRecord(f), as: UTF8.self)),"revision":2,"updated_by":null,"updated_at":"2026-10-26T20:00:00.123456+00:00"}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? Date()
        }
        let row = try decoder.decode(LabelRallyEvents.self, from: Data(rowJSON.utf8))
        XCTAssertEqual(row.sessionName, "v"); XCTAssertEqual(row.revision, 2)
        XCTAssertEqual(row.record, f, "frameTimesDigest, sourceFingerprint and the rest keep their camelCase keys")
        XCTAssertEqual(row.record.frameTimesDigest, "abc")
        // The record sent in the RPC body is the same bytes the app writes to disk (sorted camelCase keys).
        let body = try RallyEventsSync.encodeRecord(f)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("\"frameTimesDigest\":\"abc\""))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("frame_times_digest"))
        XCTAssertEqual(try JSONDecoder().decode(EventReview.File.self, from: body), f)
    }

    func testServerRefusalsAreRecognised() {
        let c = RallyEventsSync.conflict(in: "conflict: the record changed on the server (revision 5, expected 3)")
        XCTAssertEqual(c?.serverRevision, 5)
        XCTAssertEqual(RallyEventsSync.conflict(in: "conflict: no record on the server yet, expected revision 2 (server 0)")?.serverRevision, 2)
        XCTAssertNil(RallyEventsSync.conflict(in: "withheld: x is a withheld recording"))
        XCTAssertTrue(RallyEventsSync.isWithheld("withheld: project P has no published withheld list; nothing is accepted until RallyLab publishes it"))
        XCTAssertFalse(RallyEventsSync.isWithheld("rally_events_save: labelers only"))
    }

    func testAnUnreadableLocalRecordIsNeverTakenAsAbsent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rallyevents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = EventReview.url(forVideo: dir.appendingPathComponent("clip.mp4"))
        XCTAssertEqual(RallyEventsSync.localState(at: url), .absent)
        let f = file(revision: 2, rallies: 1)
        try EventReview.write(f, to: url)
        XCTAssertEqual(RallyEventsSync.localState(at: url), .record(f))
        try Data("{not json".utf8).write(to: url)
        guard case .unreadable = RallyEventsSync.localState(at: url) else { return XCTFail("a present but unreadable record is neither absent nor a record") }
        XCTAssertNil(RallyEventsSync.localState(at: url).record, "the sync has nothing to decide on, so nothing is written over it")
    }

    func testAnEditMadeWhileTheSaveWasInFlightIsKeptOnTheNewRevision() {
        let sent = file(revision: 3, rallies: 1)
        var saved = sent; saved.revision = 4
        // Nothing changed meanwhile: the saved copy is both the record and the shadow.
        var r = RallyEventsSync.afterPush(sent: sent, current: sent, saved: saved)
        XCTAssertEqual(r.local, saved); XCTAssertEqual(r.shadow, saved)
        r = RallyEventsSync.afterPush(sent: sent, current: nil, saved: saved)
        XCTAssertEqual(r.local, saved)
        // A commit landed during the save: that newer content stays, carrying the server's revision so the next sync
        // pushes it at 4; the shadow is what the server holds.
        let newer = file(revision: 3, rallies: 2)
        r = RallyEventsSync.afterPush(sent: sent, current: newer, saved: saved)
        XCTAssertEqual(r.local.rallies.count, 2); XCTAssertEqual(r.local.revision, 4); XCTAssertEqual(r.shadow, saved)
        XCTAssertEqual(RallyEventsSync.decide(local: r.local, shadow: r.shadow, server: row(saved, revision: 4)), .push(expected: 4))
    }

    func testTheOpenEditorAdoptsASyncedRecordKeepingTheDraft() {
        var e = BoundaryEditor(file: file(revision: 3, rallies: 2), annotator: "BW", tool: "t")
        let id = e.file.rallies[0].rallyId
        _ = e.apply(.select(id), at: 0, now: now)
        _ = e.apply(.mark(.contact, .earliest), at: 0.2, now: now)
        XCTAssertEqual(e.draft.rallyId, id)
        // Same content at a newer revision: bookkeeping only, the draft and selection stand.
        var synced = e.file; synced.revision = 4
        XCTAssertFalse(e.adopt(synced))
        XCTAssertEqual(e.file.revision, 4); XCTAssertEqual(e.selected, id); XCTAssertEqual(e.draft.contact?.earliest, 0.2)
        // Different content from the other side: taken, undoable, the draft kept while its rally still exists.
        var other = synced; other.revision = 5
        EventReview.Mutation.upsert(EventReview.Rally(rallyId: UUID(), kind: .rally, contact: .init(earliest: 5, latest: 5), dead: .init(earliest: 6, latest: 6), annotator: "MAC", reviewedAt: EventReview.stamp(now)), in: &other)
        XCTAssertTrue(e.adopt(other))
        XCTAssertEqual(e.file.rallies.count, 3); XCTAssertEqual(e.file.revision, 5); XCTAssertEqual(e.selected, id); XCTAssertTrue(e.canUndo)
        // The selected rally withdrawn elsewhere: the selection and its draft go, nothing else.
        var withdrawn = other; withdrawn.revision = 6
        EventReview.Mutation.withdraw(id, in: &withdrawn, at: now, annotator: "MAC")
        XCTAssertTrue(e.adopt(withdrawn))
        XCTAssertNil(e.selected); XCTAssertNil(e.draft.rallyId)
    }

    func testUndoKeepsTheSynchronisedRevision() {
        var e = BoundaryEditor(file: file(revision: 0), annotator: "BW", tool: "t")
        _ = e.apply(.mark(.contact, .earliest), at: 1, now: now)
        _ = e.apply(.mark(.dead, .earliest), at: 2, now: now)
        XCTAssertTrue(e.apply(.commit, at: 2, now: now).changed)
        // The push came back: revision 1.
        var saved = e.file; saved.revision = 1
        XCTAssertFalse(e.adopt(saved)); XCTAssertEqual(e.file.revision, 1)
        XCTAssertTrue(e.apply(.undo, at: 2, now: now).changed)
        XCTAssertTrue(e.file.rallies.isEmpty, "the content is undone")
        XCTAssertEqual(e.file.revision, 1, "the revision is bookkeeping, kept")
        XCTAssertEqual(RallyEventsSync.decide(local: e.file, shadow: saved, server: row(saved, revision: 1)), .push(expected: 1), "a change at the current revision, not a conflict")
    }

    func testADraftOverARallyTheOtherSideChangedIsNotCommittedUnseen() {
        var e = BoundaryEditor(file: file(revision: 1, rallies: 0), annotator: "BW", tool: "t")
        _ = e.apply(.mark(.contact, .earliest), at: 1, now: now)
        _ = e.apply(.mark(.dead, .earliest), at: 3, now: now)
        XCTAssertTrue(e.apply(.commit, at: 3, now: now).changed)
        let id = e.selected!
        var pushed = e.file; pushed.revision = 2
        XCTAssertFalse(e.adopt(pushed))
        // Editing it: a flag only, the times untouched in the draft.
        _ = e.apply(.select(id), at: 0, now: now)
        _ = e.apply(.toggleFlag("ambiguous"), at: 0, now: now)
        // Meanwhile the other side moved the contact to 2 s (revision 3).
        var theirs = pushed; theirs.revision = 3
        theirs.rallies[0].contact = .init(earliest: 2, latest: 2); theirs.rallies[0].annotator = "KD"
        XCTAssertTrue(e.adopt(theirs))
        XCTAssertNotNil(e.draftConflict); XCTAssertEqual(e.draftConflict?.incoming.contact?.earliest, 2)
        let refused = e.apply(.commit, at: 3, now: now)
        XCTAssertTrue(refused.refused, "the draft's 1 s contact must not overwrite their 2 s unseen"); XCTAssertEqual(e.file.rallies[0].contact?.earliest, 2)
        // Take theirs: the draft reloads from the incoming rally, my flag is gone, a commit changes nothing of the times.
        e.resolveDraftConflict(keepMine: false)
        XCTAssertNil(e.draftConflict); XCTAssertEqual(e.draft.contact?.earliest, 2); XCTAssertFalse(e.draft.flags.contains("ambiguous"))
        // Keep mine, explicitly: the commit replaces theirs at the current revision.
        _ = e.apply(.toggleFlag("ambiguous"), at: 0, now: now)
        var again = theirs; again.revision = 4; again.rallies[0].dead = .init(earliest: 3.5, latest: 3.5)
        XCTAssertTrue(e.adopt(again)); XCTAssertNotNil(e.draftConflict)
        e.resolveDraftConflict(keepMine: true)
        XCTAssertTrue(e.apply(.commit, at: 3, now: now).changed)
        XCTAssertEqual(e.file.rallies[0].contact?.earliest, 2, "mine was loaded from theirs at 2 s"); XCTAssertEqual(e.file.rallies[0].dead?.earliest, 3)
        XCTAssertTrue(e.file.rallies[0].flags.contains("ambiguous")); XCTAssertEqual(e.file.revision, 4)
        // An untouched draft simply follows the other side's change.
        _ = e.apply(.select(id), at: 0, now: now)
        var moved = e.file; moved.revision = 5; moved.rallies[0].dead = .init(earliest: 3.25, latest: 3.25)
        XCTAssertTrue(e.adopt(moved))
        XCTAssertNil(e.draftConflict); XCTAssertEqual(e.draft.dead?.earliest, 3.25)
    }

    func testDiscardingAConflictedDraftClearsTheConflict() {
        for discard in [BoundaryEditor.Action.withdraw, .undo] {
            var e = BoundaryEditor(file: file(revision: 1), annotator: "BW", tool: "t")
            _ = e.apply(.mark(.contact, .earliest), at: 1, now: now)
            _ = e.apply(.mark(.dead, .earliest), at: 3, now: now)
            XCTAssertTrue(e.apply(.commit, at: 3, now: now).changed)
            let id = e.selected!
            _ = e.apply(.select(id), at: 0, now: now)
            _ = e.apply(.toggleFlag("ambiguous"), at: 0, now: now)
            var theirs = e.file; theirs.revision = 2; theirs.rallies[0].contact = .init(earliest: 2, latest: 2)
            XCTAssertTrue(e.adopt(theirs)); XCTAssertNotNil(e.draftConflict)
            XCTAssertTrue(e.apply(discard, at: 0, now: now).changed, "\(discard)")
            XCTAssertNil(e.draftConflict, "\(discard) discards the draft and its conflict")
            _ = e.apply(.mark(.contact, .earliest), at: 5, now: now)
            _ = e.apply(.mark(.dead, .earliest), at: 7, now: now)
            XCTAssertTrue(e.apply(.commit, at: 7, now: now).changed, "an unrelated new rally commits after \(discard)")
        }
    }

    func testARecordIsTakenOnlyForTheRecordingAndFootageItDescribes() {
        let mine = file("v", revision: 2, rallies: 1)   // sourceFingerprint file:abc
        XCTAssertNil(RallyEventsSync.identityMismatch(of: mine, session: "v", originalFingerprint: "file:abc"))
        // Replaced footage (a deleted session name reused, or a new cut): refused, both kept.
        XCTAssertTrue(RallyEventsSync.identityMismatch(of: mine, session: "v", originalFingerprint: "file:new")?.contains("replaced footage") == true)
        // Another recording's record.
        XCTAssertTrue(RallyEventsSync.identityMismatch(of: mine, session: "w", originalFingerprint: "file:abc")?.contains("for v, not w") == true)
        // Missing identity on either side fails closed.
        XCTAssertNotNil(RallyEventsSync.identityMismatch(of: mine, session: "v", originalFingerprint: nil), "original unknown")
        XCTAssertNotNil(RallyEventsSync.identityMismatch(of: mine, session: "v", originalFingerprint: ""), "original unknown")
        var anonymous = mine; anonymous.sourceFingerprint = nil
        XCTAssertTrue(RallyEventsSync.identityMismatch(of: anonymous, session: "v", originalFingerprint: "file:abc")?.contains("no source fingerprint") == true)
        var other = mine; other.annotationVersion = "rally_event_truth_v0"
        XCTAssertNotNil(RallyEventsSync.identityMismatch(of: other, session: "v", originalFingerprint: "file:abc"))
        // A server row also names its project and session.
        let r = row(mine, revision: 2)   // Scratch / v
        XCTAssertNil(RallyEventsSync.identityMismatch(of: r, project: "Scratch", session: "v", originalFingerprint: "file:abc"))
        XCTAssertTrue(RallyEventsSync.identityMismatch(of: r, project: "Other", session: "v", originalFingerprint: "file:abc")?.contains("Scratch/v, not Other/v") == true)
        // The server's footage refusal is recognised apart from conflicts and withholding.
        XCTAssertTrue(RallyEventsSync.isIdentityRefusal("identity: the record describes footage file:x, but v is file:y"))
        XCTAssertNil(RallyEventsSync.conflict(in: "identity: no published original fingerprint"))
        XCTAssertFalse(RallyEventsSync.isWithheld("identity: …"))
    }

    func testAnOlderRecordGetsItsFingerprintOnceAndNeverLosesOne() {
        var anonymous = file(); anonymous.sourceFingerprint = nil
        var e = BoundaryEditor(file: anonymous, annotator: "BW", tool: "t")
        e.recordSourceFingerprint("file:now")
        XCTAssertEqual(e.file.sourceFingerprint, "file:now")
        e.recordSourceFingerprint("file:other")
        XCTAssertEqual(e.file.sourceFingerprint, "file:now", "a recorded fingerprint is never replaced")
        var known = BoundaryEditor(file: file(), annotator: "BW", tool: "t")
        known.recordSourceFingerprint("file:other")
        XCTAssertEqual(known.file.sourceFingerprint, "file:abc")
    }

    func testWithdrawingTheSelectedRallyElsewhereKeepsAnUnrelatedNewDraft() {
        var e = BoundaryEditor(file: file(revision: 1), annotator: "BW", tool: "t")
        _ = e.apply(.mark(.contact, .earliest), at: 1, now: now)
        _ = e.apply(.mark(.dead, .earliest), at: 3, now: now)
        XCTAssertTrue(e.apply(.commit, at: 3, now: now).changed)
        let a = e.selected!
        // Marking rally B: a new draft while A stays selected.
        _ = e.apply(.mark(.contact, .earliest), at: 5, now: now)
        XCTAssertNil(e.draft.rallyId); XCTAssertEqual(e.draft.contact?.earliest, 5)
        var theirs = e.file; theirs.revision = 2
        XCTAssertTrue(EventReview.Mutation.withdraw(a, in: &theirs, at: now, annotator: "KD"))
        XCTAssertTrue(e.adopt(theirs))
        XCTAssertNil(e.selected, "the withdrawn rally is deselected")
        XCTAssertEqual(e.draft.contact?.earliest, 5, "B's marks are kept")
        _ = e.apply(.mark(.dead, .earliest), at: 7, now: now)
        XCTAssertTrue(e.apply(.commit, at: 7, now: now).changed)
    }

    func testALostAcknowledgementIsRepairedNotAConflict() {
        // The Mac saved revision 2 but its bookkeeping still says 1 (local and shadow), with the same content as the server.
        let content = file(revision: 1, rallies: 2)
        var stale = content; stale.revision = 1
        var older = file(revision: 1, rallies: 1)   // the shadow from before the save
        older.revision = 1
        XCTAssertEqual(RallyEventsSync.decide(local: stale, shadow: older, server: row(content, revision: 2)), .pull, "identical content: repair the revision")
        // Different content at different revisions is still a conflict.
        XCTAssertEqual(RallyEventsSync.decide(local: file(revision: 1, rallies: 3), shadow: older, server: row(content, revision: 2)), .conflict(local: 1, server: 2))
    }

    func testShadowAndConflictFilesSitBesideTheRecordNeverOverIt() {
        let record = EventReview.url(forVideo: URL(fileURLWithPath: "/footage/clip.mp4"))
        XCTAssertEqual(record.lastPathComponent, "clip.rallyevents.json")
        XCTAssertEqual(RallyEventsSync.shadowURL(for: record).lastPathComponent, "clip.rallyevents.synced.json")
        XCTAssertEqual(RallyEventsSync.conflictURL(for: record, serverRevision: 4).lastPathComponent, "clip.rallyevents.conflict-r4.json")
        XCTAssertNotEqual(RallyMarkModel.labelsURL(for: URL(fileURLWithPath: "/footage/clip.mp4")), record, "the legacy file is another file")
    }
}
