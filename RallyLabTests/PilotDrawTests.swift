//
//  PilotDrawTests.swift
//  RallyLabTests
//
//  The frozen 24-rally draw (PilotDraw, protocol §3): the seeded draw is the same
//  every time, fills 8 per surface in the strata's order, spreads over recording
//  groups, substitutes and records it when a stratum is empty, leaves a slot unfilled
//  when a surface runs out, fixes the windows from legacy information alone and
//  clamps them; the candidate attributes; the record is never overwritten; the audit
//  rows and their figures.
//

import XCTest
@testable import RallyLab

final class PilotDrawTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-26T20:00:00Z")!

    /// `n` candidates per surface over `groups` recording groups, durations cycling short / mid / long,
    /// every prediction stratum available on some.
    private func candidates(surfaces: [String] = ["beach", "grass", "indoor"], perSurface n: Int = 12, groups: Int = 3) -> [PilotDraw.Candidate] {
        var out: [PilotDraw.Candidate] = []
        for s in surfaces {
            for i in 0..<n {
                let duration = [3.0, 8.0, 15.0][i % 3]
                var attrs: [String] = []
                if duration < PilotDraw.shortMax { attrs.append("short") }
                if duration > PilotDraw.longMin { attrs.append("long") }
                if i % 4 == 0 { attrs.append("farEnd") }
                if i % 5 == 0 { attrs.append("autoFromTrack") }
                if i % 6 == 0 { attrs.append("ambiguous") }
                if i % 7 == 0 { attrs.append("hardCase") }
                let g = (i / 3) % groups
                out.append(PilotDraw.Candidate(video: "\(s)_\(g)", surface: s, group: "\(s)_g\(g)", legacyIndex: i,
                                               legacyStart: Double(i) * 30 + 2, legacyEnd: Double(i) * 30 + 2 + duration, legacyKind: "rally",
                                               attributes: attrs, serveContact: nil, serveApproaching: nil, ballSeenAtStart: nil))
            }
            // One dedicated candidate per prediction / track stratum, so each stratum always has its own.
            for (k, attr) in ["farEnd", "autoFromTrack", "ambiguous", "hardCase"].enumerated() {
                out.append(PilotDraw.Candidate(video: "\(s)_\(k % groups)", surface: s, group: "\(s)_g\(k % groups)", legacyIndex: n + k,
                                               legacyStart: Double(n + k) * 30 + 2, legacyEnd: Double(n + k) * 30 + 10, legacyKind: "rally",
                                               attributes: [attr], serveContact: nil, serveApproaching: nil, ballSeenAtStart: nil))
            }
        }
        return out
    }

    func testTheDrawIsDeterministicAndFillsEightPerSurfaceInStrataOrder() {
        let c = candidates()
        let d1 = PilotDraw.draw(c, durations: [:], seed: 7), d2 = PilotDraw.draw(c, durations: [:], seed: 7)
        XCTAssertEqual(d1.selection, d2.selection, "the same seed and candidates give the same draw")
        XCTAssertNotEqual(d1.selection, PilotDraw.draw(c, durations: [:], seed: 8).selection)
        XCTAssertEqual(d1.selection.count, PilotDraw.size); XCTAssertTrue(d1.unfilled.isEmpty)
        for s in ["beach", "grass", "indoor"] {
            let mine = d1.selection.filter { $0.surface == s }
            XCTAssertEqual(mine.count, PilotDraw.perSurface)
            XCTAssertEqual(mine.map(\.stratum), PilotDraw.strata, "every stratum filled from its own candidates")
            XCTAssertTrue(mine.allSatisfy { $0.substitutedFor == nil })
        }
        XCTAssertEqual(Set(d1.selection.map { "\($0.video)#\($0.legacyIndex)" }).count, 24, "no rally twice")
        XCTAssertEqual(d1.selection.filter(\.repeatReview).count, PilotDraw.repeatCount)
        // Each selected rally really carries its stratum.
        for s in d1.selection {
            let cand = c.first { $0.video == s.video && $0.legacyIndex == s.legacyIndex }!
            XCTAssertTrue(cand.attributes.contains(s.stratum), "\(s.video)#\(s.legacyIndex) drawn for \(s.stratum) has \(cand.attributes)")
        }
    }

    func testTheDrawSpreadsOverRecordingGroupsBeforeRepeatingOne() {
        // Short rallies in every group: the two short slots must come from two different groups.
        let d = PilotDraw.draw(candidates(groups: 3), durations: [:], seed: 1)
        for s in ["beach", "grass", "indoor"] {
            let shorts = d.selection.filter { $0.surface == s && $0.stratum == "short" }
            XCTAssertEqual(Set(shorts.map(\.group)).count, 2, "\(s): short slots spread over groups")
            // Over the 8 slots no group has 3 while another of the surface has fewer than 2 — the spread rule
            // holds at every pick, so the final counts differ by at most one where candidates allowed it.
            let counts = Dictionary(grouping: d.selection.filter { $0.surface == s }, by: \.group).mapValues(\.count)
            XCTAssertLessThanOrEqual(counts.values.max()! - counts.values.min()!, 1, "\(s): \(counts)")
        }
    }

    func testAnEmptyStratumIsSubstitutedAndRecordedAndARunOutSurfaceLeavesASlotUnfilled() {
        // Grass: six mid-length rallies only — no short, no long, no prediction strata.
        var c = candidates(surfaces: ["beach"])
        for i in 0..<6 {
            c.append(PilotDraw.Candidate(video: "grs_\(i)", surface: "grass", group: "grs_g\(i)", legacyIndex: i, legacyStart: 10, legacyEnd: 18, legacyKind: nil,
                                         attributes: [], serveContact: nil, serveApproaching: nil, ballSeenAtStart: nil))
        }
        let d = PilotDraw.draw(c, durations: [:], seed: 3)
        let grass = d.selection.filter { $0.surface == "grass" }
        XCTAssertEqual(grass.count, 6, "six candidates, six drawn")
        XCTAssertTrue(grass.allSatisfy { $0.stratum == "any" && $0.substitutedFor != nil })
        XCTAssertEqual(grass.map(\.substitutedFor), Array(PilotDraw.strata.prefix(6)))
        XCTAssertEqual(d.unfilled, ["grass/ambiguous", "grass/hardCase"])
        XCTAssertEqual(d.selection.filter { $0.surface == "beach" }.count, 8)
    }

    func testWindowsAreFixedFromTheLegacyMarkAndClamped() {
        let c = [PilotDraw.Candidate(video: "v", surface: "beach", group: "g", legacyIndex: 0, legacyStart: 2, legacyEnd: 5, legacyKind: nil, attributes: ["short"], serveContact: nil, serveApproaching: nil, ballSeenAtStart: nil),
                 PilotDraw.Candidate(video: "v", surface: "beach", group: "g", legacyIndex: 1, legacyStart: 50, legacyEnd: 58, legacyKind: nil, attributes: [], serveContact: nil, serveApproaching: nil, ballSeenAtStart: nil)]
        let d = PilotDraw.draw(c, durations: ["v": 60], seed: 1)
        let first = d.selection.first { $0.legacyIndex == 0 }!, second = d.selection.first { $0.legacyIndex == 1 }!
        XCTAssertEqual(first.window, [0, 10], "legacyStart − 5 clamped to 0")
        XCTAssertEqual(second.window, [45, 60], "legacyEnd + 5 clamped to the duration")
        XCTAssertEqual(PilotDraw.draw(c, durations: [:], seed: 1).selection.first { $0.legacyIndex == 1 }!.window, [45, 63], "unknown duration: not clamped")
    }

    func testCandidateAttributesFollowTheProtocol() throws {
        let session = VideoSession(name: "bch_test_01", sourcePath: "/tmp/bch_test_01.mp4", split: "train", addedAt: now, frames: [],
                                   tracks: [TrackedRally(id: UUID(), start: 100, end: 110, points: [], candidates: [], done: true)])
        let marks = [RallyMarkRecord(startTime: 10, endTime: 13, kind: nil, contacts: nil),           // short
                     RallyMarkRecord(startTime: 30, endTime: 50, kind: .rally, contacts: nil),        // long, far end, hard case
                     RallyMarkRecord(startTime: 100, endTime: 110, kind: nil, contacts: nil),         // auto from track
                     RallyMarkRecord(startTime: 60, endTime: 70, kind: .missedServe, contacts: nil),  // not a rally: no candidate
                     RallyMarkRecord(startTime: 0.5, endTime: 8, kind: nil, contacts: nil)]           // at the file's edge: ambiguous
        let entry = PilotDraw.PoolEntry(session: session, marks: marks, labelsSHA256: "abc", group: "bch_test_01")
        let evidence = PilotDraw.Evidence(duration: 200,
                                          predictions: PilotDraw.Predictions(clipsRaw: [], clipsPadded: [], serves: [PilotDraw.Serve(toss: nil, contact: 31.5, end: 33, approaching: true)]),
                                          ball: stride(from: 0.0, to: 200, by: 0.1).map { ($0, $0 >= 30 && $0 < 31 ? false : true) })
        let c = PilotDraw.candidates(entry, evidence: evidence)
        XCTAssertEqual(c.map(\.legacyIndex), [0, 1, 2, 4])
        XCTAssertEqual(c[0].attributes, ["short"])
        XCTAssertEqual(Set(c[1].attributes), ["long", "farEnd", "ambiguous", "hardCase"], "serve 1.5 s after the mark, from the far end, no ball in the first second")
        XCTAssertEqual(c[1].serveContact, 31.5); XCTAssertEqual(c[1].ballSeenAtStart, 0)
        XCTAssertEqual(c[2].attributes, ["autoFromTrack"])
        XCTAssertEqual(c[3].attributes, ["ambiguous"])
        // Without evidence (a dry run) the prediction strata are not judged.
        let dry = PilotDraw.candidates(entry, evidence: nil)
        XCTAssertEqual(Set(dry[1].attributes), ["long"]); XCTAssertNil(dry[1].serveContact)
        XCTAssertEqual(PilotDraw.card(of: "bch_ele_ovc_land_self_02_v3"), "bch_ele_ovc_land_self_02")
        XCTAssertEqual(PilotDraw.card(of: "bch_ele_ovc_land_self_02"), "bch_ele_ovc_land_self_02")
    }

    func testTheFreezeIdentifiesTheConfigurationByContent() {
        let a = PilotDraw.snapshot(of: ProcessorConfig())
        XCTAssertEqual(a, PilotDraw.snapshot(of: ProcessorConfig()), "the same settings give the same text")
        XCTAssertTrue(a.contains("preroll=") && a.contains("heatmapHop="), a.prefix(200).description)
        var changed = ProcessorConfig(); changed.preroll += 0.5
        XCTAssertNotEqual(PilotDraw.sha256(PilotDraw.snapshot(of: changed)), PilotDraw.sha256(a), "one knob moved: another identity")
        let camera = ProcessorConfig().withCamera(of: VideoSession(name: "bch_ele_ovc_land_self_02", sourcePath: "/x.mp4", split: "train", addedAt: now, frames: []))
        XCTAssertNotEqual(PilotDraw.snapshot(of: camera), a, "the recording's camera setup is part of the effective configuration")
        XCTAssertEqual(PilotDraw.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNil(PilotDraw.digest(ofModel: URL(fileURLWithPath: "/nonexistent/model.mlmodelc")))
    }

    func testTheRecordIsNeverOverwrittenAndTheLatestIsRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let d = PilotDraw.draw(candidates(), durations: [:], seed: 5)
        var record = PilotDraw.Record(id: "EXP-20261026-b2-boundary-pilot", createdAt: EventReview.stamp(now), project: "Scratch", seed: 5,
                                      manifestHashes: .init(projectJson: "p", sessions: "s", validationJson: "v"), model: "m", pool: [], candidates: candidates(),
                                      selection: d.selection, unfilled: d.unfilled, supersedes: nil, dryRun: false, note: nil)
        XCTAssertNil(try PilotDraw.latest(in: root))
        let out = try PilotDraw.write(record, in: root, stamp: "20261026-200000")
        XCTAssertEqual(out.json.lastPathComponent, "20261026-200000-pilot.json")
        XCTAssertThrowsError(try PilotDraw.write(record, in: root, stamp: "20261026-200000"), "the same stamp is refused")
        XCTAssertEqual(try PilotDraw.latest(in: root), record)
        record.seed = 6
        _ = try PilotDraw.write(record, in: root, stamp: "20261026-210000")
        XCTAssertEqual(PilotDraw.existing(in: root).count, 2)
        XCTAssertEqual(try PilotDraw.latest(in: root)?.seed, 6, "the newest record is the current one; the older stays")
        let md = try String(contentsOf: out.md, encoding: .utf8)
        XCTAssertTrue(md.contains("| 1 | ") && md.contains("Strata available per surface"))
    }

    func testTheAuditReportsEveryEventWithItsSecondReviewAndFlags() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("bch_a.mp4")
        let session = VideoSession(name: "bch_a", sourcePath: video.path, split: "train", addedAt: now, frames: [])
        // Two selected rallies: one reviewed on the Mac with a second review from the phone, one not reviewed.
        let selection = [PilotDraw.Selected(video: "bch_a", legacyIndex: 0, surface: "beach", group: "bch_a", stratum: "short", substitutedFor: nil, legacyStart: 10, legacyEnd: 13, window: [5, 18], repeatReview: true),
                         PilotDraw.Selected(video: "bch_a", legacyIndex: 1, surface: "beach", group: "bch_a", stratum: "long", substitutedFor: nil, legacyStart: 30, legacyEnd: 50, window: [25, 55], repeatReview: false)]
        let record = PilotDraw.Record(id: "EXP-x", createdAt: EventReview.stamp(now), project: "T", seed: 1, manifestHashes: .init(), model: "m", pool: [], candidates: [],
                                      selection: selection, unfilled: [], supersedes: nil, dryRun: false, note: nil)
        var file = EventReview.File(video: "bch_a", sourceFingerprint: "file:x", frameRate: 30, durationSec: 60, tool: "RallyLab 1")
        // The file was created on the Mac, but this rally's review was committed on the phone: the row says so.
        var rally = EventReview.Rally(rallyId: UUID(), legacyIndex: 0, legacyStart: 10, legacyEnd: 13, kind: .rally,
                                      contact: .init(earliest: 10.4, latest: 10.433), dead: .init(earliest: 12.8, latest: 13.1, visibility: .occluded),
                                      annotator: "BW", reviewedAt: EventReview.stamp(now), tool: "Labeler 1")
        rally.secondReview = .init(annotator: "BW", reviewedAt: EventReview.stamp(now.addingTimeInterval(90000)), method: EventReview.SecondReview.sameReviewer,
                                   contact: .init(earliest: 10.433, latest: 10.433), dead: .init(earliest: 12.6, latest: 12.6), tool: "RallyLab 1")
        EventReview.Mutation.upsert(rally, in: &file)
        EventReview.Mutation.markReviewed(from: 0, to: 20, in: &file, at: now, annotator: "BW")
        try EventReview.write(file, to: EventReview.url(forVideo: video))

        let audit = try PilotDraw.audit(record, root: root, sessions: [session])
        XCTAssertEqual(audit.rows.count, 3, "two events for the reviewed rally, one row for the unreviewed one")
        let contact = audit.rows[0], dead = audit.rows[1], missing = audit.rows[2]
        XCTAssertEqual(contact.event, "contact"); XCTAssertEqual(contact.legacyTime, 10); XCTAssertEqual(contact.earliest, 10.4)
        XCTAssertEqual(contact.width!, 0.033, accuracy: 1e-9); XCTAssertEqual(contact.tool, "Labeler 1", "the rally's own tool, not the file's"); XCTAssertEqual(contact.secondTool, "RallyLab 1")
        XCTAssertEqual(contact.secondDelta!, 10.433 - 10.4165, accuracy: 1e-9); XCTAssertFalse(contact.adjudication)
        XCTAssertEqual(dead.flags, "ambiguous_dead"); XCTAssertEqual(dead.visibility, "occluded")
        XCTAssertEqual(dead.secondDelta!, 12.6 - 12.95, accuracy: 1e-9); XCTAssertTrue(dead.adjudication, "0.35 s apart: adjudication")
        XCTAssertFalse(dead.windowExceeded)
        XCTAssertEqual(missing.status, "not_reviewed"); XCTAssertEqual(missing.legacyIndex, 1)
        XCTAssertTrue(audit.csv.hasPrefix(PilotDraw.AuditRow.header + "\n"))
        XCTAssertEqual(audit.csv.split(separator: "\n").count, 4)
        XCTAssertTrue(audit.summary.contains { $0.contains("iPhone → Mac") }, "the platform pair comes from the rallies' own tools: \(audit.summary)")
        XCTAssertEqual(PilotDraw.platform(""), "unknown", "a record that kept no per-rally tool reports no platform")
        XCTAssertTrue(audit.summary.contains { $0.hasPrefix("beach contact") && $0.contains("legacy − reviewed median -0.41") && $0.contains("ambiguous 0/1") }, "\(audit.summary)")
        XCTAssertTrue(audit.summary.contains { $0.hasPrefix("beach dead") && $0.contains("ambiguous 1/1") }, "\(audit.summary)")
    }

    // MARK: - The blind rule both apps enforce (PilotBlind)

    func testLegacyMarksInsideAnUncommittedPilotWindowAreNeverShown() {
        let w = PilotWindow(video: "v", legacyIndex: 7, legacyStart: 10, legacyEnd: 13, window: [5, 18], stratum: "short", repeatReview: false)
        // The device's own numbering of legacy marks does not matter: the rule works on times.
        let marks: [(start: Double, end: Double)] = [(1, 3), (4, 6), (10, 13), (17, 20), (30, 33)]
        var f = EventReview.File(video: "v", sourceFingerprint: "file:x", frameRate: 30, durationSec: 60, tool: "t")
        XCTAssertEqual(PilotBlind.visible(marks, windows: [w], record: f), [true, false, false, false, true], "every mark touching the window is hidden before the first review")
        XCTAssertEqual(PilotBlind.visible(marks, windows: [w], record: nil), [true, false, false, false, true], "no record yet: blind")
        // A reviewed rally elsewhere does not unblind it; one overlapping the legacy interval does.
        let now = ISO8601DateFormatter().date(from: "2026-10-26T20:00:00Z")!
        EventReview.Mutation.upsert(EventReview.Rally(rallyId: UUID(), kind: .rally, contact: .init(earliest: 40, latest: 40), dead: .init(earliest: 42, latest: 42), annotator: "BW", reviewedAt: EventReview.stamp(now)), in: &f)
        XCTAssertFalse(PilotBlind.firstReviewCommitted(w, in: f))
        let answer = EventReview.Rally(rallyId: UUID(), kind: .rally, contact: .init(earliest: 10.4, latest: 10.4), dead: .init(earliest: 12.9, latest: 12.9), annotator: "BW", reviewedAt: EventReview.stamp(now))
        EventReview.Mutation.upsert(answer, in: &f)
        XCTAssertTrue(PilotBlind.firstReviewCommitted(w, in: f))
        XCTAssertEqual(PilotBlind.answer(to: w, in: f)?.rallyId, answer.rallyId)
        XCTAssertEqual(PilotBlind.visible(marks, windows: [w], record: f), [true, true, true, true, true], "committed: the marks may be compared")
        // Withdrawn answers do not count.
        _ = EventReview.Mutation.withdraw(answer.rallyId, in: &f, at: now, annotator: "BW")
        XCTAssertFalse(PilotBlind.firstReviewCommitted(w, in: f))
    }

    func testThePublishedDrawCarriesTheFrozenSelection() throws {
        let s = PilotDraw.Selected(video: "v", legacyIndex: 2, surface: "beach", group: "g", stratum: "long", substitutedFor: nil, legacyStart: 30, legacyEnd: 45, window: [25, 50], repeatReview: true)
        let w = s.pilotWindow
        XCTAssertEqual(w, PilotWindow(video: "v", legacyIndex: 2, legacyStart: 30, legacyEnd: 45, window: [25, 50], stratum: "long", repeatReview: true))
        // The selection travels with camelCase keys (what the server's shape check reads).
        let json = String(decoding: try JSONEncoder().encode([w]), as: UTF8.self)
        XCTAssertTrue(json.contains("\"legacyIndex\":2") && json.contains("\"window\":[25,50]"), json)
        let p = PilotPublication(id: "EXP-1", project: "Scratch", recordSha256: String(repeating: "a", count: 64), selectionDigest: "d", selection: [w], publishedAt: nil)
        XCTAssertEqual(p.windows(for: "v"), [w]); XCTAssertEqual(p.windows(for: "other"), [])
    }
}
