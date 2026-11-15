//
//  RallyClassifierTrustedNegatives.swift
//  RallyLab
//
//  Which unmarked time of a recording the rally-classifier dataset may label NON_RALLY —
//  the adopted gate G7 (owner, 2026-11-14: "Only explicitly reviewed clean intervals or
//  eligible Stage 1 verified coverage may supply trusted negatives"; "Do not allow edited
//  footage to supply full-video negative labels"; "Do not fabricate human review or
//  automatically certify unmarked intervals").
//
//  A declaration that every rally is marked no longer makes the rest of a recording a
//  negative. The only source here is the recording's negative-coverage audit record
//  (`<video>.coverageaudit.json`, CoverageAudit): the intervals a person watched whole and
//  called clean, once the blind repeat and its resolution are counted. Because a clean
//  interval was watched whole, any part of it is clean, so when marks change afterwards
//  the trusted time is (the time unmarked now) ∩ (the intervals reviewed clean); time that
//  was under a mark at the review and is unmarked now lies in no clean interval and stays
//  UNKNOWN. Nothing here writes a record, plays a video or runs a model.
//
//  A record supplies nothing — and the report says why — when:
//   - there is none (not an error: the recording contributes its rallies only);
//   - it is void: it fails `CoverageAudit.validate`, it is another recording's, the
//     recording's file is not the one that was reviewed (`sourceFingerprint`), or the
//     draw it belongs to is not in the project as the record hashed it;
//   - the recording is not eligible for full-video negatives (edited or restricted
//     footage), whatever the record says;
//   - the audit itself found edited footage in a recording typed continuous and the
//     footage type has not been confirmed again since (audit protocol D6).
//  A record that can't be read at all throws: the caller leaves the recording out, and
//  an unreadable record is never taken as "no audit". A withheld recording never gets
//  here — the plan leaves it out by every identity before its record is looked for.
//

import Foundation

extension RallyClassifierExporter {
    /// What a recording's negative-coverage audit record gives the dataset.
    struct AuditUse: Codable, Equatable {
        /// `audited_clean` / `partial` / `contaminated` from the record and its draw; `none` without a record that counts.
        var state = "none"
        var auditSha256: String?
        var drawId: String?
        /// The intervals the record says clean after the repeat and its resolution, as drawn. Trusted only where
        /// still unmarked (`trustedSpans`); empty when the record supplies nothing.
        var clean: [CoverageAudit.Span] = []
        /// The findings that count, by kind.
        var findings: [String: Int] = [:]
        /// Why the record supplies nothing, for the report; nil when it is used.
        var note: String?
    }

    /// The audit record beside `video` as the dataset may use it (see the file header). `content` is the
    /// recording's file as it is now; `negatives` whether the recording is eligible for full-video negatives;
    /// `typeConfirmedAt` when a person last confirmed its footage type.
    static func auditUse(of name: String, video: URL, content: String, negatives: Bool, typeConfirmedAt: String?, projectDir: URL) throws -> AuditUse {
        let sidecar = CoverageAudit.url(forVideo: video)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return AuditUse(note: "no coverage-audit record: positives only") }
        func void(_ why: String) -> AuditUse { AuditUse(note: "coverage-audit record void (\(why)): treated as absent, positives only") }
        // Hashed before and after the read, so the hash the manifest carries is of the bytes that were read.
        let sha = DatasetSplitManifest.sha256(of: sidecar)
        let file: CoverageAudit.File
        do { file = try CoverageAudit.read(sidecar) } catch CoverageAudit.Failure.invalid(let why) { return void("not valid — \(why)") }
        guard let sha, sha == DatasetSplitManifest.sha256(of: sidecar) else { throw CoverageAudit.Failure.unreadable("\(sidecar.lastPathComponent) changed while it was read") }
        guard file.recordingId == name else { return void("it is \(file.recordingId)'s record") }
        guard file.sourceFingerprint == content else { return void("the recording's file is not the one that was reviewed") }
        // The draw the record belongs to, by the hash the record carries: its intervals are what "every interval
        // reviewed" means, and a clean verdict counts only on an interval as it was drawn.
        let draws = (try? FileManager.default.contentsOfDirectory(at: CoverageAudit.drawsDirectory(in: projectDir), includingPropertiesForKeys: nil)) ?? []
        guard let drawURL = draws.first(where: { $0.pathExtension == "json" && DatasetSplitManifest.sha256(of: $0) == file.drawSha256 }) else {
            return void("its draw \(file.drawId) is not in the project's manifests/coverage-audit as the record hashed it")
        }
        let draw: CoverageAudit.Draw
        do { draw = try CoverageAudit.loadDraw(drawURL).draw } catch { return void("its draw can't be used — \(error.localizedDescription)") }
        guard draw.drawId == file.drawId, let recording = draw.recording(name), recording.contentFingerprint == content else {
            return void("draw \(draw.drawId) does not hold this recording's file")
        }

        var use = AuditUse(state: CoverageAudit.state(of: file, intervals: recording.intervals).name, auditSha256: sha, drawId: file.drawId)
        var editedFoundAt: Date?
        for interval in recording.intervals where file.review(interval.index)?.span == interval.span {
            guard case .settled(let verdict, let findings, let playedWhole) = CoverageAudit.standing(of: interval.index, in: file) else { continue }
            for f in findings { use.findings[f.kind.rawValue, default: 0] += 1 }
            if verdict == .clean, playedWhole { use.clean.append(interval.span) }
            if findings.contains(where: { $0.kind == .editedFootage }) {
                let looks = [file.review(interval.index)?.reviewedAt, file.repeatReview(interval.index)?.reviewedAt, file.resolution(interval.index)?.resolvedAt]
                editedFoundAt = (looks.compactMap { $0.flatMap(CoverageAudit.date) } + [editedFoundAt].compactMap { $0 }).max()
            }
        }
        if !negatives {
            use.clean = []
            use.note = "coverage-audit record not used: the recording is not eligible for full-video negatives (edited or restricted footage supplies none)"
        } else if let editedFoundAt, !(typeConfirmedAt.flatMap(CoverageAudit.date).map { $0 > editedFoundAt } ?? false) {
            use.clean = []
            use.note = "the audit found edited footage and the footage type has not been confirmed again since: no negatives until it is"
        }
        return use
    }

    /// The time of a recording that may be NON_RALLY (D7): unmarked now — no mark of any kind and no cut range
    /// covers it — and inside an interval reviewed clean; in time order, inside `0 ..< durationTicks`.
    static func trustedSpans(clean: [CoverageAudit.Span], truth: RallyTruth, durationTicks: Int) -> [CoverageAudit.Span] {
        guard !clean.isEmpty else { return [] }
        let unmarked = CoverageAudit.unmarkedIntervals(truth, durationTicks: durationTicks)
        return clean.flatMap { c in
            unmarked.compactMap { u -> CoverageAudit.Span? in
                let start = max(c.startTick, u.startTick), end = min(c.endTick, u.endTick)
                return start < end ? CoverageAudit.Span(startTick: start, endTick: end) : nil
            }
        }.sorted { $0.startTick < $1.startTick }
    }
}
