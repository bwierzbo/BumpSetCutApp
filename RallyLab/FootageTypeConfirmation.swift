//
//  FootageTypeConfirmation.swift
//  RallyLab
//
//  The recording-type confirmation at the end of the marking pass (owner,
//  2026-11-03: manual-first footage characterisation). Once every visible
//  rally is marked, the person says what the recording is — a continuous
//  recording, an edited one, or unknown (not yet verified) — and the
//  footage-properties record (FootageProperties, the authoritative record
//  for characterising footage) takes that and nothing else. Four facts stay
//  apart, as the direction asks: every visible rally marked (the session's
//  declaration); the footage type confirmed (the record); the timeline's
//  coverage verified (the Stage 1 record); what each model may use
//  (TrainingEligibility — shown, never overridden). Nothing is inferred: a
//  recording with no cut is not promoted to continuous, an X press never
//  makes a recording edited (a cut range is an exclusion, not a
//  characterisation — D-030, D-031 §11.4), and a type nobody confirmed stays
//  unknown. A record that exists but can't be read refuses the confirmation
//  (fail closed): nothing is written over it.
//

import Foundation

enum FootageTypeConfirmation {
    /// The recording as the step reads it: the few session facts it needs, so the reads can run off the main actor.
    struct Recording: Equatable, Sendable {
        var name: String
        var sourcePath: String
        /// The cut ranges, normalised (D-030).
        var cuts: [CutRange]
        /// The legacy declaration (session.ralliesMarked): every visible rally marked.
        var ralliesMarked: Bool

        init(name: String, sourcePath: String, cuts: [CutRange], ralliesMarked: Bool) {
            self.name = name; self.sourcePath = sourcePath; self.cuts = cuts; self.ralliesMarked = ralliesMarked
        }

        init(_ session: VideoSession) {
            self.init(name: session.name, sourcePath: session.sourcePath, cuts: session.cutRanges, ralliesMarked: session.ralliesMarked ?? false)
        }
    }

    /// What the step shows, read from the project's files.
    struct Facts: Equatable, Sendable {
        var video: String
        var cuts: [CutRange]
        /// Seconds the cuts exclude — within the duration when it is known.
        var cutSeconds: Double
        var durationSec: Double?
        var ralliesMarked: Bool
        /// The Stage 1 record's reviewed coverage over the duration less the cuts (0…1); nil without a usable record.
        var verifiedCoverage: Double?
        var stage1Complete: Bool
        /// The record on file, when it is this file's: its fingerprint is the card's, or it names none.
        var record: FootageProperties.File?
        /// The record on file is another file's (its fingerprint is not the card's): confirming starts a record of this one.
        var recordOfAnotherFile: String?
        /// The record exists but can't be read: nothing is confirmed over it.
        var recordProblem: String?
        var stage1Problem: String?
        /// The card's fingerprint (ReservedVideos.effectiveFingerprint), which the record is bound to; nil when the card has none.
        var sourceFingerprint: String?

        /// The type on file; unknown without a usable record.
        var recordingType: FootageProperties.RecordingType { record?.recordingType ?? .unknown }
    }

    /// The facts about `recording` in the project at `root`. File work — the Stage 1 record sits beside the footage
    /// and its identity check hashes the file — so call it off the main actor. `duration`: the video's length as the
    /// player knows it, for the cut seconds when there is no Stage 1 record.
    static func facts(_ recording: Recording, sourceFingerprint: String?, duration: Double? = nil, in root: URL) -> Facts {
        let cuts = recording.cuts
        var f = Facts(video: recording.name, cuts: cuts, cutSeconds: duration.map { cuts.seconds(within: $0) } ?? cuts.reduce(0) { $0 + $1.seconds },
                      durationSec: duration, ralliesMarked: recording.ralliesMarked, verifiedCoverage: nil, stage1Complete: false,
                      record: nil, recordOfAnotherFile: nil, recordProblem: nil, stage1Problem: nil, sourceFingerprint: sourceFingerprint)
        do {
            if let record = try FootageProperties.Store(root: root).load(recording.name) {
                if let other = anotherFile(record, sourceFingerprint: sourceFingerprint) { f.recordOfAnotherFile = other } else { f.record = record }
            }
        } catch {
            f.recordProblem = error.localizedDescription
        }
        let session = VideoSession(name: recording.name, sourcePath: recording.sourcePath, split: "train", addedAt: Date(), frames: [])
        let eventsURL = EventReview.url(forVideo: session.sourceURL)
        if FileManager.default.fileExists(atPath: eventsURL.path) {
            do {
                let file = try EventReview.read(eventsURL)
                if let problem = EventReview.identityProblem(of: file, for: session) {
                    f.stage1Problem = problem.localizedDescription
                } else {
                    f.durationSec = file.durationSec
                    f.cutSeconds = cuts.seconds(within: file.durationSec)
                    let reviewed = EventInventory.reviewedSeconds(file.coverage, cuts: cuts)
                    f.verifiedCoverage = min(1, reviewed / max(file.durationSec - f.cutSeconds, 0.001))
                    f.stage1Complete = file.stage1Complete != nil
                }
            } catch {
                f.stage1Problem = error.localizedDescription
            }
        }
        return f
    }

    /// Why `record` is another file's, not this recording's: it is bound to a fingerprint that is not the card's
    /// (the recording was replaced under the same id) — the source index's rule (SourceRegistry.build). nil when
    /// the record is this file's, or names no fingerprint (bound by name).
    static func anotherFile(_ record: FootageProperties.File, sourceFingerprint: String?) -> String? {
        guard let recorded = record.sourceFingerprint, recorded != sourceFingerprint else { return nil }
        return "recorded for \(recorded); the project card has \(sourceFingerprint ?? "no fingerprint")"
    }

    /// The card's fingerprint for `video` (a session name: the safe form of the video id) — what the source index
    /// binds a footage-properties record to; nil when the recording has no card or the card no fingerprint.
    static func sourceFingerprint(of video: String, in project: Project?) -> String? {
        for clip in project?.clips ?? [] {
            for source in clip.videos where DatasetStore.safeName(clip.videoId(of: source)) == video {
                return ReservedVideos.effectiveFingerprint(source)
            }
        }
        return nil
    }

    /// The record as confirming `type` would leave it: the one on file with the type set, or — with none on file,
    /// or another file's — a record of this file (what `Store.confirmRecordingType` writes).
    static func prospectiveRecord(_ type: FootageProperties.RecordingType, facts: Facts, at: String) -> FootageProperties.File {
        var file = facts.record ?? FootageProperties.File(video: facts.video, sourceFingerprint: facts.sourceFingerprint, updatedAt: at)
        file.recordingType = type
        return file
    }

    /// What each model may use once `type` is confirmed, with whatever else the record holds: the policy's verdict
    /// (TrainingEligibility), not the step's. An unreadable record stays what it is — quarantined.
    static func preview(_ type: FootageProperties.RecordingType, facts: Facts, admission: SourceRegistry.Admission, at: String) -> TrainingEligibility.Assessment {
        if let why = facts.recordProblem { return TrainingEligibility.assess(admission: admission, properties: nil, unreadableReason: why) }
        return TrainingEligibility.assess(admission: admission, properties: prospectiveRecord(type, facts: facts, at: at))
    }

    /// The recording's admission as the source index will judge it once the confirmation is written: the index
    /// built from the project's records with the prospective record in place of the one on file — so a record of
    /// another file, which quarantines the recording today, does not show as the consequence of confirming
    /// (confirming replaces it), while the reservations and the lineage judge as they do (Codex on #140). The
    /// admission does not depend on the type chosen. An unreadable record is left as it is: the confirmation is
    /// refused over it. File work (SourceRegistry.inputs): call off the main actor.
    static func prospectiveAdmission(for facts: Facts, in root: URL, at: String) throws -> SourceRegistry.Admission? {
        var inputs = try SourceRegistry.inputs(root: root)
        let name = DatasetStore.safeName(facts.video)
        if facts.recordProblem == nil {
            inputs.properties[name] = prospectiveRecord(facts.recordingType, facts: facts, at: at)
            inputs.unreadableProperties[name] = nil
        }
        return SourceRegistry.build(inputs).sources.first { $0.video == facts.video }?.admission
    }

    /// The person's confirmation, written into the project `opening` was opened on — only while that opening still
    /// holds: the recording was marked in that project, and a project opened meanwhile gets nothing of it.
    @MainActor
    @discardableResult
    static func confirm(_ type: FootageProperties.RecordingType, video: String, under opening: ProjectsModel.Opening, projects: ProjectsModel,
                        by: String = NSUserName(), at: String = EventReview.stamp(Date())) throws -> FootageProperties.File {
        try projects.require(opening)
        let fingerprint = sourceFingerprint(of: video, in: projects.project)
        return try FootageProperties.Store(root: opening.root).confirmRecordingType(type, video: video, sourceFingerprint: fingerprint, by: by, at: at)
    }
}
